// Licensed under GPL-3.0. See LICENSE.
//
//  ChromeImportFlow.swift
//  Nook
//
//  The onboarding counterpart of `ChromeImportDialog`: pick a Chrome profile and what to bring,
//  watch it import, read the summary.
//

import NookDesign
import NookWeb
import SwiftUI

struct ChromeImportFlow: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Binding var isLoading: Bool
    var onBack: () -> Void
    var onComplete: () -> Void

    @State private var model = ChromeImportModel()

    var body: some View {
        VStack(spacing: 24) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)

            Group {
                switch model.phase {
                case .options: optionsView
                case .importing: importingView
                case .done: doneView
                }
            }
            .transition(.slideAndBlur)
        }
        .transition(.slideAndBlur)
        .animation(.easeInOut(duration: 0.25), value: model.phase)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) { handleReturn() }
        .onAppear { model.attach(browserManager) }
        .onDisappear { model.isPresented = false }
        .onChange(of: model.phase) { _, phase in isLoading = phase == .importing }
    }

    private var title: String {
        switch model.phase {
        case .options, .importing: return "Import from Chrome"
        case .done: return model.summary.isEmpty ? "Nothing was imported" : "Imported from Chrome"
        }
    }

    private func handleReturn() -> KeyPress.Result {
        switch model.phase {
        case .options:
            guard model.canStart else { return .ignored }
            model.start()
        case .importing:
            return .ignored
        case .done:
            complete()
        }
        return .handled
    }

    /// Onboarding has no browser window yet, so the extensions wait in the queue for the first one.
    private func complete() {
        model.finish()
        onComplete()
    }

    // MARK: - Options

    @ViewBuilder
    private var optionsView: some View {
        if model.profiles.isEmpty {
            Text("Nook didn't find any Google Chrome profiles on this Mac.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    rowIcon("person.crop.circle")
                    Text("Profile")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer()
                    Picker("Chrome profile", selection: Binding(get: { model.selectedProfileID }, set: { model.select($0) })) {
                        ForEach(model.profiles) { profile in
                            Text(profile.label).tag(profile.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                toggleRow(icon: "clock.fill", label: "History, last \(HistoryManager.retentionDays) days", isOn: $model.importHistory)
                toggleRow(icon: "key.fill", label: "Cookies and logins", isOn: $model.importCookies)
                if model.bookmarkCount > 0 {
                    toggleRow(icon: "bookmark.fill",
                              label: "\(model.bookmarkCount.formatted()) bookmark\(model.bookmarkCount == 1 ? "" : "s"), in one pinned folder",
                              isOn: $model.importBookmarks)
                }
                if !model.extensions.isEmpty {
                    extensionsList
                }
            }
            .padding(20)
            .frame(width: 440)
            .background(.white.opacity(0.1))
            .clipShape(NookDesign.Radius.shape(NookDesign.Radius.lg))

            Text("macOS will ask for your password so Nook can read Chrome's cookie key from the keychain. Google will ask you to sign in again; most other sites keep you signed in.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(width: 440)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: 12) {
            if !model.profiles.isEmpty {
                primaryButton("Import") { model.start() }
                    .disabled(!model.canStart)
                    .opacity(model.canStart ? 1 : 0.5)
            }
            Button {
                onBack()
            } label: {
                Text("Back")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(12)
            }
            .buttonStyle(.plain)
        }
    }

    private var extensionsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                rowIcon("puzzlepiece.extension.fill")
                Text("Extensions")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            }
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
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(CGFloat(model.extensions.count) * 24 + 16, 112))
            .background(.white.opacity(0.06))
            .clipShape(NookDesign.Radius.shape(NookDesign.Radius.md))
        }
    }

    // MARK: - Importing

    private var importingView: some View {
        VStack(spacing: 16) {
            if let fraction = model.progressFraction {
                ProgressView(value: fraction)
                    .tint(.white)
                    .frame(width: 280)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: 280)
            }
            Text(model.statusText)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
            Button {
                model.stop()
            } label: {
                Text("Stop")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(12)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Done

    @ViewBuilder
    private var doneView: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.summary.lines, id: \.self) { line in
                summaryRow(icon: "checkmark.circle.fill", color: .green, label: line)
            }
            ForEach(model.summary.problems, id: \.self) { problem in
                summaryRow(icon: "exclamationmark.triangle.fill", color: .orange, label: problem)
            }
            if model.summary.isEmpty, model.summary.problems.isEmpty {
                summaryRow(icon: "checkmark.circle.fill", color: .green, label: "Nothing new to import")
            }
        }
        .padding(20)
        .frame(maxWidth: 440)
        .background(.white.opacity(0.1))
        .clipShape(NookDesign.Radius.shape(NookDesign.Radius.lg))
        .fixedSize(horizontal: false, vertical: true)

        primaryButton("Continue") { complete() }
    }

    // MARK: - Shared components

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.7))
            .frame(width: 20)
    }

    private func toggleRow(icon: String, label: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            rowIcon(icon)
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }

    private func summaryRow(icon: String, color: Color, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black)
                Image(systemName: "return")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.8))
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 24)
            .background(.white)
            .clipShape(NookDesign.Radius.shape(NookDesign.Radius.lg))
        }
        .buttonStyle(ScaleButtonStyle())
    }
}
