// Licensed under GPL-3.0. See LICENSE.
//
//  SiteBlocker.swift
//  NookBlocker
//
//  The site blocker both apps ask before a navigation goes ahead: social networks, adult
//  content and the person's own list, with safe search forced while adult content is blocked.
//  One instance for the whole app, so every window, space, profile and private window gets the
//  same answer, and a change in settings applies to the next navigation anywhere.
//

import Foundation
import NookSettings

@MainActor
public final class SiteBlocker {
    public static let shared = SiteBlocker(store: .shared, adultList: AdultDomainList())

    public let store: SiteBlockingStore
    public let adultList: AdultDomainList

    private var compiled: (settings: SiteBlockingSettings, matcher: SiteBlockMatcher)?
    private var recentReports: [ObjectIdentifier: (url: URL, at: Date)] = [:]
    private var autoUpdateStarted = false

    init(store: SiteBlockingStore, adultList: AdultDomainList) {
        self.store = store
        self.adultList = adultList
    }

    /// Nil when `url` may load; otherwise which list blocks it.
    public func verdict(for url: URL) -> SiteBlockVerdict? {
        let settings = store.settings
        if compiled?.settings != settings {
            compiled = (settings, SiteBlockMatcher(settings: settings))
        }
        var list: HashedDomainList?
        if settings.blockAdult {
            list = adultList.current
            if !autoUpdateStarted {
                autoUpdateStarted = true
                adultList.startAutoUpdate { [weak store] in store?.settings.blockAdult == true }
            }
        }
        return compiled?.matcher.verdict(for: url, adultList: list)
    }

    /// The address to load instead of `url` so a search comes back filtered, or nil when it can
    /// load as it is. Safe search follows the Adult Content switch.
    public func safeSearchURL(for url: URL) -> URL? {
        store.settings.blockAdult ? SafeSearch.rewrite(url) : nil
    }

    /// False when the same address was already reported for the same web view in the last
    /// `seconds`. A page's own address change arrives more than once, and acting on each report
    /// would go back twice or reload in a loop.
    public func isFirstReport(of url: URL, in view: ObjectIdentifier, within seconds: TimeInterval) -> Bool {
        let now = Date()
        recentReports = recentReports.filter { now.timeIntervalSince($0.value.at) < 60 }
        if let last = recentReports[view], last.url == url, now.timeIntervalSince(last.at) < seconds { return false }
        recentReports[view] = (url, now)
        return true
    }
}
