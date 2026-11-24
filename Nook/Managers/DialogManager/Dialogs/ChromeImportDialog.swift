// Licensed under GPL-3.0. See LICENSE.
//
//  ChromeImportDialog.swift
//  Nook
//
//  Picks a Google Chrome profile and what to bring over from it, shows progress while the
//  import runs, then a summary with counts.
//

import NookDesign
import NookWeb
import SwiftUI

struct ChromeImportDialog: DialogPresentable {
    @EnvironmentObject private var browserManager: BrowserManager
    @State private var model = ChromeImportModel()
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func dialogHeader() -> DialogHeader {
        switch model.phase {
        case .options:
            return DialogHeader(
                icon: "square.and.arrow.down.on.square",
                title: "Import from Chrome",
                subtitle: model.spaceName.map { "History, logins and extensions, into the space \u{201C}\($0)\u{201D}." }
                    ?? "History, logins and extensions from Google Chrome."
            )
        case .importing:
            return DialogHeader(
                icon: "square.and.arrow.down.on.square",
                title: "Importing from Chrome",
                subtitle: "Chrome can stay open. Nook works on a copy of its files."
            )
        case .done:
            return DialogHeader(
                icon: model.summary.isEmpty ? "exclamationmark.circle" : "checkmark.circle",
                title: model.summary.isEmpty ? "Nothing was imported" : "Imported from Chrome",
                subtitle: model.summary.wasStopped ? "The import was stopped early." : nil
            )
        }
    }

    @ViewBuilder
    func dialogContent() -> some View {
        ChromeImportContent(model: model)
            .onAppear { model.attach(browserManager) }
            .onDisappear {
                model.isPresented = false
                model.finish()
            }
    }

    func dialogFooter() -> DialogFooter {
        switch model.phase {
        case .options where model.profiles.isEmpty:
            return DialogFooter(rightButtons: [
                DialogButton(text: "Close", variant: .secondary, keyboardShortcut: .escape, action: onClose)
            ])
        case .options:
            return DialogFooter(rightButtons: [
                DialogButton(text: "Cancel", variant: .secondary, keyboardShortcut: .escape, action: onClose),
                DialogButton(text: "Import", variant: .primary, keyboardShortcut: .return,
                             isEnabled: model.canStart, action: { model.start() }),
            ])
        case .importing:
            return DialogFooter(rightButtons: [
                DialogButton(text: "Stop", variant: .secondary, keyboardShortcut: .escape, action: { model.stop() })
            ])
        case .done:
            return DialogFooter(rightButtons: [
                DialogButton(text: "Done", variant: .primary, keyboardShortcut: .return, action: {
                    onClose()
                    model.finish()
                })
            ])
        }
    }
}

private struct ChromeImportContent: View {
    @Bindable var model: ChromeImportModel

    var body: some View {
        Group {
            switch model.phase {
            case .options:
                if model.profiles.isEmpty {
                    Text("Nook didn't find any Google Chrome profiles on this Mac.")
                        .font(NookDesign.Font.body)
                        .foregroundStyle(.secondary)
                } else {
                    options
                }
            case .importing:
                progress
            case .done:
                ChromeImportSummaryView(summary: model.summary)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Chrome profile")
                    .font(NookDesign.Font.label)
                    .foregroundStyle(.primary)
                Picker("Chrome profile", selection: Binding(get: { model.selectedProfileID }, set: { model.select($0) })) {
                    ForEach(model.profiles) { profile in
                        Text(profile.label).tag(profile.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 12) {
                part("History", detail: "Pages visited in the last \(HistoryManager.retentionDays) days, the span Nook keeps.",
                     isOn: $model.importHistory)
                part("Cookies and logins",
                     detail: "macOS will ask for your password so Nook can read \u{201C}Chrome Safe Storage\u{201D} from the keychain.",
                     isOn: $model.importCookies)
                part("Bookmarks", detail: bookmarksDetail, isOn: $model.importBookmarks)
                    .disabled(model.bookmarkCount == 0)
            }

            if !model.extensions.isEmpty {
                extensions
            }

            Text("Google will ask you to sign in again: it ties a session to the browser it started in. Most other sites keep you signed in.")
                .font(NookDesign.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bookmarksDetail: String {
        switch model.bookmarkCount {
        case 0: return "This profile has none."
        case 1: return "1 bookmark, in a pinned folder."
        default: return "\(model.bookmarkCount.formatted()) bookmarks, together in one pinned folder."
        }
    }

    private func part(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NookDesign.Font.body)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var extensions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Extensions")
                .font(NookDesign.Font.label)
                .foregroundStyle(.primary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.extensions) { item in
                        Toggle(item.name, isOn: Binding(
                            get: { model.selectedExtensions.contains(item.id) },
                            set: { isOn in
                                if isOn { model.selectedExtensions.insert(item.id) } else { model.selectedExtensions.remove(item.id) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(NookDesign.Font.bodyRegular)
                        .lineLimit(1)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A ScrollView takes all the height it is offered; four rows show before it scrolls.
            .frame(height: min(CGFloat(model.extensions.count) * 24 + 16, 112))
            .background(Color.primary.opacity(0.05))
            .clipShape(NookDesign.Radius.shape(NookDesign.Radius.lg))
            Text("Installed from the Chrome Web Store after the import, each with its own permission prompt. Not every Chrome extension works in Nook.")
                .font(NookDesign.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Progress

    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let fraction = model.progressFraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            Text(model.statusText)
                .font(NookDesign.Font.body)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// The counts, one line each, then whatever failed.
private struct ChromeImportSummaryView: View {
    let summary: ChromeImportSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(summary.lines, id: \.self) { line in
                Label {
                    Text(line).foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            ForEach(summary.problems, id: \.self) { problem in
                Label {
                    Text(problem)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if summary.isEmpty, summary.problems.isEmpty {
                Text("Chrome had nothing new for the parts you picked.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(NookDesign.Font.body)
    }
}
