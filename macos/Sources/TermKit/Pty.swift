import CPty
import Darwin
import Foundation

public enum PtyError: Error, Equatable {
    case spawnFailed(errno: Int32)
}

/// A child process on a pseudo terminal.
public final class Pty {
    public let pid: pid_t
    public let masterFd: Int32
    private var reader: Thread?
    private let stateLock = NSLock()
    private var exited = false
    private let writeQueue = DispatchQueue(label: "pty-writer", qos: .userInteractive)

    /// True once the child has been reaped. Writes, resizes and hangups
    /// after that are ignored, so a recycled pid or descriptor is never hit.
    public var hasExited: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return exited
    }

    private func markExited() {
        stateLock.lock()
        exited = true
        stateLock.unlock()
    }

    /// Spawns `program` with `arguments` (argv[0] included) and `environment`.
    public init(program: String, arguments: [String], environment: [String: String], cols: Int, rows: Int) throws {
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let fd = cpty_spawn(program, argv, envp, UInt16(clamping: cols), UInt16(clamping: rows), &pid)
        if fd < 0 {
            throw PtyError.spawnFailed(errno: errno)
        }
        self.pid = pid
        self.masterFd = fd
    }

    /// The user's login shell, or zsh.
    public static var loginShell: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return shell.isEmpty ? "/bin/zsh" : shell
    }

    /// Environment for a child: the app's own plus the terminal identity.
    public static func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "term"
        env.removeValue(forKey: "TERM_PROBE")
        return env
    }

    /// Starts a thread that reads output until the child closes the
    /// terminal. `onData` runs on that thread with a buffer that is only
    /// valid during the call. `onExit` runs once, after the child is reaped.
    public func startReading(onData: @escaping (UnsafeRawBufferPointer) -> Void, onExit: @escaping () -> Void) {
        let fd = masterFd
        let pid = self.pid
        let thread = Thread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    buffer.withUnsafeBytes { onData(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                    continue
                } else {
                    break
                }
            }
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            self?.markExited()
            _ = Darwin.close(fd)
            onExit()
        }
        thread.name = "pty-reader"
        thread.qualityOfService = .userInteractive
        reader = thread
        thread.start()
    }

    /// Queues `bytes` for the child. Writes run on one serial queue, so a
    /// child that stops reading blocks only that queue, never the caller
    /// or the reader thread, and bytes keep their order.
    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, !hasExited else { return }
        writeQueue.async { [self] in writeNow(bytes) }
    }

    private func writeNow(_ bytes: [UInt8]) {
        guard !hasExited else { return }
        bytes.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(masterFd, p, left)
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return
                }
                left -= n
                p += n
            }
        }
    }

    public func resize(cols: Int, rows: Int) {
        guard !hasExited else { return }
        _ = cpty_resize(masterFd, UInt16(clamping: cols), UInt16(clamping: rows))
    }

    /// Hangs up the child. The reader thread closes the master once the
    /// child's side goes away; closing it here would deadlock against the
    /// blocked read on macOS.
    public func close() {
        guard !hasExited else { return }
        kill(pid, SIGHUP)
    }
}
