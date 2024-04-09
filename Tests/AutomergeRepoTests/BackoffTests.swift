import AutomergeRepo
import XCTest

final class BackoffTests: XCTestCase {
    func testSimpleBackoff() throws {
        XCTAssertEqual(0, Backoff.delay(0, withJitter: false))
        XCTAssertEqual(1, Backoff.delay(1, withJitter: false))
        XCTAssertEqual(1, Backoff.delay(2, withJitter: false))
        XCTAssertEqual(2, Backoff.delay(3, withJitter: false))
        XCTAssertEqual(3, Backoff.delay(4, withJitter: false))
        XCTAssertEqual(610, Backoff.delay(15, withJitter: false))
        XCTAssertEqual(610, Backoff.delay(16, withJitter: false))
        XCTAssertEqual(610, Backoff.delay(100, withJitter: false))
    }

    func testWithJitterBackoff() throws {
        XCTAssertEqual(0, Backoff.delay(0, withJitter: true))
        XCTAssertEqual(1, Backoff.delay(1, withJitter: true))
        for i: UInt in 2 ... 50 {
            XCTAssertTrue(Backoff.delay(i, withJitter: true) <= 987)
            print(Backoff.delay(i, withJitter: true))
        }
    }
}
