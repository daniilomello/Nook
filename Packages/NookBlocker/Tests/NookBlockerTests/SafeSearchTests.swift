// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookBlocker

struct SafeSearchTests {
    private func rewrite(_ address: String) -> String? {
        SafeSearch.rewrite(URL(string: address)!)?.absoluteString
    }

    @Test func google() {
        #expect(rewrite("https://www.google.com/search?q=cats") == "https://www.google.com/search?q=cats&safe=active")
        #expect(rewrite("https://google.com/search?q=cats&tbm=isch") == "https://google.com/search?q=cats&tbm=isch&safe=active")
        #expect(rewrite("https://www.google.com.br/search?q=gatos") == "https://www.google.com.br/search?q=gatos&safe=active")
        #expect(rewrite("https://www.google.co.uk/search?q=cats") == "https://www.google.co.uk/search?q=cats&safe=active")
        #expect(rewrite("https://www.google.de/search?q=katzen") == "https://www.google.de/search?q=katzen&safe=active")
        #expect(rewrite("https://www.google.com/imghp") == "https://www.google.com/imghp?safe=active")
    }

    @Test func bing() {
        #expect(rewrite("https://www.bing.com/search?q=cats&form=QBLH") == "https://www.bing.com/search?q=cats&form=QBLH&adlt=strict")
        #expect(rewrite("https://www.bing.com/images/search?q=cats") == "https://www.bing.com/images/search?q=cats&adlt=strict")
        #expect(rewrite("https://www.bing.com/videos/search?q=cats&adlt=off") == "https://www.bing.com/videos/search?q=cats&adlt=strict")
    }

    @Test func duckDuckGo() {
        #expect(rewrite("https://duckduckgo.com/?q=cats&ia=web") == "https://duckduckgo.com/?q=cats&ia=web&kp=1")
        #expect(rewrite("https://duckduckgo.com/?q=cats&kp=-2&ia=images") == "https://duckduckgo.com/?q=cats&kp=1&ia=images")
        #expect(rewrite("https://html.duckduckgo.com/html/?q=cats") == "https://html.duckduckgo.com/html/?q=cats&kp=1")
    }

    @Test func braveAndYahoo() {
        #expect(rewrite("https://search.brave.com/search?q=cats") == "https://search.brave.com/search?q=cats&safesearch=strict")
        #expect(rewrite("https://search.yahoo.com/search?p=cats") == "https://search.yahoo.com/search?p=cats&vm=r")
        #expect(rewrite("https://br.search.yahoo.com/search?p=gatos") == "https://br.search.yahoo.com/search?p=gatos&vm=r")
        #expect(rewrite("https://images.search.yahoo.com/search/images?p=cats") == "https://images.search.yahoo.com/search/images?p=cats&vm=r")
    }

    @Test func isIdempotent() {
        for address in [
            "https://www.google.com/search?q=cats", "https://www.bing.com/search?q=cats", "https://duckduckgo.com/?q=cats",
            "https://search.brave.com/search?q=cats", "https://search.yahoo.com/search?p=cats",
            "https://www.google.com/search?safe=off&q=cats&safe=images",
        ] {
            let once = SafeSearch.rewrite(URL(string: address)!)
            #expect(once != nil, "\(address)")
            #expect(SafeSearch.rewrite(once!) == nil, "\(address)")
        }
        #expect(rewrite("https://www.google.com/search?q=cats&safe=active") == nil)
        #expect(rewrite("https://www.bing.com/search?adlt=strict&q=cats") == nil)
        #expect(rewrite("https://duckduckgo.com/?kp=1&q=cats") == nil)
    }

    @Test func aWeakerOrRepeatedValueIsReplacedInPlace() {
        #expect(rewrite("https://www.google.com/search?safe=off&q=cats") == "https://www.google.com/search?safe=active&q=cats")
        #expect(rewrite("https://www.google.com/search?q=cats&safe=active&safe=off") == "https://www.google.com/search?q=cats&safe=active")
        #expect(rewrite("https://www.google.com/search?q=cats&safe") == "https://www.google.com/search?q=cats&safe=active")
    }

    @Test func keepsTheOtherQueryItemsAsTheyWere() {
        #expect(rewrite("https://www.google.com/search?q=caf%C3%A9+au+lait&hl=pt-BR&udm=2#ip=1")
            == "https://www.google.com/search?q=caf%C3%A9+au+lait&hl=pt-BR&udm=2&safe=active#ip=1")
        #expect(rewrite("https://www.bing.com/search?q=a%26b%3Dc&first=11") == "https://www.bing.com/search?q=a%26b%3Dc&first=11&adlt=strict")
        #expect(rewrite("https://duckduckgo.com/?q=%22exact+phrase%22&t=h_&iar=images")
            == "https://duckduckgo.com/?q=%22exact+phrase%22&t=h_&iar=images&kp=1")
    }

    @Test func leavesEverythingElseAlone() {
        for address in [
            "https://www.google.com/", "https://www.google.com/maps?q=cats", "https://mail.google.com/mail/u/0/?q=cats",
            "https://docs.google.com/search?q=cats", "https://google.evil.example/search?q=cats",
            "https://notgoogle.com/search?q=cats", "https://www.bing.com/", "https://www.bing.com/maps",
            "https://notbing.com/search?q=cats", "https://duckduckgo.com/", "https://duckduckgo.com/settings",
            "https://example.com/search?q=cats", "https://search.brave.com/", "https://www.yahoo.com/?p=cats",
            "about:blank", "file:///search?q=cats",
        ] {
            #expect(rewrite(address) == nil, "\(address)")
        }
    }
}
