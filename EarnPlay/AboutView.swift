import SwiftUI
import EarnPlayCore

/// About section with the Llama 3.2 attribution (issue #53, fix
/// round 2): the prominent "Built with Llama" label (§1.b.i(B)), the
/// shipped Notice text (§1.b.iii), and the bundled license copy
/// (§1.b.i(A)) — all read from the app bundle, fully offline.
struct AboutView: View {
    /// The child app's theme store, passed from the app root so the
    /// picker here and the chat theme stay in sync. Defaults to a
    /// fresh store (same persisted selection) for previews.
    @ObservedObject var themes: ThemeStore = ThemeStore()
    /// Demo-mode toggle (issue #87): writes the same UserDefaults key
    /// `SimulatedShieldMode` resolves, so a TestFlight tester can flip
    /// modes on-device (the only forcing input a TestFlight binary
    /// receives — launch arguments and environment variables never
    /// reach it). The setup composition reads the mode once at launch,
    /// so flipping requires a restart to take effect.
    @AppStorage(SimulatedShieldMode.forceUserDefaultsKey) private var forceSimulated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.headline)
            Text(ModelAttribution.builtWithLlamaLabel)
                .font(.title3.bold())
            Text(ModelAttribution.llamaCommunityLicenseText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let notice = ModelAttribution.bundledNoticeText() {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let license = ModelAttribution.bundledLicenseText() {
                DisclosureGroup("Llama 3.2 Community License") {
                    ScrollView {
                        Text(license)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxHeight: 240)
                }
                .font(.caption)
            }
            Divider()
            ThemePickerView(store: themes)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Demo")
                    .font(.headline)
                Toggle("Simulate shields (demo mode)", isOn: $forceSimulated)
                    .accessibilityIdentifier("simulateShieldsToggle")
                Text("Runs setup with simulated Screen Time authorization " +
                    "and simulated shields, so gate scenarios can run " +
                    "without the FamilyControls entitlement (TestFlight, " +
                    "simulator). Takes effect after you restart the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
