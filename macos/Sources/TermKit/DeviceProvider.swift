import Metal

/// Creates the system Metal device on a background thread as early in the
/// process as possible, so its cost overlaps AppKit's own start-up rather
/// than adding to it on the main thread. `resolve()` blocks until the
/// creation finishes; it is safe from any thread and may be called any
/// number of times, always returning the same device.
public final class DeviceProvider {
    private let condition = NSCondition()
    private var resolved = false
    private var device: MTLDevice?

    public convenience init() {
        self.init(factory: { MTLCreateSystemDefaultDevice() })
    }

    /// Runs `factory` on a background thread to produce the device. The
    /// default initialiser uses the system device; tests inject a factory
    /// to exercise the wait path deterministically.
    init(factory: @escaping () -> MTLDevice?) {
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            let created = factory()
            condition.lock()
            device = created
            resolved = true
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Blocks until the background creation finishes, then returns the
    /// device, or nil when the machine has no Metal capable GPU.
    public func resolve() -> MTLDevice? {
        condition.lock()
        while !resolved { condition.wait() }
        let result = device
        condition.unlock()
        return result
    }
}
