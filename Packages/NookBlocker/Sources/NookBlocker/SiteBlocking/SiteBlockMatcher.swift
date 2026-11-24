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

    /// What gave an adult site away.
    public enum AdultSign: Equatable, Sendable {
        /// On the domain list.
        case list
        /// The address names it: `AdultHostName`.
        case name
        /// The family DNS filter answered for it: `FamilyDNSFilter`.
        case familyFilter
    }

    public let category: Category
    /// The host that was asked for, without `www.`.
    public let host: String
    /// Set when only part of the site is blocked: `/shorts`.
    public let pathPrefix: String?
    /// The switch that blocked it, for a social site: "Facebook", "YouTube Shorts".
    public let siteName: String?
    /// Set for the adult category only.
    public var adultSign: AdultSign?

    public static let pageTitle = "This door stays shut"

    public var pageMessage: String {
        let reason: String
        switch category {
        case .social: reason = "\(siteName ?? "It") is on your Social Networks list."
        case .adult:
            switch adultSign {
            case .name: reason = "Its address names adult content."
            case .familyFilter: reason = "\(FamilyDNSFilter.serviceName) lists it as adult or unsafe."
            case .list, nil: reason = "It's on the Adult Content list."
            }
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
    private let asksFamilyFilter: Bool

    public init(settings: SiteBlockingSettings) {
        blocksAdult = settings.blockAdult
        asksFamilyFilter = settings.blockAdult && settings.askFamilyFilter
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
    /// `familyFiltered` says whether the family DNS filter is known to refuse a host.
    public func verdict(
        for url: URL, adultList: HashedDomainList?, familyFiltered: (String) -> Bool = { _ in false }
    ) -> SiteBlockVerdict? {
        guard let (host, path, domains) = Self.parts(of: url) else { return nil }
        if isException(domains: domains, path: path) { return nil }
        for domain in domains {
            if let entry = blocked[domain]?.first(where: { $0.rule.covers(path: path) }) {
                return SiteBlockVerdict(category: entry.category, host: host, pathPrefix: entry.rule.pathPrefix, siteName: entry.siteName)
            }
        }
        guard blocksAdult else { return nil }
        let sign: SiteBlockVerdict.AdultSign
        if adultList?.domain(covering: host) != nil {
            sign = .list
        } else if AdultHostName.matches(host) {
            sign = .name
        } else if asksFamilyFilter, familyFiltered(host) {
            sign = .familyFilter
        } else {
            return nil
        }
        return SiteBlockVerdict(category: .adult, host: host, pathPrefix: nil, siteName: nil, adultSign: sign)
    }

    /// The host to ask the family DNS filter about, or nil when the address is not one to ask
    /// for: the filter is off, the site is an exception, or it is not a public host name.
    public func familyFilterHost(for url: URL) -> String? {
        guard asksFamilyFilter, let (host, path, domains) = Self.parts(of: url),
              !isException(domains: domains, path: path), FamilyDNSFilter.canAsk(about: host) else { return nil }
        return host
    }

    private func isException(domains: [String], path: String) -> Bool {
        domains.contains { allowed[$0]?.contains(where: { $0.covers(path: path) }) == true }
    }

    private static func parts(of url: URL) -> (host: String, path: String, domains: [String])? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = url.host(percentEncoded: true), !rawHost.isEmpty else { return nil }
        let host = SiteBlockRule.normalizedHost(rawHost)
        return (host, url.path(percentEncoded: false), SiteBlockRule.domains(covering: host).map(String.init))
    }
}
