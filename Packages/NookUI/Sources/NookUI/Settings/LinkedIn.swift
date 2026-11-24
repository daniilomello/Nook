// Licensed under GPL-3.0. See LICENSE.
//
//  LinkedIn.swift
//  Nook
//

import NookSettings
import SwiftUI

/// LinkedIn's sections of the Tweaks tab; the caller supplies the Form.
public struct LinkedInSettingsSections: View {
    @Environment(NookSettingsService.self) var nookSettings

    public init() {}

    public var body: some View {
        @Bindable var settings = nookSettings
        Group {
            Section {
                Toggle("Minimal view", isOn: $settings.linkedInMinimal)
            } header: {
                Text("LinkedIn")
            } footer: {
                Text("Shows LinkedIn without what is chosen below, with the page centered. Reload an open LinkedIn page to see a change.")
            }

            if settings.linkedInMinimal {
                Section("Hide on LinkedIn") {
                    ForEach(LinkedInPart.allCases) { part in
                        Toggle(part.displayName, isOn: member(part.rawValue, of: \.linkedInHiddenParts))
                    }
                }
                Section("Hide from LinkedIn's Top Bar") {
                    ForEach(LinkedInNavItem.allCases) { item in
                        Toggle(item.displayName, isOn: member(item.rawValue, of: \.linkedInHiddenNavItems))
                    }
                }
            }
        }
    }

    private func member(_ value: String, of list: ReferenceWritableKeyPath<NookSettingsService, [String]>) -> Binding<Bool> {
        Binding(
            get: { nookSettings[keyPath: list].contains(value) },
            set: { hidden in
                nookSettings[keyPath: list].removeAll { $0 == value }
                if hidden { nookSettings[keyPath: list].append(value) }
            }
        )
    }
}
