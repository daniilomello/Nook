// Licensed under GPL-3.0. See LICENSE.
//
//  AdultHostName.swift
//  NookBlocker
//
//  The adult sites no list has yet: an address that names what it is. New domains appear faster
//  than lists pick them up, but most still say "porn" or "xxx" in the name, or sit under an
//  adult top-level domain. Run over the 300,000 most visited domains, this caught 460 adult
//  sites the lists did not have. A site caught by mistake goes on the Never Block list.
//

import Foundation

public enum AdultHostName {
    private static let topLevelDomains: Set<Substring> = ["xxx", "porn", "sex", "adult", "sexy"]

    /// Matched anywhere in the name.
    private static let words = [
        "porn", "xxx", "hentai", "xnxx", "xhamster", "nsfw", "blowjob", "cumshot", "bdsm", "shemale",
        "bokep", "camgirl", "rule34", "gangbang", "creampie", "handjob", "redtube", "youjizz",
        "spankbang", "brazzers", "bangbros", "chaturbate", "stripchat", "livejasmin", "onlyfans",
        "putaria", "fuck", "pussy", "boobs", "nude", "erotic", "erotik", "upskirt", "deepthroat", "milfs",
    ]

    /// Names that hold one of the words and mean something else: the town of Milford, size
    /// XXXL, Pornichet on the French coast, the Mixxx DJ software, the BDS movement.
    private static let innocent = [
        "milford", "xxxl", "pornichet", "mixxx", "bdsmovement", "nude-project", "nudeproject", "fuckingfast",
    ]

    /// Counted only where a part of the name starts, since "nflxvideo" and "jeuxvideo" are not it.
    private static let startingWords = ["xvideo", "milf"]
    private static let endingWords = ["milf"]

    /// "sex" counts at the start or end of a part of the name, with these left alone.
    private static let innocentSexEndings = ["essex", "sussex", "middlesex", "wessex", "unisex"]
    private static let innocentSexStarts = ["sexual", "sext"]
    private static let adultSexStarts = ["sextube", "sextoy", "sexting"]

    /// True when the host's own name says it is an adult site. `host` is lowercase.
    public static func matches(_ host: String) -> Bool {
        let labels = host.split(separator: ".")
        guard labels.count >= 2, let last = labels.last else { return false }
        if topLevelDomains.contains(last) { return true }

        var name = labels.dropLast().joined(separator: ".")
        for word in innocent { name = name.replacingOccurrences(of: word, with: "|") }
        if words.contains(where: name.contains) { return true }

        return name.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "|" }).contains { part in
            if startingWords.contains(where: part.hasPrefix) || endingWords.contains(where: part.hasSuffix) { return true }
            if part.hasSuffix("sex") { return !innocentSexEndings.contains(where: part.hasSuffix) }
            guard part.hasPrefix("sex") else { return false }
            if adultSexStarts.contains(where: part.hasPrefix) { return true }
            return !innocentSexStarts.contains(where: part.hasPrefix)
        }
    }
}
