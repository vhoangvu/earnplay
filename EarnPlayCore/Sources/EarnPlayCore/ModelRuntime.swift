import CryptoKit
import Foundation
#if canImport(CLlamaShim)
import CLlamaShim
#endif

/// Errors thrown by `ModelRuntime`. No case ever involves the network:
/// inference is fully on-device (SSOT privacy: no network at practice time).
public enum ModelRuntimeError: Error, Equatable, Sendable {
    /// The llama.cpp framework was not fetched/built on this machine.
    /// Run `Scripts/setup-model-spike.sh` (see Docs/ModelRuntimeSpike.md).
    case runtimeUnavailable
    /// No GGUF file exists at the expected location.
    case modelNotFound(path: String)
    /// llama.cpp refused the model file (message from the C shim).
    case modelLoadFailed(String)
    /// Generation failed inside llama.cpp (message from the C shim).
    case generationFailed(String)
    /// The caller passed an empty prompt.
    case emptyPrompt
    /// The file exists but is not a GGUF model (bad magic), so its
    /// identity cannot be verified as a model artifact (T5.3 F5).
    case invalidModelFile(path: String)
    /// The file at the model path no longer matches the verified
    /// digest/version the runtime was created for (T5.3 round 4 F1).
    case modelContentMismatch(path: String)
}

/// One prompt-to-response round-trip, with latency split so the spike
/// note can report a true cold-start number (load + first generation)
/// separately from a warm run (generation only).
public struct ModelInferenceResult: Equatable, Sendable {
    public let prompt: String
    public let response: String
    /// Milliseconds spent loading the model inside this call (0 when warm).
    public let loadLatencyMs: Double
    /// Milliseconds spent generating the response.
    public let generationLatencyMs: Double
    public let generatedTokenCount: Int
    /// True when this call loaded the model (process-cold start).
    public let wasColdStart: Bool

    public var totalLatencyMs: Double { loadLatencyMs + generationLatencyMs }

    public init(prompt: String, response: String, loadLatencyMs: Double,
                generationLatencyMs: Double, generatedTokenCount: Int,
                wasColdStart: Bool) {
        self.prompt = prompt
        self.response = response
        self.loadLatencyMs = loadLatencyMs
        self.generationLatencyMs = generationLatencyMs
        self.generatedTokenCount = generatedTokenCount
        self.wasColdStart = wasColdStart
    }
}

/// Identity + size facts for the loaded model. Tests assert these so a
/// canned-text stub can never pass as a real model.
public struct LoadedModelInfo: Equatable, Sendable {
    /// llama.cpp model description, e.g. "llama 1B Q4_K - Medium".
    public let modelDescription: String
    /// Parameter count reported by the model file itself.
    public let parameterCount: UInt64
    /// Size of the GGUF file on disk, in bytes.
    public let fileByteCount: Int64
    /// llama.cpp version string of the linked runtime.
    public let runtimeVersion: String

    public init(modelDescription: String, parameterCount: UInt64,
                fileByteCount: Int64, runtimeVersion: String) {
        self.modelDescription = modelDescription
        self.parameterCount = parameterCount
        self.fileByteCount = fileByteCount
        self.runtimeVersion = runtimeVersion
    }
}

/// On-device model runtime (T0.2 spike).
///
/// Wraps llama.cpp (pinned `b11935`, CPU backend) behind the smallest
/// useful API: load a GGUF file once, then run completions. The class
/// contains no networking code at all — no `URLSession`, no sockets —
/// which is what lets the integration test assert a zero network-call
/// count while a prompt runs.
///
/// Ownership note (LLD module map): each app owns a `ModelRuntime`
/// instance (tutor in the child app, auditor in the admin app). This
/// wrapper lives in the shared package so both apps use the same code;
/// instances are independent and never share a llama context.
public final class ModelRuntime: @unchecked Sendable {
    /// Model exercised by the spike: Meta Llama 3.2 1B Instruct, Q4_K_M.
    public static let modelIdentifier =
        "meta-llama Llama-3.2-1B-Instruct, GGUF Q4_K_M " +
        "(bartowski/Llama-3.2-1B-Instruct-GGUF)"
    /// Runtime exercised by the spike (llama.cpp, MLC-style on-device route).
    public static let runtimeIdentifier = "llama.cpp b11935, CPU backend"
    /// Configured spike identity (T5.3, LLD 2.2/10.3). This names
    /// the model this build was configured for — it is NOT a
    /// verified stamp for an arbitrary GGUF file. For the identity
    /// of an actual file on disk use `verifiedModelVersion(forModelAt:)`
    /// / `verifiedVersionStamp()`, which read the file itself and
    /// reject non-GGUF files instead of stamping them as Llama.
    public static var versionStamp: String {
        "\(modelIdentifier) / \(runtimeIdentifier)"
    }

    /// Verified identity of the GGUF file at `url`, derived from
    /// the file itself (its name, byte count, and GGUF magic) plus
    /// the runtime. Throws `.modelNotFound` when absent and
    /// `.invalidModelFile` when the file is not a GGUF — an
    /// arbitrary file is never reported under the Llama identity.
    public struct VerifiedModelIdentity: Equatable, Sendable {
        public let modelVersion: String
        public let contentDigest: String
        public let byteCount: Int64
    }

    /// Single-pass verified identity (round 5 F2): size, magic and
    /// SHA-256 all come from one streamed read of the file, so the
    /// version stamp and the content digest can never describe two
    /// different replacements of the same path.
    public static func verifiedModelIdentity(
        forModelAt url: URL, fileManager: FileManager = .default
    ) throws -> VerifiedModelIdentity {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            if fileManager.fileExists(atPath: url.path) {
                throw ModelRuntimeError.invalidModelFile(path: url.path)
            }
            throw ModelRuntimeError.modelNotFound(path: url.path)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ModelRuntimeError.modelNotFound(path: url.path)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        var magic = Data()
        while true {
            let chunk = try handle.read(upToCount: 65_536) ?? Data()
            if chunk.isEmpty { break }
            if magic.count < 4 { magic.append(chunk.prefix(4 - magic.count)) }
            byteCount += Int64(chunk.count)
            hasher.update(data: chunk)
        }
        guard magic.elementsEqual([0x47, 0x47, 0x55, 0x46]) else {
            throw ModelRuntimeError.invalidModelFile(path: url.path)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return VerifiedModelIdentity(
            modelVersion: "\(url.lastPathComponent) (\(byteCount) bytes, GGUF, sha256:\(digest)) / \(runtimeIdentifier)",
            contentDigest: digest, byteCount: byteCount)
    }

    public static func verifiedModelVersion(
        forModelAt url: URL, fileManager: FileManager = .default
    ) throws -> String {
        try verifiedModelIdentity(forModelAt: url, fileManager: fileManager).modelVersion
    }

    /// Reported model version for a stored bundle version (F13):
    /// the retained model identity with the runtime actually running.
    /// A stored version of the form "<model identity> / <runtime>"
    /// has its runtime component replaced with the current
    /// `runtimeIdentifier`; a model-only identity is returned as-is.
    public static func reportedModelVersion(storedModelVersion: String) -> String {
        guard let range = storedModelVersion.range(of: " / ", options: .backwards) else {
            return storedModelVersion
        }
        let modelIdentity = String(storedModelVersion[..<range.lowerBound])
        guard !modelIdentity.isEmpty else { return storedModelVersion }
        return "\(modelIdentity) / \(runtimeIdentifier)"
    }

    /// Streamed SHA-256 (hex) of a file's contents — the immutable
    /// content identity used in verified stamps and bundle binding.
    /// Always re-reads the file (round 4 F2): path+size+mtime do not
    /// uniquely identify contents, so no digest cache is kept for
    /// mutable model paths.
    public static func contentSHA256(forFileAt url: URL) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ModelRuntimeError.modelNotFound(path: url.path)
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 65_536) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Verified stamp for this instance's own model file.
    public func verifiedVersionStamp() throws -> String {
        try Self.verifiedModelVersion(forModelAt: modelPath)
    }

    static func isGGUFFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        return data.elementsEqual([0x47, 0x47, 0x55, 0x46]) // "GGUF"
    }
    /// Round-trip budget asserted by the spike tests and recorded in
    /// Docs/ModelRuntimeSpike.md. Generous because simulator CI hosts vary.
    public static let spikeTimeoutMs: Double = 300_000

    /// True when the llama.xcframework was present at package-build time.
    public static var isRuntimeLinked: Bool {
        #if canImport(CLlamaShim)
        return true
        #else
        return false
        #endif
    }

    private let modelPath: URL
    /// Verified identity this runtime is bound to (round 4 F1).
    /// When set, `load()` re-hashes/re-verifies the file at load
    /// time and refuses a replaced file instead of loading it
    /// under the previously resolved version.
    public let expectedContentDigest: String?
    public let expectedModelVersion: String?
    private let lock = NSLock()
    #if canImport(CLlamaShim)
    private var handle: OpaquePointer?
    #endif
    private var didLoad = false
    private var cachedInfo: LoadedModelInfo?

    public init(modelPath: URL, expectedContentDigest: String? = nil,
                expectedModelVersion: String? = nil) {
        self.modelPath = modelPath
        self.expectedContentDigest = expectedContentDigest
        self.expectedModelVersion = expectedModelVersion
    }

    /// Re-verify the file at `modelPath` against the bound identity.
    /// Caller must hold `lock`. No-op when no identity was bound.
    private func verifyBoundIdentityLocked() throws {
        guard expectedContentDigest != nil || expectedModelVersion != nil else { return }
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw ModelRuntimeError.modelNotFound(path: modelPath.path)
        }
        guard Self.isGGUFFile(at: modelPath) else {
            throw ModelRuntimeError.invalidModelFile(path: modelPath.path)
        }
        if let expectedContentDigest {
            let actual = try Self.contentSHA256(forFileAt: modelPath)
            guard actual == expectedContentDigest else {
                throw ModelRuntimeError.modelContentMismatch(path: modelPath.path)
            }
        } else if let expectedModelVersion {
            let verified = try Self.verifiedModelVersion(forModelAt: modelPath)
            guard verified == expectedModelVersion
                    || Self.reportedModelVersion(storedModelVersion: verified) == expectedModelVersion
                    || verified == Self.reportedModelVersion(storedModelVersion: expectedModelVersion) else {
                throw ModelRuntimeError.modelContentMismatch(path: modelPath.path)
            }
        }
    }

    deinit {
        #if canImport(CLlamaShim)
        if let handle {
            ep_llama_destroy(handle)
        }
        #endif
    }

    /// Resolves the spike model location: `$EARNPLAY_MODEL_PATH`, else
    /// `Documents/EarnPlayModel.gguf` (manual device installs), else the
    /// cache directory written by `Scripts/setup-model-spike.sh`.
    public static func defaultModelURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        // Plain key arrives via `EARNPLAY_MODEL_PATH=... xcodebuild test`;
        // the SIMCTL_CHILD_ spelling arrives via `simctl spawn` launches.
        for key in ["EARNPLAY_MODEL_PATH", "SIMCTL_CHILD_EARNPLAY_MODEL_PATH"] {
            if let override = environment[key], !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
        }
        let fileName = "Llama-3.2-1B-Instruct-Q4_K_M.gguf"
        if let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let candidate = docs.appendingPathComponent("EarnPlayModel.gguf")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let candidate = caches.appendingPathComponent("EarnPlay/models/\(fileName)")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Loads the GGUF model (idempotent). Returns load latency in ms.
    @discardableResult
    public func load() throws -> Double {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    /// Caller must hold `lock`. The didLoad check and the load itself
    /// happen under that one lock acquisition, so concurrent callers
    /// cannot both observe the not-yet-loaded state.
    /// Round 5 F1: copy the model once, hashing while copying, into
    /// a content-addressed read-only artifact and return its URL.
    /// llama.cpp opens this retained file, never the mutable source
    /// path, so the bytes loaded are exactly the bytes hashed. The
    /// copy's digest must match the bound identity when one is set.
    /// Publish `tmp` as the immutable `final` file. Round 6 F3:
    /// if another instance won the publication race, verify and
    /// reuse the winning file and remove the losing temporary copy
    /// instead of failing an otherwise valid load.
    private func publishImmutableCopy(tmp: URL, to final: URL, digest: String) throws -> URL {
        do {
            try FileManager.default.moveItem(at: tmp, to: final)
        } catch {
            if FileManager.default.fileExists(atPath: final.path),
               (try? Self.contentSHA256(forFileAt: final)) == digest {
                try? FileManager.default.removeItem(at: tmp)
                return final
            }
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: final.path)
        return final
    }

    func verifiedImmutableCopyURL() throws -> URL {
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw ModelRuntimeError.modelNotFound(path: modelPath.path)
        }
        guard Self.isGGUFFile(at: modelPath) else {
            throw ModelRuntimeError.invalidModelFile(path: modelPath.path)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = caches.appendingPathComponent("EarnPlay/immutable-models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Round 6 F2: when a digest is already bound, check and
        // verify the existing cache entry before creating any
        // temporary copy — a cache hit needs no extra 770 MiB.
        if let expectedContentDigest {
            let cached = dir.appendingPathComponent("\(expectedContentDigest).gguf")
            if FileManager.default.fileExists(atPath: cached.path) {
                if (try? Self.contentSHA256(forFileAt: cached)) == expectedContentDigest {
                    return cached
                }
                try? FileManager.default.removeItem(at: cached)
            }
        }
        guard let source = try? FileHandle(forReadingFrom: modelPath) else {
            throw ModelRuntimeError.modelNotFound(path: modelPath.path)
        }
        defer { try? source.close() }
        let tmp = dir.appendingPathComponent("immutable-\(UUID().uuidString).tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        guard let sink = try? FileHandle(forWritingTo: tmp) else {
            throw ModelRuntimeError.modelLoadFailed("cannot create immutable model copy")
        }
        var hasher = SHA256()
        do {
            while true {
                let chunk = try source.read(upToCount: 65_536) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                try sink.write(contentsOf: chunk)
            }
            try sink.synchronize()
            try sink.close()
        } catch {
            try? sink.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let expectedContentDigest, digest != expectedContentDigest {
            try? FileManager.default.removeItem(at: tmp)
            throw ModelRuntimeError.modelContentMismatch(path: modelPath.path)
        }
        if expectedContentDigest == nil, let expectedModelVersion {
            let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value ?? 0
            let verified = "\(modelPath.lastPathComponent) (\(size) bytes, GGUF, sha256:\(digest)) / \(Self.runtimeIdentifier)"
            guard verified == expectedModelVersion
                    || Self.reportedModelVersion(storedModelVersion: verified) == expectedModelVersion
                    || verified == Self.reportedModelVersion(storedModelVersion: expectedModelVersion) else {
                try? FileManager.default.removeItem(at: tmp)
                throw ModelRuntimeError.modelContentMismatch(path: modelPath.path)
            }
        }
        let final = dir.appendingPathComponent("\(digest).gguf")
        if FileManager.default.fileExists(atPath: final.path) {
            if (try? Self.contentSHA256(forFileAt: final)) == digest {
                try? FileManager.default.removeItem(at: tmp)
                return final
            }
            try? FileManager.default.removeItem(at: final)
        }
        return try publishImmutableCopy(tmp: tmp, to: final, digest: digest)
    }

    private func loadLocked() throws -> Double {
        // Round 5 F7: timing starts before identity verification so
        // loadLatencyMs includes the full verified read of the model.
        let start = Date()
        if didLoad {
            return 0
        }
        // F1: re-verify a bound identity at load time, before the
        // (possibly replaced) file is handed to llama.cpp.
        try verifyBoundIdentityLocked()
        guard Self.isRuntimeLinked else {
            throw ModelRuntimeError.runtimeUnavailable
        }
        // Round 5 F1: load the retained immutable copy, not the
        // mutable source path verified above.
        let loadPath = try verifiedImmutableCopyURL()
        #if canImport(CLlamaShim)
        var errorPtr: UnsafeMutablePointer<CChar>?
        let created = loadPath.path.withCString { ep_llama_create($0, &errorPtr) }
        if let errorPtr {
            let message = String(cString: errorPtr)
            ep_llama_free_string(errorPtr)
            throw ModelRuntimeError.modelLoadFailed(message)
        }
        guard let created else {
            throw ModelRuntimeError.modelLoadFailed("unknown llama.cpp load failure")
        }
        handle = created
        didLoad = true
        cachedInfo = makeInfoLocked()
        return Date().timeIntervalSince(start) * 1000
        #else
        throw ModelRuntimeError.runtimeUnavailable
        #endif
    }

    /// Metadata for the loaded model. Loads the model first if needed.
    public func loadedModelInfo() throws -> LoadedModelInfo {
        lock.lock()
        defer { lock.unlock() }
        if !didLoad {
            _ = try loadLocked()
        }
        if let cachedInfo {
            return cachedInfo
        }
        #if canImport(CLlamaShim)
        let info = makeInfoLocked()
        cachedInfo = info
        return info
        #else
        throw ModelRuntimeError.runtimeUnavailable
        #endif
    }

    /// Runs one prompt-to-response round-trip. The first call on a fresh
    /// instance loads the model and reports `wasColdStart == true`.
    public func generate(prompt: String, maxTokens: Int32 = 64) throws -> ModelInferenceResult {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ModelRuntimeError.emptyPrompt
        }
        // One lock acquisition covers the cold-start check, the load,
        // and generation, so exactly one concurrent caller can report
        // wasColdStart == true.
        lock.lock()
        defer { lock.unlock() }
        var loadMs: Double = 0
        var wasCold = false
        if !didLoad {
            loadMs = try loadLocked()
            wasCold = true
        }
        #if canImport(CLlamaShim)
        guard let handle else {
            throw ModelRuntimeError.modelLoadFailed("model handle missing after load")
        }
        let start = Date()
        var tokenCount: Int32 = 0
        var errorPtr: UnsafeMutablePointer<CChar>?
        let generated: String = try prompt.withCString { cPrompt in
            let raw = ep_llama_generate(handle, cPrompt, maxTokens, 42, &tokenCount, &errorPtr)
            if let errorPtr {
                let message = String(cString: errorPtr)
                ep_llama_free_string(errorPtr)
                throw ModelRuntimeError.generationFailed(message)
            }
            guard let raw else {
                throw ModelRuntimeError.generationFailed("unknown llama.cpp generation failure")
            }
            defer { ep_llama_free_string(raw) }
            return String(cString: raw)
        }
        let genMs = Date().timeIntervalSince(start) * 1000
        return ModelInferenceResult(
            prompt: prompt,
            response: generated.trimmingCharacters(in: .whitespacesAndNewlines),
            loadLatencyMs: loadMs,
            generationLatencyMs: genMs,
            generatedTokenCount: Int(tokenCount),
            wasColdStart: wasCold
        )
        #else
        throw ModelRuntimeError.runtimeUnavailable
        #endif
    }

    #if canImport(CLlamaShim)
    /// Caller must hold `lock` (or be inside `load()`, which does).
    private func makeInfoLocked() -> LoadedModelInfo {
        var description = ""
        var params: UInt64 = 0
        var version = ""
        if let handle {
            var buffer = [CChar](repeating: 0, count: 256)
            _ = ep_llama_describe(handle, &buffer, buffer.count)
            let bytes = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            description = String(decoding: bytes, as: UTF8.self)
            params = ep_llama_n_params(handle)
            version = String(cString: ep_llama_version())
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: modelPath.path)[.size] as? NSNumber) ?? nil
        return LoadedModelInfo(
            modelDescription: description,
            parameterCount: params,
            fileByteCount: size?.int64Value ?? 0,
            runtimeVersion: version
        )
    }
    #endif
}
