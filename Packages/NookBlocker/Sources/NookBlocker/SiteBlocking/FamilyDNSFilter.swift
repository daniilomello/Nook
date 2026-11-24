// Licensed under GPL-3.0. See LICENSE.
//
//  FamilyDNSFilter.swift
//  NookBlocker
//
//  A second opinion on sites no list has: Cloudflare for Families, a public DNS resolver that
//  refuses adult and malicious domains by answering 0.0.0.0. Asked over HTTPS, one host name
//  at a time, while its switch in settings is on; it tells Cloudflare which sites are
//  opened. Answers are remembered for the rest of the launch, so a site is asked about once.
//

import Foundation
import OSLog

@MainActor
public final class FamilyDNSFilter {
    public static let serviceName = "Cloudflare for Families"
    private static let endpoint = URL(string: "https://family.cloudflare-dns.com/dns-query")!
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "SiteBlocking")
    private static let maxRemembered = 4000

    private var answers: [String: Bool] = [:]
    private var pending: [String: Task<Bool?, Never>] = [:]
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
    }

    /// True when the filter is known to refuse `host`; false when it allowed it or was never asked.
    public func refuses(_ host: String) -> Bool {
        answers[host] == true
    }

    public func hasAnswer(for host: String) -> Bool {
        answers[host] != nil
    }

    /// Asks the filter. True when it refuses the host, false when it resolves it, nil when no
    /// answer came: offline, a timeout, a reply that could not be read. Nil is not remembered.
    public func ask(about host: String) async -> Bool? {
        if let known = answers[host] { return known }
        if let running = pending[host] { return await running.value }
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A")]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        let session = self.session
        let task = Task<Bool?, Never> {
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return Self.isRefusal(data)
        }
        pending[host] = task
        let answer = await task.value
        pending[host] = nil
        if let answer {
            if answers.count >= Self.maxRemembered { answers.removeAll() }
            answers[host] = answer
        } else {
            Self.log.debug("Family DNS filter gave no answer")
        }
        return answer
    }

    /// Reads a DNS-over-HTTPS JSON reply: refused when an address record points at 0.0.0.0.
    /// Nil when it is not such a reply.
    nonisolated static func isRefusal(_ data: Data) -> Bool? {
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any], reply["Status"] is Int else { return nil }
        let records = reply["Answer"] as? [[String: Any]] ?? []
        return records.contains { ($0["type"] as? Int) == 1 && ($0["data"] as? String) == "0.0.0.0" }
    }

    /// Only public host names are asked about: not addresses, single names or local ones.
    nonisolated static func canAsk(about host: String) -> Bool {
        guard host.contains("."), !host.contains(":"), host.count <= 253,
              host.contains(where: \.isLetter) else { return false }
        return !["local", "localhost", "internal", "lan", "home", "test", "invalid", "arpa"]
            .contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }
}
