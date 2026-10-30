import Foundation
import XCTest
@testable import EarnPlayCore

/// T4.5 fix round 4 repro/fix tests (PR #61 review on 3d0b828).
/// Item 1 is verify-only (see progress log); this file covers item 2:
/// a coalesced rerun must preserve work/publish pairing — each pass
/// invokes its own publish callback with its own work's results.
final class AuditorFixRound4Tests: XCTestCase {

    // Item 2: request B arrives while A's work is running. Each pass
    // must invoke its OWN publish callback, after its OWN work, exactly
    // once — never the newer request's callback, never dropped.
    func testItem2CoalescedRerunPreservesWorkPublishPairing() {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var events: [String] = []
            func add(_ e: String) { lock.lock(); events.append(e); lock.unlock() }
            func snapshot() -> [String] { lock.lock(); defer { lock.unlock() }; return events }
        }
        let box = Box()
        let performer = AuditRunPerformer(workQueue: DispatchQueue(label: "test.audit.pairing"))
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        performer.request(work: {
            box.add("workA")
            started.signal()
            _ = release.wait(timeout: .now() + 5)
        }, publish: {
            box.add("publishA")
        })
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success, "first audit work never started")
        // B arrives while A's work is still running.
        performer.request(work: {
            box.add("workB")
        }, publish: {
            box.add("publishB")
        })
        release.signal()

        // Publishing hops to the main queue, so pump the main run loop
        // until both passes have published (or time out).
        let deadline = Date().addingTimeInterval(5)
        while box.snapshot().filter({ $0.hasPrefix("publish") }).count < 2 && Date() < deadline {
            _ = RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        // Exact pairing: each publish follows its own work, each once.
        XCTAssertEqual(box.snapshot(), ["workA", "publishA", "workB", "publishB"],
                       "each pass must invoke its own publish callback after its own work")
        XCTAssertFalse(performer.isRunning)
    }
}
