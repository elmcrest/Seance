import AppKit
import Observation
import SeanceCore
import SeanceMCP
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = TabStore()
    private let attachments = SessionAttachments()
    private var server: TabMCPServer?
    private var runtime: GhosttyRuntime?
    private var window: NSWindow?
    private let terminalContainer = NSView()
    private var surfaces: [TabID: TerminalView] = [:]
    private var visibleID: TabID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let server = try TabMCPServer(store: store, attachments: attachments)
            server.onClaudeHook = { [attachments] kind, tab, session in
                let key = SessionKey(providerID: "claude", sessionID: session.uuidString)
                switch kind {
                case .start: attachments.attach(key, to: tab)
                case .end: attachments.detach(key, from: tab)
                }
            }
            try server.start()
            self.server = server
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/seance")
            let runtime = try GhosttyRuntime(store: store, environment: [
                "SEANCE_SOCKET_PATH": server.socketPath,
                "SEANCE_HELPER": helper.path,
            ])
            self.runtime = runtime
            runtime.childExited = { [attachments] id in attachments.close(id) }
            runtime.newTab = { [weak self] in self?.newTab() }
            runtime.closeTab = { [weak self] id in self?.closeTab(id) }

            let split = NSSplitViewController()
            let sidebar = SampleSidebar(
                store: store, attachments: attachments,
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
            FullDiskAccess.present(in: window, atLaunch: true)
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
    }

    @discardableResult
    func openTerminal(
        directory: URL, resume: (session: SessionKey, launch: SessionLaunch)? = nil
    ) throws -> TabID {
        guard let runtime else { throw TerminalError.initialization }
        let previous = store.selectedID
        let id = store.open(directory: directory)
        do {
            if let resume {
                guard let server else { throw TerminalError.initialization }
                guard attachments.reserve(resume.session, for: id) else { throw SessionLaunchError.alreadyAttached }
                server.prepareResume(resume.launch, in: id) { [attachments] in
                    attachments.detach(resume.session, from: id)
                }
            }
            let view = try TerminalView(runtime: runtime, tab: store.tab(id), resuming: resume != nil)
            view.frame = terminalContainer.bounds
            view.autoresizingMask = [.width, .height]
            surfaces[id] = view
            terminalContainer.addSubview(view)
            focus(id)
            return id
        } catch {
            server?.forgetResume(in: id)
            attachments.close(id)
            try? store.close(id)
            if let previous { try? store.select(previous) }
            throw error
        }
    }

    @objc func newTab() {
        guard let window else { return }
        presentNewTabPicker(in: window, attachments: attachments, newTerminal: { [weak self] in
            self?.newShell()
        }, resume: { [weak self] session, launch in
            do {
                try self?.openTerminal(directory: launch.directory, resume: (session.id, launch))
            } catch {
                NSAlert(error: error).runModal()
            }
        })
    }

    private func newShell() {
        let directory = store.selectedID.flatMap { try? store.tab($0).directory } ?? FileManager.default.homeDirectoryForCurrentUser
        do { try openTerminal(directory: directory) }
        catch { NSAlert(error: error).runModal() }
    }

    @objc func reviewFullDiskAccess() {
        if let window { FullDiskAccess.present(in: window) }
    }

    @objc func closeCurrentTab() {
        if let id = store.selectedID { surfaces[id]?.requestClose() }
    }

    private func closeTab(_ id: TabID) {
        guard let view = surfaces.removeValue(forKey: id) else { return }
        server?.forgetResume(in: id)
        attachments.close(id)
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
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard runtime?.needsConfirmQuit == true else { return .terminateNow }
        let quit = GhosttyRuntime.confirm("Quit Seance and end its running processes?", detail: "", action: "Quit")
        return quit ? .terminateNow : .terminateCancel
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the window quits the app, so let the quit path ask once.
        NSApp.terminate(nil)
        return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        for view in surfaces.values { view.shutdown() }
        surfaces.removeAll()
        runtime?.shutdown()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

private enum SessionLaunchError: LocalizedError {
    case alreadyAttached
    var errorDescription: String? { "This session is already open in a Seance tab." }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu()
let applicationItem = menu.addItem(withTitle: "Seance", action: nil, keyEquivalent: "")
applicationItem.submenu = NSMenu()
applicationItem.submenu?.addItem(withTitle: "Full Disk Access…", action: #selector(AppDelegate.reviewFullDiskAccess), keyEquivalent: "").target = delegate
applicationItem.submenu?.addItem(.separator())
applicationItem.submenu?.addItem(withTitle: "Quit Seance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let tabMenu = NSMenu(title: "Tab")
tabMenu.addItem(withTitle: "New Tab", action: #selector(AppDelegate.newTab), keyEquivalent: "t").target = delegate
tabMenu.addItem(withTitle: "Close Tab", action: #selector(AppDelegate.closeCurrentTab), keyEquivalent: "w").target = delegate
menu.addItem(withTitle: "Tab", action: nil, keyEquivalent: "").submenu = tabMenu
app.mainMenu = menu
app.run()
