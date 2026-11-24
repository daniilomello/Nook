// Licensed under GPL-3.0. See LICENSE.
//
//  AdultDomainSources.swift
//  NookBlocker
//
//  Where the adult-content domain list comes from and how its sources become one list. Two
//  curated lists are merged: OISD NSFW and HaGeZi NSFW (both GPL-3.0). The Block List Project
//  and StevenBlack porn lists were measured too and left out: what only they carry is mostly
//  caught by AdultHostName already, and the rest includes CDNs, newspapers and registrars.
//
//  Foundation only: scripts/build-adult-domains.swift compiles this file with HashedDomainList.
//

import Foundation

public enum AdultDomainSources {
    public struct Source: Sendable {
        public let name: String
        /// One domain per line, each standing for its subdomains too.
        public let url: URL
        /// The list is not rebuilt without this source; the others are left out when they fail.
        public let isRequired: Bool
    }

    public static let all: [Source] = [
        Source(name: "OISD NSFW", url: URL(string: "https://nsfw.oisd.nl/domainswild2")!, isRequired: true),
        Source(name: "HaGeZi NSFW",
               url: URL(string: "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/nsfw-onlydomains.txt")!,
               isRequired: false),
    ]

    /// "OISD NSFW and HaGeZi NSFW", for settings.
    public static var names: String {
        all.map(\.name).joined(separator: " and ")
    }

    /// General-purpose sites the sources list whole because part of them is adult, or because
    /// they sit next to adult content: dating apps, chat, video and wildcard DNS services. An
    /// entry for the domain itself is dropped; an entry for one of its subdomains stays.
    static let neverWhole: [String] = [
        "tinder.com", "gotinder.com", "bumble.com", "badoo.com", "match.com", "okcupid.com", "pof.com",
        "character.ai", "nicovideo.jp", "sslip.io", "nip.io", "in.net", "blogspot.com", "blogspot.ru",
        "tumblr.com", "b-cdn.net", "fc2.com",
    ]

    /// One list file from the text of every source that was fetched.
    public static func mergedList(texts: [Data]) -> Data {
        let dropped = Set(neverWhole.map { HashedDomainList.hash(HashedDomainList.normalized($0)) })
        var hashes: [UInt64] = []
        for text in texts {
            hashes.append(contentsOf: HashedDomainList.hashes(inListText: text).filter { !dropped.contains($0) })
        }
        return HashedDomainList.encode(hashes)
    }
}
