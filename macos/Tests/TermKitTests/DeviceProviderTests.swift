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

    func testResolveBlocksUntilACreationStillRunningFinishes() {
        // A factory that sleeps proves resolve waits rather than returning
        // the not-yet-created state, regardless of whether a GPU exists.
        let start = Date()
        let provider = DeviceProvider(factory: {
            Thread.sleep(forTimeInterval: 0.2)
            return nil
        })
        let device = provider.resolve()
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.19,
                                    "resolve blocked until the slow creation finished")
        XCTAssertNil(device)
    }

    func testConcurrentResolversAllSeeTheOneDevice() {
        let provider = DeviceProvider(factory: {
            Thread.sleep(forTimeInterval: 0.05)
            return MTLCreateSystemDefaultDevice()
        })
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [MTLDevice?] = []
        for _ in 0..<16 {
            group.enter()
            DispatchQueue.global().async {
                let device = provider.resolve()
                lock.lock(); results.append(device); lock.unlock()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success, "every resolver returned")
        XCTAssertEqual(results.count, 16)
        let first = results[0]
        for device in results {
            XCTAssertEqual(device == nil, first == nil, "all resolvers agree on availability")
            if let device, let first {
                XCTAssertTrue(device === first, "all resolvers see the same device instance")
            }
        }
    }
}
