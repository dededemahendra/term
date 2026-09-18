import AppKit
import Metal
import TermKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let config: Config
    let command: [String]?
    let deviceProvider: DeviceProvider

    init(config: Config, command: [String]?, deviceProvider: DeviceProvider) {
        self.config = config
        self.command = command
        self.deviceProvider = deviceProvider
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LatencyProbe.mark("did finish launching")
        // The device was created on a background thread while AppKit started;
        // by now it is ready, so this returns at once. A nil result means no
        // Metal GPU, which the spec says to report and exit on.
        guard let device = deviceProvider.resolve() else {
            FileHandle.standardError.write("term needs a Metal capable GPU and none is available\n".data(using: .utf8)!)
            exit(1)
        }
        openWindow(command: command, device: device)
        LatencyProbe.mark("window shown")
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func newWindow(_ sender: Any?) {
        guard let device = deviceProvider.resolve() else { return }
        openWindow(command: nil, device: device)
    }

    private func openWindow(command: [String]?, device: MTLDevice) {
        do {
            let controller = try TerminalWindowController(config: config, command: command, device: device)
            controller.show()
        } catch {
            LatencyProbe.log("could not start the shell: \(error)")
            if TerminalWindowController.open.isEmpty { NSApp.terminate(nil) }
        }
    }
}

// Kick off Metal device creation before anything else, so its cost runs
// on a background thread while the main thread brings up AppKit.
let deviceProvider = DeviceProvider()
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

let config = Config.load(warn: { LatencyProbe.log($0) })
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(config: config, command: command, deviceProvider: deviceProvider)
app.delegate = delegate
app.mainMenu = AppMenu.build()
LatencyProbe.mark("app configured")
app.run()
