// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+ChromeImport.swift
//  Nook
//
//  Applies a Google Chrome profile to one space: cookies into the space's website data store,
//  history into the history store, bookmarks into one pinned folder, extensions through the
//  Chrome Web Store. `Chrome.swift` does the reading.
//

import Foundation
import OSLog
import NookTabsCore
import NookWeb
import WebKit

struct ChromeImportOptions {
    var profile: ChromeProfile
    var history = true
    var cookies = true
    var bookmarks = false
}

/// Where an import is, for the dialog's progress line.
enum ChromeImportStep: Equatable {
    /// macOS is asking the person to let Nook read Chrome's key.
    case keychain
    case cookies
    case bookmarks
    case history(done: Int, total: Int)
}

extension BrowserManager {
    /// History visits per write. Each batch is saved before the next is read, so reads and other
    /// writes get a turn in between and a stop takes effect within one batch.
    private static let chromeHistoryBatch = 1000

    private static let chromeImportLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "Import")

    /// A regular window, as the other imports use: never a private one, and during onboarding an
    /// unregistered state that still targets the main tree.
    private var chromeImportWindow: BrowserWindowState {
        windowRegistry?.mostRecentRegularWindow ?? BrowserWindowState()
    }

    private func chromeImportSpaceID(_ window: BrowserWindowState) -> UUID? {
        window.spaceID ?? tabs.orderedSpaces.first?.id
    }

    /// The space a Chrome import lands in. Spaces keep their own logins and history, so the
    /// dialog names it.
    var chromeImportSpaceName: String? {
        chromeImportSpaceID(chromeImportWindow).flatMap { tabs.space($0)?.name }
    }

    /// Brings one Chrome profile into the current space: cookies first, since that is the step
    /// macOS interrupts with a keychain prompt, then bookmarks, then history, which takes longest.
    /// A part that fails is reported in the summary and the rest still run. Cancelling the
    /// calling task stops after the step or history batch in progress.
    func importChromeData(_ options: ChromeImportOptions,
                          progress: @escaping @MainActor (ChromeImportStep) -> Void = { _ in }) async -> ChromeImportSummary {
        var summary = ChromeImportSummary()
        let window = chromeImportWindow
        guard let spaceID = chromeImportSpaceID(window), let profile = tabs.profile(forSpace: spaceID) else {
            summary.problems.append("Nook has no space to import into.")
            return summary
        }

        if options.cookies {
            progress(.keychain)
            await importChromeCookies(from: options.profile, into: profile.dataStore.httpCookieStore, summary: &summary, progress: progress)
        }
        if options.bookmarks, !Task.isCancelled {
            progress(.bookmarks)
            importChromeBookmarks(importManager.readChromeBookmarks(in: options.profile), window: window, spaceID: spaceID, summary: &summary)
        }
        if options.history, !Task.isCancelled {
            await importChromeHistory(from: options.profile, profileID: profile.id, summary: &summary, progress: progress)
        }
        summary.wasStopped = Task.isCancelled
        // Counts only: what was read never reaches the log.
        Self.chromeImportLog.notice("Chrome import: \(summary.visits) visits, \(summary.cookies) cookies, \(summary.cookiesSkipped) cookies skipped, \(summary.bookmarks) bookmarks, \(summary.problems.count) problems")
        return summary
    }

    /// Queues Chrome Web Store extensions for installation and returns how many were new. Each
    /// shows its permission sheet in the dialog layer, so the import dialog calls this as it closes.
    @discardableResult
    func queueChromeExtensions(_ ids: [String]) -> Int {
        let installed = Set(extensionManager?.installedExtensions.map(\.id) ?? [])
        let new = ids.filter { !installed.contains($0) && !pendingExtensionImports.contains($0) }
        pendingExtensionImports += new
        installPendingExtensionImports()
        return new.count
    }

    // MARK: - Cookies

    private func importChromeCookies(from chrome: ChromeProfile, into store: WKHTTPCookieStore,
                                     summary: inout ChromeImportSummary,
                                     progress: @MainActor (ChromeImportStep) -> Void) async {
        // Newer Chrome builds keep the file under Network/, as Windows already does.
        let candidates = ["Network/Cookies", "Cookies"].map { chrome.url.appendingPathComponent($0) }
        let source = candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[1]
        do {
            // Off the main thread: the keychain prompt blocks until the person answers it. The
            // file is copied first, so a profile without cookies never raises the prompt.
            let read = try await Task.detached(priority: .userInitiated) {
                let database = try ChromeDatabase(copying: source)
                let key = chromeCookieKey(password: try chromeSafeStoragePassword())
                return try readChromeCookies(database, key: key)
            }.value
            progress(.cookies)
            var unusable = 0
            for cookie in read.cookies {
                guard let cookie = httpCookie(from: cookie) else { unusable += 1; continue }
                await store.setCookie(cookie)
                summary.cookies += 1
            }
            summary.cookiesSkipped = read.skipped + unusable
            if read.cookies.isEmpty, read.undecryptable > 0 {
                summary.problems.append("Cookies were not imported. The key in the keychain did not decrypt this profile's cookies.")
            }
        } catch {
            let reason = (error as? ChromeImportError)?.message ?? "Chrome's Cookies file could not be read."
            summary.problems.append("Cookies were not imported. \(reason)")
        }
    }

    // MARK: - History

    /// Chrome's visits from the days Nook keeps (`HistoryManager.retentionDays`); anything older
    /// would be pruned at the next launch. One history row per URL comes out, with its visit count.
    private func importChromeHistory(from chrome: ChromeProfile, profileID: UUID,
                                     summary: inout ChromeImportSummary,
                                     progress: @MainActor (ChromeImportStep) -> Void) async {
        let source = chrome.url.appendingPathComponent("History")
        let since = Date().addingTimeInterval(-Double(HistoryManager.retentionDays) * 86_400)
        let batch = Self.chromeHistoryBatch
        do {
            let (database, total) = try await Task.detached(priority: .userInitiated) {
                let database = try ChromeDatabase(copying: source)
                return (database, try chromeHistoryCount(database, since: since))
            }.value
            progress(.history(done: 0, total: total))
            var cursor: Int64 = 0
            while !Task.isCancelled {
                let after = cursor
                let page = try await Task.detached(priority: .userInitiated) {
                    try chromeHistoryPage(database, since: since, after: after, limit: batch)
                }.value
                guard !page.visits.isEmpty else { break }
                cursor = page.lastVisitID
                let visits = page.visits.compactMap { visit in
                    URL(string: visit.url).map {
                        HistoryVisit(url: $0, title: visit.title, timestamp: visit.date, tabId: nil, profileId: profileID)
                    }
                }
                historyManager.importVisits(visits)
                // A read waits for the writes queued before it: this is the pause until the batch is saved.
                _ = await historyManager.getHistory(days: 1, offset: 0, limit: 1)
                summary.visits += visits.count
                progress(.history(done: min(summary.visits, total), total: total))
            }
        } catch {
            let reason = (error as? ChromeImportError)?.message ?? "Chrome's History file could not be read."
            summary.problems.append("History was not fully imported. \(reason)")
        }
    }

    // MARK: - Bookmarks

    /// Everything goes into one pinned folder, closed, so hundreds of bookmarks add one row to
    /// the sidebar. The bookmarks bar sits at its top level, followed by "Other Bookmarks" and
    /// "Mobile Bookmarks".
    private func importChromeBookmarks(_ bookmarks: ChromeBookmarks, window: BrowserWindowState, spaceID: UUID,
                                       summary: inout ChromeImportSummary) {
        guard !bookmarks.isEmpty,
              let root = tabs.createFolder(title: "Chrome Bookmarks", in: .pinned(spaceID: spaceID), after: nil) else { return }
        var created = [root]
        var nodes = bookmarks.bar
        if !bookmarks.other.isEmpty { nodes.append(.folder(title: "Other Bookmarks", children: bookmarks.other)) }
        if !bookmarks.mobile.isEmpty { nodes.append(.folder(title: "Mobile Bookmarks", children: bookmarks.mobile)) }
        addChromeBookmarks(nodes, into: .folder(itemID: root), window: window, created: &created, summary: &summary)
        // `createFolder` opens what it makes.
        for folder in created where tabs.isOpen(folder: folder) { tabs.toggleFolder(folder) }
        summary.bookmarkFolders = created.count
    }

    /// Adds the tree under `parent` in source order without loading pages; `open` and
    /// `createFolder` insert at the top, so the list goes in reversed. A folder past the depth
    /// limit gives its bookmarks to the parent.
    private func addChromeBookmarks(_ nodes: [ChromeBookmark], into parent: Parent, window: BrowserWindowState,
                                    created: inout [UUID], summary: inout ChromeImportSummary) {
        for node in nodes.reversed() {
            switch node {
            case let .url(title, string):
                guard let url = URL(string: string),
                      tabs.open(url: url, in: window, placement: .background, parent: parent, title: title.isEmpty ? nil : title) != nil
                else { continue }
                summary.bookmarks += 1
            case let .folder(title, children):
                if let folder = tabs.createFolder(title: title.isEmpty ? "Untitled" : title, in: parent, after: nil) {
                    created.append(folder)
                    addChromeBookmarks(children, into: .folder(itemID: folder), window: window, created: &created, summary: &summary)
                } else {
                    addChromeBookmarks(children, into: parent, window: window, created: &created, summary: &summary)
                }
            }
        }
    }
}
