import XCTest
@testable import TermKit

final class VersionTests: XCTestCase {
    func testVersionIsSemver() {
        // A non-empty MAJOR.MINOR.PATCH string, so a bump does not break this.
        let parts = TermKitVersion.string.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "version should be MAJOR.MINOR.PATCH, got \(TermKitVersion.string)")
        XCTAssertTrue(parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) },
                      "each version component should be numeric, got \(TermKitVersion.string)")
    }
}
