import Foundation
import QuartzCore

/// Renders as soon as asked, but folds requests that arrive within the
/// coalescing window into one frame. Call `requestFrame` on the main thread.
public final class FrameScheduler {
    public let coalesce: TimeInterval
    private let now: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let render: () -> Void
    private var lastRender: TimeInterval = -1
    private var pending = false

    public init(coalesce: TimeInterval = 0.001,
                now: @escaping () -> TimeInterval = { CACurrentMediaTime() },
                schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, block in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
                },
                render: @escaping () -> Void) {
        self.coalesce = coalesce
        self.now = now
        self.schedule = schedule
        self.render = render
    }

    public func requestFrame() {
        if pending { return }
        let elapsed = now() - lastRender
        if elapsed >= coalesce {
            fire()
        } else {
            pending = true
            schedule(coalesce - elapsed) { [weak self] in
                guard let self else { return }
                self.pending = false
                self.fire()
            }
        }
    }

    private func fire() {
        lastRender = now()
        render()
    }
}
