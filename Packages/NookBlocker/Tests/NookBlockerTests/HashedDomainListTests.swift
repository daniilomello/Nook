// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookBlocker

struct HashedDomainListTests {
    private func list(_ text: String) -> HashedDomainList {
        HashedDomainList(data: HashedDomainList.encode(HashedDomainList.hashes(inListText: Data(text.utf8))))!
    }

    @Test func readsPlainDomainLists() {
        let list = list("""
            # Title: a list
            ! another comment

            one.example
            Two.Example   # trailing comment
            *.three.example
            www.four.example
            five.example.\r
            """)
        #expect(list.count == 5)
        for domain in ["one.example", "two.example", "three.example", "four.example", "five.example"] {
            #expect(list.contains(domain), "\(domain)")
        }
        #expect(!list.contains("six.example"))
    }

    @Test func readsHostsFilesAndFilterRules() {
        let list = list("""
            127.0.0.1 localhost
            127.0.0.1 localhost.localdomain
            255.255.255.255 broadcasthost
            ::1 localhost
            0.0.0.0 0.0.0.0
            0.0.0.0 one.example
            0.0.0.0\twww.two.example
            127.0.0.1 three.example
            ||four.example^
            """)
        #expect(list.count == 4)
        for domain in ["one.example", "two.example", "three.example", "four.example"] {
            #expect(list.contains(domain), "\(domain)")
        }
    }

    @Test func skipsLinesThatAreNotDomains() {
        let list = list("""
            localhost
            192.168.0.1
            no spaces allowed.example trailing
            bad/char.example
            ünïcode.example
            .
            a.b
            """)
        // "no" is read as the domain of the third line and has no dot; only a.b is a domain.
        #expect(list.count == 1)
        #expect(list.contains("a.b"))
    }

    @Test func duplicatesCountOnce() {
        #expect(list("one.example\nONE.example\nwww.one.example\n0.0.0.0 one.example\n").count == 1)
    }

    @Test func coversSubdomainsButNotLookalikes() {
        let list = list("example.com\ndeep.sub.example.org\n")
        #expect(list.domain(covering: "example.com") == "example.com")
        #expect(list.domain(covering: "WWW.Example.COM.") == "example.com")
        #expect(list.domain(covering: "a.b.c.example.com") == "example.com")
        #expect(list.domain(covering: "x.deep.sub.example.org") == "deep.sub.example.org")
        #expect(list.domain(covering: "sub.example.org") == nil)
        #expect(list.domain(covering: "notexample.com") == nil)
        #expect(list.domain(covering: "example.com.evil.net") == nil)
        #expect(list.domain(covering: "com") == nil)
        #expect(list.domain(covering: "") == nil)
    }

    @Test func rejectsFilesThatAreNotALists() {
        #expect(HashedDomainList(data: Data()) == nil)
        #expect(HashedDomainList(data: Data("not a list at all, just text".utf8)) == nil)
        var truncated = HashedDomainList.encode([1, 2, 3])
        truncated.removeLast(3)
        #expect(HashedDomainList(data: truncated) == nil)
        #expect(HashedDomainList(data: HashedDomainList.encode([]))?.count == 0)
        #expect(HashedDomainList(data: HashedDomainList.encode([]))?.domain(covering: "example.com") == nil)
    }

    @Test func findsEveryEntryOfALargeList() {
        let domains = (0..<20_000).map { "site-\($0).example" }
        let list = list(domains.joined(separator: "\n"))
        #expect(list.count == domains.count)
        #expect(domains.allSatisfy(list.contains))
        #expect(!(0..<20_000).contains { list.contains("other-\($0).example") })
    }

    @Test func readsFromAMappedFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nook-domains-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: file) }
        try HashedDomainList.encode(HashedDomainList.hashes(inListText: Data("example.com\n".utf8))).write(to: file)
        let list = try #require(HashedDomainList(contentsOf: file))
        #expect(list.domain(covering: "www.example.com") == "example.com")
        #expect(HashedDomainList(contentsOf: file.appendingPathExtension("missing")) == nil)
    }
}

struct AdultDomainListTests {
    @MainActor @Test func theBundledSnapshotLoadsAndBlocks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nook-adult-\(UUID().uuidString)", isDirectory: true)
        let adult = AdultDomainList(directory: directory, bundled: AdultDomainList.bundledFiles)
        #expect(adult.info == nil)
        let list = try #require(adult.current)
        let info = try #require(adult.info)
        #expect(info.count == list.count)
        #expect(list.count > 100_000)
        #expect(info.source == AdultDomainSources.all.map(\.name).joined(separator: ", "))

        for host in ["pornhub.com", "www.xvideos.com", "pt.pornhub.com", "xhamster.com", "onlyfans.com"] {
            #expect(list.domain(covering: host) != nil, "\(host)")
        }
        // In the second source only.
        #expect(list.domain(covering: "janitorai.com") != nil)
        for host in ["google.com", "www.youtube.com", "en.wikipedia.org", "github.com", "apple.com", "reddit.com", "x.com", "imgur.com",
                     "tinder.com", "www.tumblr.com", "character.ai"] {
            #expect(list.domain(covering: host) == nil, "\(host)")
        }
    }

    @MainActor @Test func aNewerDownloadedCopyWinsOverTheBundledOne() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nook-adult-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ name: String, domains: String, updated: String) throws -> (list: URL, info: URL) {
            let list = directory.appendingPathComponent("\(name).bin"), info = directory.appendingPathComponent("\(name).json")
            let encoded = HashedDomainList.encode(HashedDomainList.hashes(inListText: Data(domains.utf8)))
            try encoded.write(to: list)
            try Data(#"{"count": 1, "source": "test", "updated": "\#(updated)"}"#.utf8).write(to: info)
            return (list, info)
        }
        let old = try write("old", domains: "old.example\n", updated: "2026-01-01T00:00:00Z")
        _ = try write("adult-domains", domains: "new.example\n", updated: "2026-06-01T00:00:00Z")

        let newerDownload = AdultDomainList(directory: directory, bundled: old)
        #expect(newerDownload.current?.contains("new.example") == true)

        // After an app update the bundled snapshot can be the newer of the two.
        let newer = try write("newer", domains: "newer.example\n", updated: "2026-09-01T00:00:00Z")
        let newerBundle = AdultDomainList(directory: directory, bundled: newer)
        #expect(newerBundle.current?.contains("newer.example") == true)

        // A damaged download falls back to the bundled copy.
        try Data("garbage".utf8).write(to: directory.appendingPathComponent("adult-domains.bin"))
        let damaged = AdultDomainList(directory: directory, bundled: old)
        #expect(damaged.current?.contains("old.example") == true)
    }

    /// Fetches the real list, so it only runs when asked: NOOK_SITE_BLOCKING_LIVE=1 swift test.
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["NOOK_SITE_BLOCKING_LIVE"] == "1"))
    func downloadsTheListAndPutsItToUse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nook-adult-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let adult = AdultDomainList(directory: directory, bundled: AdultDomainList.bundledFiles)
        let bundledInfo = try #require({ adult.loadIfNeeded(); return adult.info }())
        // The bundled snapshot is fresh, so nothing is due.
        #expect(await adult.update() == false)
        #expect(await adult.update(force: true))
        let info = try #require(adult.info)
        #expect(info.updated > bundledInfo.updated)
        #expect(info.count > 100_000)
        #expect(adult.current?.count == info.count)
        #expect(adult.current?.domain(covering: "www.pornhub.com") == "pornhub.com")
        #expect(adult.current?.domain(covering: "www.wikipedia.org") == nil)

        // The next launch reads the downloaded copy, and an unchanged list is not fetched twice.
        let relaunched = AdultDomainList(directory: directory, bundled: AdultDomainList.bundledFiles)
        #expect(relaunched.current?.count == info.count)
        #expect(relaunched.info?.updated == info.updated)
        #expect(await relaunched.update() == false)
    }

    @MainActor @Test func lookupsAreFast() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nook-adult-\(UUID().uuidString)", isDirectory: true)
        let list = try #require(AdultDomainList(directory: directory, bundled: AdultDomainList.bundledFiles).current)
        let hosts = ["www.google.com", "news.ycombinator.com", "a.b.c.d.example.co.uk", "pornhub.com", "cdn.static.example.org"]
        let start = Date()
        var hits = 0
        for index in 0..<100_000 where list.domain(covering: hosts[index % hosts.count]) != nil { hits += 1 }
        let perLookup = Date().timeIntervalSince(start) / 100_000
        #expect(hits == 20_000)
        // Generous: a debug build on a busy machine still has to stay far under a millisecond.
        #expect(perLookup < 0.000_2, "\(perLookup * 1_000_000) µs per lookup")
    }
}
