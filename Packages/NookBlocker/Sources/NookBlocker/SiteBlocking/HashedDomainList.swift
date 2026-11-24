// Licensed under GPL-3.0. See LICENSE.
//
//  HashedDomainList.swift
//  NookBlocker
//
//  A large domain list as a sorted array of 64-bit hashes in one file: a 16-byte header, then
//  the hashes, little-endian. The file is memory-mapped and searched in place, so opening it
//  costs nothing and a lookup touches a handful of pages; half a million domains as Swift
//  strings in a Set would cost tens of megabytes and a parse at launch.
//
//  Foundation only: scripts/build-adult-domains.swift compiles this file to write the bundled copy.
//

import Foundation

public struct HashedDomainList: Sendable {
    static let headerSize = 16
    /// "NKDL", then the format version.
    private static let magic: [UInt8] = [0x4E, 0x4B, 0x44, 0x4C]
    private static let version: UInt32 = 1

    private let storage: Data
    public let count: Int

    /// Nil unless `data` is a whole list: the header, then exactly as many hashes as it says.
    public init?(data: Data) {
        guard data.count >= Self.headerSize, Array(data.prefix(4)) == Self.magic else { return nil }
        let (version, count) = data.withUnsafeBytes { raw in
            (UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self)),
             UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)))
        }
        guard version == Self.version, count <= UInt64(Int.max / 8),
              data.count == Self.headerSize + Int(count) * 8 else { return nil }
        storage = data
        self.count = Int(count)
    }

    /// Maps the file rather than reading it.
    public init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data)
    }

    // MARK: - Lookup

    /// The listed domain that covers `host`: the host itself or the nearest parent domain on the
    /// list. A bare top-level domain never counts.
    public func domain(covering host: String) -> String? {
        let bytes = Self.normalized(host)
        var start = 0
        while start < bytes.count {
            let suffix = bytes[start...]
            guard suffix.contains(UInt8(ascii: ".")) else { return nil }
            if contains(hash: Self.hash(suffix)) { return String(decoding: suffix, as: UTF8.self) }
            guard let dot = suffix.firstIndex(of: UInt8(ascii: ".")) else { return nil }
            start = dot + 1
        }
        return nil
    }

    public func contains(_ domain: String) -> Bool {
        contains(hash: Self.hash(Self.normalized(domain)[...]))
    }

    func contains(hash: UInt64) -> Bool {
        storage.withUnsafeBytes { raw in
            var low = 0, high = count
            while low < high {
                let middle = (low + high) / 2
                let value = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: Self.headerSize + middle * 8, as: UInt64.self))
                if value == hash { return true }
                if value < hash { low = middle + 1 } else { high = middle }
            }
            return false
        }
    }

    /// Lowercase ASCII, with no dot at either end.
    static func normalized(_ host: String) -> [UInt8] {
        var bytes = host.utf8.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
        while bytes.last == UInt8(ascii: ".") { bytes.removeLast() }
        while bytes.first == UInt8(ascii: ".") { bytes.removeFirst() }
        return bytes
    }

    /// FNV-1a. A stray host matches some entry of a 500,000-domain list once in 10^13 lookups.
    static func hash<Bytes: Sequence>(_ bytes: Bytes) -> UInt64 where Bytes.Element == UInt8 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    // MARK: - Building

    /// The list file for these hashes.
    public static func encode(_ hashes: [UInt64]) -> Data {
        // Sorted, then neighbours compared: a Set of half a million hashes costs four times the array.
        var sorted = hashes.sorted()
        var kept = 0
        for index in sorted.indices where index == 0 || sorted[index] != sorted[index - 1] {
            sorted[kept] = sorted[index]
            kept += 1
        }
        sorted.removeSubrange(kept...)
        var data = Data(capacity: headerSize + sorted.count * 8)
        data.append(contentsOf: magic)
        withUnsafeBytes(of: version.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(sorted.count).littleEndian) { data.append(contentsOf: $0) }
        sorted.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    /// A hash for every domain in a public blocklist, read a line at a time without making a
    /// string of each. Takes plain domain lists (`example.com`, `*.example.com`), hosts files
    /// (`0.0.0.0 example.com`) and domain-only filter rules (`||example.com^`); `#` and `!` start
    /// a comment. A leading `www.` is dropped, since an entry covers its subdomains.
    public static func hashes(inListText text: Data) -> [UInt64] {
        var hashes: [UInt64] = []
        hashes.reserveCapacity(text.count / 16)
        text.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var lineStart = 0
            let end = raw.count
            while lineStart < end {
                var lineEnd = lineStart
                while lineEnd < end, raw[lineEnd] != 0x0A { lineEnd += 1 }
                if let hash = domainHash(inLine: raw[lineStart..<lineEnd]) { hashes.append(hash) }
                lineStart = lineEnd + 1
            }
        }
        return hashes
    }

    private static let hostsFileAddresses: Set<[UInt8]> = [
        Array("0.0.0.0".utf8), Array("127.0.0.1".utf8), Array("::".utf8), Array("::1".utf8),
    ]
    private static let neverListed: Set<[UInt8]> = [Array("localhost.localdomain".utf8)]

    private static func domainHash(inLine line: Slice<UnsafeRawBufferPointer>) -> UInt64? {
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0D }
        var tokens: [Slice<UnsafeRawBufferPointer>] = []
        var index = line.startIndex
        while index < line.endIndex, tokens.count < 2 {
            while index < line.endIndex, isSpace(line[index]) { index += 1 }
            guard index < line.endIndex, line[index] != UInt8(ascii: "#"), line[index] != UInt8(ascii: "!") else { break }
            let start = index
            while index < line.endIndex, !isSpace(line[index]), line[index] != UInt8(ascii: "#") { index += 1 }
            tokens.append(line[start..<index])
        }
        guard var token = tokens.first else { return nil }
        if tokens.count == 2, hostsFileAddresses.contains(Array(token)) { token = tokens[1] }

        var bytes = token.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 }
        if bytes.starts(with: Array("||".utf8)) { bytes.removeFirst(2) }
        if bytes.last == UInt8(ascii: "^") { bytes.removeLast() }
        if bytes.starts(with: Array("*.".utf8)) { bytes.removeFirst(2) }
        if bytes.starts(with: Array("www.".utf8)) { bytes.removeFirst(4) }
        while bytes.last == UInt8(ascii: ".") { bytes.removeLast() }

        guard bytes.count >= 3, bytes.count <= 253, bytes.first != UInt8(ascii: "."), !neverListed.contains(bytes) else { return nil }
        var hasDot = false, hasLetter = false
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "."): hasDot = true
            case UInt8(ascii: "a")...UInt8(ascii: "z"): hasLetter = true
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"): break
            default: return nil
            }
        }
        // No dot is a bare name such as localhost; no letter is an address.
        guard hasDot, hasLetter else { return nil }
        return hash(bytes)
    }
}
