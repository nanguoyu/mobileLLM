// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import AppUI
import LLMCore

/// Hardware-fit badge (DESIGN §2.5 / §4). A colored dot + one-line verdict, reusing `Theme.fit*`
/// colors + `DotLabelStyle`. The label text *is* the VoiceOver label (DESIGN §4), so no model of the
/// world is hidden behind an icon.
struct LLMFitBadge: View {
    let presentation: ModelManager.FitPresentation

    private var color: Color {
        switch presentation {
        case .comfortable: Theme.fitGreen
        case .tight, .experimental: Theme.fitAmber
        case .unsupported: Theme.fitGray
        }
    }

    private var text: String {
        switch presentation {
        case .comfortable: "Runs great"
        case let .tight(maxContext): "Tight · up to \(Format.shortCount(maxContext)) ctx"
        case .experimental: "Experimental · may be interrupted"
        case .unsupported: "Needs more memory"
        }
    }

    var body: some View {
        Label {
            Text(text).font(.caption2.weight(.medium)).foregroundStyle(color)
        } icon: {
            Circle().fill(color)
        }
        .labelStyle(DotLabelStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

#if DEBUG
#Preview("Fit badges") {
    VStack(alignment: .leading, spacing: 12) {
        LLMFitBadge(presentation: .comfortable)
        LLMFitBadge(presentation: .tight(maxContext: 4096))
        LLMFitBadge(presentation: .experimental)
        LLMFitBadge(presentation: .unsupported)
    }
    .padding()
    .background(Theme.bg)
}
#endif
