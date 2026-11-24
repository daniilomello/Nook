// Licensed under GPL-3.0. See LICENSE.
//
//  build-adult-domains.swift
//  Nook
//
//  Turns a downloaded domain list into the bundled adult-domains.bin and its adult-domains.json,
//  with the same code the app uses to read them. Run by scripts/refresh-adult-domains.sh:
//
//    swiftc -O -parse-as-library Packages/NookBlocker/Sources/NookBlocker/SiteBlocking/HashedDomainList.swift \
//           scripts/build-adult-domains.swift -o /tmp/build-adult-domains
//    /tmp/build-adult-domains <list.txt> <source url> <output directory>
//

import Foundation

@main
enum BuildAdultDomains {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            FileHandle.standardError.write(Data("usage: build-adult-domains <list.txt> <source url> <output directory>\n".utf8))
            exit(2)
        }
        let text = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let encoded = HashedDomainList.encode(HashedDomainList.hashes(inListText: text))
        guard let list = HashedDomainList(data: encoded), list.count >= 10_000 else {
            FileHandle.standardError.write(Data("build-adult-domains: too few domains in \(arguments[1]); nothing written\n".utf8))
            exit(1)
        }
        // A list without these is not an adult-content list, whatever its size.
        for domain in ["pornhub.com", "xvideos.com"] where !list.contains(domain) {
            FileHandle.standardError.write(Data("build-adult-domains: \(domain) is missing; nothing written\n".utf8))
            exit(1)
        }
        let output = URL(fileURLWithPath: arguments[3], isDirectory: true)
        try encoded.write(to: output.appendingPathComponent("adult-domains.bin"), options: .atomic)
        let info: [String: Any] = [
            "count": list.count,
            "source": arguments[2],
            "updated": ISO8601DateFormatter().string(from: Date()),
        ]
        let json = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        try (json + Data("\n".utf8)).write(to: output.appendingPathComponent("adult-domains.json"), options: .atomic)
        print("adult-domains.bin \(list.count) domains, \(encoded.count) bytes")
    }
}
