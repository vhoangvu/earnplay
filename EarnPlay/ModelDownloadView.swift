import SwiftUI
import EarnPlayCore

/// First-launch model download screen (issue #53).
///
/// Shown instead of the tutor UI until the readiness gate resolves a
/// usable model: the active registry's validated artifacts (so a
/// retained snapshot stays usable), a legacy model location, or a
/// size- and SHA-verified first-launch download in Application
/// Support. The download is Wi-Fi only; after it succeeds the app
/// works fully offline.
struct ModelDownloadView: View {
    @ObservedObject var viewModel: ModelDownloadViewModel
    @ObservedObject var themes: ThemeStore = ThemeStore()

    /// The shared app theme, via the store this view already receives
    /// (the same object as the About picker's, so a switch re-renders
    /// this page too). No color literal lives here: the download-phase
    /// surfaces below read theme tokens, like the chat page, while the
    /// embedded About/picker subtree stays on the adaptive system
    /// background its inks assume (see body).
    private var theme: DesignSystem.Theme { themes.theme }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Download-phase content on the fixed light theme
                // surface: every ink here is theme-paired (tutorText,
                // secondaryOnTheme, the resolved Send-pattern label),
                // so it reads in both appearances.
                VStack(alignment: .leading, spacing: 16) {
                    Text("Download tutor model")
                        .font(.largeTitle.bold())
                        .foregroundStyle(theme.tokens.tutorText.color)
                    Text("One-time download of the on-device tutor (~800 MB). " +
                         "Wi-Fi only — this never uses cellular data. " +
                         "Afterward the app works fully offline.")
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryOnTheme)
                    Divider()
                    switch viewModel.phase {
                    case .checking:
                        ProgressView("Checking for model…")
                            .tint(theme.tokens.fill.color)
                            .foregroundStyle(theme.tokens.tutorText.color)
                    case .needsDownload:
                        Button("Download over Wi-Fi") {
                            viewModel.startDownload()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.tokens.accent.color)
                        .foregroundStyle(theme.childTextOnChildBackground.color)
                    case .downloading(let progress):
                        ProgressView(value: progress) {
                            Text("Downloading… \(Int(progress * 100))%")
                        }
                        .tint(theme.tokens.fill.color)
                        .foregroundStyle(theme.tokens.tutorText.color)
                        Text("Keep the app open until the download finishes.")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryOnTheme)
                    case .failed(let message):
                        // Semantic red, NOT a theme token: DesignSystem
                        // carries no error ink, and the failure must read as
                        // an error in every theme (same as the chore-trade
                        // grant failure on its themed card).
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                        Button("Retry download") {
                            viewModel.startDownload()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(theme.tokens.accent.color)
                        .foregroundStyle(theme.childTextOnChildBackground.color)
                    case .ready:
                        EmptyView()
                    }
                    Divider()
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.tokens.background.color)
                // The embedded About/theme-picker subtree sits on the
                // adaptive system background, NOT the fixed light theme
                // surface: its inks are adaptive (.primary/.secondary),
                // which would wash out as light text on near-white in
                // Dark Mode. This also keeps the picker's documented
                // "rows sit on system background" assumption (and its
                // checkmark-contrast fixture) true in every host.
                AboutView(themes: themes)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemBackground))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemBackground))
        // Bordered buttons (Download, Retry) take the theme's button
        // radius (10 rounded / 8 sharp), as in the chat composer. The
        // About picker's plain rows below are unaffected (default
        // style reads no border shape).
        .buttonBorderShape(.roundedRectangle(radius: theme.buttonRadius))
        // Stable handle for the issue #69 UI smoke tests. No behavior change.
        .accessibilityIdentifier("modelDownloadView")
    }
}

/// Drives `ModelDownloadView`. The ready check performs no network
/// I/O (registry validation + file verification only), so an
/// already-usable model skips this screen, including fully offline.
/// Resolution hashes model files, so it runs detached off the main
/// actor; the phase flips when it completes.
@MainActor
final class ModelDownloadViewModel: ObservableObject {
    @Published private(set) var phase: ModelDownloadPhase = .checking

    var isReady: Bool { phase == .ready }

    private let downloader: ModelDownloader
    private let readiness: ModelDownloadReadiness
    /// Epoch so a superseded refresh cannot overwrite a newer result.
    private var refreshEpoch = 0
    /// Isolated readiness-lookup inputs (fix round 6 test seam). A nil
    /// environment means the live process environment and `.default`
    /// means the live standard directories, so production (which passes
    /// neither) resolves exactly what the old bare `isReady()` call did.
    /// Internal so tests can pin the production defaults.
    let readinessEnvironment: [String: String]?
    let readinessFileManager: FileManager

    init(downloader: ModelDownloader = ModelDownloader(),
         readiness: ModelDownloadReadiness = ModelDownloadReadiness(),
         environment: [String: String]? = nil,
         fileManager: FileManager = .default) {
        self.downloader = downloader
        self.readiness = readiness
        self.readinessEnvironment = environment
        self.readinessFileManager = fileManager
    }

    /// Initial readiness check for the root view's `.task`. The task
    /// sits on the container whose content switches between the
    /// download screen and the setup/main screens once the model is
    /// ready; if the task re-runs on that switch, an unconditional
    /// `refresh()` would evict the ready screen back to `.checking`
    /// and restart readiness checks. The guard makes re-entry a
    /// no-op: `.checking` still refreshes normally, and any resolved
    /// phase is left untouched.
    func refreshIfNeeded() {
        if phase == .checking {
            refresh()
        }
    }

    /// Re-resolves the model through the production readiness gate.
    func refresh() {
        refreshEpoch += 1
        let epoch = refreshEpoch
        phase = .checking
        let readiness = self.readiness
        let environment = self.readinessEnvironment
        let fileManager = self.readinessFileManager
        Task.detached(priority: .userInitiated) { [readiness, environment, fileManager] in
            let ready = readiness.isReady(environment: environment ?? ProcessInfo.processInfo.environment,
                                          fileManager: fileManager)
            await MainActor.run { [weak self] in
                guard let self, self.refreshEpoch == epoch else { return }
                self.phase = ready ? .ready : .needsDownload
            }
        }
    }

    /// Starts (or manually retries) the first-launch download.
    func startDownload() {
        if case .downloading = phase {
            return
        }
        phase = .downloading(progress: 0)
        Task {
            await runDownload()
        }
    }

    private func runDownload() async {
        do {
            _ = try await downloader.downloadIfNeeded(progress: { fraction in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Queued callbacks arriving after a terminal
                    // phase are ignored, never reverting the UI.
                    self.phase = self.phase.applyingProgress(fraction)
                }
            })
            // Only proceed when the production lookup actually sees
            // the model — never on the downloader's word alone.
            if ModelRuntime.defaultModelURL() != nil {
                phase = .ready
            } else {
                phase = .failed(message: "Download finished but the model was not found. Please retry.")
            }
        } catch let error as ModelDownloadError {
            phase = .failed(message: Self.message(for: error))
        } catch is CancellationError {
            phase = .needsDownload
        } catch {
            phase = .failed(message: "Download failed: \(error.localizedDescription)")
        }
    }

    private static func message(for error: ModelDownloadError) -> String {
        switch error {
        case .networkFailure(let detail):
            return "Download failed (\(detail)). Check your Wi-Fi connection and retry."
        case .httpStatus(let status):
            return "Download failed (server status \(status)). Please retry."
        case .byteCountMismatch, .checksumMismatch:
            return "The download was corrupted and was discarded. Please retry over Wi-Fi."
        case .cancelled:
            return "Download cancelled."
        }
    }
}
