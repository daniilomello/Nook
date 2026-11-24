// Licensed under GPL-3.0. See LICENSE.
//
//  ImportManager+Chrome.swift
//  Nook
//
//  What the Chrome import dialog lists before anything is imported: the profiles, and one
//  profile's extensions and bookmarks. History and cookies are read by
//  `BrowserManager.importChromeData`.
//

import Foundation

extension ImportManager {
    func listChromeProfiles() -> [ChromeProfile] {
        chromeProfiles()
    }

    /// The Web Store extensions enabled in `profile`, by name.
    func listChromeExtensions(in profile: ChromeProfile) -> [ChromeExtension] {
        let preferences = ["Secure Preferences", "Preferences"].compactMap {
            try? Data(contentsOf: profile.url.appendingPathComponent($0))
        }
        return chromeExtensions(ids: parseChromiumExtensionIDs(preferences),
                                in: profile.url.appendingPathComponent("Extensions", isDirectory: true))
    }

    func readChromeBookmarks(in profile: ChromeProfile) -> ChromeBookmarks {
        guard let data = try? Data(contentsOf: profile.url.appendingPathComponent("Bookmarks")) else { return ChromeBookmarks() }
        return parseChromeBookmarks(data)
    }
}
