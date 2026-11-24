// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
import NookSettings
@testable import NookBlocker

struct AdultHostNameTests {
    @Test func aNameThatSaysSoIsAdult() {
        for host in ["newpornsite.io", "xxx191.cc", "free-xxx-video.monster", "hentaiz.bot", "bokepindo24.com",
                     "xvideosputaria.com", "usa-xvideos.com", "azmilf.com", "milfxten.com", "kanesex.com",
                     "sexylib.com", "sex-zbzoob.com", "sextube.tv", "stripchatcam.com", "erotikchat4free.org",
                     "nudechat.pro", "example.xxx", "studio.porn", "cams.sexy", "m.best-porno.com.br"] {
            #expect(AdultHostName.matches(host), "\(host)")
        }
    }

    @Test func aNameThatOnlyLooksLikeItIsNot() {
        for host in ["nflxvideo.net", "jeuxvideo.com", "foxvideochat.com", "zerotier.com", "aerotime.aero",
                     "mixxx.org", "xxxlutz.de", "bdsmovement.net", "emilfrey.ch", "milfordsound.co.nz",
                     "essex.gov.uk", "sussex.ac.uk", "middlesex.edu", "unisex-wear.com", "sextafeira.com.br",
                     "sexualhealth.org", "pornichet.fr", "nude-project.com", "analytics.google.com",
                     "cockpit-project.org", "github.com", "wikipedia.org", "localhost", "adult", "xxx"] {
            #expect(!AdultHostName.matches(host), "\(host)")
        }
    }
}

struct AdultSignTests {
    private func verdict(_ address: String, _ settings: SiteBlockingSettings = SiteBlockingSettings(),
                         refused: Set<String> = []) -> SiteBlockVerdict? {
        SiteBlockMatcher(settings: settings).verdict(for: URL(string: address)!, adultList: list, familyFiltered: refused.contains)
    }

    private let list = HashedDomainList(data: HashedDomainList.encode(HashedDomainList.hashes(
        inListText: Data("adult-example.com\n".utf8))))!

    @Test func theListComesBeforeTheName() {
        #expect(verdict("https://adult-example.com/")?.adultSign == .list)
        #expect(verdict("https://www.brandnewporn.io/watch")?.adultSign == .name)
        #expect(verdict("https://www.brandnewporn.io/watch")?.pageMessage.contains("Its address names adult content.") == true)
        #expect(verdict("https://www.facebook.com/")?.adultSign == nil)
    }

    @Test func theAdultSwitchTurnsNamesOffToo() {
        var settings = SiteBlockingSettings()
        settings.blockAdult = false
        settings.askFamilyFilter = true
        #expect(verdict("https://brandnewporn.io/", settings) == nil)
        #expect(verdict("https://quiet-name.example/", settings, refused: ["quiet-name.example"]) == nil)
        #expect(SiteBlockMatcher(settings: settings).familyFilterHost(for: URL(string: "https://quiet-name.example/")!) == nil)
    }

    @Test func anExceptionBeatsTheNameAndTheFilter() {
        var settings = SiteBlockingSettings()
        settings.askFamilyFilter = true
        settings.exceptions = ["yourbrainonporn.com", "quiet-name.example"]
        #expect(verdict("https://www.yourbrainonporn.com/", settings) == nil)
        #expect(verdict("https://quiet-name.example/", settings, refused: ["quiet-name.example"]) == nil)
        #expect(SiteBlockMatcher(settings: settings).familyFilterHost(for: URL(string: "https://quiet-name.example/")!) == nil)
    }

    @Test func theFamilyFilterIsOnlyHeardWhenSwitchedOn() throws {
        var settings = SiteBlockingSettings()
        #expect(settings.askFamilyFilter)
        // On for a new install, and for one that saved its settings while it was off by default.
        let saved = Data(#"{"blockAdult":true,"askFamilyFilter":false}"#.utf8)
        #expect(try JSONDecoder().decode(SiteBlockingSettings.self, from: saved).askFamilyFilter)
        settings.askFamilyFilter = false
        #expect(try JSONDecoder().decode(SiteBlockingSettings.self, from: JSONEncoder().encode(settings)) == settings)
        #expect(verdict("https://quiet-name.example/", settings, refused: ["quiet-name.example"]) == nil)
        #expect(SiteBlockMatcher(settings: settings).familyFilterHost(for: URL(string: "https://quiet-name.example/")!) == nil)

        settings.askFamilyFilter = true
        let blocked = verdict("https://www.quiet-name.example/page", settings, refused: ["quiet-name.example"])
        #expect(blocked?.adultSign == .familyFilter)
        #expect(blocked?.pageMessage.contains("Cloudflare for Families lists it as adult or unsafe.") == true)
        #expect(verdict("https://other.example/", settings, refused: ["quiet-name.example"]) == nil)
        let matcher = SiteBlockMatcher(settings: settings)
        #expect(matcher.familyFilterHost(for: URL(string: "https://www.quiet-name.example/page")!) == "quiet-name.example")
        #expect(matcher.familyFilterHost(for: URL(string: "http://192.168.0.1/")!) == nil)
        #expect(matcher.familyFilterHost(for: URL(string: "http://printer.local/")!) == nil)
        #expect(matcher.familyFilterHost(for: URL(string: "http://localhost:3000/")!) == nil)
        #expect(matcher.familyFilterHost(for: URL(string: "file:///tmp/a.html")!) == nil)
    }
}

struct FamilyDNSFilterTests {
    @Test func readsARefusal() {
        let refused = #"{"Status":0,"Question":[{"name":"a.example","type":1}],"Answer":[{"name":"a.example","type":1,"TTL":60,"data":"0.0.0.0"}],"Comment":["EDE(17): Filtered"]}"#
        let resolved = #"{"Status":0,"Answer":[{"name":"b.example","type":5,"TTL":60,"data":"c.example."},{"name":"c.example","type":1,"TTL":80,"data":"195.200.68.224"}]}"#
        let missing = #"{"Status":3,"Authority":[{"name":"com","type":6,"TTL":900,"data":"a. b. 1 2 3 4 5"}]}"#
        #expect(FamilyDNSFilter.isRefusal(Data(refused.utf8)) == true)
        #expect(FamilyDNSFilter.isRefusal(Data(resolved.utf8)) == false)
        #expect(FamilyDNSFilter.isRefusal(Data(missing.utf8)) == false)
        #expect(FamilyDNSFilter.isRefusal(Data("<html>".utf8)) == nil)
        #expect(FamilyDNSFilter.isRefusal(Data("[]".utf8)) == nil)
    }
}

struct AdultDomainSourcesTests {
    @Test func mergesSourcesAndDropsWholePlatforms() throws {
        let first = Data("one.example\ntumblr.com\nshared.example\n".utf8)
        let second = Data("# a comment\ntwo.example\nshared.example\nnsfw-blog.tumblr.com\ntinder.com\n".utf8)
        let list = try #require(HashedDomainList(data: AdultDomainSources.mergedList(texts: [first, second])))
        #expect(list.count == 4)
        #expect(list.domain(covering: "www.one.example") == "one.example")
        #expect(list.domain(covering: "two.example") == "two.example")
        #expect(list.domain(covering: "nsfw-blog.tumblr.com") == "nsfw-blog.tumblr.com")
        #expect(list.domain(covering: "www.tumblr.com") == nil)
        #expect(list.domain(covering: "tinder.com") == nil)
    }

    @Test func theFirstSourceIsTheRequiredOne() {
        #expect(AdultDomainSources.all.first?.isRequired == true)
        #expect(AdultDomainSources.all.allSatisfy { $0.url.scheme == "https" })
    }
}
