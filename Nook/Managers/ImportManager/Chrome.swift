// Licensed under GPL-3.0. See LICENSE.
//
//  Chrome.swift
//  Nook
//
//  Reads a Google Chrome profile: history, cookies, bookmarks and extension names. Parsing only;
//  `BrowserManager+ChromeImport.swift` applies what comes out. Nothing here logs or prints what it
//  reads: cookie values, the Safe Storage password and history URLs stay in memory.
//

import CommonCrypto
import Foundation
import Security
import SQLite3

// MARK: - Profiles

/// One Chrome profile directory. Several profiles can share a display name ("Person 1"), so the
/// directory and the signed-in account are kept to tell them apart.
struct ChromeProfile: Equatable, Identifiable {
    /// "Default" or "Profile 1".
    let directory: String
    /// The name in Chrome's profile menu.
    let name: String
    /// The Google account signed in to the profile, when there is one.
    let account: String?
    let url: URL

    var id: String { directory }

    /// "Work — Profile 1 (me@example.com)".
    var label: String {
        var text = name == directory ? name : "\(name) \u{2014} \(directory)"
        if let account, !account.isEmpty { text += " (\(account))" }
        return text
    }
}

/// Chrome Web Store id of the 1Password extension, the one extension an import picks by default.
let chromeOnePasswordID = "aeblfdkhhhdcdjpifhhbdiojplfjncoa"

var chromeDataDirectory: URL {
    URL(fileURLWithPath: NSString(string: "~/Library/Application Support/Google/Chrome").expandingTildeInPath)
}

/// The profiles under Chrome's data directory, in Chrome's own order.
func chromeProfiles(in root: URL = chromeDataDirectory) -> [ChromeProfile] {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    let localState = try? Data(contentsOf: root.appendingPathComponent("Local State"))
    return parseChromeProfiles(localState: localState, directories: entries).map {
        ChromeProfile(directory: $0.directory, name: $0.name, account: $0.account,
                      url: root.appendingPathComponent($0.directory, isDirectory: true))
    }
}

/// Names for the profile directories that exist, from `Local State`'s `profile.info_cache`.
/// `Default` comes first and the rest follow by number, unless Chrome recorded its own order.
func parseChromeProfiles(localState: Data?, directories: [String]) -> [(directory: String, name: String, account: String?)] {
    let root = localState.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    let profile = root?["profile"] as? [String: Any]
    let cache = profile?["info_cache"] as? [String: Any] ?? [:]
    let order = profile?["profiles_order"] as? [String] ?? []

    let found = directories.filter { $0 == "Default" || $0.hasPrefix("Profile ") }
    func rank(_ directory: String) -> (Int, Int) {
        if let index = order.firstIndex(of: directory) { return (0, index) }
        return (1, directory == "Default" ? -1 : Int(directory.dropFirst("Profile ".count)) ?? .max)
    }
    return found.sorted { rank($0) < rank($1) }.map { directory in
        let info = cache[directory] as? [String: Any]
        let name = (info?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let account = (info?["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (directory, name ?? directory, account)
    }
}

// MARK: - Time

/// Seconds from Chrome's epoch (1601-01-01 UTC) to Unix's.
private let chromeEpochOffset: Int64 = 11_644_473_600

/// Chrome stores times as microseconds since 1601-01-01 UTC. Split into whole seconds first: the
/// raw count no longer fits a Double exactly.
func chromeDate(_ microseconds: Int64) -> Date {
    let seconds = microseconds / 1_000_000 - chromeEpochOffset
    return Date(timeIntervalSince1970: Double(seconds) + Double(microseconds % 1_000_000) / 1_000_000)
}

func chromeTime(_ date: Date) -> Int64 {
    let whole = date.timeIntervalSince1970.rounded(.down)
    return (Int64(whole) + chromeEpochOffset) * 1_000_000 + Int64(((date.timeIntervalSince1970 - whole) * 1_000_000).rounded())
}

// MARK: - Errors

enum ChromeImportError: Error, Equatable {
    /// The profile has no such file.
    case missing(String)
    /// SQLite could not read the copy.
    case unreadable(String)
    /// The person declined the keychain prompt.
    case keychainDenied
    /// Chrome never stored a Safe Storage key on this Mac.
    case keychainItemMissing
    case keychain(OSStatus)

    /// A sentence for the import summary.
    var message: String {
        switch self {
        case .missing(let file): return "This Chrome profile has no \(file) file."
        case .unreadable(let file): return "Chrome's \(file) file could not be read."
        case .keychainDenied: return "Keychain access was denied, so Chrome's cookies stayed encrypted."
        case .keychainItemMissing: return "The keychain has no \u{201C}Chrome Safe Storage\u{201D} key to decrypt Chrome's cookies with."
        case .keychain(let status): return "The keychain could not provide Chrome's cookie key (error \(status))."
        }
    }
}

// MARK: - SQLite

/// A private copy of one of Chrome's SQLite files. Chrome keeps the original locked while it
/// runs, so the file and its journal siblings are copied to a temporary directory only this user
/// can read, opened there, and deleted when this object goes away.
final class ChromeDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let directory: URL
    private let name: String

    init(copying source: URL) throws {
        name = source.lastPathComponent
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nook-chrome-import-\(UUID().uuidString)", isDirectory: true)
        let files = FileManager.default
        guard files.fileExists(atPath: source.path) else { throw ChromeImportError.missing(name) }
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let copy = directory.appendingPathComponent(name)
            try files.copyItem(at: source, to: copy)
            for suffix in ["-wal", "-journal", "-shm"] where files.fileExists(atPath: source.path + suffix) {
                try? files.copyItem(at: URL(fileURLWithPath: source.path + suffix), to: URL(fileURLWithPath: copy.path + suffix))
            }
            handle = try Self.open(copy)
        } catch {
            try? files.removeItem(at: directory)
            throw (error as? ChromeImportError) ?? ChromeImportError.unreadable(name)
        }
    }

    deinit {
        sqlite3_close(handle)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Read-only first. A copy taken in the middle of one of Chrome's writes carries a hot journal,
    /// which only a writable connection can roll back; the copy is ours, so that is the fallback.
    private static func open(_ file: URL) throws -> OpaquePointer? {
        for mode in [SQLITE_OPEN_READONLY, SQLITE_OPEN_READWRITE] {
            var db: OpaquePointer?
            if sqlite3_open_v2(file.path, &db, mode | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
               sqlite3_exec(db, "SELECT count(*) FROM sqlite_master; PRAGMA query_only = ON;", nil, nil, nil) == SQLITE_OK {
                return db
            }
            sqlite3_close(db)
        }
        throw ChromeImportError.unreadable(file.lastPathComponent)
    }

    /// Runs `sql` with integer arguments bound to `?1`, `?2`… and hands each row to `row`.
    func query(_ sql: String, _ arguments: [Int64] = [], row: (ChromeRow) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw ChromeImportError.unreadable(name) }
        defer { sqlite3_finalize(statement) }
        for (index, value) in arguments.enumerated() { sqlite3_bind_int64(statement, Int32(index + 1), value) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(ChromeRow(statement: statement))
            case SQLITE_DONE: return
            default: throw ChromeImportError.unreadable(name)
            }
        }
    }

    func columns(of table: String) throws -> Set<String> {
        var names = Set<String>()
        try query("PRAGMA table_info(\(table))") { names.insert($0.text(1)) }
        return names
    }
}

struct ChromeRow {
    fileprivate let statement: OpaquePointer?

    func int(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }

    func text(_ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    func data(_ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}

// MARK: - History

struct ChromeVisit: Equatable {
    let url: String
    let title: String
    let date: Date
}

/// The visits Chrome's own History page lists: the end of each redirect chain, without subframe
/// loads and keyword-generated searches (`ui::PageTransition`), and only web pages.
private let chromeListedVisits = """
    FROM visits v JOIN urls u ON u.id = v.url
    WHERE v.visit_time >= ?1 AND v.id > ?2
      AND (v.transition & 0x20000000) != 0 AND (v.transition & 0xFF) NOT IN (3, 4, 10)
      AND (u.url LIKE 'http://%' OR u.url LIKE 'https://%')
    """

func chromeHistoryCount(_ db: ChromeDatabase, since: Date) throws -> Int {
    var count = 0
    try db.query("SELECT count(*) \(chromeListedVisits)", [chromeTime(since), 0]) { count = Int($0.int(0)) }
    return count
}

/// Up to `limit` visits from `since` on, in the order Chrome recorded them, starting after the
/// visit `visitID`. A profile's history runs to hundreds of thousands of rows, so callers page
/// through it with the returned `lastVisitID` instead of holding it all. An empty page is the end.
func chromeHistoryPage(_ db: ChromeDatabase, since: Date, after visitID: Int64 = 0, limit: Int = 1000)
    throws -> (visits: [ChromeVisit], lastVisitID: Int64) {
    var visits: [ChromeVisit] = []
    var last = visitID
    visits.reserveCapacity(limit)
    try db.query("SELECT v.id, u.url, u.title, v.visit_time \(chromeListedVisits) ORDER BY v.id LIMIT \(max(limit, 1))",
                 [chromeTime(since), visitID]) { row in
        last = row.int(0)
        visits.append(ChromeVisit(url: row.text(1), title: row.text(2), date: chromeDate(row.int(3))))
    }
    return (visits, last)
}

// MARK: - Cookies

enum ChromeSameSite: Int64 {
    case unspecified = -1, none = 0, lax = 1, strict = 2
}

struct ChromeCookie: Equatable {
    /// `host_key`: a leading dot marks a cookie its subdomains also get.
    let host: String
    let name: String
    let value: String
    let path: String
    /// Nil for a session cookie.
    let expires: Date?
    let isSecure: Bool
    let isHTTPOnly: Bool
    let sameSite: ChromeSameSite
}

struct ChromeCookieRead: Equatable {
    var cookies: [ChromeCookie] = []
    var expired = 0
    /// Cookies partitioned by top-level site (CHIPS). WebKit's cookie store has no way to set
    /// the partition, and without it they would turn into ordinary third-party cookies.
    var partitioned = 0
    /// Values that did not decrypt with the key, or did not carry their host's hash.
    var undecryptable = 0

    var skipped: Int { expired + partitioned + undecryptable }
}

/// Reads the generic password "Chrome Safe Storage" (account "Chrome"). The item belongs to
/// Chrome, so macOS asks the person to approve the read; this blocks until they answer.
func chromeSafeStoragePassword() throws -> Data {
    let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "Chrome Safe Storage",
        kSecAttrAccount: "Chrome",
        kSecMatchLimit: kSecMatchLimitOne,
        kSecReturnData: true,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    switch status {
    case errSecSuccess:
        guard let password = item as? Data, !password.isEmpty else { throw ChromeImportError.keychainItemMissing }
        return password
    case errSecItemNotFound:
        throw ChromeImportError.keychainItemMissing
    case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
        throw ChromeImportError.keychainDenied
    default:
        throw ChromeImportError.keychain(status)
    }
}

/// Chrome's cookie key on macOS: PBKDF2-HMAC-SHA1 of the Safe Storage password with the salt
/// `saltysalt`, 1003 rounds, 16 bytes (`os_crypt_mac.mm`).
func chromeCookieKey(password: Data) -> Data {
    let salt = Array("saltysalt".utf8)
    var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
    let status = password.withUnsafeBytes { bytes in
        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.bindMemory(to: CChar.self).baseAddress, password.count,
                             salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
    }
    return status == kCCSuccess ? Data(key) : Data()
}

/// Decrypts one `encrypted_value`: the tag `v10`, then AES-128-CBC with an IV of 16 spaces.
/// From cookie database version 24 the plaintext starts with the SHA-256 of the cookie's host,
/// which is checked and removed. Nil when the tag, key, padding, hash or text encoding is wrong.
func decryptChromeCookie(_ encrypted: Data, key: Data, host: String, hostHashPrefixed: Bool) -> String? {
    let tag = Data("v10".utf8)
    guard encrypted.starts(with: tag), key.count == kCCKeySizeAES128 else { return nil }
    let cipher = encrypted.dropFirst(tag.count)
    guard !cipher.isEmpty, cipher.count.isMultiple(of: kCCBlockSizeAES128) else { return nil }

    let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
    var plain = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
    var length = 0
    let status = cipher.withUnsafeBytes { input in
        key.withUnsafeBytes { keyBytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, key.count, iv, input.baseAddress, cipher.count, &plain, plain.count, &length)
        }
    }
    guard status == kCCSuccess else { return nil }
    var value = Data(plain[..<length])
    if hostHashPrefixed {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        let hostBytes = Array(host.utf8)
        CC_SHA256(hostBytes, CC_LONG(hostBytes.count), &hash)
        guard value.count >= hash.count, value.prefix(hash.count).elementsEqual(hash) else { return nil }
        value = value.dropFirst(hash.count)
    }
    return String(data: value, encoding: .utf8)
}

/// Every cookie of a profile's `Cookies` file that is still valid, with its value decrypted.
func readChromeCookies(_ db: ChromeDatabase, key: Data, now: Date = Date()) throws -> ChromeCookieRead {
    var version: Int64 = 0
    try db.query("SELECT value FROM meta WHERE key = 'version'") { version = $0.int(0) }
    // Chrome 119 added the partition key; older files have no such column.
    let partition = try db.columns(of: "cookies").contains("top_frame_site_key") ? "top_frame_site_key" : "''"

    var read = ChromeCookieRead()
    try db.query("""
        SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite, has_expires, \(partition)
        FROM cookies
        """) { row in
        let host = row.text(0)
        let expires = row.int(9) != 0 && row.int(5) != 0 ? chromeDate(row.int(5)) : nil
        if let expires, expires <= now { read.expired += 1; return }
        guard row.text(10).isEmpty else { read.partitioned += 1; return }

        var value = row.text(2)
        let encrypted = row.data(3)
        if !encrypted.isEmpty {
            guard let decrypted = decryptChromeCookie(encrypted, key: key, host: host, hostHashPrefixed: version >= 24)
            else { read.undecryptable += 1; return }
            value = decrypted
        }
        read.cookies.append(ChromeCookie(
            host: host, name: row.text(1), value: value, path: row.text(4), expires: expires,
            isSecure: row.int(6) != 0, isHTTPOnly: row.int(7) != 0,
            sameSite: ChromeSameSite(rawValue: row.int(8)) ?? .unspecified))
    }
    return read
}

/// The cookie as WebKit's cookie store takes it. `HttpOnly` has no public property key, but
/// `HTTPCookie` reads and writes it under that name. A cookie without SameSite stays without:
/// WebKit, unlike Chrome, does not treat those as Lax.
func httpCookie(from cookie: ChromeCookie) -> HTTPCookie? {
    guard !cookie.host.isEmpty, !cookie.name.isEmpty else { return nil }
    var properties: [HTTPCookiePropertyKey: Any] = [
        .domain: cookie.host,
        .name: cookie.name,
        .value: cookie.value,
        .path: cookie.path.isEmpty ? "/" : cookie.path,
    ]
    if let expires = cookie.expires { properties[.expires] = expires } else { properties[.discard] = "TRUE" }
    if cookie.isSecure { properties[.secure] = "TRUE" }
    if cookie.isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
    switch cookie.sameSite {
    case .lax: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
    case .strict: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
    case .none, .unspecified: break
    }
    return HTTPCookie(properties: properties)
}

// MARK: - Bookmarks

indirect enum ChromeBookmark: Equatable {
    case url(title: String, url: String)
    case folder(title: String, children: [ChromeBookmark])
}

struct ChromeBookmarks: Equatable {
    /// `roots.bookmark_bar`, `roots.other` and `roots.synced` (Mobile Bookmarks).
    var bar: [ChromeBookmark] = []
    var other: [ChromeBookmark] = []
    var mobile: [ChromeBookmark] = []

    var urlCount: Int { [bar, other, mobile].reduce(0) { $0 + Self.count($1) } }
    var isEmpty: Bool { urlCount == 0 }

    private static func count(_ nodes: [ChromeBookmark]) -> Int {
        nodes.reduce(0) { total, node in
            switch node {
            case .url: return total + 1
            case .folder(_, let children): return total + count(children)
            }
        }
    }
}

/// A profile's `Bookmarks` file. Only http(s) and file links are kept (bookmarklets and
/// `chrome://` pages mean nothing here), and folders left empty are dropped.
func parseChromeBookmarks(_ data: Data) -> ChromeBookmarks {
    let roots = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["roots"] as? [String: Any] ?? [:]
    func nodes(_ value: Any?) -> [ChromeBookmark] {
        (value as? [Any] ?? []).compactMap { entry -> ChromeBookmark? in
            guard let node = entry as? [String: Any] else { return nil }
            let title = node["name"] as? String ?? ""
            if node["type"] as? String == "folder" {
                let children = nodes(node["children"])
                return children.isEmpty ? nil : .folder(title: title, children: children)
            }
            guard let url = node["url"] as? String,
                  ["http://", "https://", "file://"].contains(where: { url.lowercased().hasPrefix($0) }) else { return nil }
            return .url(title: title, url: url)
        }
    }
    func root(_ key: String) -> [ChromeBookmark] { nodes((roots[key] as? [String: Any])?["children"]) }
    return ChromeBookmarks(bar: root("bookmark_bar"), other: root("other"), mobile: root("synced"))
}

// MARK: - Extensions

struct ChromeExtension: Equatable, Identifiable {
    /// Chrome Web Store id.
    let id: String
    let name: String
}

/// The extensions among `ids` that are unpacked under `<profile>/Extensions`, with their names,
/// sorted by name. Themes and legacy Chrome apps are left out: neither is an extension.
func chromeExtensions(ids: [String], in extensionsDirectory: URL) -> [ChromeExtension] {
    ids.compactMap { id -> ChromeExtension? in
        guard let manifest = chromeExtensionManifest(id: id, in: extensionsDirectory),
              manifest.json["theme"] == nil, manifest.json["app"] == nil else { return nil }
        return ChromeExtension(id: id, name: chromeExtensionName(manifest: manifest.json, versionDirectory: manifest.directory) ?? id)
    }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

/// The manifest of the newest version Chrome has unpacked for `id` (`Extensions/<id>/<version>_0`).
private func chromeExtensionManifest(id: String, in extensionsDirectory: URL) -> (json: [String: Any], directory: URL)? {
    let root = extensionsDirectory.appendingPathComponent(id, isDirectory: true)
    let versions = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    for version in versions {
        let directory = root.appendingPathComponent(version, isDirectory: true)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return (json, directory)
        }
    }
    return nil
}

/// The manifest's `name`. A `__MSG_key__` placeholder is looked up in the default locale's
/// `_locales/<locale>/messages.json`, whose keys match without regard to case.
func chromeExtensionName(manifest: [String: Any], versionDirectory: URL) -> String? {
    guard let name = manifest["name"] as? String, !name.isEmpty else { return nil }
    guard name.hasPrefix("__MSG_"), name.hasSuffix("__"), name.count > 8 else { return name }
    let key = name.dropFirst(6).dropLast(2).lowercased()
    let locales = [manifest["default_locale"] as? String, "en", "en_US"].compactMap { $0 }
    for locale in locales {
        let file = versionDirectory.appendingPathComponent("_locales/\(locale)/messages.json")
        guard let data = try? Data(contentsOf: file),
              let messages = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = messages.first(where: { $0.key.lowercased() == key })?.value as? [String: Any],
              let message = entry["message"] as? String, !message.isEmpty else { continue }
        return message
    }
    return nil
}

// MARK: - Summary

/// What one import brought in. Counts only.
struct ChromeImportSummary: Equatable {
    var visits = 0
    var cookies = 0
    /// Cookies left behind: expired, partitioned, or not decryptable.
    var cookiesSkipped = 0
    var bookmarks = 0
    var bookmarkFolders = 0
    /// Extensions queued for installation; each still asks for its permissions.
    var extensions = 0
    /// Parts that failed, as sentences.
    var problems: [String] = []
    var wasStopped = false

    var isEmpty: Bool { visits == 0 && cookies == 0 && bookmarks == 0 && extensions == 0 }

    /// One line per part that brought something in.
    var lines: [String] {
        func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
            "\(count.formatted()) \(count == 1 ? singular : plural)"
        }
        var lines: [String] = []
        if visits > 0 { lines.append(counted(visits, "history visit", "history visits")) }
        if cookies > 0 {
            let skipped = cookiesSkipped > 0 ? " (\(cookiesSkipped.formatted()) expired or unusable left out)" : ""
            lines.append(counted(cookies, "cookie", "cookies") + skipped)
        }
        if bookmarks > 0 {
            let folders = bookmarkFolders > 0 ? " in " + counted(bookmarkFolders, "folder", "folders") : ""
            lines.append(counted(bookmarks, "bookmark", "bookmarks") + folders)
        }
        if extensions > 0 { lines.append(counted(extensions, "extension", "extensions") + " to install next") }
        return lines
    }
}
