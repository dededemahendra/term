import AppKit
import Metal
import QuartzCore

/// The terminal surface: a Metal layer driven by the renderer, plus
/// keyboard, text input, mouse and scroll handling.
public final class TerminalView: NSView, NSTextInputClient {
    public let session: TerminalSession
    public let config: Config
    public let palette: Palette
    public let probe = LatencyProbe()
    public var defaultTitle = "term"

    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice
    private var atlas: GlyphAtlas!
    private var atlasScale: CGFloat = 0
    private var atlasFontSize: CGFloat = 0
    private var renderer: Renderer!
    private var scheduler: FrameScheduler!
    private var fontSize: CGFloat
    private var scale: CGFloat = 2
    private var cols = 0
    private var rows = 0
    private var markedText = ""
    private var lastTitle = ""
    private var scrollAccumulator: CGFloat = 0
    private var blinkTimer: Timer?
    private var probeTimer: Timer?
    private var probeKeysLeft = 0

    deinit {
        blinkTimer?.invalidate()
        probeTimer?.invalidate()
    }

    public init(session: TerminalSession, config: Config, device: MTLDevice) {
        self.session = session
        self.config = config
        palette = Palette(config: config)
        fontSize = CGFloat(config.fontSize)
        self.device = device
        super.init(frame: .zero)
        wantsLayer = true
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.displaySyncEnabled = false
        metalLayer.presentsWithTransaction = false
        metalLayer.isOpaque = true
        metalLayer.framebufferOnly = true
        rebuildAtlas()
        scheduler = FrameScheduler { [weak self] in self?.renderFrame() }
        session.onOutput = { [weak self] in self?.requestFrame() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    public override func makeBackingLayer() -> CALayer { metalLayer }
    public override var acceptsFirstResponder: Bool { true }
    public override var isOpaque: Bool { true }
    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() {}

    public var terminal: Terminal { session.terminal }
    public var cellSize: CGSize { CGSize(width: CGFloat(atlas.cellWidth) / scale, height: CGFloat(atlas.cellHeight) / scale) }

    // MARK: Layout and rendering

    /// Builds the atlas for the current scale and font size, once per change.
    private func rebuildAtlas() {
        let newScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if atlas != nil, newScale == atlasScale, fontSize == atlasFontSize { return }
        scale = newScale
        atlasScale = newScale
        atlasFontSize = fontSize
        metalLayer.contentsScale = scale
        let warn: (String) -> Void = { LatencyProbe.log($0) }
        atlas = GlyphAtlas(device: device, fontName: config.font, pointSize: fontSize, scale: scale,
                           lineHeight: CGFloat(config.lineHeight), warn: warn)
        LatencyProbe.mark("atlas built")
        if renderer == nil {
            renderer = try! Renderer(device: device, pixelFormat: .bgra8Unorm, atlas: atlas, palette: palette,
                                     paddingPixels: Float(config.padding * scale),
                                     library: Renderer.bundledLibrary(device: device))
            LatencyProbe.mark("pipeline built")
        } else {
            renderer.replaceAtlas(atlas)
            renderer.paddingPixels = Float(config.padding * scale)
        }
        switch config.cursorStyle {
        case .block: renderer.cursorShapeOverride = nil
        case .underline: renderer.cursorShapeOverride = 1
        case .bar: renderer.cursorShapeOverride = 2
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuildAtlas()
        updateGrid()
    }

    public override func layout() {
        super.layout()
        updateGrid()
    }

    private func updateGrid() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        metalLayer.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
        let pad = CGFloat(config.padding)
        let newCols = max(1, Int((size.width - 2 * pad) * scale / CGFloat(atlas.cellWidth)))
        let newRows = max(1, Int((size.height - 2 * pad) * scale / CGFloat(atlas.cellHeight)))
        if newCols != cols || newRows != rows {
            cols = newCols
            rows = newRows
            session.resize(cols: cols, rows: rows)
        }
        renderer.gridChanged(cols: cols, rows: rows)
        requestFrame()
    }

    public func requestFrame() {
        scheduler.requestFrame()
    }

    private var firstFrame = true

    private func renderFrame() {
        renderer.update(from: terminal)
        if firstFrame { firstFrame = false; LatencyProbe.mark("first frame") }
        guard let drawable = metalLayer.nextDrawable() else { return }
        renderer.render(to: drawable) { [probe] time in probe.framePresented(at: time) }
        probe.frameCommitted(at: CACurrentMediaTime())
        let title = terminal.title
        if title != lastTitle {
            lastTitle = title
            window?.title = title.isEmpty ? defaultTitle : title
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        rebuildAtlas()
        updateGrid()
        NotificationCenter.default.addObserver(self, selector: #selector(becameKey), name: NSWindow.didBecomeKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(resignedKey), name: NSWindow.didResignKeyNotification, object: window)
        startProbeIfRequested()
    }

    @objc private func becameKey() {
        if terminal.modes.focus_events { session.write("\u{1B}[I") }
        startBlink()
    }

    @objc private func resignedKey() {
        if terminal.modes.focus_events { session.write("\u{1B}[O") }
        stopBlink()
    }

    private func startBlink() {
        guard config.cursorBlink, blinkTimer == nil else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.renderer.cursorHidden.toggle()
            self.requestFrame()
        }
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        renderer.cursorHidden = false
        requestFrame()
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        probe.keyDown(at: event.timestamp)
        terminal.scrollViewport(by: Int.min / 2)
        let input = KeyInput(characters: event.characters ?? "",
                             charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                             keyCode: event.keyCode, modifiers: TerminalView.modifiers(of: event))
        if let bytes = KeyEncoder.encode(input, modes: terminal.modes, altIsMeta: config.altIsMeta) {
            send(bytes)
        } else {
            interpretKeyEvents([event])
        }
    }

    static func modifiers(of event: NSEvent) -> KeyModifiers {
        var m: KeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { m.insert(.shift) }
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }

    private func send(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        session.write(bytes)
    }

    // MARK: NSTextInputClient

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        markedText = ""
        send(Array(text.utf8))
    }

    public override func doCommand(by selector: Selector) {
        // Control and function keys never reach here: keyDown encodes them first.
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }

    public func unmarkText() { markedText = "" }
    public func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    public func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: markedText.utf16.count)
    }
    public func hasMarkedText() -> Bool { !markedText.isEmpty }
    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    public func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    public func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let c = terminal.cursor
        let pad = CGFloat(config.padding)
        let rect = NSRect(x: pad + CGFloat(c.col) * cellSize.width, y: pad + CGFloat(c.row) * cellSize.height,
                          width: cellSize.width, height: cellSize.height)
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    // MARK: Mouse

    private func cell(at point: NSPoint) -> (col: Int, row: Int) {
        let pad = CGFloat(config.padding)
        let col = Int(((point.x - pad) / cellSize.width).rounded(.down))
        let row = Int(((point.y - pad) / cellSize.height).rounded(.down))
        return (min(max(col, 0), max(cols - 1, 0)), min(max(row, 0), max(rows - 1, 0)))
    }

    private func reporting(_ event: NSEvent) -> Bool {
        terminal.modes.mouse != 0 && !event.modifierFlags.contains(.shift)
    }

    private func report(_ button: MouseButton, event: NSEvent, pressed: Bool, motion: Bool = false) {
        let modes = terminal.modes
        if modes.mouse == 1 && (!pressed || motion) { return }
        if motion && modes.mouse < 3 { return }
        let (col, row) = cell(at: convert(event.locationInWindow, from: nil))
        send(MouseEncoder.encode(button: button, col: col, row: row, pressed: pressed, motion: motion,
                                 modifiers: TerminalView.modifiers(of: event), sgr: modes.mouse_sgr))
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let (col, row) = cell(at: convert(event.locationInWindow, from: nil))
        if event.modifierFlags.contains(.command) {
            openURL(col: col, row: row)
            return
        }
        if reporting(event) {
            report(.left, event: event, pressed: true)
            return
        }
        let mode: SelectionMode = event.clickCount >= 3 ? .line : (event.clickCount == 2 ? .word : .normal)
        terminal.selectionStart(col: col, row: row, mode: mode)
        requestFrame()
    }

    public override func mouseDragged(with event: NSEvent) {
        if reporting(event) {
            report(.left, event: event, pressed: true, motion: true)
            return
        }
        let (col, row) = cell(at: convert(event.locationInWindow, from: nil))
        terminal.selectionExtend(col: col, row: row)
        requestFrame()
    }

    public override func mouseUp(with event: NSEvent) {
        if reporting(event) {
            report(.left, event: event, pressed: false)
            return
        }
        if config.copyOnSelect { copySelection() }
    }

    public override func rightMouseDown(with event: NSEvent) {
        if reporting(event) { report(.right, event: event, pressed: true) }
    }

    public override func rightMouseUp(with event: NSEvent) {
        if reporting(event) { report(.right, event: event, pressed: false) }
    }

    public override func otherMouseDown(with event: NSEvent) {
        if reporting(event) { report(.middle, event: event, pressed: true) }
    }

    public override func otherMouseUp(with event: NSEvent) {
        if reporting(event) { report(.middle, event: event, pressed: false) }
    }

    public override func scrollWheel(with event: NSEvent) {
        let modes = terminal.modes
        let lineHeight = cellSize.height
        var delta = event.scrollingDeltaY
        if !event.hasPreciseScrollingDeltas { delta *= lineHeight }
        scrollAccumulator += delta
        let lines = Int((scrollAccumulator / lineHeight).rounded(.towardZero))
        guard lines != 0 else { return }
        scrollAccumulator -= CGFloat(lines) * lineHeight
        if reporting(event) {
            let button: MouseButton = lines > 0 ? .wheelUp : .wheelDown
            for _ in 0..<abs(lines) { report(button, event: event, pressed: true) }
        } else if modes.alt_screen {
            let key = lines > 0 ? "\u{1B}[A" : "\u{1B}[B"
            send(Array(String(repeating: key, count: abs(lines)).utf8))
        } else {
            terminal.scrollViewport(by: lines)
            requestFrame()
        }
    }

    private func openURL(col: Int, row: Int) {
        var cells: [UInt64] = []
        terminal.copyGrid(into: &cells)
        let start = row * cols
        let line = String(String.UnicodeScalarView(cells[start..<(start + cols)].map { raw -> Unicode.Scalar in
            let cell = Cell(raw: raw)
            return cell.flags.contains(.wideSpacer) ? " " : cell.scalar
        }))
        if let url = UrlDetector.url(in: line, at: col), let parsed = URL(string: url) {
            NSWorkspace.shared.open(parsed)
        }
    }

    // MARK: Actions

    @objc public func copy(_ sender: Any?) { copySelection() }

    private func copySelection() {
        let text = terminal.selectionText
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc public func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) {
            terminal.scrollViewport(by: Int.min / 2)
            session.paste(text)
        }
    }

    public override func selectAll(_ sender: Any?) {
        terminal.selectionStart(col: 0, row: 0, mode: .normal)
        terminal.selectionExtend(col: cols - 1, row: rows - 1)
        requestFrame()
    }

    @objc public func increaseFontSize(_ sender: Any?) { setFontSize(fontSize + 1) }
    @objc public func decreaseFontSize(_ sender: Any?) { setFontSize(fontSize - 1) }
    @objc public func resetFontSize(_ sender: Any?) { setFontSize(CGFloat(config.fontSize)) }

    private func setFontSize(_ size: CGFloat) {
        fontSize = min(max(size, 4), 96)
        rebuildAtlas()
        updateGrid()
    }

    // MARK: Probe support

    /// `TERM_PROBE_KEYS=n` types n synthetic keys, prints latency stats
    /// and quits. `TERM_SCREENSHOT=path` captures the window and quits.
    private func startProbeIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let keys = env["TERM_PROBE_KEYS"].flatMap(Int.init), keys > 0, probeTimer == nil {
            probeKeysLeft = keys
            probeTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
                guard let self, let window = self.window else { return }
                if self.probeKeysLeft == 0 {
                    self.probeTimer?.invalidate()
                    self.probe.report()
                    NSApp.terminate(nil)
                    return
                }
                self.probeKeysLeft -= 1
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: "a",
                                                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0) {
                    self.keyDown(with: event)
                }
            }
        }
        if let path = env["TERM_SCREENSHOT"], let window {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                task.arguments = ["-l", "\(window.windowNumber)", "-x", "-o", path]
                try? task.run()
                task.waitUntilExit()
                NSApp.terminate(nil)
            }
        }
    }
}
