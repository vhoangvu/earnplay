import XCTest
@testable import EarnPlayCore

/// T5.3: every session record carries the active model + prompt version,
/// and selecting a rollback bundle changes what new sessions stamp.
/// The production bundle must derive from the real runtime/prompt
/// constants — never from hard-coded copies of those strings.
final class VersioningTests: XCTestCase {

    private func makeRegistry() throws -> VersionRegistry {
        try VersionRegistry(
            bundles: [
                VersionBundle(
                    bundleID: "current",
                    modelVersion: ModelRuntime.versionStamp,
                    promptVersion: SpikePrompts.version
                ),
                VersionBundle(
                    bundleID: VersionRegistry.previousKnownGoodBundleID,
                    modelVersion: "previous-model-fixture",
                    promptVersion: "previous-prompt-fixture"
                ),
            ],
            activeBundleID: "current"
        )
    }

    func testProductionBundleDerivesFromRuntimeAndPromptConstants() throws {
        let registry = try VersionRegistry.production()
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
        let registry = try VersionRegistry.production()
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
