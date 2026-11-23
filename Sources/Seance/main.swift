import AppKit
import Observation
import SeanceCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = TabStore()
    private var runtime: GhosttyRuntime?
    private var window: NSWindow?
    private let terminalContainer = NSView()
    private var surfaces: [TabID: TerminalView] = [:]
    private var visibleID: TabID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let runtime = try GhosttyRuntime(store: store, environment: [:])
            self.runtime = runtime
            runtime.newTab = { [weak self] in self?.newTab() }
            runtime.closeTab = { [weak self] id in self?.closeTab(id) }

            let split = NSSplitViewController()
            let sidebar = SampleSidebar(
                store: store,
                onNewTab: { [weak self] in self?.newTab() },
                onCloseTab: { [weak self] id in self?.surfaces[id]?.requestClose() },
                onActivateTab: { [weak self] id in self?.focus(id) }
            )
            let item = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: sidebar))
            item.minimumThickness = 150
            item.maximumThickness = 380
            split.addSplitViewItem(item)
            let content = NSViewController()
            content.view = terminalContainer
            split.addSplitViewItem(.init(viewController: content))

            let window = NSWindow(contentViewController: split)
            window.title = "Seance"
            window.setContentSize(.init(width: 920, height: 590))
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
            window.makeKeyAndOrderFront(nil)
            _ = try openTerminal(directory: FileManager.default.homeDirectoryForCurrentUser)
            observeSelection()
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
    }

    @discardableResult
    func openTerminal(directory: URL, executable: String? = nil, arguments: [String] = []) throws -> TabID {
        guard let runtime else { throw TerminalError.initialization }
        let previous = store.selectedID
        let id = store.open(directory: directory)
        do {
            let view = try TerminalView(runtime: runtime, tab: store.tab(id), executable: executable, arguments: arguments)
            view.frame = terminalContainer.bounds
            view.autoresizingMask = [.width, .height]
            surfaces[id] = view
            terminalContainer.addSubview(view)
            focus(id)
            return id
        } catch {
            try? store.close(id)
            if let previous { try? store.select(previous) }
            throw error
        }
    }

    @objc func newTab() {
        let directory = store.selectedID.flatMap { try? store.tab($0).directory } ?? FileManager.default.homeDirectoryForCurrentUser
        do { try openTerminal(directory: directory) }
        catch { NSAlert(error: error).runModal() }
    }

    @objc func closeCurrentTab() {
        if let id = store.selectedID { surfaces[id]?.requestClose() }
    }

    private func closeTab(_ id: TabID) {
        guard let view = surfaces.removeValue(forKey: id) else { return }
        try? store.close(id)
        view.removeFromSuperview()
        view.shutdown()
        if let next = store.selectedID {
            if visibleID == id { focus(next) }
        } else {
            window?.close()
        }
    }

    private func observeSelection() {
        withObservationTracking {
            _ = store.selectedID
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                if let id = self.store.selectedID, id != self.visibleID { self.focus(id) }
                self.observeSelection()
            }
        }
    }

    private func focus(_ id: TabID) {
        guard let view = surfaces[id] else { return }
        if let previous = visibleID, previous != id { surfaces[previous]?.show(false) }
        view.show(true)
        visibleID = id
        window?.makeFirstResponder(view)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        for view in surfaces.values { view.updateGeometry() }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        runtime?.setFocus(true)
    }
    func applicationDidResignActive(_ notification: Notification) {
        runtime?.setFocus(false)
    }
    func applicationWillTerminate(_ notification: Notification) {
        for view in surfaces.values { view.shutdown() }
        surfaces.removeAll()
        runtime?.shutdown()
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
let tabMenu = NSMenu(title: "Tab")
tabMenu.addItem(withTitle: "New Tab", action: #selector(AppDelegate.newTab), keyEquivalent: "t").target = delegate
tabMenu.addItem(withTitle: "Close Tab", action: #selector(AppDelegate.closeCurrentTab), keyEquivalent: "w").target = delegate
menu.addItem(withTitle: "Tab", action: nil, keyEquivalent: "").submenu = tabMenu
app.mainMenu = menu
app.run()
