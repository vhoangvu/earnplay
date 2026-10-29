import CryptoKit
import XCTest
@testable import EarnPlayCore

/// Scripted fetcher: no network. Repeats its last scripted result when
/// the downloader attempts more fetches than the script lists.
final class MockModelDownloadFetcher: ModelDownloadFetching, @unchecked Sendable {
    enum ScriptResult {
        case file(Data)
        case failure(ModelDownloadError)
    }

    private let script: [ScriptResult]
    private(set) var callCount = 0
    private(set) var requestedURLs: [URL] = []

    init(script: [ScriptResult]) {
        self.script = script
    }

    init(alwaysFile data: Data) {
        self.script = [.file(data)]
    }

    init(alwaysFailure error: ModelDownloadError) {
        self.script = [.failure(error)]
    }

    func fetch(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        callCount += 1
        requestedURLs.append(url)
        let result = script[min(callCount - 1, script.count - 1)]
        switch result {
        case .failure(let error):
            throw error
        case .file(let data):
            progress(0.0)
            progress(0.5)
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent("mock-download-\(UUID().uuidString).gguf")
            try data.write(to: staged)
            progress(1.0)
            return staged
        }
    }
}

/// Thread-safe progress recorder for `@Sendable` progress closures.
final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

/// FileManager with stubbed standard directories under a temp root, so
/// lookup-order tests never touch the real Application Support.
final class StubFileManager: FileManager {
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

final class ModelDownloadTests: XCTestCase {
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
            .appendingPathComponent("ModelDownloadTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempRoots.append(root)
        return root
    }

    private func testConfiguration(payload: Data, maxAttempts: Int = 3) -> ModelDownloadConfiguration {
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return ModelDownloadConfiguration(
            sourceURL: URL(string: "https://example.com/model.gguf")!,
            expectedByteCount: Int64(payload.count),
            expectedSHA256: digest,
            maxAttempts: maxAttempts
        )
    }

    // MARK: - Production constants

    /// The downloader must fetch the same file the setup script fetches.
    func testProductionConfigurationMatchesSetupScript() {
        let production = ModelDownloadConfiguration.production
        XCTAssertEqual(production.sourceURL.absoluteString,
            "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")
        XCTAssertEqual(production.expectedByteCount, 807_694_464)
        XCTAssertEqual(production.expectedSHA256,
            "6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83")
        XCTAssertGreaterThanOrEqual(production.maxAttempts, 2, "must retry failed downloads")
    }

    // MARK: - License attribution

    /// The About screen renders this text; pin the license name so it
    /// cannot be silently dropped.
    func testAttributionNamesCommunityLicense() {
        XCTAssertTrue(ModelAttribution.llamaCommunityLicenseText.contains("Llama 3.2 Community License"))
        XCTAssertTrue(ModelAttribution.llamaCommunityLicenseText.contains("Llama-3.2-1B-Instruct-GGUF"))
    }

    // MARK: - Wi-Fi only

    func testDownloadSessionIsWifiOnly() {
        XCTAssertFalse(URLSessionModelDownloadFetcher.wifiOnlyConfiguration().allowsCellularAccess,
            "the ~800 MB model must never download over cellular")
    }

    // MARK: - Caches-purge safety

    func testDefaultDestinationIsApplicationSupportNotCaches() {
        let fileManager = FileManager.default
        let destination = ModelDownloader.defaultDestinationURL(fileManager: fileManager)
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        XCTAssertTrue(destination.path.hasPrefix(appSupport.path),
            "model must live in Application Support, got \(destination.path)")
        XCTAssertFalse(destination.path.hasPrefix(caches.path),
            "model must survive a Caches purge, got \(destination.path)")
        XCTAssertEqual(destination.lastPathComponent, "EarnPlayModel.gguf")
    }

    // MARK: - Success path

    func testDownloadSuccessWritesVerifiedFile() async throws {
        let payload = Data((0..<1024).map { UInt8($0 & 0xff) })
        let destination = makeTempRoot().appendingPathComponent("EarnPlayModel.gguf")
        let fetcher = MockModelDownloadFetcher(alwaysFile: payload)
        let recorder = ProgressRecorder()
        let downloader = ModelDownloader(configuration: testConfiguration(payload: payload),
                                          destinationURL: destination,
                                          fetcher: fetcher)
        let installed = try await downloader.download { recorder.record($0) }
        XCTAssertEqual(installed, destination)
        XCTAssertEqual(fetcher.callCount, 1)
        XCTAssertEqual(fetcher.requestedURLs, [downloader.configuration.sourceURL])
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(recorderValue(recorder: recorder), 1.0, "progress must reach 1.0")
    }

    private func recorderValue(recorder: ProgressRecorder) -> Double {
        recorder.values.last ?? -1
    }

    // MARK: - Checksum mismatch

    func testChecksumMismatchDiscardsRetriesAndNeverInstalls() async {
        let goodPayload = Data("verified model bytes".utf8)
        // Same length as the good payload, so the size check passes and
        // the SHA-256 check is what rejects this file.
        let corruptPayload = Data("corrupted model bytz".utf8)
        let destination = makeTempRoot().appendingPathComponent("EarnPlayModel.gguf")
        let fetcher = MockModelDownloadFetcher(alwaysFile: corruptPayload)
        let downloader = ModelDownloader(configuration: testConfiguration(payload: goodPayload),
                                          destinationURL: destination,
                                          fetcher: fetcher)
        do {
            _ = try await downloader.download()
            XCTFail("corrupt download must throw")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .checksumMismatch)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(fetcher.callCount, 3, "mismatch must be retried, not accepted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
            "corrupt download must be discarded")
        // Nothing unverified is left behind for any loader to pick up.
        XCTAssertThrowsError(try ModelRuntime.verifiedModelVersion(forModelAt: destination)) { error in
            XCTAssertEqual(error as? ModelRuntimeError, .modelNotFound(path: destination.path))
        }
    }

    func testByteCountMismatchDiscardsDownload() async {
        let payload = Data("tiny".utf8)
        var configuration = testConfiguration(payload: payload)
        configuration = ModelDownloadConfiguration(
            sourceURL: configuration.sourceURL,
            expectedByteCount: Int64(payload.count) + 1,
            expectedSHA256: configuration.expectedSHA256,
            maxAttempts: 1)
        let destination = makeTempRoot().appendingPathComponent("EarnPlayModel.gguf")
        let downloader = ModelDownloader(configuration: configuration,
                                          destinationURL: destination,
                                          fetcher: MockModelDownloadFetcher(alwaysFile: payload))
        do {
            _ = try await downloader.download()
            XCTFail("short download must throw")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .byteCountMismatch(expected: Int64(payload.count) + 1,
                                                     actual: Int64(payload.count)))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Retry path

    func testRetryAfterFailedDownloadsThenSucceeds() async throws {
        let payload = Data("model after two failures".utf8)
        let destination = makeTempRoot().appendingPathComponent("EarnPlayModel.gguf")
        let fetcher = MockModelDownloadFetcher(script: [
            .failure(.networkFailure("wifi dropped")),
            .failure(.httpStatus(503)),
            .file(payload),
        ])
        let downloader = ModelDownloader(configuration: testConfiguration(payload: payload),
                                          destinationURL: destination,
                                          fetcher: fetcher)
        let installed = try await downloader.download()
        XCTAssertEqual(installed, destination)
        XCTAssertEqual(fetcher.callCount, 3)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    func testExhaustedRetriesThrowLastError() async {
        let payload = Data("never delivered".utf8)
        let destination = makeTempRoot().appendingPathComponent("EarnPlayModel.gguf")
        let fetcher = MockModelDownloadFetcher(alwaysFailure: .networkFailure("offline"))
        let downloader = ModelDownloader(configuration: testConfiguration(payload: payload, maxAttempts: 2),
                                          destinationURL: destination,
                                          fetcher: fetcher)
        do {
            _ = try await downloader.download()
            XCTFail("exhausted retries must throw")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .networkFailure("offline"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(fetcher.callCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Offline after download

    func testOfflineAfterDownloadLoadsFromDiskWithNoNetwork() async throws {
        let payload = Data("downloaded once, offline after".utf8)
        let destination = makeTempRoot().appendingPathComponent("EarnPlayModel.gguf")
        let configuration = testConfiguration(payload: payload)
        let first = ModelDownloader(configuration: configuration,
                                     destinationURL: destination,
                                     fetcher: MockModelDownloadFetcher(alwaysFile: payload))
        _ = try await first.download()

        let offlineFetcher = MockModelDownloadFetcher(
            alwaysFailure: .networkFailure("must not be called"))
        let second = ModelDownloader(configuration: configuration,
                                      destinationURL: destination,
                                      fetcher: offlineFetcher)
        let resolved = try await second.downloadIfNeeded()
        XCTAssertEqual(resolved, destination)
        XCTAssertEqual(offlineFetcher.callCount, 0, "verified file must load with no network")
        XCTAssertEqual(try Data(contentsOf: resolved), payload)
    }

    func testCorruptExistingFileIsDiscardedAndRedownloaded() async throws {
        let payload = Data("fresh verified bytes".utf8)
        let destination = makeTempRoot().appendingPathComponent("EarnPlayModel.gguf")
        try Data("stale corrupt bytes!!".utf8).write(to: destination)
        let fetcher = MockModelDownloadFetcher(alwaysFile: payload)
        let downloader = ModelDownloader(configuration: testConfiguration(payload: payload),
                                          destinationURL: destination,
                                          fetcher: fetcher)
        let resolved = try await downloader.downloadIfNeeded()
        XCTAssertEqual(resolved, destination)
        XCTAssertEqual(fetcher.callCount, 1, "corrupt file must trigger a re-download")
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    // MARK: - ModelRuntime lookup order

    private func stubbedFileManager() -> (StubFileManager, URL) {
        let root = makeTempRoot()
        let fileManager = StubFileManager(
            appSupport: root.appendingPathComponent("appSupport", isDirectory: true),
            documents: root.appendingPathComponent("docs", isDirectory: true),
            caches: root.appendingPathComponent("caches", isDirectory: true))
        return (fileManager, root)
    }

    private func writeStubFile(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("stub".utf8).write(to: url)
    }

    func testLookupFindsApplicationSupportDownload() throws {
        let (fileManager, _) = stubbedFileManager()
        XCTAssertNil(ModelRuntime.defaultModelURL(environment: [:], fileManager: fileManager))
        let downloaded = ModelDownloader.defaultDestinationURL(fileManager: fileManager)
        try writeStubFile(at: downloaded)
        XCTAssertEqual(ModelRuntime.defaultModelURL(environment: [:], fileManager: fileManager),
                       downloaded)
    }

    /// Full cascade: env override first, then the Application Support
    /// download, then the legacy Documents staging, then the setup-script
    /// cache. The pre-existing relative order is unchanged.
    func testLookupOrderAcrossAllLocations() throws {
        let (fileManager, root) = stubbedFileManager()
        let downloaded = ModelDownloader.defaultDestinationURL(fileManager: fileManager)
        let documents = fileManager.documentsDir.appendingPathComponent("EarnPlayModel.gguf")
        let scriptCache = fileManager.cachesDir
            .appendingPathComponent("EarnPlay/models/Llama-3.2-1B-Instruct-Q4_K_M.gguf")
        let envOverride = root.appendingPathComponent("override.gguf").path

        try writeStubFile(at: downloaded)
        try writeStubFile(at: documents)
        try writeStubFile(at: scriptCache)

        // Env override wins over every file location.
        XCTAssertEqual(
            ModelRuntime.defaultModelURL(environment: ["EARNPLAY_MODEL_PATH": envOverride],
                                          fileManager: fileManager),
            URL(fileURLWithPath: envOverride))
        // Then the Application Support download.
        XCTAssertEqual(ModelRuntime.defaultModelURL(environment: [:], fileManager: fileManager),
                       downloaded)
        // Then legacy Documents staging (still intact for demo builds).
        try FileManager.default.removeItem(at: downloaded)
        XCTAssertEqual(ModelRuntime.defaultModelURL(environment: [:], fileManager: fileManager),
                       documents)
        // Then the setup-script cache (still intact for local builds).
        try FileManager.default.removeItem(at: documents)
        XCTAssertEqual(ModelRuntime.defaultModelURL(environment: [:], fileManager: fileManager),
                       scriptCache)
        // Nothing anywhere resolves to nil.
        try FileManager.default.removeItem(at: scriptCache)
        XCTAssertNil(ModelRuntime.defaultModelURL(environment: [:], fileManager: fileManager))
    }
}
