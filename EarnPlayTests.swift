import XCTest
import EarnPlayCore

final class EarnPlayTests: XCTestCase {
    func testCoreLinksIntoAppTarget() {
        XCTAssertEqual(EarnPlayCore.version, "0.1.0")
    }
}
