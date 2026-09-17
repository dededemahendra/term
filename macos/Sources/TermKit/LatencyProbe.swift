import CPty
import Foundation
import QuartzCore

/// Measures keystroke to presented frame, and process start to first
/// frame, when `TERM_PROBE` is set. Reports to standard error.
public final class LatencyProbe {
    public static let enabled = ProcessInfo.processInfo.environment["TERM_PROBE"] != nil
    private var pendingKey: TimeInterval?
    private var samples: [Double] = []
    private var commitSamples: [Double] = []
    private var reportedStartup = false
    private let lock = NSLock()

    public init() {}

    private static let processStart = cpty_process_start_uptime()

    /// Logs how long after process start `label` was reached.
    public static func mark(_ label: String) {
        guard enabled else { return }
        log(String(format: "mark %@: %.1f ms", label, (CACurrentMediaTime() - processStart) * 1000))
    }

    public func keyDown(at timestamp: TimeInterval) {
        guard LatencyProbe.enabled else { return }
        lock.lock()
        if pendingKey == nil { pendingKey = timestamp }
        lock.unlock()
    }

    /// Called when a frame's commands were handed to the GPU; measures
    /// the terminal's own pipeline without the display's refresh wait.
    public func frameCommitted(at time: TimeInterval) {
        lock.lock()
        if let key = pendingKey { commitSamples.append((time - key) * 1000) }
        lock.unlock()
    }

    public func framePresented(at time: TimeInterval) {
        lock.lock()
        if !reportedStartup, LatencyProbe.enabled {
            reportedStartup = true
            let start = cpty_process_start_uptime()
            if start > 0 {
                LatencyProbe.log(String(format: "startup: %.1f ms (process start to first frame)", (time - start) * 1000))
            }
        }
        if let key = pendingKey {
            samples.append((time - key) * 1000)
            pendingKey = nil
            if samples.count % 50 == 0 { reportLocked() }
        }
        lock.unlock()
    }

    public func report() {
        lock.lock()
        reportLocked()
        lock.unlock()
    }

    private func reportLocked() {
        guard !samples.isEmpty else { return }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        let commits = commitSamples.sorted()
        let commitMedian = commits.isEmpty ? 0 : commits[commits.count / 2]
        LatencyProbe.log(String(format: "latency: n=%d key-to-present median=%.2f ms p99=%.2f ms max=%.2f ms; key-to-commit median=%.2f ms",
                                sorted.count, median, p99, sorted.last!, commitMedian))
    }

    public static func log(_ line: String) {
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
    }
}
