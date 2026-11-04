import Foundation
import XCTest
@testable import EarnPlayCore

/// Issue #87 fix round 3 — `ChildSyncService.onPolicyApplied` fires once
/// per accepted policy update (the refresh trigger the child app's
/// installed state observes without a relaunch), and stays silent when
/// the update changes nothing.
final class SyncPolicyAppliedTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncPolicyAppliedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    private func dir(_ name: String) -> URL { directory.appendingPathComponent(name, isDirectory: true) }

    private func childService() -> ChildSyncService {
        let (_, ct, _) = InMemorySyncTransport.pair()
        let child = ChildSyncService(policyStore: PolicyStore(directory: dir("child-store")),
                                     sessionQueue: SessionLogQueue(directory: dir("child-queue")),
                                     transport: ct)
        child.start()
        return child
    }

    /// An accepted update fires the hook once with the applied policy.
    func testAppliedPolicyFiresHookOnce() throws {
        let child = childService()
        var fired: [Policy] = []
        child.onPolicyApplied = { fired.append($0) }
        var update = Policy.defaultPolicy.withVersion(1)
        update.unlockDurations = UnlockDurations(practiceMinutes: 45, tradeMinutes: 15)
        child.handleReceived(try SyncMessageCodec.encode(.policyUpdate(update)))
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.version, 1)
        XCTAssertEqual(fired.first?.unlockDurations.practiceMinutes, 45)
    }

    /// A stale version is discarded (and acked) without firing: nothing
    /// changed, so no refresh is owed.
    func testStalePolicyStaysSilent() throws {
        let child = childService()
        var fired: [Policy] = []
        child.onPolicyApplied = { fired.append($0) }
        child.handleReceived(
            try SyncMessageCodec.encode(.policyUpdate(Policy.defaultPolicy.withVersion(2))))
        XCTAssertEqual(fired.count, 1)
        child.handleReceived(
            try SyncMessageCodec.encode(.policyUpdate(Policy.defaultPolicy.withVersion(1))))
        XCTAssertEqual(fired.count, 1, "stale versions must not fire the hook")
        XCTAssertEqual(child.policyStore.storedVersion, 2)
    }
}
