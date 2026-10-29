import CryptoKit
import XCTest
@testable import EarnPlayCore

/// Fix round 3 regression tests (issue #53): pinned artifact integrity
/// at the download destination. Step 1 of `isReady()` resolves through
/// the active registry, whose digest is computed FROM the current bytes —
/// so a modified/truncated destination file that retains a valid GGUF
/// header self-validates and short-circuits the size+SHA check. The fix
/// requires configured verification when the resolved artifact sits AT
/// the destination, while preserving the bypass for separate retained
/// snapshots and legacy locations.
final class ModelDownloadFixRound3Tests: XCTestCase {
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
            .appendingPathComponent("ModelDownloadFixRound3Tests-\(UUID().uuidString)", isDirectory: true)
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

    /// Corrupted destination (same size, wrong bytes) that retains a
    /// valid GGUF header must NOT count as ready — it must route back
    /// through the downloader for discard + re-fetch. Pre-fix this
    /// self-validates through the registry and wrongly returns true.
    func testCorruptedDestinationWithValidGGUFHeaderDoesNotCountAsReady() throws {
        let root = makeTempRoot()
        let fileManager = stubbedFileManager(root: root)
        let destination = ModelDownloader.defaultDestinationURL(fileManager: fileManager)
        let good = Data("GGUF-good-model-bytes!!".utf8)
        var bad = good
        // Flip the trailing bytes: same size, GGUF magic preserved,
        // SHA no longer matches the pinned digest.
        bad[bad.count - 1] ^= 0xFF
        bad[bad.count - 2] ^= 0xFF
        XCTAssertEqual(bad.count, good.count)
        XCTAssertEqual(bad.prefix(4), Data([0x47, 0x47, 0x55, 0x46]))
        try writeFile(at: destination, data: bad)

        let readiness = ModelDownloadReadiness(
            configuration: testConfiguration(payload: good),
            destinationURL: destination,
            registryStoreURL: root.appendingPathComponent("registry")
                .appendingPathComponent("version-registry.json"))
        XCTAssertFalse(readiness.isReady(environment: [:], fileManager: fileManager),
            "a corrupted destination with a valid GGUF header must fail pinned verification, not self-validate")
    }

    /// Truncated destination (fewer bytes) that retains a valid GGUF
    /// header must NOT count as ready either.
    func testTruncatedDestinationWithValidGGUFHeaderDoesNotCountAsReady() throws {
        let root = makeTempRoot()
        let fileManager = stubbedFileManager(root: root)
        let destination = ModelDownloader.defaultDestinationURL(fileManager: fileManager)
        let good = Data("GGUF-good-model-bytes!!".utf8)
        let truncated = good.prefix(good.count - 5)
        XCTAssertEqual(truncated.prefix(4), Data([0x47, 0x47, 0x55, 0x46]))
        try writeFile(at: destination, data: Data(truncated))

        let readiness = ModelDownloadReadiness(
            configuration: testConfiguration(payload: good),
            destinationURL: destination,
            registryStoreURL: root.appendingPathComponent("registry")
                .appendingPathComponent("version-registry.json"))
        XCTAssertFalse(readiness.isReady(environment: [:], fileManager: fileManager),
            "a truncated destination with a valid GGUF header must fail pinned verification")
    }

    /// An intact pinned file AT the destination still counts as ready
    /// (verified through the configured size+SHA, not just the header).
    func testIntactPinnedDestinationCountsAsReady() throws {
        let root = makeTempRoot()
        let fileManager = stubbedFileManager(root: root)
        let destination = ModelDownloader.defaultDestinationURL(fileManager: fileManager)
        let good = Data("GGUF-good-model-bytes!!".utf8)
        try writeFile(at: destination, data: good)

        let readiness = ModelDownloadReadiness(
            configuration: testConfiguration(payload: good),
            destinationURL: destination,
            registryStoreURL: root.appendingPathComponent("registry")
                .appendingPathComponent("version-registry.json"))
        XCTAssertTrue(readiness.isReady(environment: [:], fileManager: fileManager),
            "an intact pinned destination file must stay ready")
    }

    /// A retained snapshot at a DIFFERENT path still bypasses
    /// re-verification — even when the destination holds a corrupted
    /// GGUF file. The destination check applies only when the resolved
    /// artifact sits AT the destination.
    func testRetainedSnapshotAtDifferentPathBypassesDestinationVerification() throws {
        let root = makeTempRoot()
        let fileManager = stubbedFileManager(root: root)
        let destination = ModelDownloader.defaultDestinationURL(fileManager: fileManager)
        let good = Data("GGUF-good-model-bytes!!".utf8)
        var bad = good
        bad[bad.count - 1] ^= 0xFF
        try writeFile(at: destination, data: bad)

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
            "a retained snapshot at a different path must bypass destination re-verification")
    }
}
