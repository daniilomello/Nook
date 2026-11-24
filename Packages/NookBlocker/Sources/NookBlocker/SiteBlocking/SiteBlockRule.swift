// Licensed under GPL-3.0. See LICENSE.
//
//  SiteBlockRule.swift
//  NookBlocker
//
//  One line of a block list or of the exceptions: a domain, which stands for its subdomains
//  too, and optionally a path it is limited to.
//

import Foundation

public struct SiteBlockRule: Hashable, Sendable {
    /// Lowercase, without `www.` or a trailing dot.
    public let domain: String
    /// `/shorts` covers `/shorts` and everything under `/shorts/`, never `/shortstory`.
    public let pathPrefix: String?

    /// Reads what a person types or pastes: `example.com`, `www.example.com/feed`,
    /// `https://example.com/feed?x=1`, `*.example.com`. Nil when there is no usable domain in it.
    public init?(_ input: String) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        // Anything before an @ is a user name, and the rest after ? or # is not part of a path.
        let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? text.endIndex
        text = String(text[..<cut])
        let slash = text.firstIndex(of: "/") ?? text.endIndex
        var host = String(text[..<slash])
        var path = String(text[slash...])
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
        if host.hasPrefix("*.") { host.removeFirst(2) }
        host = Self.normalizedHost(host)
        // A name with characters outside ASCII is matched in the form WebKit reports it.
        if !host.allSatisfy(\.isASCII), let encoded = URL(string: "https://\(host)/")?.host(percentEncoded: true) {
            host = Self.normalizedHost(encoded)
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-_")
        guard !host.isEmpty, host.count <= 253, host.allSatisfy(allowed.contains),
              !host.hasPrefix("."), !host.contains("..") else { return nil }

        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        domain = host
        pathPrefix = path.isEmpty || path == "/" ? nil : path
    }

    /// The rule as it is saved and shown: `example.com` or `example.com/feed`.
    public var text: String { domain + (pathPrefix ?? "") }

    /// Lowercase, without `www.` or dots at the end: `WWW.Example.com.` is `example.com`.
    public static func normalizedHost(_ host: String) -> String {
        var host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// The host and each parent domain, nearest first: `m.example.com`, `example.com`, `com`.
    public static func domains(covering host: String) -> [Substring] {
        var result: [Substring] = []
        var rest = host[...]
        while !rest.isEmpty {
            result.append(rest)
            guard let dot = rest.firstIndex(of: ".") else { break }
            rest = rest[rest.index(after: dot)...]
        }
        return result
    }

    func covers(path: String) -> Bool {
        guard let pathPrefix else { return true }
        let path = path.lowercased()
        return path == pathPrefix || path.hasPrefix(pathPrefix + "/")
    }
}
