import XCTest
@testable import TermKit

final class VersionTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertEqual(TermKitVersion.string, "0.1.0")
    }
}
