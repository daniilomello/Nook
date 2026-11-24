// Licensed under GPL-3.0. See LICENSE.
//
//  SiteBlockMatcher.swift
//  NookBlocker
//
//  The site blocker's settings turned into lookups by domain, and the question they answer:
//  is this address blocked, and by which list. Exceptions win over every list.
//

import Foundation
import NookSettings

/// Why an address was blocked, and the words the blocked page shows for it.
public struct SiteBlockVerdict: Equatable, Sendable {
    public enum Category: Equatable, Sendable {
        case social, adult, custom
    }

    public let category: Category
    /// The host that was asked for, without `www.`.
    public let host: String
    /// Set when only part of the site is blocked: `/shorts`.
    public let pathPrefix: String?
    /// The switch that blocked it, for a social site: "Facebook", "YouTube Shorts".
    public let siteName: String?

    public static let pageTitle = "This door stays shut"

    public var pageMessage: String {
        let reason: String
        switch category {
        case .social: reason = "\(siteName ?? "It") is on your Social Networks list."
        case .adult: reason = "It's on the Adult Content list."
        case .custom: reason = "It's on your own list of blocked sites."
        }
        return "Nook blocked \(host)\(pathPrefix ?? ""). \(reason) You can change that in Settings › Site Blocking."
    }
}

public struct SiteBlockMatcher: Sendable {
    private struct Entry: Sendable {
        let rule: SiteBlockRule
        let category: SiteBlockVerdict.Category
        let siteName: String?
    }

    private var blocked: [String: [Entry]] = [:]
    private var allowed: [String: [SiteBlockRule]] = [:]
    private let blocksAdult: Bool

    public init(settings: SiteBlockingSettings) {
        blocksAdult = settings.blockAdult
        // The person's own list first, so a site on both is reported as theirs.
        for rule in settings.customDomains.compactMap(SiteBlockRule.init) {
            blocked[rule.domain, default: []].append(Entry(rule: rule, category: .custom, siteName: nil))
        }
        for site in settings.blockedSocialSites {
            for rule in site.rules.compactMap(SiteBlockRule.init) {
                blocked[rule.domain, default: []].append(Entry(rule: rule, category: .social, siteName: site.name))
            }
        }
        for rule in settings.exceptions.compactMap(SiteBlockRule.init) {
            allowed[rule.domain, default: []].append(rule)
        }
    }

    /// Nil when the address may load. Only http and https addresses are ever blocked.
    public func verdict(for url: URL, adultList: HashedDomainList?) -> SiteBlockVerdict? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = url.host(percentEncoded: true), !rawHost.isEmpty else { return nil }
        let host = SiteBlockRule.normalizedHost(rawHost)
        let path = url.path(percentEncoded: false)
        let domains = SiteBlockRule.domains(covering: host).map(String.init)

        for domain in domains {
            if allowed[domain]?.contains(where: { $0.covers(path: path) }) == true { return nil }
        }
        for domain in domains {
            if let entry = blocked[domain]?.first(where: { $0.rule.covers(path: path) }) {
                return SiteBlockVerdict(category: entry.category, host: host, pathPrefix: entry.rule.pathPrefix, siteName: entry.siteName)
            }
        }
        if blocksAdult, adultList?.domain(covering: host) != nil {
            return SiteBlockVerdict(category: .adult, host: host, pathPrefix: nil, siteName: nil)
        }
        return nil
    }
}
