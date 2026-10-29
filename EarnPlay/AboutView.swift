import SwiftUI
import EarnPlayCore

/// Minimal About section, including the Llama 3.2 Community License
/// attribution for the on-device tutor model (issue #53).
struct AboutView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.headline)
            Text(ModelAttribution.llamaCommunityLicenseText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
