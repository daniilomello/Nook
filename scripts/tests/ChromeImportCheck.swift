// Licensed under GPL-3.0. See LICENSE.
//
//  ChromeImportCheck.swift
//  Nook
//
//  The Chrome importer's reading layer against synthetic files: the 1601 epoch, history rows and
//  paging from a SQLite file that is locked or mid-write the way Chrome keeps it, cookie decryption (against
//  vectors made with openssl and Python, and a round trip), bookmarks, profile and extension
//  names. Compiles the shipped source directly:
//
//    swiftc Nook/Managers/ImportManager/Chrome.swift scripts/tests/ChromeImportCheck.swift \
//           -o /tmp/chrome-import-check && /tmp/chrome-import-check [History]
//
//  With the path of a Chrome `History` file it also prints that file's counts: no URLs, no titles.
//  The keychain is never read here.
//

import CommonCrypto
import Foundation
import SQLite3

@main
struct ChromeImportCheck {
    static func main() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-import-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        checkEpoch()
        try checkHistory(in: scratch)
        try checkCookies(in: scratch)
        checkBookmarks()
        checkProfiles()
        try checkExtensions(in: scratch)
        checkSummary()
        precondition(leftoverCopies().isEmpty, "every private copy is deleted once its database is released")
        print("PASS: epoch, history paging from a locked file and from one caught mid-write, cookie decryption, bookmarks, profiles, extension names, summary")

        if CommandLine.arguments.count > 1 {
            try printCounts(of: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
    }

    // MARK: - Epoch

    static func checkEpoch() {
        precondition(chromeDate(0) == date("1601-01-01T00:00:00Z"), "Chrome's zero is 1601")
        precondition(chromeDate(11_644_473_600_000_000) == Date(timeIntervalSince1970: 0), "Unix epoch")
        precondition(chromeDate(13_350_000_000_000_000) == date("2024-01-17T21:20:00Z"))
        precondition(abs(chromeDate(13_350_000_000_500_000).timeIntervalSince1970 - 1_705_526_400.5) < 0.000_001, "microseconds survive")
        for value: Int64 in [13_350_000_000_000_000, 13_350_000_000_000_001, 13_412_345_678_901_234] {
            precondition(chromeTime(chromeDate(value)) == value, "round trip to the microsecond")
        }
    }

    // MARK: - History

    static func checkHistory(in scratch: URL) throws {
        let file = scratch.appendingPathComponent("History")
        let now = date("2026-11-01T12:00:00Z")
        let since = now.addingTimeInterval(-100 * 86_400)
        func at(_ daysAgo: Double) -> Int64 { chromeTime(now.addingTimeInterval(-daysAgo * 86_400)) }
        let chainEnd: Int64 = 0x2000_0000

        let source = try SQLite(file)
        try source.run("""
            CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT,url LONGVARCHAR,title LONGVARCHAR,visit_count INTEGER DEFAULT 0 NOT NULL,typed_count INTEGER DEFAULT 0 NOT NULL,last_visit_time INTEGER NOT NULL,hidden INTEGER DEFAULT 0 NOT NULL);
            CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT,url INTEGER NOT NULL,visit_time INTEGER NOT NULL,from_visit INTEGER,transition INTEGER DEFAULT 0 NOT NULL,segment_id INTEGER,visit_duration INTEGER DEFAULT 0 NOT NULL);
            INSERT INTO urls(id, url, title, last_visit_time) VALUES
              (1, 'https://a.example/', 'A', 0), (2, 'http://b.example/page?q=1', 'B é', 0),
              (3, 'chrome://settings/', 'Settings', 0), (4, 'https://redirect.example/', 'Hop', 0),
              (5, 'https://frame.example/', 'Frame', 0), (6, 'https://old.example/', 'Old', 0),
              (7, 'https://untitled.example/', '', 0);
            INSERT INTO visits(id, url, visit_time, transition) VALUES
              (1, 6, \(at(150)), \(chainEnd)),
              (2, 1, \(at(30)), \(chainEnd | 1)),
              (3, 4, \(at(29)), \(0x1000_0000 as Int64)),
              (4, 2, \(at(29)), \(chainEnd | 0x1000_0000)),
              (5, 5, \(at(28)), \(chainEnd | 3)),
              (6, 5, \(at(28)), \(chainEnd | 4)),
              (7, 3, \(at(27)), \(chainEnd | 1)),
              (8, 1, \(at(2)), \(chainEnd | 8)),
              (9, 1, \(at(1.5)), \(chainEnd | 10)),
              (10, 7, \(at(1)), \(Int64(Int32(bitPattern: 0xA000_0000)))),
              (11, 1, \(at(0.5)), \(chainEnd));
            """)
        // Chrome holds its files locked while it runs, and leaves a journal beside them.
        try Data().write(to: URL(fileURLWithPath: file.path + "-journal"))
        try source.run("BEGIN EXCLUSIVE")

        do {
            let db = try ChromeDatabase(copying: file)
            let listed = try chromeHistoryCount(db, since: since)
            precondition(listed == 5, "redirect hops, subframes, keyword searches, chrome:// and old visits are left out")

            let all = try chromeHistoryPage(db, since: since)
            precondition(all.visits.map(\.url) == [
                "https://a.example/", "http://b.example/page?q=1", "https://a.example/",
                "https://untitled.example/", "https://a.example/",
            ], "visits in the order Chrome recorded them")
            precondition(all.visits[1].title == "B é" && all.visits[3].title.isEmpty)
            precondition(all.visits[0].date == now.addingTimeInterval(-30 * 86_400), "visit_time converts exactly")
            precondition(all.lastVisitID == 11)

            var cursor: Int64 = 0, paged: [ChromeVisit] = [], pages = 0
            while true {
                let page = try chromeHistoryPage(db, since: since, after: cursor, limit: 2)
                if page.visits.isEmpty { break }
                precondition(page.visits.count <= 2)
                paged += page.visits
                cursor = page.lastVisitID
                pages += 1
            }
            precondition(paged == all.visits && pages == 3, "paging by visit id covers every row once")
            let wider = try chromeHistoryCount(db, since: now.addingTimeInterval(-200 * 86_400))
            precondition(wider == 6, "the window is the caller's")
            precondition(leftoverCopies().count == 1, "the copy lives in a private temporary directory")
            let attributes = try FileManager.default.attributesOfItem(atPath: leftoverCopies()[0].path)
            precondition(attributes[.posixPermissions] as? Int == 0o700, "only this user can read the copy")
            let copied = try FileManager.default.contentsOfDirectory(atPath: leftoverCopies()[0].path).sorted()
            precondition(copied == ["History", "History-journal"], "the journal comes along")
            withExtendedLifetime(db) {}
        }
        try source.run("COMMIT")
        precondition(leftoverCopies().isEmpty, "the copy goes when the database does")

        // Chrome in the middle of a write: pages already changed on disk, the journal holding the
        // originals. A read-only connection cannot use such a copy; the importer still reads what
        // was last committed.
        let busyFile = scratch.appendingPathComponent("Busy")
        let busy = try SQLite(busyFile)
        try busy.run("""
            PRAGMA cache_spill = 1;
            PRAGMA cache_size = 1;
            CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT,url LONGVARCHAR,title LONGVARCHAR,last_visit_time INTEGER NOT NULL);
            CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT,url INTEGER NOT NULL,visit_time INTEGER NOT NULL,transition INTEGER DEFAULT 0 NOT NULL);
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 3000)
              INSERT INTO urls(id, url, title, last_visit_time) SELECT i, 'https://busy.example/' || i, 'Committed', 0 FROM n;
            INSERT INTO visits(url, visit_time, transition) SELECT id, \(at(1)), \(chainEnd) FROM urls;
            BEGIN;
            UPDATE urls SET url = 'chrome://rewritten/' || id, title = 'Uncommitted';
            DELETE FROM visits WHERE id % 2 = 0;
            """)
        let journalSize = try FileManager.default.attributesOfItem(atPath: busyFile.path + "-journal")[.size] as? Int ?? 0
        precondition(journalSize > 0, "the fixture has a journal in use")
        let manual = scratch.appendingPathComponent("manual")
        try FileManager.default.createDirectory(at: manual, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: busyFile, to: manual.appendingPathComponent("Busy"))
        try FileManager.default.copyItem(atPath: busyFile.path + "-journal", toPath: manual.path + "/Busy-journal")
        var readOnly: OpaquePointer?
        sqlite3_open_v2(manual.path + "/Busy", &readOnly, SQLITE_OPEN_READONLY, nil)
        precondition(sqlite3_exec(readOnly, "SELECT count(*) FROM urls", nil, nil, nil) != SQLITE_OK, "read-only alone fails on a hot journal")
        sqlite3_close(readOnly)
        do {
            let db = try ChromeDatabase(copying: busyFile)
            let committed = try chromeHistoryCount(db, since: since)
            let page = try chromeHistoryPage(db, since: since, limit: 5)
            precondition(committed == 3000 && page.visits.allSatisfy { $0.title == "Committed" }, "the copy is rolled back to the last commit")
        }
        try busy.run("ROLLBACK")

        do {
            _ = try ChromeDatabase(copying: scratch.appendingPathComponent("Missing"))
            preconditionFailure("a missing file throws")
        } catch let error as ChromeImportError {
            precondition(error == .missing("Missing"))
        }
        try Data("not a database".utf8).write(to: scratch.appendingPathComponent("Garbage"))
        do {
            _ = try ChromeDatabase(copying: scratch.appendingPathComponent("Garbage"))
            preconditionFailure("a file that is not SQLite throws")
        } catch let error as ChromeImportError {
            precondition(error == .unreadable("Garbage"))
        }
    }

    // MARK: - Cookies

    static func checkCookies(in scratch: URL) throws {
        // PBKDF2-HMAC-SHA1("check-password", "saltysalt", 1003, 16) from Python's hashlib.
        let key = chromeCookieKey(password: Data("check-password".utf8))
        precondition(hex(key) == "5ea4c6f448c23cba0175912988a4cb9f", "key derivation matches hashlib")

        // SHA-256(".example.com") + "sess=abc123; café", encrypted with openssl enc -aes-128-cbc.
        let reference = unhex("7631300b1d7e1785ffb7c9f6a1e3f66a33e4977c1a6c0f5e5fd7c47671d609adc5cb8e4a8627620ab7f5838c4cedd1785bf4188a2000a55a6cbb77d1dca0f65f031fe2")
        precondition(decryptChromeCookie(reference, key: key, host: ".example.com", hostHashPrefixed: true) == "sess=abc123; café",
                     "an openssl ciphertext with the version 24 host hash decrypts")
        precondition(decryptChromeCookie(reference, key: key, host: ".other.example", hostHashPrefixed: true) == nil,
                     "a value moved to another host is refused")
        let legacy = unhex("763130097c3897306ba7b4d0de1eeb86108891")
        precondition(decryptChromeCookie(legacy, key: key, host: "any", hostHashPrefixed: false) == "legacy-value",
                     "before version 24 there is no prefix to remove")

        let wrongKey = chromeCookieKey(password: Data("another-password".utf8))
        precondition(decryptChromeCookie(reference, key: wrongKey, host: ".example.com", hostHashPrefixed: true) == nil, "wrong key")
        precondition(decryptChromeCookie(Data("v11".utf8) + reference.dropFirst(3), key: key, host: ".example.com", hostHashPrefixed: true) == nil, "unknown tag")
        precondition(decryptChromeCookie(Data("v10".utf8), key: key, host: "x", hostHashPrefixed: true) == nil, "no ciphertext")
        precondition(decryptChromeCookie(reference.dropLast(1), key: key, host: ".example.com", hostHashPrefixed: true) == nil, "truncated")

        // Round trip through this file's own encryption, for values of several lengths.
        for value in ["", "x", String(repeating: "0123456789abcdef", count: 4), "töken=✓; path"] {
            let sealed = encrypt(value, key: key, host: "site.example", hostHash: true)
            precondition(decryptChromeCookie(sealed, key: key, host: "site.example", hostHashPrefixed: true) == value, "round trip")
        }

        let now = date("2026-11-01T12:00:00Z")
        let future = chromeTime(now.addingTimeInterval(86_400 * 30))
        let past = chromeTime(now.addingTimeInterval(-86_400))
        let file = scratch.appendingPathComponent("Cookies")
        let source = try SQLite(file)
        try source.run("""
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            INSERT INTO meta VALUES ('version', '24'), ('last_compatible_version', '24');
            CREATE TABLE cookies(creation_utc INTEGER NOT NULL,host_key TEXT NOT NULL,top_frame_site_key TEXT NOT NULL,name TEXT NOT NULL,value TEXT NOT NULL,encrypted_value BLOB NOT NULL,path TEXT NOT NULL,expires_utc INTEGER NOT NULL,is_secure INTEGER NOT NULL,is_httponly INTEGER NOT NULL,last_access_utc INTEGER NOT NULL,has_expires INTEGER NOT NULL,is_persistent INTEGER NOT NULL,priority INTEGER NOT NULL,samesite INTEGER NOT NULL,source_scheme INTEGER NOT NULL,source_port INTEGER NOT NULL,last_update_utc INTEGER NOT NULL,source_type INTEGER NOT NULL,has_cross_site_ancestor INTEGER NOT NULL);
            """)
        func insert(_ host: String, _ name: String, plain: String = "", sealed: Data = Data(), path: String = "/", expires: Int64,
                    secure: Int = 0, httpOnly: Int = 0, sameSite: Int = -1, partition: String = "") throws {
            try source.run("""
                INSERT INTO cookies VALUES (0, '\(host)', '\(partition)', '\(name)', '\(plain)', x'\(hex(sealed))', '\(path)', \(expires),
                  \(secure), \(httpOnly), 0, \(expires == 0 ? 0 : 1), \(expires == 0 ? 0 : 1), 1, \(sameSite), 2, 443, 0, 0, 0)
                """)
        }
        try insert(".example.com", "session", sealed: reference, expires: future, secure: 1, httpOnly: 1, sameSite: 1)
        try insert("app.example.org", "tab", sealed: encrypt("only-this-tab", key: key, host: "app.example.org", hostHash: true), path: "/app", expires: 0)
        try insert("strict.example", "s", sealed: encrypt("v", key: key, host: "strict.example", hostHash: true), expires: future, sameSite: 2)
        try insert("none.example", "n", sealed: encrypt("v", key: key, host: "none.example", hostHash: true), expires: future, secure: 1, sameSite: 0)
        try insert("plain.example", "old", plain: "unencrypted", expires: future)
        try insert("gone.example", "expired", sealed: encrypt("v", key: key, host: "gone.example", hostHash: true), expires: past)
        try insert("embed.example", "chips", sealed: encrypt("v", key: key, host: "embed.example", hostHash: true), expires: future, partition: "https://top.example")
        try insert("stolen.example", "moved", sealed: reference, expires: future)
        try insert("other.example", "foreign", sealed: encrypt("v", key: wrongKey, host: "other.example", hostHash: true), expires: future)

        let read = try readChromeCookies(try ChromeDatabase(copying: file), key: key, now: now)
        precondition(read.expired == 1 && read.partitioned == 1 && read.undecryptable == 2 && read.skipped == 4)
        precondition(read.cookies.map(\.name) == ["session", "tab", "s", "n", "old"])
        precondition(read.cookies[0] == ChromeCookie(
            host: ".example.com", name: "session", value: "sess=abc123; café", path: "/",
            expires: now.addingTimeInterval(86_400 * 30), isSecure: true, isHTTPOnly: true, sameSite: .lax))
        precondition(read.cookies[1].expires == nil && read.cookies[1].value == "only-this-tab" && read.cookies[1].sameSite == .unspecified)
        precondition(read.cookies[4].value == "unencrypted", "a value Chrome left in the clear is used as it is")
        let mismatched = try readChromeCookies(try ChromeDatabase(copying: file), key: wrongKey, now: now)
        precondition(mismatched.cookies.map(\.name) == ["old", "foreign"] && mismatched.undecryptable == 5,
                     "with another key only the values in the clear and the ones it sealed come through")

        let session = httpCookie(from: read.cookies[0])!
        precondition(session.domain == ".example.com" && session.name == "session" && session.value == "sess=abc123; café" && session.path == "/")
        precondition(session.isSecure && session.isHTTPOnly && !session.isSessionOnly && session.sameSitePolicy == .sameSiteLax)
        precondition(session.expiresDate == now.addingTimeInterval(86_400 * 30))
        let tab = httpCookie(from: read.cookies[1])!
        precondition(tab.domain == "app.example.org" && tab.path == "/app" && tab.isSessionOnly && !tab.isSecure && !tab.isHTTPOnly)
        precondition(tab.sameSitePolicy == nil, "no SameSite stays no SameSite")
        precondition(httpCookie(from: read.cookies[2])!.sameSitePolicy == .sameSiteStrict)
        precondition(httpCookie(from: read.cookies[3])!.sameSitePolicy == nil && httpCookie(from: read.cookies[3])!.isSecure)
        precondition(httpCookie(from: ChromeCookie(host: "x.example", name: "", value: "v", path: "/", expires: nil,
                                                   isSecure: false, isHTTPOnly: false, sameSite: .none)) == nil, "a nameless cookie is not built")

        // An older file: version 23, no partition column, no host hash.
        let oldFile = scratch.appendingPathComponent("OldCookies")
        let old = try SQLite(oldFile)
        try old.run("""
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            INSERT INTO meta VALUES ('version', '23');
            CREATE TABLE cookies(host_key TEXT NOT NULL,name TEXT NOT NULL,value TEXT NOT NULL,encrypted_value BLOB NOT NULL,path TEXT NOT NULL,expires_utc INTEGER NOT NULL,is_secure INTEGER NOT NULL,is_httponly INTEGER NOT NULL,has_expires INTEGER NOT NULL,is_persistent INTEGER NOT NULL,samesite INTEGER NOT NULL);
            INSERT INTO cookies VALUES ('legacy.example', 'l', '', x'\(hex(legacy))', '/', \(future), 0, 0, 1, 1, 0);
            """)
        let oldRead = try readChromeCookies(try ChromeDatabase(copying: oldFile), key: key, now: now)
        precondition(oldRead.cookies.map(\.value) == ["legacy-value"] && oldRead.skipped == 0 && oldRead.cookies[0].sameSite == ChromeSameSite.none)
    }

    // MARK: - Bookmarks

    static func checkBookmarks() {
        let bookmarks = parseChromeBookmarks(Data("""
        {"checksum": "x", "version": 1, "roots": {
          "bookmark_bar": {"type": "folder", "name": "Bookmarks bar", "children": [
            {"type": "url", "name": "First", "url": "https://first.example/"},
            {"type": "folder", "name": "Work", "children": [
              {"type": "url", "name": "Docs", "url": "https://docs.example/a?b=c"},
              {"type": "folder", "name": "Deep", "children": [{"type": "url", "name": "", "url": "http://deep.example"}]},
              {"type": "folder", "name": "Empty", "children": []},
              {"type": "folder", "name": "Only scripts", "children": [{"type": "url", "name": "Run", "url": "javascript:void(0)"}]}
            ]},
            {"type": "url", "name": "Bookmarklet", "url": "javascript:alert(1)"},
            {"type": "url", "name": "Settings", "url": "chrome://settings"},
            {"type": "url", "name": "Local", "url": "file:///tmp/a.html"}
          ]},
          "other": {"type": "folder", "name": "Other bookmarks", "children": [
            {"type": "url", "name": "Other", "url": "HTTPS://other.example/"}
          ]},
          "synced": {"type": "folder", "name": "Mobile bookmarks", "children": []}
        }}
        """.utf8))
        precondition(bookmarks.bar == [
            .url(title: "First", url: "https://first.example/"),
            .folder(title: "Work", children: [
                .url(title: "Docs", url: "https://docs.example/a?b=c"),
                .folder(title: "Deep", children: [.url(title: "", url: "http://deep.example")]),
            ]),
            .url(title: "Local", url: "file:///tmp/a.html"),
        ], "order and nesting kept; bookmarklets, chrome:// pages and emptied folders dropped")
        precondition(bookmarks.other == [.url(title: "Other", url: "HTTPS://other.example/")])
        precondition(bookmarks.mobile.isEmpty && bookmarks.urlCount == 5 && !bookmarks.isEmpty)
        precondition(parseChromeBookmarks(Data("{}".utf8)).isEmpty && parseChromeBookmarks(Data("nonsense".utf8)).isEmpty)
    }

    // MARK: - Profiles

    static func checkProfiles() {
        let state = Data("""
        {"profile": {"info_cache": {
          "Default": {"name": "Person 1", "user_name": "one@example.com"},
          "Profile 1": {"name": "Person 1", "user_name": ""},
          "Profile 10": {"name": "Work"},
          "Profile 2": {"name": ""},
          "Profile 7": {"name": "Deleted"}
        }}}
        """.utf8)
        let found = parseChromeProfiles(localState: state, directories: ["Profile 10", "Local State", "Profile 2", "Default", "System Profile", "Profile 1", "Guest Profile"])
        precondition(found.map(\.directory) == ["Default", "Profile 1", "Profile 2", "Profile 10"], "only profile directories that exist, by number")
        precondition(found.map(\.name) == ["Person 1", "Person 1", "Profile 2", "Work"], "a missing name falls back to the directory")
        precondition(found[0].account == "one@example.com" && found[1].account == nil)

        let ordered = Data(#"{"profile": {"profiles_order": ["Profile 2", "Default"], "info_cache": {}}}"#.utf8)
        precondition(parseChromeProfiles(localState: ordered, directories: ["Default", "Profile 1", "Profile 2"]).map(\.directory)
                     == ["Profile 2", "Default", "Profile 1"], "Chrome's own order first")
        precondition(parseChromeProfiles(localState: nil, directories: ["Default"]).map(\.name) == ["Default"], "no Local State")

        let root = URL(fileURLWithPath: "/tmp/chrome")
        precondition(ChromeProfile(directory: "Profile 1", name: "Person 1", account: "a@b.c", url: root).label == "Person 1 \u{2014} Profile 1 (a@b.c)")
        precondition(ChromeProfile(directory: "Default", name: "Default", account: nil, url: root).label == "Default")
    }

    // MARK: - Extensions

    static func checkExtensions(in scratch: URL) throws {
        let extensions = scratch.appendingPathComponent("Extensions")
        func write(_ id: String, _ version: String, manifest: String, locales: [String: String] = [:]) throws {
            let directory = extensions.appendingPathComponent("\(id)/\(version)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(manifest.utf8).write(to: directory.appendingPathComponent("manifest.json"))
            for (locale, messages) in locales {
                let folder = directory.appendingPathComponent("_locales/\(locale)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data(messages.utf8).write(to: folder.appendingPathComponent("messages.json"))
            }
        }
        try write(chromeOnePasswordID, "8.9.0_0", manifest: #"{"name": "__MSG_extName__", "default_locale": "en"}"#,
                  locales: ["en": #"{"extname": {"message": "Old name"}}"#])
        try write(chromeOnePasswordID, "8.12.46_0", manifest: #"{"name": "__MSG_extName__", "default_locale": "en"}"#,
                  locales: ["en": #"{"extname": {"message": "1Password – Password Manager"}}"#, "de": #"{"extName": {"message": "Falsch"}}"#])
        try write("plainplainplainplainplainplainpl", "1.0_0", manifest: #"{"name": "Plain Name"}"#)
        try write("localelocalelocalelocalelocalelo", "2.0_0", manifest: #"{"name": "__MSG_appName__", "default_locale": "pt_BR"}"#,
                  locales: ["pt_BR": #"{"appName": {"message": "nome local"}}"#, "en": #"{"appName": {"message": "english"}}"#])
        try write("fallbackfallbackfallbackfallback", "1_0", manifest: #"{"name": "__MSG_title__", "default_locale": "fr"}"#,
                  locales: ["en": #"{"title": {"message": "Zed fallback"}}"#])
        try write("unresolvedunresolvedunresolvedun", "1_0", manifest: #"{"name": "__MSG_missing__", "default_locale": "en"}"#)
        try write("themethemethemethemethemethemeth", "1_0", manifest: #"{"name": "A Theme", "theme": {}}"#)
        try write("appappappappappappappappappappap", "1_0", manifest: #"{"name": "A Legacy App", "app": {"launch": {}}}"#)

        let found = chromeExtensions(ids: [
            "unresolvedunresolvedunresolvedun", "plainplainplainplainplainplainpl", "notunpackednotunpackednotunpacke",
            "themethemethemethemethemethemeth", chromeOnePasswordID, "appappappappappappappappappappap",
            "fallbackfallbackfallbackfallback", "localelocalelocalelocalelocalelo",
        ], in: extensions)
        precondition(found.map(\.name) == [
            "1Password \u{2013} Password Manager", "nome local", "Plain Name", "unresolvedunresolvedunresolvedun", "Zed fallback",
        ], "newest version, default locale, key without regard to case, English fallback, id when nothing resolves; themes, apps and ids without files left out")
        precondition(found[0].id == chromeOnePasswordID)
    }

    // MARK: - Summary

    static func checkSummary() {
        var summary = ChromeImportSummary()
        precondition(summary.isEmpty && summary.lines.isEmpty)
        summary.visits = 812
        summary.cookies = 1
        summary.cookiesSkipped = 7
        summary.bookmarks = 12
        summary.bookmarkFolders = 1
        summary.extensions = 1
        precondition(summary.lines == [
            "812 history visits", "1 cookie (7 expired or unusable left out)", "12 bookmarks in 1 folder", "1 extension to install next",
        ])
        precondition(!summary.isEmpty)
        precondition(ChromeImportError.keychainDenied.message.contains("denied"))
    }

    // MARK: - A real file

    /// Counts and the date range only.
    static func printCounts(of file: URL) throws {
        let db = try ChromeDatabase(copying: file)
        let since = Date().addingTimeInterval(-100 * 86_400)
        let total = try chromeHistoryCount(db, since: since)
        var cursor: Int64 = 0, read = 0, pages = 0, withoutTitle = 0, unparseable = 0
        var oldest = Date.distantFuture, newest = Date.distantPast
        var urls = Set<Int>()
        let start = Date()
        while true {
            let page = try chromeHistoryPage(db, since: since, after: cursor, limit: 1000)
            if page.visits.isEmpty { break }
            cursor = page.lastVisitID
            pages += 1
            read += page.visits.count
            for visit in page.visits {
                oldest = min(oldest, visit.date)
                newest = max(newest, visit.date)
                urls.insert(visit.url.hashValue)
                if visit.title.isEmpty { withoutTitle += 1 }
                if URL(string: visit.url) == nil { unparseable += 1 }
            }
        }
        precondition(read == total, "paging returns exactly the counted rows")
        precondition(read == 0 || (oldest >= since && newest <= Date().addingTimeInterval(86_400)), "dates fall inside the window")
        let format = ISO8601DateFormatter()
        print("\(file.lastPathComponent): \(total) visits to \(urls.count) pages in the last 100 days, \(pages) pages of 1000, " +
              "\(withoutTitle) without a title, \(unparseable) URLs Foundation rejects, " +
              "\(read == 0 ? "no dates" : "\(format.string(from: oldest)) to \(format.string(from: newest))"), " +
              String(format: "read in %.2f s", Date().timeIntervalSince(start)))
    }

    // MARK: - Helpers

    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func unhex(_ text: String) -> Data {
        var data = Data(), index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            data.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    /// The importer's private copies still on disk.
    static func leftoverCopies() -> [URL] {
        let temporary = FileManager.default.temporaryDirectory
        return ((try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [])
            .filter { $0.hasPrefix("nook-chrome-import-") }.map { temporary.appendingPathComponent($0) }
    }

    /// What Chrome does on macOS: "v10", then AES-128-CBC over the host's SHA-256 and the value.
    static func encrypt(_ value: String, key: Data, host: String, hostHash: Bool) -> Data {
        var plain = [UInt8]()
        if hostHash {
            var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            let bytes = Array(host.utf8)
            CC_SHA256(bytes, CC_LONG(bytes.count), &hash)
            plain += hash
        }
        plain += Array(value.utf8)
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let capacity = plain.count + kCCBlockSizeAES128
        var cipher = [UInt8](repeating: 0, count: capacity)
        var length = 0
        let status = key.withUnsafeBytes { keyBytes in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, key.count, iv, plain, plain.count, &cipher, capacity, &length)
        }
        precondition(status == kCCSuccess)
        return Data("v10".utf8) + Data(cipher[..<length])
    }
}

/// A writable SQLite file for building fixtures.
final class SQLite {
    private var handle: OpaquePointer?

    init(_ file: URL) throws {
        guard sqlite3_open(file.path, &handle) == SQLITE_OK else { throw ChromeImportError.unreadable(file.lastPathComponent) }
    }

    deinit { sqlite3_close(handle) }

    func run(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "?"
            sqlite3_free(message)
            preconditionFailure("fixture SQL failed: \(text)")
        }
    }
}
