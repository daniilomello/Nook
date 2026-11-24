// Licensed under GPL-3.0. See LICENSE.
//
//  SiteBlockingSettings.swift
//  NookSettings
//
//  What the site blocker is set to: the two categories, each social site's switch, the person's
//  own blocked domains and the exceptions. Kept apart from NookSettingsService in a store of its
//  own, under the same `settings.` defaults prefix, so both apps and the blocker read one value.
//

import Foundation
import Observation

/// One switchable entry on the social list.
public struct SocialSite: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// `example.com` blocks the domain and its subdomains; `example.com/path` only that path
    /// and what is under it.
    public let rules: [String]
    public let enabledByDefault: Bool

    public init(id: String, name: String, rules: [String], enabledByDefault: Bool = true) {
        self.id = id
        self.name = name
        self.rules = rules
        self.enabledByDefault = enabledByDefault
    }

    /// The first few rules, for the line under the name in settings.
    public var summary: String {
        let shown = rules.prefix(3).joined(separator: ", ")
        return rules.count > 3 ? "\(shown) and \(rules.count - 3) more" : shown
    }

    public static let youTubeShortsID = "youtube-shorts"

    public static let catalog: [SocialSite] = [
        SocialSite(id: "facebook", name: "Facebook", rules: ["facebook.com", "fb.com", "fb.watch"]),
        SocialSite(id: "instagram", name: "Instagram", rules: ["instagram.com", "instagr.am"]),
        SocialSite(id: "x", name: "X (Twitter)", rules: ["x.com", "twitter.com"]),
        SocialSite(id: "tiktok", name: "TikTok", rules: ["tiktok.com"]),
        SocialSite(id: "threads", name: "Threads", rules: ["threads.net", "threads.com"]),
        SocialSite(id: "reddit", name: "Reddit", rules: ["reddit.com", "redd.it"]),
        SocialSite(id: "snapchat", name: "Snapchat", rules: ["snapchat.com"]),
        SocialSite(id: "pinterest", name: "Pinterest", rules: [
            "pinterest.com", "pin.it", "pinterest.co.uk", "pinterest.ca", "pinterest.com.au", "pinterest.de",
            "pinterest.fr", "pinterest.es", "pinterest.it", "pinterest.pt", "pinterest.com.mx", "pinterest.jp",
            "pinterest.co.kr", "pinterest.se", "pinterest.dk", "pinterest.ch", "pinterest.at", "pinterest.ie",
            "pinterest.nz", "pinterest.cl", "pinterest.ph",
        ]),
        SocialSite(id: "tumblr", name: "Tumblr", rules: ["tumblr.com"]),
        SocialSite(id: youTubeShortsID, name: "YouTube Shorts", rules: ["youtube.com/shorts"]),
        // Off until switched on: places to publish as much as to scroll.
        SocialSite(id: "linkedin", name: "LinkedIn", rules: ["linkedin.com", "lnkd.in"], enabledByDefault: false),
        SocialSite(id: "youtube", name: "YouTube", rules: ["youtube.com", "youtu.be"], enabledByDefault: false),
    ]
}

public struct SiteBlockingSettings: Codable, Equatable, Sendable {
    public var blockSocial = true
    /// Blocks the adult domain list and keeps safe search on.
    public var blockAdult = true
    /// Also asks a family DNS filter about each site opened, which sends the names of the sites
    /// visited to that service.
    public var askFamilyFilter = true
    /// Only the social sites whose switch differs from the catalog's default, so a later change
    /// to a default reaches everyone who never touched that switch.
    public var socialSiteOverrides: [String: Bool] = [:]
    /// The person's own blocked sites, as `domain` or `domain/path`.
    public var customDomains: [String] = []
    /// Sites no list may block, in the same form.
    public var exceptions: [String] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case blockSocial, blockAdult, socialSiteOverrides, customDomains, exceptions
        /// Saved as `askFamilyFilter` while it was off by default. The name changed with the
        /// default, so a value saved back then does not keep it off.
        case askFamilyFilter = "familyFilter"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        blockSocial = try values.decodeIfPresent(Bool.self, forKey: .blockSocial) ?? true
        blockAdult = try values.decodeIfPresent(Bool.self, forKey: .blockAdult) ?? true
        askFamilyFilter = try values.decodeIfPresent(Bool.self, forKey: .askFamilyFilter) ?? true
        socialSiteOverrides = try values.decodeIfPresent([String: Bool].self, forKey: .socialSiteOverrides) ?? [:]
        customDomains = try values.decodeIfPresent([String].self, forKey: .customDomains) ?? []
        exceptions = try values.decodeIfPresent([String].self, forKey: .exceptions) ?? []
    }

    public func isEnabled(_ site: SocialSite) -> Bool {
        socialSiteOverrides[site.id] ?? site.enabledByDefault
    }

    public mutating func setEnabled(_ enabled: Bool, for site: SocialSite) {
        socialSiteOverrides[site.id] = enabled == site.enabledByDefault ? nil : enabled
    }

    /// The social sites being blocked now.
    public var blockedSocialSites: [SocialSite] {
        blockSocial ? SocialSite.catalog.filter(isEnabled) : []
    }

    /// YouTube stays open but its Shorts do not, so their shelves are worth hiding too.
    public var hidesYouTubeShorts: Bool {
        blockedSocialSites.contains { $0.id == SocialSite.youTubeShortsID }
    }
}

/// The site blocker's settings, saved as they change. On for a new install and for anyone who
/// has never opened the pane: nothing saved reads as every default.
@MainActor
@Observable
public final class SiteBlockingStore {
    public static let shared = SiteBlockingStore()
    public static let defaultsKey = "settings.siteBlocking"

    @ObservationIgnored private let defaults: UserDefaults

    public var settings: SiteBlockingSettings {
        didSet {
            guard settings != oldValue, let data = try? JSONEncoder().encode(settings) else { return }
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(SiteBlockingSettings.self, from: $0) } ?? SiteBlockingSettings()
    }
}
