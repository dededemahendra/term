import AppKit
import Metal
import TermKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let config: Config
    let command: [String]?

    init(config: Config, command: [String]?) {
        self.config = config
        self.command = command
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LatencyProbe.mark("did finish launching")
        openWindow(command: command)
        LatencyProbe.mark("window shown")
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func newWindow(_ sender: Any?) {
        openWindow(command: nil)
    }

    private func openWindow(command: [String]?) {
        do {
            let controller = try TerminalWindowController(config: config, command: command)
            controller.show()
        } catch {
            LatencyProbe.log("could not start the shell: \(error)")
            if TerminalWindowController.open.isEmpty { NSApp.terminate(nil) }
        }
    }
}

LatencyProbe.mark("main")
var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--version" {
    print("term \(TermKitVersion.string)")
    exit(0)
}
var command: [String]? = nil
if let e = arguments.firstIndex(of: "-e") {
    command = Array(arguments[(e + 1)...])
    if command?.isEmpty == true {
        FileHandle.standardError.write("usage: term [-e program [args...]]\n".data(using: .utf8)!)
        exit(2)
    }
}

guard MTLCreateSystemDefaultDevice() != nil else {
    FileHandle.standardError.write("term needs a Metal capable GPU and none is available\n".data(using: .utf8)!)
    exit(1)
}
let config = Config.load(warn: { LatencyProbe.log($0) })
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(config: config, command: command)
app.delegate = delegate
app.mainMenu = AppMenu.build()
LatencyProbe.mark("app configured")
app.run()
