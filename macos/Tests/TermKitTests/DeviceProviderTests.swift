import Metal
import XCTest
@testable import TermKit

final class DeviceProviderTests: XCTestCase {
    func testResolveIsRepeatableAndAgreesWithADirectCreate() {
        let provider = DeviceProvider()
        let first = provider.resolve()
        let second = provider.resolve()
        XCTAssertEqual(first == nil, MTLCreateSystemDefaultDevice() == nil,
                       "the provider agrees with a direct create on whether a GPU exists")
        if let first, let second {
            XCTAssertTrue(first === second, "resolve returns the same device instance each time")
        } else {
            XCTAssertNil(first)
            XCTAssertNil(second)
        }
    }

    func testResolveBlocksUntilCreationFinishes() {
        // resolve must never return the not-yet-created state; on a machine
        // with a GPU it is non-nil the first time it is asked.
        let provider = DeviceProvider()
        if MTLCreateSystemDefaultDevice() != nil {
            XCTAssertNotNil(provider.resolve())
        }
    }
}
