import XCTest
import EarnPlayCore
@testable import EarnPlay

/// Issue #63 fix 3 — a durable `SessionLogQueue.enqueue` from the
/// practice engine must fire `onSessionEnqueued` (production wires it to
/// the shared sync service's `notifySessionEnqueued()`), exactly once per
/// durable finish and never for a failed enqueue or a no-op finish.
final class SessionSyncNotifyAppTests: XCTestCase {

    private final class FakeClock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private final class Counter {
        var count = 0
    }

    private struct FailWrite: Error {}

    private func tempDir(_ tag: String) -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue63-notify-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: seconds)
    }

    private func engine(queue: SessionLogQueue, counter: Counter, clock: FakeClock) -> DemoTutorEngine {
        let deps = PracticeRecordingDependencies(
            makeSessionId: { "test-notify-1" },
            logger: DecisionLogger(directory: tempDir("log")),
            queue: queue,
            makeScorer: { EffortScorer() },
            policyVersion: { 7 },
            now: { clock.now },
            onSessionEnqueued: { counter.count += 1 })
        return DemoTutorEngine(recording: deps)
    }

    /// A finished session fires the hook exactly once; a second (no-op)
    /// finish fires nothing more.
    func testDurableFinishFiresHookOnce() {
        let t0: TimeInterval = 5_000_000
        let clock = FakeClock(date(t0))
        let counter = Counter()
        let queue = SessionLogQueue(directory: tempDir("queue"))
        let engine = engine(queue: queue, counter: counter, clock: clock)

        _ = engine.startSession()
        clock.now = date(t0 + 10)
        _ = engine.submitAnswer("56") // Q1 correct.
        let log = engine.finishRecordingSession(at: date(t0 + 20))
        XCTAssertNotNil(log)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(queue.pending().count, 1)

        XCTAssertNil(engine.finishRecordingSession(at: date(t0 + 30)))
        XCTAssertEqual(counter.count, 1, "no-op finish must not re-fire")
    }

    /// A failed enqueue fires nothing; the healed retry fires once.
    func testFailedEnqueueFiresNothingUntilRetry() {
        let t0: TimeInterval = 6_000_000
        let clock = FakeClock(date(t0))
        let counter = Counter()
        var fail = true
        let queue = SessionLogQueue(directory: tempDir("queue"), dataWriter: { _, _ in
            if fail { throw FailWrite() }
        })
        let engine = engine(queue: queue, counter: counter, clock: clock)

        _ = engine.startSession()
        clock.now = date(t0 + 10)
        _ = engine.submitAnswer("56") // Q1 correct.
        XCTAssertNil(engine.finishRecordingSession(at: date(t0 + 20)))
        XCTAssertEqual(counter.count, 0, "failed enqueue must not fire")

        fail = false
        XCTAssertNotNil(engine.finishRecordingSession(at: date(t0 + 99)))
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(queue.pending().count, 1)
    }

    /// Finishing with no session (or recording disabled) fires nothing.
    func testNoSessionFiresNothing() {
        let counter = Counter()
        let idle = engine(queue: SessionLogQueue(directory: tempDir("queue")),
                          counter: counter, clock: FakeClock(date(0)))
        XCTAssertNil(idle.finishRecordingSession())
        XCTAssertEqual(counter.count, 0)
    }
}
