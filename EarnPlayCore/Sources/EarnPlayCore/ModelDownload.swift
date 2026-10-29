import Foundation

// MARK: - First-launch tutor-model download (issue #53)

/// Configuration for the one-time first-launch download of the tutor model.
///
/// Production values name the exact file `Scripts/setup-model-spike.sh`
/// fetches (bartowski Llama-3.2-1B-Instruct-GGUF, Q4_K_M); the setup
/// script stays the source of truth for local/demo builds and is
/// unchanged by this feature.
public struct ModelDownloadConfiguration: Sendable, Equatable {
    /// Full URL of the GGUF file to fetch. The only network fetch the
    /// download path ever performs (no server/account/cloud code paths).
    public let sourceURL: URL
    /// Expected size in bytes; a size mismatch discards the download.
    public let expectedByteCount: Int64
    /// Expected SHA-256 (lowercase hex) of the file; a mismatch
    /// discards the download and the model is never loaded unverified.
    public let expectedSHA256: String
    /// How many fetch attempts a single `download()` makes before
    /// surfacing the last error (the UI offers a manual retry after that).
    public let maxAttempts: Int

    public init(sourceURL: URL, expectedByteCount: Int64,
                expectedSHA256: String, maxAttempts: Int = 3) {
        self.sourceURL = sourceURL
        self.expectedByteCount = expectedByteCount
        self.expectedSHA256 = expectedSHA256
        self.maxAttempts = maxAttempts
    }

    /// Production model. Keep in sync with `Scripts/setup-model-spike.sh`.
    public static var production: ModelDownloadConfiguration {
        ModelDownloadConfiguration(
            sourceURL: URL(string: "https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf")!,
            expectedByteCount: 807_694_464,
            expectedSHA256: "6f85a640a97cf2bf5b8e764087b1e83da0fdb51d7c9fab7d0fece9385611df83",
            maxAttempts: 3
        )
    }
}

/// Shipped license attribution for the tutor model (issue #53).
/// The child app's About screen renders this text verbatim; the tests
/// pin it so the attribution cannot be silently dropped.
public enum ModelAttribution {
    public static let llamaCommunityLicenseText =
        "On-device tutor model: Llama 3.2 1B Instruct " +
        "(bartowski Llama-3.2-1B-Instruct-GGUF, Q4_K_M), used under " +
        "the Llama 3.2 Community License. The model is downloaded " +
        "once over Wi-Fi and runs entirely on this device."
}

/// Errors from `ModelDownloader`. Every failure leaves the destination
/// without a new file: partial or corrupt downloads are discarded.
public enum ModelDownloadError: Error, Equatable, Sendable {
    /// The fetch failed (message describes the underlying error).
    case networkFailure(String)
    /// The server answered with a non-2xx HTTP status.
    case httpStatus(Int)
    /// The fetched file's size differs from the expected byte count.
    case byteCountMismatch(expected: Int64, actual: Int64)
    /// The fetched file's SHA-256 differs from the expected digest.
    /// The file was discarded; the model must be re-downloaded.
    case checksumMismatch
    /// The download was cancelled.
    case cancelled
}

/// Fetches a remote file to a caller-owned temporary file.
///
/// The live implementation (`URLSessionModelDownloadFetcher`) is Wi-Fi
/// only; tests inject a mock so no 800 MB download runs in unit tests.
public protocol ModelDownloadFetching: Sendable {
    /// Downloads `url` to a temporary file and returns its location.
    /// Calls `progress` with 0...1 fractions as the fetch proceeds.
    /// The caller owns the returned file (verify, then move or remove).
    func fetch(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// Wi-Fi-only URLSession fetcher for the ~800 MB model file.
///
/// `allowsCellularAccess = false` is what enforces the Wi-Fi-only
/// constraint: the system will not run this transfer over cellular.
public struct URLSessionModelDownloadFetcher: ModelDownloadFetching {
    public init() {}

    /// Session configuration for the model fetch: Wi-Fi only, with a
    /// generous resource timeout for the ~800 MB file.
    public static func wifiOnlyConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.allowsCellularAccess = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return configuration
    }

    public func fetch(url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = ModelDownloadTaskDelegate(progress: progress)
        let session = URLSession(configuration: Self.wifiOnlyConfiguration(),
                                 delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                delegate.begin(session: session, url: url, continuation: continuation)
            }
        }, onCancel: {
            delegate.cancel()
        })
    }
}

/// Download-task delegate bridging URLSession callbacks to an
/// async continuation, with progress reporting. Single-task: one
/// delegate instance serves one `fetch(url:progress:)` call.
final class ModelDownloadTaskDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, any Error>?
    private var stagedLocation: URL?
    private var task: URLSessionDownloadTask?
    private var didResume = false

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func begin(session: URLSession, url: URL, continuation: CheckedContinuation<URL, any Error>) {
        lock.lock()
        self.continuation = continuation
        let downloadTask = session.downloadTask(with: url)
        self.task = downloadTask
        lock.unlock()
        downloadTask.resume()
    }

    func cancel() {
        lock.lock()
        let downloadTask = task
        lock.unlock()
        downloadTask?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The system removes `location` after this callback returns,
        // so move it to a caller-owned file first. The completion
        // callback below delivers it (or discards it on HTTP errors).
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent("EarnPlayModel-\(UUID().uuidString).download")
        do {
            try FileManager.default.moveItem(at: location, to: owned)
            lock.lock()
            stagedLocation = owned
            lock.unlock()
        } catch {
            finish(throwing: ModelDownloadError.networkFailure(
                "cannot stage download: \(String(describing: error))"))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0, totalBytesWritten >= 0 else { return }
        progress(min(1.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            cleanupStaged()
            if let urlError = error as? URLError, urlError.code == .cancelled {
                finish(throwing: ModelDownloadError.cancelled)
            } else {
                finish(throwing: ModelDownloadError.networkFailure(String(describing: error)))
            }
            return
        }
        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            cleanupStaged()
            finish(throwing: ModelDownloadError.httpStatus(http.statusCode))
            return
        }
        lock.lock()
        let staged = stagedLocation
        stagedLocation = nil
        lock.unlock()
        if let staged {
            finish(returning: staged)
        } else {
            finish(throwing: ModelDownloadError.networkFailure("download finished without a file"))
        }
    }

    private func cleanupStaged() {
        lock.lock()
        let staged = stagedLocation
        stagedLocation = nil
        lock.unlock()
        if let staged {
            try? FileManager.default.removeItem(at: staged)
        }
    }

    private func finish(returning url: URL) {
        lock.lock()
        guard !didResume, let continuation else { lock.unlock(); return }
        didResume = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: url)
    }

    private func finish(throwing error: Error) {
        lock.lock()
        guard !didResume, let continuation else { lock.unlock(); return }
        didResume = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }
}

/// Downloads and verifies the tutor model into Application Support.
///
/// - Destination is Application Support (`EarnPlay/EarnPlayModel.gguf`),
///   never Caches: iOS can purge Caches under storage pressure, which
///   would silently delete an 800 MB model.
/// - Every fetched file is size- and SHA-256-verified before it is
///   moved into place; on mismatch the file is discarded and the
///   fetch retried. An unverified model is never installed, so it
///   can never be picked up by `ModelRuntime.defaultModelURL()`.
/// - After a successful download the model loads from disk with no
///   network (`downloadIfNeeded` returns the verified file without
///   fetching), so the app works fully offline.
public struct ModelDownloader: Sendable {
    public let configuration: ModelDownloadConfiguration
    public let destinationURL: URL
    private let fetcher: any ModelDownloadFetching

    public init(configuration: ModelDownloadConfiguration = .production,
                destinationURL: URL? = nil,
                fetcher: any ModelDownloadFetching = URLSessionModelDownloadFetcher(),
                fileManager: FileManager = .default) {
        self.configuration = configuration
        self.destinationURL = destinationURL ?? Self.defaultDestinationURL(fileManager: fileManager)
        self.fetcher = fetcher
    }

    /// Production destination: `Application Support/EarnPlay/EarnPlayModel.gguf`.
    /// (Same `EarnPlay` directory convention as `PolicyStore`.)
    public static func defaultDestinationURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("EarnPlay/EarnPlayModel.gguf")
    }

    /// The destination when it already holds a verified model (correct
    /// size and SHA-256), otherwise nil. Re-reads the file every time:
    /// path existence alone never counts as verified.
    public func verifiedExistingModelURL() -> URL? {
        guard FileManager.default.fileExists(atPath: destinationURL.path) else { return nil }
        do {
            try verify(destinationURL)
            return destinationURL
        } catch {
            return nil
        }
    }

    /// Returns the verified model file, downloading it first when needed.
    /// A corrupt pre-existing file is discarded and re-downloaded.
    /// After a successful download this performs no network I/O.
    public func downloadIfNeeded(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            if verifiedExistingModelURL() != nil {
                progress(1.0)
                return destinationURL
            }
            // Discard the corrupt artifact so a failed re-download
            // cannot leave a bad file behind for the lookup to find.
            try? FileManager.default.removeItem(at: destinationURL)
        }
        return try await download(progress: progress)
    }

    /// Downloads, verifies, and installs the model, retrying failed
    /// attempts up to `configuration.maxAttempts`. Throws the last
    /// error when every attempt fails.
    public func download(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        var lastError: ModelDownloadError = .networkFailure("download failed")
        for _ in 1...max(1, configuration.maxAttempts) {
            if Task.isCancelled {
                throw ModelDownloadError.cancelled
            }
            do {
                return try await attemptDownload(progress: progress)
            } catch let error as ModelDownloadError {
                lastError = error
                if case .cancelled = error {
                    throw error
                }
            } catch is CancellationError {
                throw ModelDownloadError.cancelled
            } catch {
                lastError = .networkFailure(String(describing: error))
            }
        }
        throw lastError
    }

    /// One fetch + verify + install attempt. The staged file is always
    /// removed when verification or installation fails.
    private func attemptDownload(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let staged = try await fetcher.fetch(url: configuration.sourceURL, progress: progress)
        do {
            try verify(staged)
            try publish(staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        progress(1.0)
        return destinationURL
    }

    /// Size + SHA-256 verification. Throws `.byteCountMismatch` or
    /// `.checksumMismatch` for a bad file.
    private func verify(_ fileURL: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let actual = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
        guard actual == configuration.expectedByteCount else {
            throw ModelDownloadError.byteCountMismatch(
                expected: configuration.expectedByteCount, actual: actual)
        }
        let digest: String
        do {
            digest = try ModelRuntime.contentSHA256(forFileAt: fileURL)
        } catch {
            throw ModelDownloadError.networkFailure(
                "cannot verify download: \(String(describing: error))")
        }
        guard digest == configuration.expectedSHA256 else {
            throw ModelDownloadError.checksumMismatch
        }
    }

    /// Atomically installs a verified staged file at the destination.
    private func publish(_ staged: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: staged, to: destinationURL)
        } catch {
            throw ModelDownloadError.networkFailure(
                "cannot install download: \(String(describing: error))")
        }
        // Re-downloadable ~800 MB asset: keep it out of device backups.
        var installURL = destinationURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? installURL.setResourceValues(values)
    }
}
