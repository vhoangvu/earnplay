import XCTest
@testable import EarnPlayCore

final class EarnPlayCoreTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertFalse(EarnPlayCore.version.isEmpty)
    }

    func testEffortScorerCountsMinutesAndAttempts() {
        let scorer = EffortScorer()
        XCTAssertEqual(scorer.points(activeSeconds: 300, attempts: 2), 7)
    }

    func testEffortScorerZeroesEmptySession() {
        let scorer = EffortScorer()
        XCTAssertEqual(scorer.points(activeSeconds: 0, attempts: 0), 0)
    }

    func testEffortScorerIgnoresNegativeInput() {
        let scorer = EffortScorer()
        XCTAssertEqual(scorer.points(activeSeconds: -120, attempts: -1), 0)
    }
}
