// Licensed under GPL-3.0. See LICENSE.
//
//  build-adult-domains.swift
//  Nook
//
//  Turns the downloaded source lists into the bundled adult-domains.bin and its
//  adult-domains.json, with the same code the app uses to merge and read them. Run by
//  scripts/refresh-adult-domains.sh:
//
//    build-adult-domains --sources                          prints "<required|optional> <url>" per source
//    build-adult-domains <output directory> <list.txt>...   one file per source that was fetched, in order
//

import Foundation

@main
enum BuildAdultDomains {
    static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("build-adult-domains: \(message)\n".utf8))
        exit(code)
    }

    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--sources"] {
            for source in AdultDomainSources.all {
                print(source.isRequired ? "required" : "optional", source.url.absoluteString)
            }
            return
        }
        guard arguments.count >= 2 else {
            fail("usage: build-adult-domains --sources | <output directory> <list.txt>...", code: 2)
        }
        let texts = try arguments.dropFirst().map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        let encoded = AdultDomainSources.mergedList(texts: texts)
        guard let list = HashedDomainList(data: encoded), list.count >= 10_000 else {
            fail("too few domains; nothing written")
        }
        // A list without these is not an adult-content list, whatever its size.
        for domain in ["pornhub.com", "xvideos.com"] where !list.contains(domain) {
            fail("\(domain) is missing; nothing written")
        }
        // And one with these would block half the web.
        for domain in ["google.com", "youtube.com", "wikipedia.org", "github.com", "apple.com", "tumblr.com", "b-cdn.net"]
        where list.domain(covering: domain) != nil {
            fail("\(domain) is listed; nothing written")
        }
        let output = URL(fileURLWithPath: arguments[0], isDirectory: true)
        try encoded.write(to: output.appendingPathComponent("adult-domains.bin"), options: .atomic)
        let names = AdultDomainSources.all.prefix(texts.count).map(\.name).joined(separator: ", ")
        let info: [String: Any] = [
            "count": list.count,
            "source": names,
            "updated": ISO8601DateFormatter().string(from: Date()),
        ]
        let json = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        try (json + Data("\n".utf8)).write(to: output.appendingPathComponent("adult-domains.json"), options: .atomic)
        print("adult-domains.bin \(list.count) domains from \(names), \(encoded.count) bytes")
    }
}
