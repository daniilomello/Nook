// Licensed under GPL-3.0. See LICENSE.
//
//  LinkedInTweaks.swift
//  Nook
//

import Foundation
import NookBlocker
import NookSettings
import OSLog
import WebKit

private let linkedInLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "LinkedInTweaks")

/// LinkedIn's minimal view: the parts in `NookSettingsService.linkedInHiddenParts` and the top bar
/// items in `linkedInHiddenNavItems` are hidden, and what is left is centered.
@MainActor
public enum LinkedInTweaks {
    private static let marker = "// Nook LinkedIn Tweaks"
    private static let world = WKContentWorld.world(name: "NookLinkedInTweaks")

    private static let script = resource("linkedin-tweaks", "js")
    private static let css = resource("linkedin-tweaks", "css")

    private static func resource(_ name: String, _ ext: String) -> String? {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            linkedInLog.warning("Failed to load \(name, privacy: .public).\(ext, privacy: .public) from NookTweaks")
            return nil
        }
        return source
    }

    /// Main-frame navigation hook, next to YouTubeTweaks. Settings apply from the next page load.
    public static func apply(for url: URL, in webView: WKWebView, settings: NookSettingsService) {
        let source = url.host?.lowercased() == "www.linkedin.com" ? userScriptSource(settings) : nil

        let ucc = webView.configuration.userContentController
        // Read everything from the lazily bridged array before removeAllUserScripts() (Release-only trap).
        let all = ucc.userScripts
        let others = all.nookOwned.filter { !$0.source.hasPrefix(marker) }
        let current = all.first { $0.source.hasPrefix(marker) }?.source
        guard current != source else { return }

        ucc.resetUserScripts(to: others)
        if let source {
            ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        }
    }

    private static func userScriptSource(_ settings: NookSettingsService) -> String? {
        guard settings.linkedInMinimal, let script, let css else { return nil }
        let parts = settings.linkedInHiddenParts.compactMap(LinkedInPart.init(rawValue:))
        let items = settings.linkedInHiddenNavItems.compactMap(LinkedInNavItem.init(rawValue:))
        let hidden = parts.map(\.rawValue) + items.map { "nav-\($0.rawValue)" }
        guard !hidden.isEmpty else { return nil }

        let config: [String: Any] = [
            "css": css,
            "hidden": hidden,
            "columns": parts.contains(.leftColumn) || parts.contains(.rightColumn),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: .sortedKeys),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return "\(marker)\n\(script)(\(json));"
    }
}
