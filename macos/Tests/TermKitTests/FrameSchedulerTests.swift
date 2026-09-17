import XCTest
@testable import TermKit

final class FrameSchedulerTests: XCTestCase {
    func testRendersImmediatelyThenCoalesces() {
        var now: TimeInterval = 10
        var scheduled: [(TimeInterval, () -> Void)] = []
        var renders = 0
        let scheduler = FrameScheduler(coalesce: 0.001, now: { now }, schedule: { delay, block in scheduled.append((delay, block)) },
                                       render: { renders += 1 })
        scheduler.requestFrame()
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(scheduled.count, 0)
        now += 0.0002
        scheduler.requestFrame()
        scheduler.requestFrame()
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(scheduled[0].0, 0.0008, accuracy: 1e-9)
        now += 0.0008
        scheduled[0].1()
        XCTAssertEqual(renders, 2)
        now += 0.005
        scheduler.requestFrame()
        XCTAssertEqual(renders, 3)
        XCTAssertEqual(scheduled.count, 1)
    }
}
