// Licensed under GPL-3.0. See LICENSE.
//
//  SafeSearch.swift
//  NookBlocker
//
//  Forces a search engine's strict filter by rewriting the address of a results page: each
//  engine reads one query parameter that wins over the person's saved preference for that
//  request. Covers Google, Bing, DuckDuckGo, Brave and Yahoo.
//

import Foundation

public enum SafeSearch {
    private struct Engine {
        let name: String
        let value: String
        let applies: (_ host: String, _ path: String, _ items: [URLQueryItem]) -> Bool
    }

    private static func hasQuery(_ items: [URLQueryItem], _ name: String) -> Bool {
        items.contains { $0.name == name }
    }

    private static let engines: [Engine] = [
        // google.com and its country domains: google.com.br, google.co.uk, google.de.
        Engine(name: "safe", value: "active") { host, path, _ in
            guard host.hasPrefix("google.") else { return false }
            let suffix = host.dropFirst("google.".count).split(separator: ".", omittingEmptySubsequences: false)
            return (1...2).contains(suffix.count) && suffix.allSatisfy { (2...3).contains($0.count) }
                && (path == "/search" || path == "/images" || path == "/imghp")
        },
        Engine(name: "adlt", value: "strict") { host, _, items in
            (host == "bing.com" || host.hasSuffix(".bing.com")) && hasQuery(items, "q")
        },
        Engine(name: "kp", value: "1") { host, _, items in
            (host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com")) && hasQuery(items, "q")
        },
        Engine(name: "safesearch", value: "strict") { host, _, items in
            host == "search.brave.com" && hasQuery(items, "q")
        },
        Engine(name: "vm", value: "r") { host, _, items in
            (host == "search.yahoo.com" || host.hasSuffix(".search.yahoo.com")) && hasQuery(items, "p")
        },
    ]

    /// The address with the engine's strict filter on, or nil when `url` is not a search this
    /// covers or already carries it. The other query items keep their order and encoding.
    public static func rewrite(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = url.host(percentEncoded: true),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let host = SiteBlockRule.normalizedHost(rawHost)
        let items = components.percentEncodedQueryItems ?? []
        guard let engine = engines.first(where: { $0.applies(host, components.path, items) }) else { return nil }

        let current = items.filter { $0.name == engine.name }
        if current.count == 1, current[0].value == engine.value { return nil }
        // In the place of the first one the page set, so a later duplicate cannot undo it.
        var rewritten: [URLQueryItem] = []
        var placed = false
        for item in items {
            if item.name != engine.name {
                rewritten.append(item)
            } else if !placed {
                rewritten.append(URLQueryItem(name: engine.name, value: engine.value))
                placed = true
            }
        }
        if !placed { rewritten.append(URLQueryItem(name: engine.name, value: engine.value)) }
        components.percentEncodedQueryItems = rewritten
        return components.url
    }
}
