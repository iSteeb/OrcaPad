// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import SwiftUI

/// Tip of the Day sheet (app.tips): one concise tip with Next, a "Show
/// tips at launch" toggle, and "Don't show again". Presented once per
/// launch from RootView and on demand from the About screen.
struct TipsSheet: View {
    @AppStorage(TipCatalog.Storage.enabledKey) private var tipsEnabled = true
    @AppStorage(TipCatalog.Storage.lastShownIndexKey) private var lastShownIndex = 0

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    private var tip: TipCatalog.Tip {
        guard TipCatalog.all.indices.contains(index) else {
            return TipCatalog.all[0]
        }
        return TipCatalog.all[index]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: tip.symbol)
                    .font(.system(size: 40, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text("Tip \(index + 1) of \(TipCatalog.all.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(tip.title)
                    .font(.title3.weight(.semibold))
                Text(tip.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                Spacer()
                Button("Next tip", action: nextTip)
                    .buttonStyle(.borderedProminent)
                Toggle("Show tips at launch", isOn: $tipsEnabled)
                    .font(.callout)
                    .padding(.horizontal, 28)
                Button("Don't show again") {
                    tipsEnabled = false
                    dismiss()
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Tip of the Day")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            // Every presentation advances the rotation (launch and About
            // both show the tip AFTER the one seen last time).
            index = (lastShownIndex + 1) % TipCatalog.all.count
            lastShownIndex = index
        }
    }

    private func nextTip() {
        index = (index + 1) % TipCatalog.all.count
        lastShownIndex = index
    }
}
