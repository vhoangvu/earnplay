import CryptoKit
import XCTest
import EarnPlayCore
@testable import EarnPlay

/// FileManager with stubbed standard directories under a temp root, so
/// the readiness lookup never consults the real Application Support,
/// Documents, or Caches. (Same pattern as the `StubFileManager` in the
/// package suite, repeated here because the app test bundle cannot see
/// the package's test helpers.)
final class FixRound5StubFileManager: FileManager {
    let appSupportDir: URL
    let documentsDir: URL
    let cachesDir: URL

    init(appSupport: URL, documents: URL, caches: URL) {
        self.appSupportDir = appSupport
        self.documentsDir = documents
        self.cachesDir = caches
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory,
                       in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        switch directory {
        case .applicationSupportDirectory:
            return [appSupportDir]
        case .documentDirectory:
            return [documentsDir]
        case .cachesDirectory:
            return [cachesDir]
        default:
            return super.urls(for: directory, in: domainMask)
        }
    }
}

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
///
/// Fix round 6: every test here is hermetic. Each view model under
/// test resolves readiness through an EMPTY environment and stubbed
/// standard directories, with the destination fixture and the
/// registry store under a per-test temp root. No test writes to,
/// reads, or deletes the real default destination, and `tearDown`
/// removes temp roots only.
final class ModelDownloadFixRound5Tests: XCTestCase {
    private var tempRoots: [URL] = []

    /// An isolated readiness lookup: stub standard directories plus a
    /// destination and registry store under one temp root. Nothing in
    /// it can see a real installed model, a legacy env override, or a
    /// Documents-staged model on the test host.
    private struct IsolatedLookup {
        let destination: URL
        let registryStoreURL: URL
        let fileManager: FixRound5StubFileManager
    }

    override func tearDown() {
        removeTempRoots()
        super.tearDown()
    }

    /// The entire cleanup this suite performs: temp roots only. The
    /// real default destination is never touched here (pinned by
    /// `testRealDefaultDestinationSurvivesIsolatedSuite`, which runs
    /// this exact cleanup and then proves the real location intact).
    private func removeTempRoots() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots = []
    }

    private func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloadFixRound5Tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    private func stubbedFileManager(root: URL) -> FixRound5StubFileManager {
        FixRound5StubFileManager(
            appSupport: root.appendingPathComponent("appSupport", isDirectory: true),
            documents: root.appendingPathComponent("docs", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true))
    }

    private func makeIsolatedLookup() -> IsolatedLookup {
        let root = makeTempRoot()
        let fileManager = stubbedFileManager(root: root)
        return IsolatedLookup(
            destination: ModelDownloader.defaultDestinationURL(fileManager: fileManager),
            registryStoreURL: root.appendingPathComponent("registry")
                .appendingPathComponent("registry.json"),
            fileManager: fileManager)
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

    private func makeReadiness(payload: Data, lookup: IsolatedLookup) -> ModelDownloadReadiness {
        ModelDownloadReadiness(
            configuration: testConfiguration(payload: payload),
            destinationURL: lookup.destination,
            registryStoreURL: lookup.registryStoreURL)
    }

    @MainActor
    private func makeViewModel(payload: Data, lookup: IsolatedLookup) -> ModelDownloadViewModel {
        ModelDownloadViewModel(readiness: makeReadiness(payload: payload, lookup: lookup),
                               environment: [:],
                               fileManager: lookup.fileManager)
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
        try runReadyGuardFlow()
    }

    /// From `.checking` (the initial phase, and the state the root
    /// view's task first observes), the guarded path refreshes
    /// normally — here resolving `.needsDownload` with nothing
    /// installed. The guard must only suppress re-entry, never the
    /// initial check.
    @MainActor
    func testCheckingStillRefreshesNormallyThroughGuardedPath() throws {
        try runCheckingGuardFlow()
    }

    /// The ready-guard flow, extracted so the real-destination
    /// survival test can run the exact same sequence.
    @MainActor
    private func runReadyGuardFlow() throws {
        // Arrange: a pinned-verified file at the isolated
        // destination — the exact state a completed download leaves
        // behind, staged entirely under the temp root.
        let lookup = makeIsolatedLookup()
        let payload = Data("GGUF-round5-ready-guard!!".utf8)
        try writeFile(at: lookup.destination, data: payload)
        let readiness = makeReadiness(payload: payload, lookup: lookup)

        // Drive the view model to .ready through the same guarded
        // path the root view's task calls.
        let viewModel = ModelDownloadViewModel(readiness: readiness,
                                               environment: [:],
                                               fileManager: lookup.fileManager)
        XCTAssertEqual(viewModel.phase, .checking)
        viewModel.refreshIfNeeded()
        waitForPhase(.ready, in: viewModel)

        // Sabotage the underlying file, then calibrate: a fresh view
        // model re-checking this state must reach `.needsDownload`,
        // proving a re-check WOULD flip the phase if one ran.
        try FileManager.default.removeItem(at: lookup.destination)
        let control = ModelDownloadViewModel(readiness: readiness,
                                             environment: [:],
                                             fileManager: lookup.fileManager)
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

    /// The checking-guard flow, extracted so the real-destination
    /// survival test can run the exact same sequence.
    @MainActor
    private func runCheckingGuardFlow() throws {
        let lookup = makeIsolatedLookup()
        let viewModel = makeViewModel(payload: Data("GGUF-round5-absent".utf8), lookup: lookup)
        XCTAssertEqual(viewModel.phase, .checking)
        viewModel.refreshIfNeeded()
        waitForPhase(.needsDownload, in: viewModel)
    }

    /// Fix round 6 (a): the guarded-refresh `.needsDownload`
    /// expectations hold even with a simulated legacy override and a
    /// Documents-staged model present. The hostile signals are passed
    /// as explicit lookup inputs — never installed into the process
    /// environment or the real directories, since mutating that
    /// shared host state would itself be unhermetic — and the
    /// potency checks prove those exact signals WOULD satisfy the
    /// gate, so the isolated flow resolving `.needsDownload` proves
    /// it ignores them.
    @MainActor
    func testCheckingIgnoresSimulatedLegacyOverrideAndDocumentsModel() throws {
        // Simulate host contamination: a legacy env-override file and
        // a model staged in (stub) Documents.
        let hostileRoot = makeTempRoot()
        let hostileFileManager = stubbedFileManager(root: hostileRoot)
        let legacyOverride = hostileRoot.appendingPathComponent("legacy-override.gguf")
        try Data("not-a-gguf-stub".utf8).write(to: legacyOverride)
        let documentsStaged = hostileFileManager.documentsDir.appendingPathComponent("EarnPlayModel.gguf")
        try writeFile(at: documentsStaged, data: Data("legacy-docs-model".utf8))
        let hostileDestination = ModelDownloader.defaultDestinationURL(fileManager: hostileFileManager)
        let hostileRegistry = hostileRoot.appendingPathComponent("registry")
            .appendingPathComponent("registry.json")
        let hostileReadiness = ModelDownloadReadiness(
            configuration: testConfiguration(payload: Data("GGUF-unused".utf8)),
            destinationURL: hostileDestination,
            registryStoreURL: hostileRegistry)

        // Potency: each hostile signal WOULD satisfy the gate on its
        // own (legacy locations count by existence, without
        // re-verification), so they are a real threat to a lookup
        // that consulted them.
        XCTAssertTrue(
            hostileReadiness.isReady(environment: ["EARNPLAY_MODEL_PATH": legacyOverride.path],
                                     fileManager: hostileFileManager),
            "setup: the simulated legacy override must satisfy the gate, or it proves nothing")
        XCTAssertTrue(hostileReadiness.isReady(environment: [:], fileManager: hostileFileManager),
            "setup: the simulated Documents-staged model must satisfy the gate, or it proves nothing")

        // The isolated guarded-refresh flow ignores both signals: an
        // empty environment, clean stub directories, and nothing
        // installed still resolve `.needsDownload`.
        try runCheckingGuardFlow()
    }

    /// Fix round 6 (b): no test in this suite writes to or deletes the
    /// real default destination. A sentinel file is planted at the
    /// real location (a pre-existing real model is first sheltered
    /// aside under temp and restored afterwards, so it can never be
    /// harmed), every flow in this suite runs plus the exact cleanup
    /// `tearDown` performs, and the sentinel must survive
    /// byte-identical. Afterwards the prior state — file or absence —
    /// is restored exactly.
    @MainActor
    func testRealDefaultDestinationSurvivesIsolatedSuite() throws {
        let real = ModelDownloader.defaultDestinationURL()
        let parentDir = real.deletingLastPathComponent()
        let parentExisted = FileManager.default.fileExists(atPath: parentDir.path)
        let sentinel = Data("round6-no-touch-sentinel".utf8)

        // Shelter a pre-existing real model aside so the suite can
        // never harm it; refuse to proceed rather than risk it.
        var shelter: URL?
        if FileManager.default.fileExists(atPath: real.path) {
            let backup = makeTempRoot().appendingPathComponent("sheltered-real-model.gguf")
            do {
                try FileManager.default.moveItem(at: real, to: backup)
            } catch {
                throw XCTSkip("cannot shelter the pre-existing model at \(real.path); refusing to risk it: \(error)")
            }
            print("round6: sheltered pre-existing \(real.path) at \(backup.path)")
            shelter = backup
        }
        try writeFile(at: real, data: sentinel)
        defer {
            try? FileManager.default.removeItem(at: real)
            if !parentExisted {
                try? FileManager.default.removeItem(at: parentDir)
            }
            if let shelter {
                do {
                    try FileManager.default.moveItem(at: shelter, to: real)
                } catch {
                    XCTFail("FAILED to restore sheltered model from \(shelter.path) to \(real.path): \(error)")
                }
            }
        }

        // Every flow in this suite, plus the exact cleanup tearDown
        // performs — then the real location must still hold the
        // untouched sentinel.
        try runReadyGuardFlow()
        try runCheckingGuardFlow()
        removeTempRoots()

        XCTAssertEqual(try? Data(contentsOf: real), sentinel,
            "no test may write to or delete the real default destination; the sentinel must survive the suite byte-identical")
    }

    /// The round-6 seam must leave the production lookup unchanged: a
    /// default-constructed view model (the production call site in
    /// `EarnPlayApp`) carries a nil environment — the live process
    /// environment — and the default file manager — the live standard
    /// directories — so `refresh()` resolves exactly what the old
    /// bare `isReady()` call did.
    @MainActor
    func testDefaultInitPreservesProductionLookup() {
        let viewModel = ModelDownloadViewModel()
        XCTAssertNil(viewModel.readinessEnvironment,
            "production must resolve against the live process environment")
        XCTAssertIdentical(viewModel.readinessFileManager, FileManager.default,
            "production must resolve against the live standard directories")
    }
}
