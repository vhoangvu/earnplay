import XCTest
import EarnPlayCore

/// Counts every URL load attempted through URLProtocol while the model
/// runs. The card requires this count to stay 0 (fully offline inference).
final class CountingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _count = 0
    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }
    static func reset() {
        lock.lock()
        _count = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self._count += 1
        Self.lock.unlock()
        // Never completes: any attempted load is both counted and stuck,
        // so a network call could never silently satisfy the prompt.
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// T0.2 card test: networking disabled (counting stub installed), load
/// the real GGUF model, run 1 prompt, assert a non-empty response within
/// the recorded timeout and zero attempted network calls.
///
/// Skips — never fakes a pass — when the runtime framework or the model
/// file has not been fetched. Run `Scripts/setup-model-spike.sh`, then:
/// `SIMCTL_CHILD_EARNPLAY_MODEL_PATH=<gguf> xcodebuild test ...`
final class ModelRuntimeIntegrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CountingURLProtocol.reset()
        URLProtocol.registerClass(CountingURLProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(CountingURLProtocol.self)
        super.tearDown()
    }

    func testOfflinePromptRoundTrip() throws {
        guard ModelRuntime.isRuntimeLinked else {
            throw XCTSkip("llama.xcframework not fetched; run Scripts/setup-model-spike.sh")
        }
        guard let modelURL = ModelRuntime.defaultModelURL(),
              FileManager.default.fileExists(atPath: modelURL.path) else {
            let env = ProcessInfo.processInfo.environment
            print("T02 diag: envPath=\(env["EARNPLAY_MODEL_PATH"] ?? "unset") resolved=\(ModelRuntime.defaultModelURL()?.path ?? "nil") docs=\(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "nil")")
            throw XCTSkip("spike GGUF not found; run Scripts/setup-model-spike.sh")
        }
        print("T02 model: \(modelURL.path)")

        let runtime = ModelRuntime(modelPath: modelURL)
        // Cold run first: loadedModelInfo() would otherwise pre-load and
        // make the "cold" generate warm.
        let cold = try runtime.generate(prompt: SpikePrompts.all[0], maxTokens: 48)
        let info = try runtime.loadedModelInfo()
        // Real-model proof: a canned-text stub has no 1B weights to report.
        XCTAssertTrue(info.modelDescription.lowercased().contains("llama"),
                      "unexpected model description: \(info.modelDescription)")
        XCTAssertGreaterThan(info.parameterCount, 500_000_000)
        XCTAssertEqual(info.fileByteCount, 807_694_464)
        XCTAssertFalse(info.runtimeVersion.isEmpty)
        print("T02 cold: load=\(Int(cold.loadLatencyMs))ms gen=\(Int(cold.generationLatencyMs))ms total=\(Int(cold.totalLatencyMs))ms tokens=\(cold.generatedTokenCount) response=\(cold.response.prefix(120))")
        XCTAssertTrue(cold.wasColdStart)
        XCTAssertFalse(cold.response.isEmpty, "model returned an empty response")
        XCTAssertLessThan(cold.totalLatencyMs, ModelRuntime.spikeTimeoutMs,
                          "cold round-trip exceeded the recorded spike timeout")
        XCTAssertEqual(CountingURLProtocol.count, 0, "inference attempted a network call")

        let warm = try runtime.generate(prompt: SpikePrompts.all[1], maxTokens: 48)
        print("T02 warm: gen=\(Int(warm.generationLatencyMs))ms tokens=\(warm.generatedTokenCount) response=\(warm.response.prefix(120))")
        XCTAssertFalse(warm.wasColdStart)
        XCTAssertFalse(warm.response.isEmpty)
        XCTAssertLessThan(warm.totalLatencyMs, ModelRuntime.spikeTimeoutMs,
                          "warm round-trip exceeded the recorded spike timeout")
        XCTAssertEqual(CountingURLProtocol.count, 0, "inference attempted a network call")
    }
}
