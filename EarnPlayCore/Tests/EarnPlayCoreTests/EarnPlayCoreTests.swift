import XCTest
@testable import EarnPlayCore

final class EarnPlayCoreTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertFalse(EarnPlayCore.version.isEmpty)
    }

    // EffortScorer coverage lives in EffortScoringTests.swift (T1.4).
}
