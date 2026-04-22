import XCTest
@testable import Diriger

final class SmokeTests: XCTestCase {
    func test_ruleKindHasExpectedCases() {
        XCTAssertEqual(RuleKind.allCases.count, 3)
    }
}
