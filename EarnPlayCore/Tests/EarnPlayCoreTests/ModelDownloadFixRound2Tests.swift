import CryptoKit
import XCTest
@testable import EarnPlayCore

/// Fix round 2 regression tests (issue #53): each test pins one
/// review finding. Written failing-first against the run-1 behavior;
/// the fixes make them pass. All hermetic — no network is touched
/// (the finding-5 probe targets an unroutable loopback port).
final class ModelDownloadFixRound2Tests: XCTestCase {
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
            .appendingPathComponent("ModelDownloadFixRound2Tests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Finding 2: retained snapshot bypasses redundant download

    /// Default/current file gone but a retained previous-known-good
    /// snapshot validates: the gate must pass without a download.
    func testRetainedSnapshotSatisfiesGateWhenDefaultFileIsMissing() throws {
        let root = makeTempRoot()
        let fileManager = stubbedFileManager(root: root)
        XCTAssertNil(ModelRuntime.defaultModelURL(environment: [:], fileManager: fileManager),
            "setup: no default file, so the old existence-only gate would block here")

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
            configuration: testConfiguration(payload: Data("GGUF-unused".utf8)),
            destinationURL: ModelDownloader.defaultDestinationURL(fileManager: fileManager),
            registryStoreURL: store)
        XCTAssertTrue(readiness.isReady(environment: [:], fileManager: fileManager),
            "a retained active snapshot must satisfy the gate without another ~800 MB download")
    }

    /// Nothing anywhere (no default file, no retained snapshot) still
    /// requires a download — the finding-2 fix must not invent models.
    func testMissingDefaultWithNoSnapshotStillNeedsDownload() throws {
        let root = makeTempRoot()
        let fileManager = stubbedFileManager(root: root)
        let readiness = ModelDownloadReadiness(
            configuration: testConfiguration(payload: Data("GGUF-unused".utf8)),
            destinationURL: ModelDownloader.defaultDestinationURL(fileManager: fileManager),
            registryStoreURL: root.appendingPathComponent("registry")
                .appendingPathComponent("version-registry.json"))
        XCTAssertFalse(readiness.isReady(environment: [:], fileManager: fileManager))
    }

    // MARK: - Finding 3: verify size and SHA before ready

    /// A wrong-size file at the download destination must not count
    /// as ready — it routes back through the downloader.
    func testCorruptDownloadDestinationDoesNotCountAsReady() throws {
        let root = makeTempRoot()
        let fileManager = stubbedFileManager(root: root)
        let destination = ModelDownloader.defaultDestinationURL(fileManager: fileManager)
        try writeFile(at: destination, data: Data("corrupt-bytes".utf8))
        XCTAssertEqual(ModelRuntime.defaultModelURL(environment: [:], fileManager: fileManager),
                       destination, "setup: a file exists at the destination")

        let readiness = ModelDownloadReadiness(
            configuration: testConfiguration(payload: Data("GGUF-good-model-bytes!!".utf8)),
            destinationURL: destination,
            registryStoreURL: root.appendingPathComponent("registry")
                .appendingPathComponent("version-registry.json"))
        XCTAssertFalse(readiness.isReady(environment: [:], fileManager: fileManager),
            "a corrupt download-destination file must show download/retry, not ready")
    }

    /// Same size but wrong bytes: the SHA check (not just the size
    /// check) must reject the file.
    func testWrongBytesAtDestinationFailEvenAtExpectedSize() throws {
        let root = makeTempRoot()
        let fileManager = stubbedFileManager(root: root)
        let destination = ModelDownloader.defaultDestinationURL(fileManager: fileManager)
        let good = Data("GGUF-good-model-bytes!!".utf8)
        try writeFile(at: destination, data: Data("XXXX-good-model-bytes!!".utf8))
        XCTAssertEqual(Int64("XXXX-good-model-bytes!!".utf8.count), Int64(good.count))

        let readiness = ModelDownloadReadiness(
            configuration: testConfiguration(payload: good),
            destinationURL: destination,
            registryStoreURL: root.appendingPathComponent("registry")
                .appendingPathComponent("version-registry.json"))
        XCTAssertFalse(readiness.isReady(environment: [:], fileManager: fileManager),
            "wrong bytes at the expected size must fail SHA verification")
    }

    /// A size- and SHA-verified file at the destination counts as ready.
    func testVerifiedDownloadDestinationCountsAsReady() throws {
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
        XCTAssertTrue(readiness.isReady(environment: [:], fileManager: fileManager))
    }

    /// Legacy overrides (env/Documents/script-cache) still count by
    /// existence — no re-verification of demo/local paths.
    func testLegacyOverrideCountsAsReadyWithoutReverification() throws {
        let root = makeTempRoot()
        let fileManager = stubbedFileManager(root: root)
        let legacy = root.appendingPathComponent("legacy.gguf")
        try Data("not-a-gguf-stub".utf8).write(to: legacy)

        let readiness = ModelDownloadReadiness(
            configuration: testConfiguration(payload: Data("GGUF-unused".utf8)),
            destinationURL: ModelDownloader.defaultDestinationURL(fileManager: fileManager),
            registryStoreURL: root.appendingPathComponent("registry")
                .appendingPathComponent("version-registry.json"))
        XCTAssertTrue(
            readiness.isReady(environment: ["EARNPLAY_MODEL_PATH": legacy.path], fileManager: fileManager),
            "legacy override paths must stay ready-by-existence")
    }

    // MARK: - Finding 4: stale progress must not revert terminal state

    func testLateProgressAfterReadyIsIgnored() {
        XCTAssertEqual(ModelDownloadPhase.ready.applyingProgress(0.5), .ready,
            "a queued progress update must not revert .ready to downloading")
    }

    func testLateProgressAfterFailureIsIgnored() {
        XCTAssertEqual(ModelDownloadPhase.failed(message: "wifi dropped").applyingProgress(0.9),
                       .failed(message: "wifi dropped"),
            "a queued progress update must not hide Retry by reverting .failed")
    }

    func testLateProgressAfterNeedsDownloadIsIgnored() {
        XCTAssertEqual(ModelDownloadPhase.needsDownload.applyingProgress(0.5), .needsDownload)
    }

    func testProgressWhileDownloadingUpdates() {
        XCTAssertEqual(ModelDownloadPhase.downloading(progress: 0.1).applyingProgress(0.5),
                       .downloading(progress: 0.5))
    }

    // MARK: - Finding 5: cancel-before-begin starts no download

    /// Cancellation recorded before `begin()` assigns the task must
    /// fail the continuation as cancelled without starting a fetch.
    /// The URL is unroutable loopback, so even the pre-fix code path
    /// cannot touch the network beyond a refused connection.
    func testCancelBeforeBeginStartsNoDownloadAndFailsCancelled() async {
        let delegate = ModelDownloadTaskDelegate(progress: { _ in })
        delegate.cancel()
        XCTAssertFalse(delegate.didStartTask)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                delegate.begin(session: session,
                               url: URL(string: "https://127.0.0.1:1/model.gguf")!,
                               continuation: continuation)
            }
            XCTFail("cancel-before-begin must fail the continuation, not deliver a file")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(delegate.didStartTask,
            "no download task may start after cancellation was recorded")
    }

    // MARK: - Finding 1: shipped Llama notices and attribution

    func testBuiltWithLlamaLabel() {
        XCTAssertEqual(ModelAttribution.builtWithLlamaLabel, "Built with Llama")
    }

    /// Section 1.b.i(A): a copy of the Agreement ships with the app.
    func testBundledLicenseCopyShipsAndNamesAgreement() {
        XCTAssertNotNil(ModelAttribution.bundledLicenseURL(),
            "the Llama 3.2 license copy must ship in the bundle")
        let text = ModelAttribution.bundledLicenseText()
        XCTAssertNotNil(text, "the license must be readable offline from the bundle")
        XCTAssertTrue(text?.contains("LLAMA 3.2 COMMUNITY LICENSE AGREEMENT") == true)
        XCTAssertTrue(text?.contains("Built with Llama") == true)
    }

    /// Section 1.b.iii: the Notice file carries the exact sentence.
    func testBundledNoticeCarriesRequiredSentence() {
        XCTAssertNotNil(ModelAttribution.bundledNoticeURL(),
            "the Notice file must ship in the bundle")
        let text = ModelAttribution.bundledNoticeText()
        XCTAssertNotNil(text, "the Notice must be readable offline from the bundle")
        XCTAssertTrue(text?.contains(ModelAttribution.noticeAttributionSentence) == true,
            "the Notice must carry the exact 1.b.iii attribution sentence")
    }
}
