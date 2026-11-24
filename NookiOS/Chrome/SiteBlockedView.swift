// Licensed under GPL-3.0. See LICENSE.
//
//  SiteBlockedView.swift
//  NookiOS
//
//  The page over a site the site blocker stopped, with the Mac error page's words and type.
//  It covers the web view, so the page underneath cannot be touched, and it has no way past:
//  only back to where you were, or closing a tab that never loaded anything.
//

import SwiftUI
import NookBlocker
import NookDesign
import NookWeb

struct SiteBlockedView: View {
    let session: PageSession

    private static let textWidth: CGFloat = 420

    var body: some View {
        if let error = session.loadError, error.kind == .blocked {
            VStack(spacing: NookDesign.Spacing.xxxl) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(spacing: NookDesign.Spacing.md) {
                    Text(SiteBlockVerdict.pageTitle)
                        .font(NookDesign.Font.serifTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text(error.message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: Self.textWidth)
                Button(session.hasCommittedPage ? "Go Back" : "Close Tab") {
                    session.leaveFailedLoad()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(NookDesign.Spacing.xxxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground).ignoresSafeArea())
        }
    }
}
