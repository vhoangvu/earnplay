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
        let digest = try ModelRuntime.contentSHA256(forFileAt: model)
        XCTAssertEqual(
            registry.activeBundle.modelVersion,
            "InstalledModel.gguf (12 bytes, GGUF, sha256:\(digest)) / llama.cpp b11935, CPU backend")
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

extension VersioningTests {
    // F7: same-size different content yields a different stamp.
    func testVerifiedStampDistinguishesSameSizeDifferentContent() throws {
        let a = try tempGGUF(named: "SameSize.gguf")
        // tempGGUF creates a fresh dir each call; rewrite a second file manually
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let b = dir.appendingPathComponent("SameSize.gguf")
        try Data("GGUF-fixture".utf8).write(to: a) // 12 bytes
        try Data("GGUF-fixturf".utf8).write(to: b) // also 12 bytes, different content
        XCTAssertNotEqual(try ModelRuntime.verifiedModelVersion(forModelAt: a),
                          try ModelRuntime.verifiedModelVersion(forModelAt: b))
    }

    // F1: corrupt current model does not block restoring/using previous.
    func testProductionRecoversPersistedRegistryWhenCurrentModelCorrupt() throws {
        let store = tempStoreURL()
        let good = try tempGGUF(named: "Good.gguf")
        try Data("GGUF-good-model".utf8).write(to: good)
        let first = try VersionRegistry.production(storeURL: store, modelURL: good)
        try first.registerActiveAsPreviousKnownGood()
        try first.rollbackToPreviousKnownGood()
        let corruptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corrupt = corruptDir.appendingPathComponent("Corrupt.gguf")
        try Data("not a gguf at all".utf8).write(to: corrupt)
        let restored = try VersionRegistry.production(storeURL: store, modelURL: corrupt)
        XCTAssertEqual(restored.activeBundleID, VersionRegistry.previousKnownGoodBundleID)
        let artifacts = try restored.inferenceArtifacts(defaultModelURL: nil)
        XCTAssertEqual(artifacts.prompts, SpikePrompts.all)
        XCTAssertNotNil(artifacts.modelURL)
    }

    // F2: corrupt registry file propagates instead of resetting.
    func testProductionPropagatesCorruptRegistry() throws {
        let store = tempStoreURL()
        try FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{{{ not json".utf8).write(to: store)
        XCTAssertThrowsError(try VersionRegistry.production(storeURL: store, modelURL: nil))
    }

    // F3: snapshot captures resolved prompts and retains model copy.
    func testRegisterActiveSnapshotsPromptsAndRetainsModelCopy() throws {
        let store = tempStoreURL()
        let model = try tempGGUF(named: "Installed.gguf")
        try Data("GGUF-original-bytes".utf8).write(to: model)
        let registry = try VersionRegistry.production(storeURL: store, modelURL: model)
        try registry.registerActiveAsPreviousKnownGood()
        let previous = registry.registeredBundles.first { $0.bundleID == VersionRegistry.previousKnownGoodBundleID }!
        XCTAssertEqual(previous.promptTexts, SpikePrompts.all)
        XCTAssertNotNil(previous.modelFilePath)
        XCTAssertNotEqual(previous.modelFilePath, model.path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: previous.modelFilePath!)),
                       Data("GGUF-original-bytes".utf8))
        // Replacing the installed model must not affect the retained copy.
        try Data("GGUF-replacement!".utf8).write(to: model)
        try registry.rollbackToPreviousKnownGood()
        let artifacts = try registry.inferenceArtifacts(defaultModelURL: nil)
        XCTAssertEqual(artifacts.modelURL?.path, previous.modelFilePath)
        XCTAssertEqual(artifacts.prompts, SpikePrompts.all)
    }

    // F4: explicit path rejects directory, non-GGUF, and changed content.
    func testExplicitPathRejectsDirectoryNonGGUFAndChangedContent() throws {
        let registry = try makeRegistry()
        let dirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        try registry.register(VersionBundle(bundleID: "dir-model", modelVersion: "m", promptVersion: "spike-v1",
                                            modelFilePath: dirURL.path, promptTexts: ["p"]))
        XCTAssertThrowsError(try registry.select(bundleID: "dir-model")) { e in
            XCTAssertEqual(e as? VersioningError, .artifactUnavailable(bundleID: "dir-model", artifact: "modelFile"))
        }
        let bad = dirURL.appendingPathComponent("bad.gguf")
        try Data("plain text here".utf8).write(to: bad)
        try registry.register(VersionBundle(bundleID: "bad-model", modelVersion: "m", promptVersion: "spike-v1",
                                            modelFilePath: bad.path, promptTexts: ["p"]))
        XCTAssertThrowsError(try registry.select(bundleID: "bad-model"))
        // Changed content under the same path (same size) is rejected.
        let changing = try tempGGUF(named: "Changing.gguf")
        try Data("GGUF-AAAAAAA".utf8).write(to: changing)
        let reg2 = try VersionRegistry(bundles: [
            VersionBundle(bundleID: "current", modelVersion: ModelRuntime.versionStamp, promptVersion: SpikePrompts.version),
            VersionBundle(bundleID: "chg", modelVersion: "m", promptVersion: "spike-v1",
                          modelFilePath: changing.path, promptTexts: ["p"]),
        ], activeBundleID: "current")
        _ = reg2
        try Data("GGUF-BBBBBBB".utf8).write(to: changing)
        XCTAssertThrowsError(try registry.select(bundleID: "chg"))
        XCTAssertThrowsError(try reg2.select(bundleID: "chg")) { e in
            XCTAssertEqual(e as? VersioningError, .artifactUnavailable(bundleID: "chg", artifact: "modelFile"))
        }
    }

    // F5/F8: configured stamp does not bind an unrelated default file;
    // supplied production model path is used by inferenceArtifacts().
    func testConfiguredStampRejectsUnboundModelAndProductionBindsSuppliedPath() throws {
        let registry = try makeRegistry()
        let other = try tempGGUF(named: "Other.gguf")
        XCTAssertThrowsError(try registry.inferenceArtifacts(defaultModelURL: other)) { e in
            XCTAssertEqual(e as? VersioningError, .artifactUnavailable(bundleID: "current", artifact: "modelFile"))
        }
        let installed = try tempGGUF(named: "Bound.gguf")
        try Data("GGUF-bound-model".utf8).write(to: installed)
        let prod = try VersionRegistry.production(storeURL: tempStoreURL(), modelURL: installed)
        let artifacts = try prod.inferenceArtifacts(defaultModelURL: nil)
        XCTAssertEqual(artifacts.modelURL?.path, installed.path)
    }

    // F9/F10/F12: active replacement validation + persistence-failure rollback.
    func testActiveReplacementValidatedAndPersistenceFailureRestoresState() throws {
        let registry = try makeRegistry()
        XCTAssertThrowsError(try registry.register(VersionBundle(
            bundleID: "current", modelVersion: "ghost-model", promptVersion: "ghost-prompt")))
        XCTAssertEqual(registry.activeBundle.modelVersion, ModelRuntime.versionStamp)

        let store = tempStoreURL()
        let persisted = try VersionRegistry.production(storeURL: store, modelURL: nil)
        let prevModel = try tempGGUF()
        try persisted.register(VersionBundle(
            bundleID: VersionRegistry.previousKnownGoodBundleID, modelVersion: "prev-m",
            promptVersion: "prev-p", modelFilePath: prevModel.path, promptTexts: ["Prev."]))
        let storeDir = store.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: storeDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeDir.path) }
        XCTAssertThrowsError(try persisted.register(VersionBundle(
            bundleID: "never-persisted", modelVersion: "m", promptVersion: "p")))
        XCTAssertFalse(persisted.registeredBundles.contains { $0.bundleID == "never-persisted" })
        XCTAssertThrowsError(try persisted.select(bundleID: VersionRegistry.previousKnownGoodBundleID))
        XCTAssertEqual(persisted.activeBundleID, "current")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeDir.path)
        try persisted.select(bundleID: VersionRegistry.previousKnownGoodBundleID)
        XCTAssertEqual(persisted.activeBundleID, VersionRegistry.previousKnownGoodBundleID)
    }

    // F6: two instances on one store do not lose each other's updates.
    func testCrossInstanceRegistriesMergeLatestState() throws {
        let store = tempStoreURL()
        let a = try VersionRegistry.production(storeURL: store, modelURL: nil)
        let b = try VersionRegistry.production(storeURL: store, modelURL: nil)
        let prevModel = try tempGGUF()
        try a.register(VersionBundle(bundleID: VersionRegistry.previousKnownGoodBundleID,
                                     modelVersion: "prev-m", promptVersion: "prev-p",
                                     modelFilePath: prevModel.path, promptTexts: ["Prev."]))
        try b.register(VersionBundle(bundleID: "from-b", modelVersion: "m-b", promptVersion: "p-b"))
        XCTAssertTrue(b.registeredBundles.contains { $0.bundleID == VersionRegistry.previousKnownGoodBundleID })
        try a.rollbackToPreviousKnownGood()
        let fresh = try VersionRegistry.production(storeURL: store, modelURL: nil)
        XCTAssertEqual(fresh.activeBundleID, VersionRegistry.previousKnownGoodBundleID)
        XCTAssertTrue(fresh.registeredBundles.contains { $0.bundleID == "from-b" })
        XCTAssertTrue(fresh.registeredBundles.contains { $0.bundleID == VersionRegistry.previousKnownGoodBundleID })
    }
}
