// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
import NookSettings
@testable import NookBlocker

struct SiteBlockRuleTests {
    @Test func readsWhatPeopleType() {
        #expect(SiteBlockRule("example.com")?.text == "example.com")
        #expect(SiteBlockRule("  WWW.Example.COM.  ")?.text == "example.com")
        #expect(SiteBlockRule("https://www.example.com/")?.text == "example.com")
        #expect(SiteBlockRule("https://user@m.example.com:8443/Feed/?x=1#top")?.text == "m.example.com/feed")
        #expect(SiteBlockRule("*.example.com")?.text == "example.com")
        #expect(SiteBlockRule("youtube.com/shorts/")?.pathPrefix == "/shorts")
        #expect(SiteBlockRule("xxx")?.text == "xxx")
    }

    @Test func rejectsWhatIsNotADomain() {
        #expect(SiteBlockRule("") == nil)
        #expect(SiteBlockRule("   ") == nil)
        #expect(SiteBlockRule("two words.com") == nil)
        #expect(SiteBlockRule("https:///path") == nil)
        #expect(SiteBlockRule("exa mple") == nil)
        #expect(SiteBlockRule("a..b") == nil)
    }

    @Test func listsTheHostAndItsParents() {
        #expect(SiteBlockRule.domains(covering: "m.example.co.uk").map(String.init) == ["m.example.co.uk", "example.co.uk", "co.uk", "uk"])
        #expect(SiteBlockRule.domains(covering: "localhost").map(String.init) == ["localhost"])
    }
}

struct SiteBlockMatcherTests {
    private func verdict(_ address: String, _ settings: SiteBlockingSettings = SiteBlockingSettings(),
                         adult: HashedDomainList? = nil) -> SiteBlockVerdict? {
        SiteBlockMatcher(settings: settings).verdict(for: URL(string: address)!, adultList: adult)
    }

    private let adult = HashedDomainList(data: HashedDomainList.encode(HashedDomainList.hashes(
        inListText: Data("adult-example.com\nsub.partly-adult.org\n".utf8))))!

    // MARK: Hosts and parent domains

    @Test func blocksTheDefaultSocialSites() {
        for address in [
            "https://facebook.com/", "https://www.instagram.com/p/abc", "https://x.com/home", "https://twitter.com/",
            "https://www.tiktok.com/@someone", "https://www.threads.net/", "https://www.threads.com/",
            "https://www.reddit.com/r/swift", "https://www.snapchat.com/", "https://br.pinterest.com/", "https://www.tumblr.com/",
        ] {
            #expect(verdict(address)?.category == .social, "\(address)")
        }
    }

    @Test func matchesEveryParentDomain() {
        let blocked = verdict("https://m.facebook.com/home.php")
        #expect(blocked?.category == .social)
        #expect(blocked?.siteName == "Facebook")
        #expect(blocked?.host == "m.facebook.com")
        #expect(verdict("https://a.b.c.old.reddit.com/")?.siteName == "Reddit")
        #expect(verdict("http://FACEBOOK.com./")?.siteName == "Facebook")
    }

    @Test func aLookalikeHostIsNotAParentDomain() {
        #expect(verdict("https://notfacebook.com/") == nil)
        #expect(verdict("https://facebook.com.example.org/") == nil)
        #expect(verdict("https://example.org/facebook.com") == nil)
        #expect(verdict("https://xx.com/") == nil)
    }

    @Test func onlyWebAddressesAreBlocked() {
        #expect(verdict("about:blank") == nil)
        #expect(verdict("file:///facebook.com/index.html") == nil)
        #expect(verdict("mailto:someone@facebook.com") == nil)
    }

    @Test func linkedInAndYouTubeAreOffUntilSwitchedOn() {
        #expect(verdict("https://www.linkedin.com/feed/") == nil)
        #expect(verdict("https://www.youtube.com/watch?v=abc") == nil)
        #expect(verdict("https://youtu.be/abc") == nil)

        var settings = SiteBlockingSettings()
        settings.setEnabled(true, for: SocialSite.catalog.first { $0.id == "youtube" }!)
        settings.setEnabled(true, for: SocialSite.catalog.first { $0.id == "linkedin" }!)
        #expect(verdict("https://www.youtube.com/watch?v=abc", settings)?.siteName == "YouTube")
        #expect(verdict("https://youtu.be/abc", settings)?.siteName == "YouTube")
        #expect(verdict("https://www.linkedin.com/feed/", settings)?.siteName == "LinkedIn")
    }

    @Test func eachSocialSiteHasItsOwnSwitch() {
        var settings = SiteBlockingSettings()
        let reddit = SocialSite.catalog.first { $0.id == "reddit" }!
        settings.setEnabled(false, for: reddit)
        #expect(verdict("https://www.reddit.com/", settings) == nil)
        #expect(verdict("https://www.facebook.com/", settings) != nil)
        settings.setEnabled(true, for: reddit)
        #expect(settings.socialSiteOverrides.isEmpty)
        #expect(verdict("https://www.reddit.com/", settings) != nil)
    }

    @Test func theSocialSwitchTurnsTheWholeListOff() {
        var settings = SiteBlockingSettings()
        settings.blockSocial = false
        #expect(verdict("https://www.facebook.com/", settings) == nil)
        #expect(verdict("https://www.youtube.com/shorts/abc", settings) == nil)
        #expect(!settings.hidesYouTubeShorts)
    }

    // MARK: Path rules

    @Test func youTubeShortsIsBlockedAndTheRestOfYouTubeIsNot() {
        #expect(verdict("https://www.youtube.com/shorts/abc123")?.siteName == "YouTube Shorts")
        #expect(verdict("https://m.youtube.com/shorts/abc123")?.siteName == "YouTube Shorts")
        #expect(verdict("https://youtube.com/shorts")?.siteName == "YouTube Shorts")
        #expect(verdict("https://www.youtube.com/shorts/")?.siteName == "YouTube Shorts")
        #expect(verdict("https://www.youtube.com/Shorts/abc")?.siteName == "YouTube Shorts")
        #expect(verdict("https://www.youtube.com/%73horts/abc")?.siteName == "YouTube Shorts")
        #expect(verdict("https://www.youtube.com/") == nil)
        #expect(verdict("https://www.youtube.com/watch?v=abc") == nil)
        #expect(verdict("https://www.youtube.com/shortsighted") == nil)
        #expect(verdict("https://www.youtube.com/results?search_query=/shorts/") == nil)
        #expect(verdict("https://www.youtube.com/@channel/shorts") == nil)
        #expect(SiteBlockingSettings().hidesYouTubeShorts)
    }

    // MARK: The person's own list

    @Test func customDomainsAreBlocked() {
        var settings = SiteBlockingSettings()
        settings.customDomains = ["news.example.com", "https://www.Example.org/feed", "not a domain", "xxx"]
        #expect(verdict("https://news.example.com/", settings)?.category == .custom)
        #expect(verdict("https://live.news.example.com/a", settings)?.category == .custom)
        #expect(verdict("https://example.com/", settings) == nil)
        #expect(verdict("https://example.org/feed/today", settings)?.category == .custom)
        #expect(verdict("https://example.org/about", settings) == nil)
        // A bare top-level domain blocks everything under it.
        #expect(verdict("https://anything.xxx/", settings)?.category == .custom)
    }

    @Test func customDomainsStayOnWhenBothCategoriesAreOff() {
        var settings = SiteBlockingSettings()
        settings.blockSocial = false
        settings.blockAdult = false
        settings.customDomains = ["example.com"]
        #expect(verdict("https://example.com/", settings, adult: adult)?.category == .custom)
        #expect(verdict("https://adult-example.com/", settings, adult: adult) == nil)
    }

    // MARK: Exceptions

    @Test func exceptionsBeatEveryList() {
        var settings = SiteBlockingSettings()
        settings.customDomains = ["example.com"]
        settings.exceptions = ["reddit.com", "docs.example.com", "adult-example.com"]
        #expect(verdict("https://www.reddit.com/r/swift", settings) == nil)
        #expect(verdict("https://old.reddit.com/", settings) == nil)
        #expect(verdict("https://docs.example.com/page", settings) == nil)
        #expect(verdict("https://example.com/", settings)?.category == .custom)
        #expect(verdict("https://adult-example.com/", settings, adult: adult) == nil)
        #expect(verdict("https://www.facebook.com/", settings)?.category == .social)
    }

    @Test func anExceptionCanBeOnePartOfASite() {
        var settings = SiteBlockingSettings()
        settings.exceptions = ["reddit.com/r/swift"]
        #expect(verdict("https://www.reddit.com/r/swift/comments/1", settings) == nil)
        #expect(verdict("https://www.reddit.com/r/all", settings)?.siteName == "Reddit")
    }

    // MARK: Adult list

    @Test func adultDomainsAreBlockedWithTheirSubdomains() {
        #expect(verdict("https://adult-example.com/", adult: adult)?.category == .adult)
        #expect(verdict("https://www.adult-example.com/video/1", adult: adult)?.category == .adult)
        #expect(verdict("https://cdn.media.adult-example.com/", adult: adult)?.category == .adult)
        #expect(verdict("https://sub.partly-adult.org/", adult: adult)?.category == .adult)
        #expect(verdict("https://partly-adult.org/", adult: adult) == nil)
        #expect(verdict("https://example.com/", adult: adult) == nil)
    }

    @Test func theAdultSwitchTurnsTheListOff() {
        var settings = SiteBlockingSettings()
        settings.blockAdult = false
        #expect(verdict("https://adult-example.com/", settings, adult: adult) == nil)
    }

    // MARK: Blocked page

    @Test func theBlockedPageNamesTheSiteAndTheCategory() {
        #expect(verdict("https://m.facebook.com/")?.pageMessage
            == "Nook blocked m.facebook.com. Facebook is on your Social Networks list. You can change that in Settings › Site Blocking.")
        #expect(verdict("https://adult-example.com/", adult: adult)?.pageMessage.contains("adult-example.com. It's on the Adult Content list.") == true)
        // A path rule says which part of the site, not the whole of it.
        #expect(verdict("https://m.youtube.com/shorts/abc")?.pageMessage.hasPrefix("Nook blocked m.youtube.com/shorts. YouTube Shorts is on") == true)
    }
}

struct SiteBlockingSettingsTests {
    @Test func everythingIsOnWhenNothingWasSaved() throws {
        let settings = try JSONDecoder().decode(SiteBlockingSettings.self, from: Data("{}".utf8))
        #expect(settings == SiteBlockingSettings())
        #expect(settings.blockSocial && settings.blockAdult)
        #expect(settings.blockedSocialSites.map(\.id) == [
            "facebook", "instagram", "x", "tiktok", "threads", "reddit", "snapchat", "pinterest", "tumblr", "youtube-shorts",
        ])
    }

    @Test func theCatalogParses() {
        for site in SocialSite.catalog {
            for rule in site.rules {
                #expect(SiteBlockRule(rule)?.text == rule, "\(site.id): \(rule)")
            }
        }
        #expect(Set(SocialSite.catalog.map(\.id)).count == SocialSite.catalog.count)
    }

    @MainActor @Test func theStoreSavesAndReadsBack() {
        let name = "nook.siteblocking.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SiteBlockingStore(defaults: defaults)
        #expect(store.settings == SiteBlockingSettings())
        store.settings.blockAdult = false
        store.settings.customDomains = ["example.com"]
        store.settings.setEnabled(true, for: SocialSite.catalog.first { $0.id == "linkedin" }!)

        let reread = SiteBlockingStore(defaults: defaults)
        #expect(reread.settings == store.settings)
        #expect(!reread.settings.blockAdult)
        #expect(reread.settings.blockedSocialSites.contains { $0.id == "linkedin" })
    }

    @MainActor @Test func aChangeAppliesToTheNextQuestion() {
        let name = "nook.siteblocking.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        let blocker = SiteBlocker(store: SiteBlockingStore(defaults: defaults),
                                  adultList: AdultDomainList(directory: directory, bundled: nil))
        let reddit = URL(string: "https://www.reddit.com/")!
        // Off, so the test starts no list update.
        blocker.store.settings.blockAdult = false

        #expect(blocker.verdict(for: reddit) != nil)
        blocker.store.settings.exceptions = ["reddit.com"]
        #expect(blocker.verdict(for: reddit) == nil)
        blocker.store.settings.exceptions = []
        blocker.store.settings.blockSocial = false
        #expect(blocker.verdict(for: reddit) == nil)
        blocker.store.settings.customDomains = ["reddit.com"]
        #expect(blocker.verdict(for: reddit)?.category == .custom)
    }
}
