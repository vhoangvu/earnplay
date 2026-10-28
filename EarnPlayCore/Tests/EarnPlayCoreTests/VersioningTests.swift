import XCTest
@testable import EarnPlayCore

/// T5.3: every session record carries the active model + prompt version,
/// and selecting a rollback bundle changes what new sessions stamp.
/// The production bundle must derive from the real runtime/prompt
/// constants — never from hard-coded copies of those strings.
final class VersioningTests: XCTestCase {

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("version-registry.json")
    }

    private func tempGGUF(named name: String = "PreviousModel.gguf") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("GGUF-fixture".utf8).write(to: url)
        return url
    }

    private func makeRegistry() throws -> VersionRegistry {
        let previousModel = try tempGGUF()
        return try VersionRegistry(
            bundles: [
                VersionBundle(
                    bundleID: "current",
                    modelVersion: ModelRuntime.versionStamp,
                    promptVersion: SpikePrompts.version
                ),
                VersionBundle(
                    bundleID: VersionRegistry.previousKnownGoodBundleID,
                    modelVersion: "previous-model-fixture",
                    promptVersion: "previous-prompt-fixture",
                    modelFilePath: previousModel.path,
                    promptTexts: ["Previous prompt alpha.", "Previous prompt beta."]
                ),
            ],
            activeBundleID: "current"
        )
    }

    func testProductionBundleDerivesFromRuntimeAndPromptConstants() throws {
        let registry = try VersionRegistry.production(storeURL: tempStoreURL(), modelURL: nil)
        XCTAssertEqual(registry.activeBundle.modelVersion, ModelRuntime.versionStamp)
        XCTAssertEqual(
            registry.activeBundle.modelVersion,
            "\(ModelRuntime.modelIdentifier) / \(ModelRuntime.runtimeIdentifier)"
        )
        XCTAssertEqual(registry.activeBundle.promptVersion, SpikePrompts.version)
        XCTAssertFalse(registry.activeBundle.modelVersion.isEmpty)
        XCTAssertFalse(registry.activeBundle.promptVersion.isEmpty)
    }

    /// Production ships exactly one bundle today, so production rollback
    /// must fail honestly instead of pretending an older bundle exists.
    func testProductionRegistryHasNoPreviousBundleYet() throws {
        let registry = try VersionRegistry.production(storeURL: tempStoreURL(), modelURL: nil)
        XCTAssertThrowsError(try registry.rollbackToPreviousKnownGood()) { error in
            XCTAssertEqual(error as? VersioningError, .noPreviousBundle)
        }
    }

    func testFixtureSessionStampsActiveVersions() throws {
        let registry = try makeRegistry()
        let startedAt = Date(timeIntervalSince1970: 1_730_000_000)
        let session = try SessionRecord.start(
            sessionId: "fixture-session-1",
            startedAt: startedAt,
            registry: registry
        )
        XCTAssertEqual(session.sessionId, "fixture-session-1")
        XCTAssertEqual(session.startedAt, startedAt)
        XCTAssertFalse(session.modelVersion.isEmpty)
        XCTAssertFalse(session.promptVersion.isEmpty)
        XCTAssertEqual(session.modelVersion, registry.activeBundle.modelVersion)
        XCTAssertEqual(session.promptVersion, registry.activeBundle.promptVersion)
        XCTAssertEqual(session.modelVersion, ModelRuntime.versionStamp)
        XCTAssertEqual(session.promptVersion, SpikePrompts.version)
    }

    func testSessionRecordRejectsMissingVersions() {
        let startedAt = Date(timeIntervalSince1970: 1_730_000_000)
        XCTAssertThrowsError(
            try SessionRecord(sessionId: "s", startedAt: startedAt, modelVersion: "", promptVersion: "p")
        ) { error in
            XCTAssertEqual(error as? SessionRecordError, .missingVersion(field: "modelVersion"))
        }
        XCTAssertThrowsError(
            try SessionRecord(sessionId: "s", startedAt: startedAt, modelVersion: "m", promptVersion: "  ")
        ) { error in
            XCTAssertEqual(error as? SessionRecordError, .missingVersion(field: "promptVersion"))
        }
    }

    /// The card's rollback proof: after selecting the previous bundle,
    /// a new session stamps the older versions; rolling forward again
    /// restores the current stamp.
    func testRollbackChangesStampedVersionAndRollForwardRestores() throws {
        let registry = try makeRegistry()
        let startedAt = Date(timeIntervalSince1970: 1_730_000_100)
        let before = try SessionRecord.start(sessionId: "s-before", startedAt: startedAt, registry: registry)
        XCTAssertEqual(before.modelVersion, ModelRuntime.versionStamp)

        try registry.rollbackToPreviousKnownGood()
        XCTAssertEqual(registry.activeBundle.bundleID, VersionRegistry.previousKnownGoodBundleID)
        let rolledBack = try SessionRecord.start(sessionId: "s-rollback", startedAt: startedAt, registry: registry)
        XCTAssertEqual(rolledBack.modelVersion, "previous-model-fixture")
        XCTAssertEqual(rolledBack.promptVersion, "previous-prompt-fixture")
        XCTAssertNotEqual(rolledBack.modelVersion, before.modelVersion)

        try registry.select(bundleID: "current")
        let forward = try SessionRecord.start(sessionId: "s-forward", startedAt: startedAt, registry: registry)
        XCTAssertEqual(forward.modelVersion, ModelRuntime.versionStamp)
        XCTAssertEqual(forward.promptVersion, SpikePrompts.version)
    }

    func testUnknownBundleSelectionThrows() throws {
        let registry = try makeRegistry()
        XCTAssertThrowsError(try registry.select(bundleID: "does-not-exist")) { error in
            XCTAssertEqual(error as? VersioningError, .unknownBundle("does-not-exist"))
        }
        // A failed selection must not change the active bundle.
        XCTAssertEqual(registry.activeBundle.bundleID, "current")
    }

    func testRegistryRejectsInvalidBundles() {
        XCTAssertThrowsError(
            try VersionRegistry(
                bundles: [VersionBundle(bundleID: "current", modelVersion: "", promptVersion: "p")],
                activeBundleID: "current"
            )
        ) { error in
            XCTAssertEqual(
                error as? VersioningError,
                .emptyVersionField(bundleID: "current", field: "modelVersion")
            )
        }
        XCTAssertThrowsError(
            try VersionRegistry(
                bundles: [VersionBundle(bundleID: "current", modelVersion: "m", promptVersion: "p")],
                activeBundleID: "missing"
            )
        ) { error in
            XCTAssertEqual(error as? VersioningError, .unknownBundle("missing"))
        }
    }

    // F1: concurrent register + session-stamp must not race/crash.
    func testConcurrentRegisterAndStampIsConsistent() throws {
        let registry = try makeRegistry()
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var errors: [Error] = []; var stamps = 0
        }
        let box = Box()
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            do {
                try registry.register(VersionBundle(
                    bundleID: "extra-\(i)", modelVersion: "m-\(i)", promptVersion: "p-\(i)"))
                _ = try SessionRecord.start(sessionId: "s-\(i)", registry: registry)
                box.lock.lock(); box.stamps += 1; box.lock.unlock()
            } catch {
                box.lock.lock(); box.errors.append(error); box.lock.unlock()
            }
        }
        XCTAssertTrue(box.errors.isEmpty, "unexpected errors: \(box.errors)")
        XCTAssertEqual(box.stamps, 100)
        XCTAssertEqual(registry.registeredBundles.count, 102)
        XCTAssertEqual(registry.activeBundleID, "current")
    }

    // F2: after rollback, inference artifacts are the rolled-back ones.
    func testRollbackArtifactsAreUsedByInference() throws {
        let registry = try makeRegistry()
        let previous = registry.registeredBundles.first {
            $0.bundleID == VersionRegistry.previousKnownGoodBundleID
        }!
        try registry.rollbackToPreviousKnownGood()
        let artifacts = try registry.inferenceArtifacts(defaultModelURL: nil)
        XCTAssertEqual(artifacts.modelVersion, "previous-model-fixture")
        XCTAssertEqual(artifacts.promptVersion, "previous-prompt-fixture")
        XCTAssertEqual(artifacts.prompts, ["Previous prompt alpha.", "Previous prompt beta."])
        XCTAssertEqual(artifacts.modelURL?.path, previous.modelFilePath)
        let session = try SessionRecord.start(sessionId: "after-rollback", registry: registry)
        XCTAssertEqual(session.modelVersion, "previous-model-fixture")
        XCTAssertEqual(session.promptVersion, "previous-prompt-fixture")
    }

    // F2: a bundle with no bound artifacts cannot be selected.
    func testSelectRejectsBundleWithoutArtifacts() throws {
        let registry = try makeRegistry()
        try registry.register(VersionBundle(
            bundleID: "label-only", modelVersion: "ghost-model", promptVersion: "ghost-prompt"))
        XCTAssertThrowsError(try registry.select(bundleID: "label-only")) { error in
            XCTAssertEqual(error as? VersioningError,
                           .artifactUnavailable(bundleID: "label-only", artifact: "modelFile"))
        }
        XCTAssertEqual(registry.activeBundleID, "current")
        try registry.register(VersionBundle(
            bundleID: "missing-model", modelVersion: "m", promptVersion: "spike-v1",
            modelFilePath: "/nonexistent/ghost.gguf"))
        XCTAssertThrowsError(try registry.select(bundleID: "missing-model")) { error in
            XCTAssertEqual(error as? VersioningError,
                           .artifactUnavailable(bundleID: "missing-model", artifact: "modelFile"))
        }
        XCTAssertEqual(registry.activeBundleID, "current")
    }

    // F6+F4: persisted registry survives reconstruction; a second
    // instance (the admin panel's data source) sees the selection.
    func testPersistedRegistrySurvivesReconstructionAndPanelReadsIt() throws {
        let store = tempStoreURL()
        let previousModel = try tempGGUF()
        let first = try VersionRegistry.production(storeURL: store, modelURL: nil)
        try first.register(VersionBundle(
            bundleID: VersionRegistry.previousKnownGoodBundleID,
            modelVersion: "persisted-previous-model",
            promptVersion: "persisted-previous-prompt",
            modelFilePath: previousModel.path,
            promptTexts: ["Persisted previous prompt."]))
        try first.rollbackToPreviousKnownGood()

        let panelSource = try VersionRegistry.production(storeURL: store, modelURL: nil)
        XCTAssertEqual(panelSource.activeBundleID, VersionRegistry.previousKnownGoodBundleID)
        XCTAssertEqual(panelSource.activeBundle.modelVersion, "persisted-previous-model")
        XCTAssertEqual(panelSource.activeBundle.promptVersion, "persisted-previous-prompt")
        XCTAssertEqual(panelSource.registeredBundles.count, 2)
        let session = try SessionRecord.start(sessionId: "after-restart", registry: panelSource)
        XCTAssertEqual(session.modelVersion, "persisted-previous-model")
        XCTAssertEqual(session.promptVersion, "persisted-previous-prompt")
        let artifacts = try panelSource.inferenceArtifacts(defaultModelURL: nil)
        XCTAssertEqual(artifacts.prompts, ["Persisted previous prompt."])
        XCTAssertEqual(artifacts.modelURL?.path, previousModel.path)
    }

    // F5: production registry stamps an installed file's true identity.
    func testProductionUsesVerifiedIdentityOfInstalledModel() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = dir.appendingPathComponent("InstalledModel.gguf")
        try Data([0x47, 0x47, 0x55, 0x46, 0, 0, 0, 0, 0, 0, 0, 0]).write(to: model)
        let registry = try VersionRegistry.production(storeURL: tempStoreURL(), modelURL: model)
        XCTAssertEqual(
            registry.activeBundle.modelVersion,
            "InstalledModel.gguf (12 bytes, GGUF) / llama.cpp b11935, CPU backend")
        XCTAssertFalse(registry.activeBundle.modelVersion.contains("Llama-3.2-1B"))
    }

    // F7: decoding enforces the non-empty version invariant.
    func testDecodingRecordWithEmptyVersionThrows() throws {
        let decoder = JSONDecoder()
        let emptyModel = #"{"sessionId":"s1","startedAt":1000,"modelVersion":"","promptVersion":"p1"}"#
        XCTAssertThrowsError(try decoder.decode(SessionRecord.self, from: Data(emptyModel.utf8))) { error in
            XCTAssertEqual(error as? SessionRecordError, .missingVersion(field: "modelVersion"))
        }
        let blankPrompt = #"{"sessionId":"s1","startedAt":1000,"modelVersion":"m1","promptVersion":"   "}"#
        XCTAssertThrowsError(try decoder.decode(SessionRecord.self, from: Data(blankPrompt.utf8))) { error in
            XCTAssertEqual(error as? SessionRecordError, .missingVersion(field: "promptVersion"))
        }
        let valid = #"{"sessionId":"s9","startedAt":1000,"modelVersion":"m9","promptVersion":"p9"}"#
        let record = try decoder.decode(SessionRecord.self, from: Data(valid.utf8))
        XCTAssertEqual(record.sessionId, "s9")
        XCTAssertEqual(record.modelVersion, "m9")
        XCTAssertEqual(record.promptVersion, "p9")
        XCTAssertEqual(record.startedAt, Date(timeIntervalSinceReferenceDate: 1000))
    }

    func testKnownLimitsNoteMentionsVerifiedLimits() {
        XCTAssertFalse(VersionKnownLimits.notes.isEmpty)
        let text = VersionKnownLimits.noteText()
        XCTAssertFalse(text.isEmpty)
        // Simulator-only inference validation (Docs/ModelRuntimeSpike.md).
        XCTAssertTrue(text.contains("simulator"), "note must name the simulator-only limit")
        // CI skips real inference without the fetched model/framework.
        XCTAssertTrue(text.lowercased().contains("ci"), "note must name the CI skip limit")
    }
}
