// Licensed under GPL-3.0. See LICENSE.
//
//  ShortcutsButton.swift
//  Nook
//
//  The keyboard button in the sidebar's bottom bar: a list of the app's shortcuts as they are
//  set now, a click away at any time. Read-only; "Customize…" leads to Settings › Shortcuts.
//

import SwiftUI
import NookDesign

struct ShortcutsButton: View {
    @EnvironmentObject var browserManager: BrowserManager
    @State private var isPresented = false

    var body: some View {
        Button("Keyboard Shortcuts", systemImage: "keyboard") {
            isPresented.toggle()
        }
        .nookSidebarIconButtons()
        .help("Keyboard Shortcuts")
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ShortcutsCheatSheet(shortcuts: browserManager.keyboardShortcutManager?.shortcuts ?? KeyboardShortcut.defaultShortcuts) {
                isPresented = false
                browserManager.openSettings(tab: .shortcuts)
            }
        }
    }
}

/// One line of the list: what it does and the keys for it.
struct ShortcutsCheatSheetRow: Identifiable, Equatable {
    let name: String
    let keys: String
    var id: String { name }
}

struct ShortcutsCheatSheetSection: Identifiable, Equatable {
    let category: ShortcutCategory
    let rows: [ShortcutsCheatSheetRow]
    var id: ShortcutCategory { category }
}

extension ShortcutsCheatSheetSection {
    private static let tabRun: [ShortcutAction] = [
        .goToTab1, .goToTab2, .goToTab3, .goToTab4, .goToTab5, .goToTab6, .goToTab7, .goToTab8,
    ]

    /// The shortcuts that have keys, by category, in the order the defaults are written in
    /// rather than by name. "Go to Tab 1" to "8" and "Go to Space 1" to "9" take one line each
    /// when both ends have keys. `search` matches a name or the keys.
    static func sections(for shortcuts: [KeyboardShortcut], search: String = "") -> [ShortcutsCheatSheetSection] {
        var keys: [ShortcutAction: String] = [:]
        for shortcut in shortcuts where shortcut.isEnabled && !shortcut.keyCombination.key.isEmpty {
            keys[shortcut.action] = shortcut.keyCombination.displayString
        }

        var rows: [ShortcutCategory: [ShortcutsCheatSheetRow]] = [:]
        var folded: Set<ShortcutAction> = []
        for (run, name) in [(tabRun, "Go to Tab 1–8"), (ShortcutAction.goToSpaceActions, "Go to Space 1–9")] {
            guard let first = run.first, let last = run.last, let from = keys[first], let to = keys[last] else { continue }
            rows[first.category, default: []].append(ShortcutsCheatSheetRow(name: name, keys: "\(from) – \(to)"))
            folded.formUnion(run)
        }

        let defaultOrder = KeyboardShortcut.defaultShortcuts.map(\.action)
        let ordered = defaultOrder + ShortcutAction.allCases.filter { !defaultOrder.contains($0) }
        for action in ordered where !folded.contains(action) {
            guard let combination = keys[action] else { continue }
            rows[action.category, default: []].append(ShortcutsCheatSheetRow(name: action.displayName, keys: combination))
        }

        let query = search.trimmingCharacters(in: .whitespaces)
        return ShortcutCategory.allCases.compactMap { category in
            let matching = (rows[category] ?? []).filter {
                query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.keys.localizedCaseInsensitiveContains(query)
            }
            return matching.isEmpty ? nil : ShortcutsCheatSheetSection(category: category, rows: matching)
        }
    }
}

struct ShortcutsCheatSheet: View {
    let shortcuts: [KeyboardShortcut]
    let onCustomize: () -> Void
    @State private var search = ""

    private var sections: [ShortcutsCheatSheetSection] {
        ShortcutsCheatSheetSection.sections(for: shortcuts, search: search)
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarMenuSearchField(prompt: "Search shortcuts...", text: $search)
                .padding(NookDesign.Spacing.lg)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: NookDesign.Spacing.lg) {
                    if sections.isEmpty {
                        Text("No shortcut matches")
                            .font(NookDesign.Font.bodyRegular)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, NookDesign.Spacing.xxl)
                    }
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                            Label(section.category.displayName, systemImage: section.category.icon)
                                .font(NookDesign.Font.captionStrong)
                                .foregroundStyle(.secondary)
                                .padding(.bottom, NookDesign.Spacing.xs)
                            ForEach(section.rows) { row in
                                HStack(spacing: NookDesign.Spacing.md) {
                                    Text(row.name)
                                        .font(NookDesign.Font.body)
                                        .lineLimit(1)
                                    Spacer(minLength: NookDesign.Spacing.md)
                                    Text(row.keys)
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, NookDesign.Spacing.sm)
                                        .padding(.vertical, NookDesign.Spacing.xxs)
                                        .background(NookDesign.Surface.fillPressed, in: NookDesign.Radius.shape(NookDesign.Radius.xs))
                                        .fixedSize()
                                }
                                .frame(minHeight: 24)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                .padding(.horizontal, NookDesign.Spacing.lg)
                .padding(.bottom, NookDesign.Spacing.lg)
            }

            Divider()
            HStack {
                Text("Press a shortcut twice when a site uses the same keys.")
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: NookDesign.Spacing.md)
                Button("Customize…", action: onCustomize)
            }
            .padding(NookDesign.Spacing.lg)
        }
        .frame(width: 340, height: 520)
    }
}
