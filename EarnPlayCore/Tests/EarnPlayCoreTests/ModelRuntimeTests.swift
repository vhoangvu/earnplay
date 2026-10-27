import XCTest
@testable import EarnPlayCore

final class ModelRuntimeTests: XCTestCase {
    func testSpikePromptSetHasFiveFixedPrompts() {
        XCTAssertEqual(SpikePrompts.all.count, 5)
        XCTAssertEqual(Set(SpikePrompts.all).count, 5, "prompts must be distinct")
        for prompt in SpikePrompts.all {
            XCTAssertFalse(prompt.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    func testEmptyPromptIsRejected() {
        let runtime = ModelRuntime(modelPath: URL(fileURLWithPath: "/nonexistent/model.gguf"))
        XCTAssertThrowsError(try runtime.generate(prompt: "   ")) { error in
            XCTAssertEqual(error as? ModelRuntimeError, .emptyPrompt)
        }
    }

    func testMissingModelOrMissingRuntimeFailsHonestly() {
        let runtime = ModelRuntime(modelPath: URL(fileURLWithPath: "/nonexistent/model.gguf"))
        XCTAssertThrowsError(try runtime.load()) { error in
            guard let runtimeError = error as? ModelRuntimeError else {
                return XCTFail("unexpected error: \(error)")
            }
            if ModelRuntime.isRuntimeLinked {
                XCTAssertEqual(runtimeError, .modelNotFound(path: "/nonexistent/model.gguf"))
            } else {
                XCTAssertEqual(runtimeError, .runtimeUnavailable)
            }
        }
    }

    /// Real inference on the host (macOS slice). Opt-in: runs only when
    /// EARNPLAY_MODEL_PATH points at the spike GGUF; otherwise skips.
    /// The simulator/device proof lives in EarnPlayTests.
    func testRealInferenceWhenModelProvided() throws {
        guard ModelRuntime.isRuntimeLinked else {
            throw XCTSkip("llama.xcframework not fetched; run Scripts/setup-model-spike.sh")
        }
        guard let path = ProcessInfo.processInfo.environment["EARNPLAY_MODEL_PATH"],
              !path.isEmpty else {
            throw XCTSkip("EARNPLAY_MODEL_PATH not set; real-inference check skipped")
        }
        let runtime = ModelRuntime(modelPath: URL(fileURLWithPath: path))
        // Cold run first: loadedModelInfo() would otherwise pre-load and
        // make the "cold" generate warm.
        let cold = try runtime.generate(prompt: SpikePrompts.all[0], maxTokens: 32)
        let info = try runtime.loadedModelInfo()
        XCTAssertGreaterThan(info.parameterCount, 500_000_000, "expected a real ~1B model")
        XCTAssertEqual(info.fileByteCount, 807_694_464)
        XCTAssertFalse(cold.response.isEmpty)
        XCTAssertTrue(cold.wasColdStart)
        XCTAssertLessThan(cold.totalLatencyMs, ModelRuntime.spikeTimeoutMs)

        let warm = try runtime.generate(prompt: SpikePrompts.all[1], maxTokens: 32)
        XCTAssertFalse(warm.response.isEmpty)
        XCTAssertFalse(warm.wasColdStart)
        XCTAssertEqual(warm.loadLatencyMs, 0, accuracy: 0.001)
    }

    /// Regression (Copilot review, PR #33): the cold-start check and the
    /// load must be atomic, so concurrent first generations report
    /// exactly one wasColdStart == true.
    func testConcurrentFirstGenerationsReportSingleColdStart() throws {
        guard ModelRuntime.isRuntimeLinked else {
            throw XCTSkip("llama.xcframework not fetched; run Scripts/setup-model-spike.sh")
        }
        guard let path = ProcessInfo.processInfo.environment["EARNPLAY_MODEL_PATH"],
              !path.isEmpty else {
            throw XCTSkip("EARNPLAY_MODEL_PATH not set; real-inference check skipped")
        }
        let runtime = ModelRuntime(modelPath: URL(fileURLWithPath: path))
        let resultsLock = NSLock()
        var coldFlags: [Bool] = []
        var errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 4) { _ in
            do {
                let result = try runtime.generate(prompt: SpikePrompts.all[0], maxTokens: 8)
                resultsLock.lock()
                coldFlags.append(result.wasColdStart)
                resultsLock.unlock()
            } catch {
                resultsLock.lock()
                errors.append(error)
                resultsLock.unlock()
            }
        }
        XCTAssertTrue(errors.isEmpty, "concurrent generations failed: \(errors)")
        XCTAssertEqual(coldFlags.count, 4)
        XCTAssertEqual(coldFlags.filter { $0 }.count, 1,
                       "exactly one concurrent caller may report a cold start")
    }

    /// Regression (Copilot review, PR #33): a prompt whose prefill
    /// exceeds the old 512-token decode batch must still generate.
    func testPrefillLongerThanOldBatchSize() throws {
        guard ModelRuntime.isRuntimeLinked else {
            throw XCTSkip("llama.xcframework not fetched; run Scripts/setup-model-spike.sh")
        }
        guard let path = ProcessInfo.processInfo.environment["EARNPLAY_MODEL_PATH"],
              !path.isEmpty else {
            throw XCTSkip("EARNPLAY_MODEL_PATH not set; real-inference check skipped")
        }
        let runtime = ModelRuntime(modelPath: URL(fileURLWithPath: path))
        // ~800 tokens of prompt: beyond the old n_batch = 512, inside
        // the 2048-token context.
        let longPrompt = String(repeating: "The quick brown fox jumps over the lazy dog. ",
                                count: 80)
            + "\nIn one short sentence, what animal jumps?"
        let result = try runtime.generate(prompt: longPrompt, maxTokens: 8)
        XCTAssertFalse(result.response.isEmpty)
    }
}
