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
    private let lock = NSLock()
    #if canImport(CLlamaShim)
    private var handle: OpaquePointer?
    #endif
    private var didLoad = false
    private var cachedInfo: LoadedModelInfo?

    public init(modelPath: URL) {
        self.modelPath = modelPath
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
    private func loadLocked() throws -> Double {
        if didLoad {
            return 0
        }
        guard Self.isRuntimeLinked else {
            throw ModelRuntimeError.runtimeUnavailable
        }
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw ModelRuntimeError.modelNotFound(path: modelPath.path)
        }
        #if canImport(CLlamaShim)
        let start = Date()
        var errorPtr: UnsafeMutablePointer<CChar>?
        let created = modelPath.path.withCString { ep_llama_create($0, &errorPtr) }
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
