// Licensed under GPL-3.0. See LICENSE.
//
//  AdultDomainList.swift
//  NookBlocker
//
//  The adult-content domain list: OISD NSFW (https://oisd.nl, GPL-3.0), about half a million
//  domains. A snapshot ships in the bundle as a HashedDomainList, so it works on first launch
//  with no network; a newer copy is fetched in the background every few days and kept in
//  ~/Library/Application Support/<bundle id>/SiteBlocking/. scripts/refresh-adult-domains.sh
//  renews the bundled snapshot.
//

import Foundation
import Observation
import OSLog

@MainActor
@Observable
public final class AdultDomainList {
    public struct Info: Codable, Equatable, Sendable {
        public var count: Int
        /// When this copy was fetched from the source.
        public var updated: Date
        public var source: String
        var etag: String?
    }

    /// One domain per line, each standing for its subdomains too.
    public static let source = URL(string: "https://nsfw.oisd.nl/domainswild2")!
    public static let sourceName = "OISD NSFW"
    /// How old the copy in use may get before a new one is fetched.
    static let updateInterval: TimeInterval = 3 * 24 * 3600
    /// How often to look at whether an update is due.
    private static let checkInterval: TimeInterval = 3600
    /// The list is 9 MB of text; anything far past that is not the list.
    private static let maxDownloadBytes = 64 * 1024 * 1024
    private static let minimumCount = 10_000

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "SiteBlocking")

    /// The copy in use: how many domains and how fresh. Nil until the list is first needed.
    public private(set) var info: Info?
    public private(set) var isUpdating = false

    @ObservationIgnored private var list: HashedDomainList?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let bundled: (list: URL, info: URL)?
    @ObservationIgnored private let session: URLSession

    public convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = support.appendingPathComponent("\(Bundle.main.bundleIdentifier ?? "Nook")/SiteBlocking", isDirectory: true)
        self.init(directory: directory, bundled: Self.bundledFiles)
    }

    init(directory: URL, bundled: (list: URL, info: URL)?) {
        self.directory = directory
        self.bundled = bundled
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    static var bundledFiles: (list: URL, info: URL)? {
        guard let list = Bundle.module.url(forResource: "adult-domains", withExtension: "bin", subdirectory: "Resources"),
              let info = Bundle.module.url(forResource: "adult-domains", withExtension: "json", subdirectory: "Resources")
        else { return nil }
        return (list, info)
    }

    private var cachedList: URL { directory.appendingPathComponent("adult-domains.bin") }
    private var cachedInfo: URL { directory.appendingPathComponent("adult-domains.json") }
    private var checkedStamp: URL { directory.appendingPathComponent("adult-domains.checked") }

    // MARK: - Reading

    /// The list, mapped from disk the first time it is asked for. Nothing is parsed and nothing
    /// is read ahead, so the first navigation of a launch does not wait on it.
    public var current: HashedDomainList? {
        loadIfNeeded()
        return list
    }

    public func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        let downloaded = Self.read(list: cachedList, info: cachedInfo)
        let shipped = bundled.flatMap { Self.read(list: $0.list, info: $0.info) }
        // An app update can ship a newer snapshot than the last download.
        let newest = [downloaded, shipped].compactMap { $0 }.max { $0.info.updated < $1.info.updated }
        list = newest?.list
        info = newest?.info
        if newest == nil { Self.log.error("No adult domain list could be read; the Adult Content category blocks nothing") }
    }

    private static func read(list: URL, info: URL) -> (list: HashedDomainList, info: Info)? {
        guard let data = try? Data(contentsOf: info), let info = try? decoder.decode(Info.self, from: data),
              let list = HashedDomainList(contentsOf: list) else { return nil }
        return (list, info)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    // MARK: - Updating

    /// Looks for a due update shortly after the first use and then once an hour. `wanted` says
    /// whether the category is on; nothing is fetched while it is off.
    func startAutoUpdate(wanted: @escaping @MainActor () -> Bool) {
        guard timer == nil else { return }
        let check: @MainActor () -> Void = { [weak self] in
            guard wanted() else { return }
            Task { await self?.update() }
        }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { _ in
            Task { @MainActor in check() }
        }
        timer.tolerance = 15 * 60
        self.timer = timer
        // Not during launch: the bundled or cached copy is already in use.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(45))
            check()
        }
    }

    private var isDue: Bool {
        guard let stamp = try? String(contentsOf: checkedStamp, encoding: .utf8), let checked = TimeInterval(stamp) else {
            // Never checked: the bundled snapshot's own age decides.
            return info.map { Date().timeIntervalSince($0.updated) >= Self.updateInterval } ?? true
        }
        return Date().timeIntervalSince1970 - checked >= Self.updateInterval
    }

    private func markChecked() {
        try? String(Date().timeIntervalSince1970).write(to: checkedStamp, atomically: true, encoding: .utf8)
    }

    /// Fetches the list when it is due, or now when `force` is set. Returns true when a new copy
    /// went into use. A failed or implausible download leaves the copy in use as it was.
    @discardableResult
    public func update(force: Bool = false) async -> Bool {
        loadIfNeeded()
        guard !isUpdating, force || isDue else { return false }
        isUpdating = true
        defer { isUpdating = false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var request = URLRequest(url: Self.source)
        // 2.5 MB compressed. An automatic check waits for a network that is not metered.
        if !force {
            request.allowsConstrainedNetworkAccess = false
            #if os(iOS)
            request.allowsExpensiveNetworkAccess = false
            #endif
        }
        if let etag = info?.etag, FileManager.default.fileExists(atPath: cachedList.path) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (file, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: file) }
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 304 {
                markChecked()
                return false
            }
            guard http.statusCode == 200 else {
                Self.log.warning("Adult domain list: HTTP \(http.statusCode)")
                return false
            }
            let limit = Self.maxDownloadBytes
            let encoded = await Task.detached(priority: .utility) { () -> Data? in
                guard let text = try? Data(contentsOf: file, options: .alwaysMapped), text.count <= limit else { return nil }
                return HashedDomainList.encode(HashedDomainList.hashes(inListText: text))
            }.value
            guard let encoded, let fresh = HashedDomainList(data: encoded) else {
                Self.log.warning("Adult domain list: download could not be read, keeping the copy in use")
                return false
            }
            // A truncated or emptied list must not quietly unblock everything.
            guard fresh.count >= max(Self.minimumCount, (list?.count ?? 0) / 2) else {
                Self.log.warning("Adult domain list: only \(fresh.count) domains, keeping the copy in use")
                return false
            }
            // Whole seconds, which is what the saved file keeps.
            let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
            let newInfo = Info(count: fresh.count, updated: now, source: Self.source.absoluteString,
                               etag: http.value(forHTTPHeaderField: "ETag"))
            // Atomic writes replace the file, so the mapping of the old copy stays valid.
            try encoded.write(to: cachedList, options: .atomic)
            try Self.encoder.encode(newInfo).write(to: cachedInfo, options: .atomic)
            markChecked()
            list = HashedDomainList(contentsOf: cachedList) ?? fresh
            info = newInfo
            Self.log.info("Adult domain list updated: \(fresh.count) domains")
            return true
        } catch {
            Self.log.error("Adult domain list: download failed: \(error.localizedDescription)")
            return false
        }
    }
}
