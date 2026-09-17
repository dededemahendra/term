import AppKit

/// The menu bar. Actions travel the responder chain to the view or the
/// app delegate.
public enum AppMenu {
    public static func build(appName: String = "Term") -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: appName))

        let shell = NSMenu(title: "Shell")
        shell.addItem(withTitle: "New Window", action: Selector(("newWindow:")), keyEquivalent: "n")
        shell.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(shell, title: "Shell"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Bigger", action: #selector(TerminalView.increaseFontSize(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Smaller", action: #selector(TerminalView.decreaseFontSize(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(TerminalView.resetFontSize(_:)), keyEquivalent: "0")
        view.addItem(.separator())
        let full = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        full.keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu(view, title: "View"))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
