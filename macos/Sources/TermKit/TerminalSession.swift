import Foundation

/// A terminal plus the process on its pseudo terminal. Output arrives on
/// the reader thread and is parsed there; the main thread is only told
/// that something changed.
public final class TerminalSession {
    public let terminal: Terminal
    public let pty: Pty
    public let config: Config
    /// Runs on the main thread after output arrived, at most once per
    /// pending notification.
    public var onOutput: (() -> Void)?
    /// Runs on the main thread once the child has exited.
    public var onExit: (() -> Void)?
    private let notifyLock = NSLock()
    private var notifyPending = false

    /// `command` replaces the login shell (argv, program first).
    public init(config: Config, command: [String]?, cols: Int, rows: Int) throws {
        self.config = config
        terminal = Terminal(cols: cols, rows: rows, scrollback: config.scrollback)
        let program: String
        let arguments: [String]
        if let command, let first = command.first {
            program = first
            arguments = command
        } else {
            program = config.shell ?? Pty.loginShell
            arguments = ["-" + (program as NSString).lastPathComponent]
        }
        pty = try Pty(program: program, arguments: arguments, environment: Pty.childEnvironment(), cols: cols, rows: rows)
        LatencyProbe.mark("shell spawned")
    }

    public func start() {
        pty.startReading(onData: { [weak self] bytes in
            guard let self else { return }
            self.terminal.feed(bytes)
            let replies = self.terminal.drainResponses()
            if !replies.isEmpty { self.pty.write(replies) }
            self.notifyLock.lock()
            let already = self.notifyPending
            self.notifyPending = true
            self.notifyLock.unlock()
            if !already {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.notifyLock.lock()
                    self.notifyPending = false
                    self.notifyLock.unlock()
                    self.onOutput?()
                }
            }
        }, onExit: { [weak self] in
            DispatchQueue.main.async { self?.onExit?() }
        })
    }

    public func write(_ bytes: [UInt8]) {
        pty.write(bytes)
    }

    public func write(_ text: String) {
        pty.write(Array(text.utf8))
    }

    /// Pastes text: newlines become carriage returns, and bracketed paste
    /// markers wrap it when the program asked for them.
    public func paste(_ text: String) {
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if terminal.modes.bracketed_paste {
            write("\u{1B}[200~" + normalised + "\u{1B}[201~")
        } else {
            write(normalised)
        }
    }

    public func resize(cols: Int, rows: Int) {
        terminal.resize(cols: cols, rows: rows)
        pty.resize(cols: cols, rows: rows)
    }

    public func close() {
        pty.close()
    }
}
