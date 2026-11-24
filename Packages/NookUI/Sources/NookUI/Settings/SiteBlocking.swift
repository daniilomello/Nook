// Licensed under GPL-3.0. See LICENSE.
//
//  SiteBlocking.swift
//  NookUI
//
//  The Site Blocking pane, shared by the Mac's settings window and the phone's settings sheet:
//  a switch per category, a switch per social site, the person's own blocked domains and the
//  exceptions. Every change applies to the next navigation in any open tab.
//

import SwiftUI

import NookBlocker
import NookDesign
import NookSettings

public struct SettingsSiteBlockingTab: View {
    private let store = SiteBlockingStore.shared
    private let adultList = SiteBlocker.shared.adultList
    @State private var newBlocked = ""
    @State private var newException = ""

    public init() {}

    public var body: some View {
        @Bindable var store = self.store
        Form {
            Section {
                Toggle("Block Social Networks", isOn: $store.settings.blockSocial)
            } footer: {
                Text("Site blocking covers every window, Space and profile, private windows included.")
            }

            if store.settings.blockSocial {
                Section("Social Networks") {
                    ForEach(SocialSite.catalog) { site in
                        Toggle(isOn: Binding(
                            get: { store.settings.isEnabled(site) },
                            set: { store.settings.setEnabled($0, for: site) }
                        )) {
                            VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                                Text(site.name)
                                Text(site.summary)
                                    .font(NookDesign.Font.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Toggle("Block Adult Content", isOn: $store.settings.blockAdult)
                if store.settings.blockAdult {
                    adultListStatus
                }
            } footer: {
                Text("Blocks the sites on the \(AdultDomainList.sourceName) lists and any address that names adult content, and keeps safe search on for Google, Bing, DuckDuckGo, Brave and Yahoo. The lists update automatically every few days.")
            }

            if store.settings.blockAdult {
                Section {
                    Toggle("Also Ask \(FamilyDNSFilter.serviceName)", isOn: $store.settings.askFamilyFilter)
                } footer: {
                    Text("Catches adult sites the lists do not have yet. The name of each site you open, never the page or what you do on it, is sent to Cloudflare's family DNS, in private windows too.")
                }
            }

            domainSection(
                title: "Also Block",
                footer: "A domain covers its subdomains too. Add a path, like example.com/feed, to block only part of a site.",
                empty: "No sites of your own yet",
                domains: $store.settings.customDomains,
                draft: $newBlocked
            )

            domainSection(
                title: "Never Block",
                footer: "Exceptions win over every list above.",
                empty: "No exceptions yet",
                domains: $store.settings.exceptions,
                draft: $newException
            )
        }
        .formStyle(.grouped)
        .task { adultList.loadIfNeeded() }
    }

    private var adultListStatus: some View {
        HStack {
            if adultList.isUpdating {
                ProgressView()
                    .controlSize(.small)
                Text("Updating the list...")
                    .foregroundStyle(.secondary)
            } else {
                if let info = adultList.info {
                    Text("\(info.count.formatted()) sites, updated \(info.updated, style: .relative) ago")
                        .foregroundStyle(.secondary)
                } else {
                    Text("The list could not be read")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Update Now") {
                    Task { await adultList.update(force: true) }
                }
            }
        }
    }

    private func domainSection(
        title: String, footer: String, empty: String, domains: Binding<[String]>, draft: Binding<String>
    ) -> some View {
        Section {
            if domains.wrappedValue.isEmpty {
                Text(empty)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(domains.wrappedValue, id: \.self) { domain in
                    LabeledContent {
                        Button {
                            domains.wrappedValue.removeAll { $0 == domain }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(domain)")
                    } label: {
                        Text(domain)
                    }
                }
            }

            HStack {
                TextField("example.com", text: draft)
                    .labelsHidden()
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit { add(draft, to: domains) }
                Button {
                    add(draft, to: domains)
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(SiteBlockRule(draft.wrappedValue) == nil)
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
    }

    /// Saves what was typed in the form the blocker matches: no scheme, no `www.`, lowercase.
    private func add(_ draft: Binding<String>, to domains: Binding<[String]>) {
        guard let rule = SiteBlockRule(draft.wrappedValue) else { return }
        if !domains.wrappedValue.contains(rule.text) { domains.wrappedValue.append(rule.text) }
        draft.wrappedValue = ""
    }
}
