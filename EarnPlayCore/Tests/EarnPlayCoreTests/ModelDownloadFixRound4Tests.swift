import CryptoKit
import XCTest
@testable import EarnPlayCore

/// Fix round 4 regression tests (issue #53): avoid repeated full-file
/// hashing during model readiness checks. On a normal launch with the
/// downloaded model selected, `isReady()` hashed the ~800 MB file three
/// times (registry production + inferenceArtifacts digest + the fix-3
/// pinned check) while the UI showed "Checking for model…". The fix
/// fast-paths an intact download with ONE pinned size+SHA verification
/// and keeps registry resolution as the fallback.
///
/// Test design (no timing flakes, no production hooks): constructing a
/// `VersionRegistry` always persists the store file (`persistLocked`
/// creates parent directories and atomically writes the state), so a
/// missing store file after `isReady()` proves the registry — and its
/// two full-file hashes — never ran, leaving the single pinned
/// verification as the only hash. Conversely, a newly created store
/// file proves the fallback ran.
final class ModelDownloadFixRound4Tests: XCTestCase {
    private var tempRoots: [URL] = []

    override func tearDown() {
        for root in tempRoots {
            try? FileManager.default.removeItem(at: root)
        }
        tempRoots = []
        super.tearDown()
    }

    private func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloadFixRound4Tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    private func stubbedFileManager(root: URL) -> StubFileManager {
        StubFileManager(
            appSupport: root.appendingPathComponent("appSupport", isDirectory: true),
            documents: root.appendingPathComponent("docs", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true))
    }

    private func writeFile(at url: URL, data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func testConfiguration(payload: Data, maxAttempts: Int = 1) -> ModelDownloadConfiguration {
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return ModelDownloadConfiguration(
            sourceURL: URL(string: "https://example.com/model.gguf")!,
            expectedByteCount: Int64(payload.count),
            expectedSHA256: digest,
            maxAttempts: maxAttempts
        )
    }

    /// An intact pinned file AT the destination resolves ready through
    /// the fast path: one pinned size+SHA verification, registry never
    /// constructed (the store file stays absent, proving its two
    /// full-file hashes never ran). Pre-fix this consults the registry
    /// (creating the store) and hashes the file three times.
    func testIntactDestinationResolvesReadyWithoutTouchingRegistry() throws {
        let root = makeTempRoot()
        let fileManager = stubbedFileManager(root: root)
        let destination = ModelDownloader.defaultDestinationURL(fileManager: fileManager)
        let good = Data("GGUF-good-model-bytes!!".utf8)
        try writeFile(at: destination, data: good)

        let store = root.appendingPathComponent("registry")
            .appendingPathComponent("version-registry.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path),
            "precondition: the registry store must start out absent")

        let readiness = ModelDownloadReadiness(
            configuration: testConfiguration(payload: good),
            destinationURL: destination,
            registryStoreURL: store)
        XCTAssertTrue(readiness.isReady(environment: [:], fileManager: fileManager),
            "an intact pinned destination file must stay ready")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path),
            "fast path must resolve readiness with one pinned verification and never construct the registry (which persists the store and hashes the file twice more)")
    }

    /// A corrupt destination must fall through to the registry fallback
    /// — never silently ready (fix 3 preserved), and never an early
    /// return that skips the fallback: the store file proves the
    /// registry was consulted so a retained snapshot could repair.
    func testCorruptDestinationFallsThroughToRegistryFallback() throws {
        let root = makeTempRoot()
        let fileManager = stubbedFileManager(root: root)
        let destination = ModelDownloader.defaultDestinationURL(fileManager: fileManager)
        let good = Data("GGUF-good-model-bytes!!".utf8)
        var bad = good
        bad[bad.count - 1] ^= 0xFF
        bad[bad.count - 2] ^= 0xFF
        XCTAssertEqual(bad.prefix(4), Data([0x47, 0x47, 0x55, 0x46]))
        try writeFile(at: destination, data: bad)

        let store = root.appendingPathComponent("registry")
            .appendingPathComponent("version-registry.json")

        let readiness = ModelDownloadReadiness(
            configuration: testConfiguration(payload: good),
            destinationURL: destination,
            registryStoreURL: store)
        XCTAssertFalse(readiness.isReady(environment: [:], fileManager: fileManager),
            "a corrupt destination must never count as ready, even with a valid GGUF header")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path),
            "a corrupt destination must fall through to the registry fallback (which persists the store), not short-circuit")
    }

    /// A missing download with a retained snapshot at a different path
    /// stays ready via the registry fallback — the fast path only
    /// applies when the default lookup selects the destination.
    func testMissingDestinationWithRetainedSnapshotStaysReadyViaRegistry() throws {
        let root = makeTempRoot()
        let fileManager = stubbedFileManager(root: root)
        let destination = ModelDownloader.defaultDestinationURL(fileManager: fileManager)
        let good = Data("GGUF-good-model-bytes!!".utf8)
        // No file at the destination: the download is missing entirely.

        let snapshot = root.appendingPathComponent("previous-known-good-model-fixture.gguf")
        try Data("GGUF-retained-snapshot".utf8).write(to: snapshot)
        let digest = try ModelRuntime.contentSHA256(forFileAt: snapshot)
        let store = root.appendingPathComponent("registry").appendingPathComponent("version-registry.json")
        _ = try VersionRegistry(
            bundles: [
                VersionBundle(bundleID: "current", modelVersion: "current-model-fixture",
                              promptVersion: SpikePrompts.version),
                VersionBundle(bundleID: VersionRegistry.previousKnownGoodBundleID,
                              modelVersion: "previous-model-fixture",
                              promptVersion: SpikePrompts.version,
                              modelFilePath: snapshot.path,
                              promptTexts: ["Retained prompt alpha."],
                              modelContentDigest: digest),
            ],
            activeBundleID: VersionRegistry.previousKnownGoodBundleID,
            storeURL: store)

        let readiness = ModelDownloadReadiness(
            configuration: testConfiguration(payload: good),
            destinationURL: destination,
            registryStoreURL: store)
        XCTAssertTrue(readiness.isReady(environment: [:], fileManager: fileManager),
            "a retained snapshot at a different path must keep the gate ready when the download is missing")
    }
}
