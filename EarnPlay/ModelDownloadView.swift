import SwiftUI
import EarnPlayCore

/// First-launch model download screen (issue #53).
///
/// Shown instead of the tutor UI until `ModelRuntime.defaultModelURL()`
/// resolves a model file. The download is Wi-Fi only, verified by
/// SHA-256, and installed into Application Support; after it succeeds
/// the app works fully offline.
struct ModelDownloadView: View {
    @ObservedObject var viewModel: ModelDownloadViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Download tutor model")
                    .font(.largeTitle.bold())
                Text("One-time download of the on-device tutor (~800 MB). " +
                     "Wi-Fi only — this never uses cellular data. " +
                     "Afterward the app works fully offline.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Divider()
                switch viewModel.phase {
                case .checking:
                    ProgressView("Checking for model…")
                case .needsDownload:
                    Button("Download over Wi-Fi") {
                        viewModel.startDownload()
                    }
                    .buttonStyle(.borderedProminent)
                case .downloading(let progress):
                    ProgressView(value: progress) {
                        Text("Downloading… \(Int(progress * 100))%")
                    }
                    Text("Keep the app open until the download finishes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                    Button("Retry download") {
                        viewModel.startDownload()
                    }
                    .buttonStyle(.borderedProminent)
                case .ready:
                    EmptyView()
                }
                Divider()
                AboutView()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Drives `ModelDownloadView`. The ready check is a pure filesystem
/// lookup (no network), so an already-downloaded model skips this
/// screen instantly, including fully offline.
@MainActor
final class ModelDownloadViewModel: ObservableObject {
    enum Phase: Equatable {
        case checking
        case needsDownload
        case downloading(progress: Double)
        case failed(message: String)
        case ready
    }

    @Published private(set) var phase: Phase = .checking

    var isReady: Bool { phase == .ready }

    private let downloader: ModelDownloader

    init(downloader: ModelDownloader = ModelDownloader()) {
        self.downloader = downloader
    }

    /// Re-resolves the model through the production lookup.
    func refresh() {
        if ModelRuntime.defaultModelURL() != nil {
            phase = .ready
        } else {
            phase = .needsDownload
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
                    self?.phase = .downloading(progress: fraction)
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
