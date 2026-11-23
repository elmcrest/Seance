import AppKit
import SeanceCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = TabStore()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let first = store.open(directory: home)
        store.open(directory: FileManager.default.temporaryDirectory)
        try? store.select(first)

        let split = NSSplitViewController()
        split.addSplitViewItem(.init(sidebarWithViewController:
            NSHostingController(rootView: SampleSidebar(store: store))))
        let placeholder = NSViewController()
        placeholder.view = NSView()
        let label = NSTextField(labelWithString: "Terminal surface pending")
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        placeholder.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: placeholder.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: placeholder.view.centerYAnchor),
        ])
        split.addSplitViewItem(.init(viewController: placeholder))

        let window = NSWindow(contentViewController: split)
        window.title = "Seance"
        window.setContentSize(.init(width: 900, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu()
let applicationItem = menu.addItem(withTitle: "Seance", action: nil, keyEquivalent: "")
applicationItem.submenu = NSMenu()
applicationItem.submenu?.addItem(withTitle: "Quit Seance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
app.mainMenu = menu
app.run()
