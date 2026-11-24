// Licensed under GPL-3.0. See LICENSE.
//
//  ChromeImportModel.swift
//  Nook
//
//  State of one Chrome import, shared by the dialog and the onboarding flow: the profile and
//  parts picked, progress while it runs, and the summary at the end.
//

import AppKit
import Observation

@MainActor
@Observable
final class ChromeImportModel {
    enum Phase {
        case options, importing, done
    }

    private(set) var profiles: [ChromeProfile] = []
    private(set) var selectedProfileID = ""
    var importHistory = true
    var importCookies = true
    /// Off unless asked for: a bookmarks bar can hold hundreds of links.
    var importBookmarks = false
    /// The picked profile's extensions that Nook does not have yet.
    private(set) var extensions: [ChromeExtension] = []
    var selectedExtensions: Set<String> = []
    private(set) var bookmarkCount = 0
    private(set) var spaceName: String?

    private(set) var phase: Phase = .options
    private(set) var step: ChromeImportStep?
    private(set) var summary = ChromeImportSummary()
    /// False once the view showing this model is gone; the summary then comes as an alert.
    var isPresented = true

    @ObservationIgnored private weak var browserManager: BrowserManager?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var queuedExtensions: [String] = []

    var selectedProfile: ChromeProfile? { profiles.first { $0.id == selectedProfileID } }

    var canStart: Bool {
        phase == .options && selectedProfile != nil
            && (importHistory || importCookies || importBookmarks || !selectedExtensions.isEmpty)
    }

    /// Known only while history is coming in; the other steps are short or wait on the person.
    var progressFraction: Double? {
        guard case let .history(done, total) = step, total > 0 else { return nil }
        return Double(done) / Double(total)
    }

    var statusText: String {
        switch step {
        case nil: return "Getting ready\u{2026}"
        case .keychain: return "Waiting for keychain access\u{2026}"
        case .cookies: return "Importing cookies\u{2026}"
        case .bookmarks: return "Importing bookmarks\u{2026}"
        case let .history(done, total): return "Importing history\u{2026} \(done.formatted()) of \(total.formatted())"
        }
    }

    /// Finds Chrome's profiles and picks the first. Safe to call again when the view reappears.
    func attach(_ browserManager: BrowserManager) {
        isPresented = true
        guard self.browserManager == nil else { return }
        self.browserManager = browserManager
        spaceName = browserManager.chromeImportSpaceName
        profiles = browserManager.importManager.listChromeProfiles()
        if let first = profiles.first { select(first.id) }
    }

    /// Lists the profile's extensions and counts its bookmarks, off the main thread: a profile's
    /// preferences file runs to megabytes.
    func select(_ profileID: String) {
        guard profileID != selectedProfileID, let profile = profiles.first(where: { $0.id == profileID }),
              let browserManager else { return }
        selectedProfileID = profileID
        extensions = []
        selectedExtensions = []
        bookmarkCount = 0
        let importManager = browserManager.importManager
        let installed = Set(browserManager.extensionManager?.installedExtensions.map(\.id) ?? [])
        Task {
            let (found, bookmarks) = await Task.detached(priority: .userInitiated) {
                (importManager.listChromeExtensions(in: profile), importManager.readChromeBookmarks(in: profile).urlCount)
            }.value
            guard selectedProfileID == profileID else { return }
            extensions = found.filter { !installed.contains($0.id) }
            // Only 1Password starts checked: plenty of Chrome extensions do nothing in WebKit.
            selectedExtensions = extensions.contains { $0.id == chromeOnePasswordID } ? [chromeOnePasswordID] : []
            bookmarkCount = bookmarks
            if bookmarks == 0 { importBookmarks = false }
        }
    }

    func start() {
        guard canStart, let profile = selectedProfile, let browserManager else { return }
        phase = .importing
        step = nil
        let options = ChromeImportOptions(profile: profile, history: importHistory, cookies: importCookies,
                                          bookmarks: importBookmarks && bookmarkCount > 0)
        let extensionIDs = extensions.map(\.id).filter(selectedExtensions.contains)
        task = Task {
            var summary = await browserManager.importChromeData(options) { self.step = $0 }
            summary.extensions = extensionIDs.count
            self.summary = summary
            queuedExtensions = extensionIDs
            phase = .done
            if !isPresented {
                presentSummaryAlert()
                finish()
            }
        }
    }

    /// Stops after the step or history batch in progress; what is already in stays.
    func stop() {
        task?.cancel()
    }

    /// Hands the picked extensions to the installer. Their permission sheets take over the dialog
    /// layer, so this runs once the summary has been seen.
    func finish() {
        guard phase == .done, !queuedExtensions.isEmpty else { return }
        let ids = queuedExtensions
        queuedExtensions = []
        browserManager?.queueChromeExtensions(ids)
    }

    /// The dialog was dismissed while the import ran, so there is nowhere left to show the result.
    private func presentSummaryAlert() {
        let alert = NSAlert()
        alert.messageText = summary.isEmpty ? "Nothing was imported from Chrome" : "Imported from Chrome"
        alert.informativeText = (summary.lines + summary.problems).joined(separator: "\n")
        alert.runModal()
    }
}
