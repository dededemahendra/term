import AppKit

/// One window, one shell.
public final class TerminalWindowController: NSWindowController, NSWindowDelegate {
    public static var open: [TerminalWindowController] = []
    public let session: TerminalSession
    public let terminalView: TerminalView

    public init(config: Config, command: [String]?) throws {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let m = GlyphAtlas.metrics(fontName: config.font, pointSize: CGFloat(config.fontSize), scale: scale,
                                   lineHeight: CGFloat(config.lineHeight))
        let pad = CGFloat(config.padding)
        let size = NSSize(width: CGFloat(80 * m.cellWidth) / scale + 2 * pad,
                          height: CGFloat(24 * m.cellHeight) / scale + 2 * pad)
        session = try TerminalSession(config: config, command: command, cols: 80, rows: 24)
        terminalView = TerminalView(session: session, config: config)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "term"
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        window.contentView = terminalView
        window.center()
        super.init(window: window)
        window.delegate = self
        session.onExit = { [weak self] in self?.close() }
        session.start()
        TerminalWindowController.open.append(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    public func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(terminalView)
    }

    public func windowWillClose(_ notification: Notification) {
        session.close()
        TerminalWindowController.open.removeAll { $0 === self }
    }
}
