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
        XCTAssertEqual(try registry.activeBundle.modelVersion, ModelRuntime.versionStamp)
        XCTAssertEqual(
            try registry.activeBundle.modelVersion,
            "\(ModelRuntime.modelIdentifier) / \(ModelRuntime.runtimeIdentifier)"
        )
        XCTAssertEqual(try registry.activeBundle.promptVersion, SpikePrompts.version)
        XCTAssertFalse(try registry.activeBundle.modelVersion.isEmpty)
        XCTAssertFalse(try registry.activeBundle.promptVersion.isEmpty)
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
        XCTAssertEqual(session.modelVersion, try registry.activeBundle.modelVersion)
        XCTAssertEqual(session.promptVersion, try registry.activeBundle.promptVersion)
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
        // Round 4 F12: roll-forward target must carry a real model
        // artifact, so this registry binds "current" to a GGUF file.
        let currentModel = try tempGGUF(named: "CurrentModel.gguf")
        let previousModel = try tempGGUF()
        let registry = try VersionRegistry(
            bundles: [
                VersionBundle(
                    bundleID: "current",
                    modelVersion: ModelRuntime.versionStamp,
                    promptVersion: SpikePrompts.version,
                    modelFilePath: currentModel.path,
                    promptTexts: SpikePrompts.all
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
        let startedAt = Date(timeIntervalSince1970: 1_730_000_100)
        let before = try SessionRecord.start(sessionId: "s-before", startedAt: startedAt, registry: registry)
        XCTAssertEqual(before.modelVersion, ModelRuntime.versionStamp)

        try registry.rollbackToPreviousKnownGood()
        XCTAssertEqual(try registry.activeBundle.bundleID, VersionRegistry.previousKnownGoodBundleID)
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
        XCTAssertEqual(try registry.activeBundle.bundleID, "current")
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
        XCTAssertEqual(try registry.registeredBundles.count, 102)
        XCTAssertEqual(try registry.activeBundleID, "current")
    }

    // F2: after rollback, inference artifacts are the rolled-back ones.
    func testRollbackArtifactsAreUsedByInference() throws {
        let registry = try makeRegistry()
        let previous = try registry.registeredBundles.first {
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
        XCTAssertEqual(try registry.activeBundleID, "current")
        try registry.register(VersionBundle(
            bundleID: "missing-model", modelVersion: "m", promptVersion: "spike-v1",
            modelFilePath: "/nonexistent/ghost.gguf"))
        XCTAssertThrowsError(try registry.select(bundleID: "missing-model")) { error in
            XCTAssertEqual(error as? VersioningError,
                           .artifactUnavailable(bundleID: "missing-model", artifact: "modelFile"))
        }
        XCTAssertEqual(try registry.activeBundleID, "current")
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
        XCTAssertEqual(try panelSource.activeBundleID, VersionRegistry.previousKnownGoodBundleID)
        XCTAssertEqual(try panelSource.activeBundle.modelVersion, "persisted-previous-model")
        XCTAssertEqual(try panelSource.activeBundle.promptVersion, "persisted-previous-prompt")
        XCTAssertEqual(try panelSource.registeredBundles.count, 2)
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
            try registry.activeBundle.modelVersion,
            "InstalledModel.gguf (12 bytes, GGUF, sha256:\(digest)) / llama.cpp b11935, CPU backend")
        XCTAssertFalse(try registry.activeBundle.modelVersion.contains("Llama-3.2-1B"))
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
        XCTAssertEqual(try restored.activeBundleID, VersionRegistry.previousKnownGoodBundleID)
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
        let previous = try registry.registeredBundles.first { $0.bundleID == VersionRegistry.previousKnownGoodBundleID }!
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
        XCTAssertEqual(try registry.activeBundle.modelVersion, ModelRuntime.versionStamp)

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
        XCTAssertFalse(try persisted.registeredBundles.contains { $0.bundleID == "never-persisted" })
        XCTAssertThrowsError(try persisted.select(bundleID: VersionRegistry.previousKnownGoodBundleID))
        XCTAssertEqual(try persisted.activeBundleID, "current")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeDir.path)
        try persisted.select(bundleID: VersionRegistry.previousKnownGoodBundleID)
        XCTAssertEqual(try persisted.activeBundleID, VersionRegistry.previousKnownGoodBundleID)
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
        XCTAssertTrue(try b.registeredBundles.contains { $0.bundleID == VersionRegistry.previousKnownGoodBundleID })
        try a.rollbackToPreviousKnownGood()
        let fresh = try VersionRegistry.production(storeURL: store, modelURL: nil)
        XCTAssertEqual(try fresh.activeBundleID, VersionRegistry.previousKnownGoodBundleID)
        XCTAssertTrue(try fresh.registeredBundles.contains { $0.bundleID == "from-b" })
        XCTAssertTrue(try fresh.registeredBundles.contains { $0.bundleID == VersionRegistry.previousKnownGoodBundleID })
    }
}

extension VersioningTests {
    // Round 4 F2: same-size replacement with preserved mtime rehashes.
    func testSameSizeReplacementWithPreservedMtimeRehashes() throws {
        let url = try tempGGUF(named: "CacheBust.gguf")
        try Data("GGUF-AAAAAAA".utf8).write(to: url)
        let first = try ModelRuntime.contentSHA256(forFileAt: url)
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs[.modificationDate] as! Date
        try Data("GGUF-BBBBBBB".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        let second = try ModelRuntime.contentSHA256(forFileAt: url)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(try ModelRuntime.verifiedModelVersion(forModelAt: url),
                          "CacheBust.gguf (12 bytes, GGUF, sha256:\(first)) / llama.cpp b11935, CPU backend")
    }

    // Round 4 F1: a runtime bound to a verified digest rejects a
    // file replaced after the runtime was created, at load time.
    func testBoundRuntimeRejectsReplacedModelAtLoad() throws {
        let url = try tempGGUF(named: "BoundLoad.gguf")
        try Data("GGUF-AAAAAAA".utf8).write(to: url)
        let digest = try ModelRuntime.contentSHA256(forFileAt: url)
        let runtime = ModelRuntime(modelPath: url, expectedContentDigest: digest)
        try Data("GGUF-BBBBBBB".utf8).write(to: url)
        XCTAssertThrowsError(try runtime.load()) { error in
            XCTAssertEqual(error as? ModelRuntimeError, .modelContentMismatch(path: url.path))
        }
        // Re-resolving against the new file binds its new digest.
        let newDigest = try ModelRuntime.contentSHA256(forFileAt: url)
        XCTAssertNotEqual(newDigest, digest)
        let artifactsDigest = try ModelRuntime.verifiedModelVersion(forModelAt: url)
        XCTAssertTrue(artifactsDigest.contains(newDigest))
    }

    // Round 4 F12: snapshot and rollback/select reject missing models.
    func testSnapshotAndSelectionRejectMissingModelArtifacts() throws {
        let registry = try VersionRegistry.production(storeURL: tempStoreURL(), modelURL: nil)
        XCTAssertThrowsError(try registry.registerActiveAsPreviousKnownGood(defaultModelURL: nil)) { error in
            XCTAssertEqual(error as? VersioningError,
                           .artifactUnavailable(bundleID: "current", artifact: "modelFile"))
        }
        XCTAssertThrowsError(try registry.rollbackToPreviousKnownGood()) { error in
            XCTAssertEqual(error as? VersioningError, .noPreviousBundle)
        }
        let labelOnly = try VersionRegistry(
            bundles: [
                VersionBundle(bundleID: "current", modelVersion: ModelRuntime.versionStamp,
                              promptVersion: SpikePrompts.version,
                              modelFilePath: try tempGGUF().path, promptTexts: SpikePrompts.all),
                VersionBundle(bundleID: VersionRegistry.previousKnownGoodBundleID,
                              modelVersion: "ghost", promptVersion: "ghost-prompt"),
            ], activeBundleID: "current")
        XCTAssertThrowsError(try labelOnly.rollbackToPreviousKnownGood()) { error in
            XCTAssertEqual(error as? VersioningError,
                           .artifactUnavailable(bundleID: VersionRegistry.previousKnownGoodBundleID,
                                                artifact: "modelFile"))
        }
    }

    // Round 4 F4: throwing reads propagate a corrupt persisted store
    // instead of returning stale cached state; stamping follows suit.
    func testThrowingReadsPropagateCorruptPersistedState() throws {
        let store = tempStoreURL()
        let registry = try VersionRegistry.production(storeURL: store, modelURL: nil)
        try Data("{{{ corrupt".utf8).write(to: store)
        XCTAssertThrowsError(try registry.activeBundle)
        XCTAssertThrowsError(try registry.registeredBundles)
        XCTAssertThrowsError(try registry.activeBundleID)
        XCTAssertThrowsError(try SessionRecord.start(sessionId: "s-corrupt", registry: registry))
    }

    // Round 4 F5: snapshot rejects a source replaced after binding.
    func testSnapshotRejectsSourceReplacedAfterBinding() throws {
        let store = tempStoreURL()
        let model = try tempGGUF(named: "SnapshotSrc.gguf")
        try Data("GGUF-AAAAAAA".utf8).write(to: model)
        let registry = try VersionRegistry.production(storeURL: store, modelURL: model)
        try Data("GGUF-BBBBBBB".utf8).write(to: model)
        XCTAssertThrowsError(try registry.registerActiveAsPreviousKnownGood()) { error in
            XCTAssertEqual(error as? VersioningError,
                           .artifactUnavailable(bundleID: "current", artifact: "modelFile"))
        }
        XCTAssertFalse(try registry.registeredBundles.contains {
            $0.bundleID == VersionRegistry.previousKnownGoodBundleID
        })
    }

    // Round 4 F6: snapshots live at distinct immutable paths; the
    // old snapshot is retired only after the new entry persists.
    func testSnapshotsUseDistinctImmutablePathsAndRetireOld() throws {
        let store = tempStoreURL()
        let model = try tempGGUF(named: "Immutable.gguf")
        try Data("GGUF-version-A".utf8).write(to: model)
        let first = try VersionRegistry.production(storeURL: store, modelURL: model)
        try first.registerActiveAsPreviousKnownGood()
        let firstBundle = try first.registeredBundles.first {
            $0.bundleID == VersionRegistry.previousKnownGoodBundleID
        }!
        let firstPath = firstBundle.modelFilePath!
        XCTAssertTrue(firstPath.contains("previous-known-good-model-"))
        XCTAssertNotEqual(firstPath, store.deletingLastPathComponent()
            .appendingPathComponent("previous-known-good-model.gguf").path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: firstPath)),
                       Data("GGUF-version-A".utf8))

        try Data("GGUF-version-B".utf8).write(to: model)
        let second = try VersionRegistry.production(storeURL: store, modelURL: model)
        try second.registerActiveAsPreviousKnownGood()
        let secondBundle = try second.registeredBundles.first {
            $0.bundleID == VersionRegistry.previousKnownGoodBundleID
        }!
        XCTAssertNotEqual(secondBundle.modelFilePath, firstPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: secondBundle.modelFilePath!)),
                       Data("GGUF-version-B".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath),
                       "unreferenced previous snapshot must be retired after persist")
        try second.rollbackToPreviousKnownGood()
        let artifacts = try second.inferenceArtifacts(defaultModelURL: nil)
        XCTAssertEqual(artifacts.modelURL?.path, secondBundle.modelFilePath)
        XCTAssertEqual(artifacts.modelContentDigest, secondBundle.modelContentDigest)
    }

    // Round 4 F13: reported version keeps the retained model
    // identity but names the runtime actually running.
    func testReportedVersionComposesRetainedModelWithRunningRuntime() throws {
        XCTAssertEqual(
            ModelRuntime.reportedModelVersion(storedModelVersion: "OldModel.gguf (12 bytes, GGUF, sha256:abc) / stale-runtime-0"),
            "OldModel.gguf (12 bytes, GGUF, sha256:abc) / \(ModelRuntime.runtimeIdentifier)")
        XCTAssertEqual(ModelRuntime.reportedModelVersion(storedModelVersion: "plain-model-fixture"),
                       "plain-model-fixture")
        let model = try tempGGUF(named: "RuntimeCompose.gguf")
        let registry = try VersionRegistry(
            bundles: [
                VersionBundle(bundleID: "current", modelVersion: ModelRuntime.versionStamp,
                              promptVersion: SpikePrompts.version,
                              modelFilePath: model.path, promptTexts: SpikePrompts.all),
                VersionBundle(bundleID: VersionRegistry.previousKnownGoodBundleID,
                              modelVersion: "RetainedModel.gguf (12 bytes, GGUF, sha256:deadbeef) / stale-runtime-0",
                              promptVersion: "prev-prompt",
                              modelFilePath: model.path, promptTexts: ["Prev."]),
            ], activeBundleID: "current")
        try registry.rollbackToPreviousKnownGood()
        let artifacts = try registry.inferenceArtifacts(defaultModelURL: nil)
        XCTAssertEqual(artifacts.modelVersion,
                       "RetainedModel.gguf (12 bytes, GGUF, sha256:deadbeef) / \(ModelRuntime.runtimeIdentifier)")
        let session = try SessionRecord.start(sessionId: "s-runtime", registry: registry)
        XCTAssertEqual(session.modelVersion, artifacts.modelVersion)
    }
}

extension VersioningTests {
    // Round 5 F2: version stamp and digest come from one read.
    func testSinglePassIdentityMatchesBundleDigest() throws {
        let model = try tempGGUF(named: "SinglePass.gguf")
        try Data("GGUF-single-pass".utf8).write(to: model)
        let identity = try ModelRuntime.verifiedModelIdentity(forModelAt: model)
        XCTAssertEqual(identity.contentDigest, try ModelRuntime.contentSHA256(forFileAt: model))
        XCTAssertTrue(identity.modelVersion.contains(identity.contentDigest))
        let registry = try VersionRegistry.production(storeURL: tempStoreURL(), modelURL: model)
        let bundle = try registry.activeBundle
        XCTAssertEqual(bundle.modelContentDigest, identity.contentDigest)
        XCTAssertTrue(bundle.modelVersion.contains(bundle.modelContentDigest!))
    }

    // Round 5 F1: the retained immutable copy keeps verified bytes
    // even after the mutable source path is replaced.
    func testImmutableCopyRetainsVerifiedBytesAfterSourceReplacement() throws {
        let model = try tempGGUF(named: "ImmutableSrc.gguf")
        try Data("GGUF-AAAAAAA".utf8).write(to: model)
        let digest = try ModelRuntime.contentSHA256(forFileAt: model)
        let runtime = ModelRuntime(modelPath: model, expectedContentDigest: digest)
        let copy = try runtime.verifiedImmutableCopyURL()
        XCTAssertNotEqual(copy.path, model.path)
        try Data("GGUF-BBBBBBB".utf8).write(to: model)
        XCTAssertEqual(try Data(contentsOf: copy), Data("GGUF-AAAAAAA".utf8))
        XCTAssertEqual(try ModelRuntime.contentSHA256(forFileAt: copy), digest)
    }

    // Round 5 F4: replacing the previous entry never deletes an
    // externally registered model file.
    func testSnapshotRetirementPreservesExternallyOwnedFile() throws {
        let store = tempStoreURL()
        let external = try tempGGUF(named: "External.gguf")
        try Data("GGUF-external!".utf8).write(to: external)
        let model = try tempGGUF(named: "Owned.gguf")
        try Data("GGUF-owned-model".utf8).write(to: model)
        let registry = try VersionRegistry.production(storeURL: store, modelURL: model)
        try registry.register(VersionBundle(
            bundleID: VersionRegistry.previousKnownGoodBundleID,
            modelVersion: "external-m", promptVersion: "external-p",
            modelFilePath: external.path, promptTexts: ["External."]))
        try registry.registerActiveAsPreviousKnownGood()
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path),
                      "externally owned model must never be retired")
        let previous = try registry.registeredBundles.first {
            $0.bundleID == VersionRegistry.previousKnownGoodBundleID
        }!
        XCTAssertNotEqual(previous.modelFilePath, external.path)
    }

    // Round 5 F8: retained paths persist relative to the registry
    // directory and resolve in a restored (moved) container.
    func testRetainedPathStoredRelativeAndResolvesAfterContainerMove() throws {
        let store = tempStoreURL()
        let model = try tempGGUF(named: "Movable.gguf")
        try Data("GGUF-movable-model".utf8).write(to: model)
        let registry = try VersionRegistry.production(storeURL: store, modelURL: model)
        try registry.registerActiveAsPreviousKnownGood()
        let json = try String(decoding: Data(contentsOf: store), as: UTF8.self)
        XCTAssertFalse(json.contains(store.deletingLastPathComponent().path + "/previous-known-good-model-"),
                       "snapshot path must be stored relative, got: \(json)")
        XCTAssertTrue(json.contains("previous-known-good-model-"))
        // Simulate iOS restoring the data into a new container.
        let newDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let oldDir = store.deletingLastPathComponent()
        for name in try FileManager.default.contentsOfDirectory(atPath: oldDir.path) {
            try FileManager.default.copyItem(at: oldDir.appendingPathComponent(name),
                                             to: newDir.appendingPathComponent(name))
        }
        let restored = try VersionRegistry.production(
            storeURL: newDir.appendingPathComponent("version-registry.json"), modelURL: nil)
        try restored.rollbackToPreviousKnownGood()
        let artifacts = try restored.inferenceArtifacts(defaultModelURL: nil)
        XCTAssertEqual(artifacts.modelURL?.deletingLastPathComponent().path, newDir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifacts.modelURL!.path))
    }

    // Round 5 F9: a failing load validator blocks selection and
    // preserves the prior active bundle.
    func testCandidateLoadValidatorGatesSelection() throws {
        let registry = try makeRegistry()
        registry.candidateLoadValidator = { _ in
            throw ModelRuntimeError.modelLoadFailed("unloadable candidate")
        }
        XCTAssertThrowsError(try registry.rollbackToPreviousKnownGood())
        XCTAssertEqual(try registry.activeBundleID, "current")
        registry.candidateLoadValidator = { _ in }
        try registry.rollbackToPreviousKnownGood()
        XCTAssertEqual(try registry.activeBundleID, VersionRegistry.previousKnownGoodBundleID)
    }

    // Round 5 F10: artifacts and session stamp share one snapshot.
    func testInferenceSessionStampsFromSameSnapshot() throws {
        let currentModel = try tempGGUF(named: "SessionCurrent.gguf")
        let previousModel = try tempGGUF()
        let registry = try VersionRegistry(
            bundles: [
                VersionBundle(bundleID: "current", modelVersion: ModelRuntime.versionStamp,
                              promptVersion: SpikePrompts.version,
                              modelFilePath: currentModel.path, promptTexts: SpikePrompts.all),
                VersionBundle(bundleID: VersionRegistry.previousKnownGoodBundleID,
                              modelVersion: "previous-model-fixture",
                              promptVersion: "previous-prompt-fixture",
                              modelFilePath: previousModel.path,
                              promptTexts: ["Previous prompt alpha."]),
            ], activeBundleID: "current")
        try registry.rollbackToPreviousKnownGood()
        let session = try registry.inferenceSession(sessionId: "snap-1", defaultModelURL: nil)
        XCTAssertEqual(session.record.modelVersion, session.artifacts.modelVersion)
        XCTAssertEqual(session.record.promptVersion, session.artifacts.promptVersion)
        XCTAssertEqual(session.record.modelVersion, "previous-model-fixture")
        let fromArtifacts = try SessionRecord.start(sessionId: "snap-2", artifacts: session.artifacts)
        XCTAssertEqual(fromArtifacts.modelVersion, session.artifacts.modelVersion)
    }
}

extension VersioningTests {
    // Round 6 F1: child rollback policy follows the build config.
    func testChildRollbackControlsAreDebugOnly() {
        #if DEBUG
        XCTAssertTrue(RollbackControlPolicy.allowsChildAppRollbackControls)
        #else
        XCTAssertFalse(RollbackControlPolicy.allowsChildAppRollbackControls)
        #endif
    }

    // Round 6 F2: a bound digest reuses the verified cache entry
    // without recopied source bytes; a corrupt entry is republished.
    func testBoundDigestReusesVerifiedImmutableCache() throws {
        let model = try tempGGUF(named: "CacheHit.gguf")
        try Data("GGUF-cache-hit-A".utf8).write(to: model)
        let digest = try ModelRuntime.contentSHA256(forFileAt: model)
        let first = try ModelRuntime(modelPath: model, expectedContentDigest: digest)
            .verifiedImmutableCopyURL()
        // Replacing the source must not change the cached bytes a
        // digest-bound copy returns (load() still rejects this via
        // verifyBoundIdentityLocked; the copy lookup is cache-first).
        try Data("GGUF-cache-hit-B".utf8).write(to: model)
        let second = try ModelRuntime(modelPath: model, expectedContentDigest: digest)
            .verifiedImmutableCopyURL()
        XCTAssertEqual(second, first)
        XCTAssertEqual(try Data(contentsOf: second), Data("GGUF-cache-hit-A".utf8))
        // Corrupt the cache entry: it is verified, rejected, rebuilt.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: first.path)
        try Data("GGUF-corrupt!!!".utf8).write(to: first)
        try Data("GGUF-cache-hit-A".utf8).write(to: model)
        let rebuilt = try ModelRuntime(modelPath: model, expectedContentDigest: digest)
            .verifiedImmutableCopyURL()
        XCTAssertEqual(try Data(contentsOf: rebuilt), Data("GGUF-cache-hit-A".utf8))
        XCTAssertEqual(try ModelRuntime.contentSHA256(forFileAt: rebuilt), digest)
    }

    // Round 6 F3: concurrent publication of the same model — all
    // instances reuse the winning file, no temp copies remain.
    func testConcurrentImmutablePublicationReusesWinningFile() throws {
        let model = try tempGGUF(named: "Race.gguf")
        var bytes = Data("GGUF".utf8)
        bytes.append(Data(repeating: 0x41, count: 4_000_000))
        try bytes.write(to: model)
        let digest = try ModelRuntime.contentSHA256(forFileAt: model)
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var urls: [URL] = []; var errors: [Error] = []
        }
        let box = Box()
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            do {
                let url = try ModelRuntime(modelPath: model, expectedContentDigest: digest)
                    .verifiedImmutableCopyURL()
                box.lock.lock(); box.urls.append(url); box.lock.unlock()
            } catch {
                box.lock.lock(); box.errors.append(error); box.lock.unlock()
            }
        }
        XCTAssertTrue(box.errors.isEmpty, "race losers must reuse winner: \(box.errors)")
        XCTAssertEqual(box.urls.count, 4)
        XCTAssertEqual(Set(box.urls).count, 1)
        let dir = box.urls[0].deletingLastPathComponent()
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "temp copies must be removed: \(leftovers)")
    }

    // Round 6 F5: the active-register commit path runs the load
    // validator (selectLocked already did); failure preserves prior.
    func testCandidateLoadValidatorGatesActiveRegisterReplacement() throws {
        let registry = try makeRegistry()
        let candidateModel = try tempGGUF(named: "Candidate.gguf")
        registry.candidateLoadValidator = { _ in
            throw ModelRuntimeError.modelLoadFailed("unloadable candidate")
        }
        XCTAssertThrowsError(try registry.register(VersionBundle(
            bundleID: "current", modelVersion: "candidate-m", promptVersion: "candidate-p",
            modelFilePath: candidateModel.path, promptTexts: ["Candidate."])))
        XCTAssertEqual(try registry.activeBundle.modelVersion, ModelRuntime.versionStamp)
        XCTAssertEqual(try registry.activeBundleID, "current")
        registry.candidateLoadValidator = { _ in }
        try registry.register(VersionBundle(
            bundleID: "current", modelVersion: "candidate-m", promptVersion: "candidate-p",
            modelFilePath: candidateModel.path, promptTexts: ["Candidate."]))
        XCTAssertEqual(try registry.activeBundle.modelVersion, "candidate-m")
    }

    // Round 7 helper: snapshot A retained by a resolved session,
    // then snapshot B replaces it as previous-known-good, leaving
    // A pending retirement (retained, unreferenced, owned).
    private func makePendingRetirementScenario() throws -> (
        store: URL, registry: VersionRegistry, artifacts: InferenceArtifacts,
        firstPath: String, secondPath: String, model: URL
    ) {
        let store = tempStoreURL()
        let model = try tempGGUF(named: "Round7.gguf")
        try Data("GGUF-round7-A".utf8).write(to: model)
        let registry = try VersionRegistry.production(storeURL: store, modelURL: model)
        try registry.registerActiveAsPreviousKnownGood()
        let firstPath = try registry.registeredBundles.first {
            $0.bundleID == VersionRegistry.previousKnownGoodBundleID
        }!.modelFilePath!
        try registry.rollbackToPreviousKnownGood()
        let artifacts = try registry.inferenceArtifacts(defaultModelURL: nil)
        XCTAssertEqual(artifacts.modelURL?.path, firstPath)
        try registry.select(bundleID: "current")
        try Data("GGUF-round7-B".utf8).write(to: model)
        let second = try VersionRegistry.production(storeURL: store, modelURL: model)
        try second.registerActiveAsPreviousKnownGood()
        let secondPath = try second.registeredBundles.first {
            $0.bundleID == VersionRegistry.previousKnownGoodBundleID
        }!.modelFilePath!
        XCTAssertNotEqual(secondPath, firstPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPath))
        return (store, second, artifacts, firstPath, secondPath, model)
    }

    // Round 7 item 1: a failed registry reload during release
    // must not delete the snapshot or persist stale state.
    func testFailedReloadDuringReleaseLeavesSnapshotAndStoreUntouched() throws {
        let s = try makePendingRetirementScenario()
        let validStore = try Data(contentsOf: s.store)
        try Data("{{{ corrupt".utf8).write(to: s.store)
        s.registry.releaseInferenceArtifacts(s.artifacts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.firstPath),
                      "failed reload must leave the pending snapshot on disk")
        XCTAssertEqual(try Data(contentsOf: s.store), Data("{{{ corrupt".utf8),
                       "failed reload must not persist stale in-memory state")
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.secondPath))
        // A later successful reload retries the pending retirement.
        try validStore.write(to: s.store)
        _ = try s.registry.registeredBundles
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.firstPath),
                       "pending retirement must be retried on a later successful reload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.secondPath))
    }

    // Round 7 item 2: a pending retirement that survives process
    // termination is cleaned up on recovery; a snapshot still
    // referenced by the current previous bundle is never swept.
    func testInterruptedPendingRetirementIsCleanedUpOnRecovery() throws {
        let s = try makePendingRetirementScenario()
        VersionRegistry.simulateProcessTerminationForTesting()
        let recovered = try VersionRegistry.production(storeURL: s.store, modelURL: s.model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.firstPath),
                       "interrupted pending snapshot must be cleaned up on recovery")
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.secondPath),
                      "snapshot referenced by the current bundle must never be swept")
        _ = try recovered.registeredBundles.first {
            $0.bundleID == VersionRegistry.previousKnownGoodBundleID
        }!
    }

    // Round 7 item 3: retirement marking and artifact release
    // race — whichever order they interleave, no snapshot is
    // orphaned and the new snapshot stays on disk.
    func testRetirementMarkingRacingReleaseDoesNotOrphanSnapshot() throws {
        for _ in 0..<20 {
            let store = tempStoreURL()
            let model = try tempGGUF(named: "Round7Race.gguf")
            try Data("GGUF-race-A".utf8).write(to: model)
            let registry = try VersionRegistry.production(storeURL: store, modelURL: model)
            try registry.registerActiveAsPreviousKnownGood()
            let firstPath = try registry.registeredBundles.first {
                $0.bundleID == VersionRegistry.previousKnownGoodBundleID
            }!.modelFilePath!
            try registry.rollbackToPreviousKnownGood()
            let artifacts = try registry.inferenceArtifacts(defaultModelURL: nil)
            try registry.select(bundleID: "current")
            try Data("GGUF-race-B".utf8).write(to: model)
            let second = try VersionRegistry.production(storeURL: store, modelURL: model)
            final class ErrBox: @unchecked Sendable {
                let lock = NSLock(); var errors: [Error] = []
            }
            let box = ErrBox()
            DispatchQueue.concurrentPerform(iterations: 2) { idx in
                if idx == 0 {
                    do { try second.registerActiveAsPreviousKnownGood() }
                    catch { box.lock.lock(); box.errors.append(error); box.lock.unlock() }
                } else {
                    second.releaseInferenceArtifacts(artifacts)
                }
            }
            XCTAssertTrue(box.errors.isEmpty, "marking must not fail: \(box.errors)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath),
                           "raced retirement must not orphan the old snapshot")
            let secondPath = try second.registeredBundles.first {
                $0.bundleID == VersionRegistry.previousKnownGoodBundleID
            }!.modelFilePath!
            XCTAssertTrue(FileManager.default.fileExists(atPath: secondPath))
        }
    }

    // Round 8: initialization interrupted between construction
    // and restore must NOT lose ownership or pending-retirement
    // metadata. The restoring initializer installs the complete
    // decoded state in memory before its single atomic persist,
    // so stopping right after construction leaves the store with
    // full metadata and the pending snapshot still recoverable.
    // (Pre-fix, plain construction persisted empty sets — see
    // STEP27 probe: ownedSnapshotPaths=[] pendingRetirementPaths=[].)
    func testInterruptedRegistryInitPreservesOwnershipAndPendingMetadata() throws {
        let s = try makePendingRetirementScenario()
        let bundles = try s.registry.registeredBundles
        let active = try s.registry.activeBundleID
        let firstName = URL(fileURLWithPath: s.firstPath).lastPathComponent
        let secondName = URL(fileURLWithPath: s.secondPath).lastPathComponent
        VersionRegistry.simulateProcessTerminationForTesting()
        // Interrupted init: construct from the decoded state, then
        // stop — no sweep, no further restore step (the kill point).
        _ = try VersionRegistry(
            bundles: bundles, activeBundleID: active, storeURL: s.store,
            restoredOwnedSnapshotPaths: [s.firstPath, s.secondPath],
            restoredPendingRetirementPaths: [s.firstPath])
        let raw = try Data(contentsOf: s.store)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(Set(object["ownedSnapshotPaths"] as? [String] ?? []),
                       [firstName, secondName],
                       "interrupted init must keep ownership metadata")
        XCTAssertEqual(object["pendingRetirementPaths"] as? [String], [firstName],
                       "interrupted init must keep pending-retirement metadata")
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.firstPath),
                      "unreferenced retained snapshot must still be recoverable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.secondPath))
        // Recovery: the intact metadata drives cleanup of the
        // unreferenced snapshot; the referenced one is preserved.
        let recovered = try VersionRegistry.production(storeURL: s.store, modelURL: s.model)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.firstPath),
                       "recovered pending snapshot must be cleaned up")
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.secondPath),
                      "referenced snapshot must never be swept")
        let previous = try recovered.registeredBundles.first {
            $0.bundleID == VersionRegistry.previousKnownGoodBundleID
        }!
        XCTAssertEqual(URL(fileURLWithPath: previous.modelFilePath!).lastPathComponent, secondName)
    }

    // Round 6 F4: a snapshot handed to a resolved session is
    // retained when a new previous snapshot replaces it, and is
    // retired only when that session releases its artifacts.
    func testRetiredSnapshotRetainedUntilResolvedSessionReleases() throws {
        let store = tempStoreURL()
        let model = try tempGGUF(named: "Retained.gguf")
        try Data("GGUF-retained-A".utf8).write(to: model)
        let registry = try VersionRegistry.production(storeURL: store, modelURL: model)
        try registry.registerActiveAsPreviousKnownGood()
        let firstPath = try registry.registeredBundles.first {
            $0.bundleID == VersionRegistry.previousKnownGoodBundleID
        }!.modelFilePath!
        try registry.rollbackToPreviousKnownGood()
        let sessionArtifacts = try registry.inferenceArtifacts(defaultModelURL: nil)
        XCTAssertEqual(sessionArtifacts.modelURL?.path, firstPath)
        try registry.select(bundleID: "current")
        try Data("GGUF-retained-B".utf8).write(to: model)
        let second = try VersionRegistry.production(storeURL: store, modelURL: model)
        try second.registerActiveAsPreviousKnownGood()
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPath),
                      "resolved session's snapshot must be retained")
        second.releaseInferenceArtifacts(sessionArtifacts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPath),
                       "snapshot must retire after the session releases it")
    }
}

extension VersioningTests {
    // Fix round 2 F1 (issue #93): an unbound runtime (no digest, no
    // version — the chat tutor's `ModelRuntime(modelPath:)`) checks
    // the immutable cache BEFORE writing any temporary copy. With
    // the cache directory read-only, a cache hit still resolves (the
    // old path failed creating its ~770 MiB tmp).
    func testUnboundRuntimeChecksImmutableCacheBeforeCopying() throws {
        let model = try tempGGUF(named: "UnboundCacheFirst.gguf")
        try Data("GGUF-unbound-cache-first".utf8).write(to: model)
        let first = try ModelRuntime(modelPath: model).verifiedImmutableCopyURL()
        let dir = first.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let second = try ModelRuntime(modelPath: model).verifiedImmutableCopyURL()
        XCTAssertEqual(second, first)
        XCTAssertEqual(try Data(contentsOf: second), Data("GGUF-unbound-cache-first".utf8))
    }

    // Fix round 2 F1: a version-only binding also resolves its cache
    // hit with pure reads — no tmp copy before the lookup.
    func testVersionBoundRuntimeChecksImmutableCacheBeforeCopying() throws {
        let model = try tempGGUF(named: "VersionCacheFirst.gguf")
        try Data("GGUF-version-cache-first".utf8).write(to: model)
        let version = try ModelRuntime.verifiedModelVersion(forModelAt: model)
        let first = try ModelRuntime(modelPath: model, expectedModelVersion: version)
            .verifiedImmutableCopyURL()
        let dir = first.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let second = try ModelRuntime(modelPath: model, expectedModelVersion: version)
            .verifiedImmutableCopyURL()
        XCTAssertEqual(second, first)
        XCTAssertEqual(try Data(contentsOf: second), Data("GGUF-version-cache-first".utf8))
    }

    // Fix round 2 F1: a genuine miss still copies and publishes (the
    // early lookup must not become an early return of nothing).
    func testUnboundRuntimePublishesOnCacheMiss() throws {
        let model = try tempGGUF(named: "UnboundCacheMiss.gguf")
        try Data("GGUF-unbound-cache-miss-\(UUID().uuidString)".utf8).write(to: model)
        let copy = try ModelRuntime(modelPath: model).verifiedImmutableCopyURL()
        XCTAssertNotEqual(copy.path, model.path)
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: model))
        XCTAssertEqual(try ModelRuntime.contentSHA256(forFileAt: copy),
                       try ModelRuntime.contentSHA256(forFileAt: model))
    }

    // Fix round 2 F1: a version mismatch fails on the binding BEFORE
    // any copy — under a read-only cache dir the old code failed
    // with `.modelLoadFailed` (tmp creation) instead.
    func testVersionBoundRuntimeRejectsMismatchBeforeCopying() throws {
        let model = try tempGGUF(named: "VersionMismatchNoCopy.gguf")
        try Data("GGUF-version-mismatch-nocopy".utf8).write(to: model)
        let dir = try ModelRuntime(modelPath: model).verifiedImmutableCopyURL()
            .deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        XCTAssertThrowsError(try ModelRuntime(modelPath: model, expectedModelVersion: "bogus-version")
            .verifiedImmutableCopyURL()) { error in
            XCTAssertEqual(error as? ModelRuntimeError, .modelContentMismatch(path: model.path))
        }
    }

    // Fix round 2 F1: the unbound early lookup verifies its hit — a
    // corrupt entry is removed and rebuilt from the source.
    func testUnboundRuntimeRebuildsCorruptCacheEntry() throws {
        let model = try tempGGUF(named: "UnboundCorruptEntry.gguf")
        try Data("GGUF-unbound-corrupt-A".utf8).write(to: model)
        let first = try ModelRuntime(modelPath: model).verifiedImmutableCopyURL()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: first.path)
        try Data("GGUF-unbound-corrupt!!!".utf8).write(to: first)
        let rebuilt = try ModelRuntime(modelPath: model).verifiedImmutableCopyURL()
        XCTAssertEqual(rebuilt, first)
        XCTAssertEqual(try Data(contentsOf: rebuilt), Data("GGUF-unbound-corrupt-A".utf8))
    }

    // Fix round 3 F1 (issue #93): a digest-bound warm hit is a pure
    // name check — the source is never hashed (replaced source bytes
    // under the same valid magic still hit) and no temp copy is
    // created (the lookup succeeds with the cache dir read-only,
    // where any tmp creation would fail). The tutor factory relies
    // on this by binding the registry/download digest.
    func testBoundDigestHitSkipsSourceHashAndTempCopy() throws {
        let model = try tempGGUF(named: "BoundHitNoHash.gguf")
        try Data("GGUF-bound-hit-original".utf8).write(to: model)
        let digest = try ModelRuntime.contentSHA256(forFileAt: model)
        let first = try ModelRuntime(modelPath: model, expectedContentDigest: digest)
            .verifiedImmutableCopyURL()
        // Replace the source with different, longer bytes under valid
        // magic: a hash-first lookup would derive a new name and miss.
        try Data("GGUF-bound-hit-REPLACED-longer".utf8).write(to: model)
        let dir = first.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let second = try ModelRuntime(modelPath: model, expectedContentDigest: digest)
            .verifiedImmutableCopyURL()
        XCTAssertEqual(second, first)
        XCTAssertEqual(try Data(contentsOf: second), Data("GGUF-bound-hit-original".utf8))
    }
}
