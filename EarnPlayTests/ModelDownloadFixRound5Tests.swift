import CryptoKit
import XCTest
import EarnPlayCore
@testable import EarnPlay

/// Fix round 5 regression tests (issue #53): the root view's `.task`
/// calls the guarded refresh path, so a task re-run after the model
/// is ready never evicts the ready screen back into `.checking`.
///
/// Production wiring under test: `ContentView` attaches its `.task`
/// to the container whose content switches between `ModelDownloadView`
/// and the setup/main screens once `isReady` flips. `refresh()`
/// unconditionally resets the phase to `.checking`, so an unguarded
/// re-entry of that task restarts readiness checks (and, before fix
/// 4's fast path, repeated hashing) and swaps the ready screen back
/// to the download view. The guard makes re-entry a no-op.
///
/// What these tests establish — and what they honestly cannot: the
/// SwiftUI `.task` restart mechanics themselves are not directly
/// unit-testable here (no view-hosting harness in the repo), so the
/// tests pin the guard the task calls through instead. From
/// `.checking` the guarded path refreshes normally; from `.ready` it
/// is a synchronous no-op that starts no readiness re-check (proven
/// by sabotaging the underlying model file and showing a fresh view
/// model's re-check would flip to `.needsDownload` in that state).
final class ModelDownloadFixRound5Tests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDown() {
        // The destination fixture lives at the real default location
        // because the view model resolves readiness with default
        // environment/file-manager; always restore absence so later
        // tests (and the integration skip-guard) see a clean lookup.
        try? FileManager.default.removeItem(at: ModelDownloader.defaultDestinationURL())
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots = []
        super.tearDown()
    }

    private func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloadFixRound5Tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    private func writeFile(at url: URL, data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func testConfiguration(payload: Data) -> ModelDownloadConfiguration {
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return ModelDownloadConfiguration(
            sourceURL: URL(string: "https://example.com/model.gguf")!,
            expectedByteCount: Int64(payload.count),
            expectedSHA256: digest,
            maxAttempts: 1
        )
    }

    @MainActor
    private func waitForPhase(
        _ expected: ModelDownloadPhase,
        in viewModel: ModelDownloadViewModel,
        timeoutSeconds: Double = 10
    ) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while viewModel.phase != expected {
            if Date() > deadline {
                XCTFail("timed out waiting for phase \(expected); stuck at \(viewModel.phase)")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
    }

    /// From `.ready`, the guarded path is a no-op: the phase stays
    /// `.ready` and no readiness re-check runs — even though a
    /// re-check in the sabotaged state would resolve `.needsDownload`
    /// (proven by the fresh-model control below).
    @MainActor
    func testReadySurvivesGuardedRefreshWithoutRecheck() throws {
        // Arrange: a pinned-verified file at the destination — the
        // exact state a completed download leaves behind.
        let destination = ModelDownloader.defaultDestinationURL()
        let payload = Data("GGUF-round5-ready-guard!!".utf8)
        try writeFile(at: destination, data: payload)
        let readiness = ModelDownloadReadiness(
            configuration: testConfiguration(payload: payload),
            destinationURL: destination,
            registryStoreURL: makeTempRoot().appendingPathComponent("registry.json"))

        // Drive the view model to .ready through the same guarded
        // path the root view's task calls.
        let viewModel = ModelDownloadViewModel(readiness: readiness)
        XCTAssertEqual(viewModel.phase, .checking)
        viewModel.refreshIfNeeded()
        waitForPhase(.ready, in: viewModel)

        // Sabotage the underlying file, then calibrate: a fresh view
        // model re-checking this state must reach `.needsDownload`,
        // proving a re-check WOULD flip the phase if one ran.
        try FileManager.default.removeItem(at: destination)
        let control = ModelDownloadViewModel(readiness: readiness)
        control.refresh()
        waitForPhase(.needsDownload, in: control)

        // Re-invoke the guarded refresh path: `refresh()` resets to
        // `.checking` synchronously, so still being `.ready` here
        // proves the guard blocked it.
        viewModel.refreshIfNeeded()
        XCTAssertEqual(viewModel.phase, .ready,
            "guarded refresh from .ready must not re-enter .checking")

        // Grace window: the control just showed a re-check resolves
        // `.needsDownload` in well under a second, so staying `.ready`
        // across it proves no detached re-check is in flight either.
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        XCTAssertEqual(viewModel.phase, .ready,
            "no readiness re-check may run from the guarded path once ready")
    }

    /// From `.checking` (the initial phase, and the state the root
    /// view's task first observes), the guarded path refreshes
    /// normally — here resolving `.needsDownload` with nothing
    /// installed. The guard must only suppress re-entry, never the
    /// initial check.
    @MainActor
    func testCheckingStillRefreshesNormallyThroughGuardedPath() throws {
        try? FileManager.default.removeItem(at: ModelDownloader.defaultDestinationURL())
        let readiness = ModelDownloadReadiness(
            configuration: testConfiguration(payload: Data("GGUF-round5-absent".utf8)),
            destinationURL: ModelDownloader.defaultDestinationURL(),
            registryStoreURL: makeTempRoot().appendingPathComponent("registry.json"))
        let viewModel = ModelDownloadViewModel(readiness: readiness)
        XCTAssertEqual(viewModel.phase, .checking)
        viewModel.refreshIfNeeded()
        waitForPhase(.needsDownload, in: viewModel)
    }
}
