import AppKit
import SeanceCore
import SeanceMCP

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = TabStore()
    private let attachments = SessionAttachments()
    private let attention = AgentAttention()
    private var server: TabMCPServer?
    private var runtime: GhosttyRuntime?
    private var agentMonitor: Task<Void, Never>?
    private var windows: [TerminalWindow] = []

    private var active: TerminalWindow? {
        windows.first { $0.window === NSApp.keyWindow || $0.window === NSApp.mainWindow } ?? windows.last
    }

    private func owner(of id: TabID?) -> TerminalWindow? {
        guard let id else { return active }
        return windows.first { $0.surfaces[id] != nil }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let server = try TabMCPServer(store: store, attachments: attachments)
            server.onClaudeHook = { [attachments, attention] kind, tab, session in
                let key = SessionKey(providerID: "claude", sessionID: session.uuidString)
                switch kind {
                case .start: attachments.attach(key, to: tab)
                case .end: attachments.detach(key, from: tab)
                case .permission, .question, .elicitation:
                    if attention.shouldPlay(for: tab) { NSSound.beep() }
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
            agentMonitor = Task.detached(priority: .utility) { [attachments] in
                while !Task.isCancelled {
                    let snapshot = ForegroundAgents.snapshot(parent: getpid())
                    await attachments.updateForeground(snapshot)
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            runtime.desktopNotification = { [attachments, attention] tab, title, body in
                guard AgentAttention.isCodexPrompt(title: title, body: body, providers: attachments.providers(in: tab))
                else { return false }
                if attention.shouldPlay(for: tab) { NSSound.beep() }
                return true
            }
            runtime.childExited = { [attachments] id in attachments.close(id) }
            runtime.newTab = { [weak self] id in self?.owner(of: id)?.newHorizontalTab(from: id) }
            runtime.newWindow = { [weak self] in self?.newWindow() }
            runtime.goToTab = { [weak self] id, destination in
                self?.owner(of: id)?.goToTab(from: id, destination: destination) ?? false
            }
            runtime.closeTab = { [weak self] id in self?.owner(of: id)?.closeTab(id) }
            let first = try createWindow()
            NSApp.activate(ignoringOtherApps: true)
            FullDiskAccess.present(in: first.window, atLaunch: true)
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil)
        }
    }

    private func createWindow() throws -> TerminalWindow {
        guard let server, let runtime else { throw TerminalError.initialization }
        let controller = TerminalWindow(runtime: runtime, server: server, attachments: attachments)
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        do {
            try controller.openTerminal(directory: FileManager.default.homeDirectoryForCurrentUser)
        } catch {
            controller.shutdown()
            throw error
        }
        if let previous = active {
            var frame = controller.window.frame
            frame.origin = NSPoint(x: previous.window.frame.minX + 24,
                                   y: previous.window.frame.maxY - 24 - frame.height)
            // Start again from the screen's top left once the cascade would leave it.
            if let screen = previous.window.screen?.visibleFrame, !screen.contains(frame) {
                frame.origin = NSPoint(x: screen.minX, y: screen.maxY - frame.height)
            }
            controller.window.setFrameOrigin(frame.origin)
        } else {
            controller.window.center()
        }
        windows.append(controller)
        controller.window.makeKeyAndOrderFront(nil)
        return controller
    }

    @objc func newWindow() {
        do { _ = try createWindow() }
        catch { NSAlert(error: error).runModal() }
    }
    @objc func newSession() { active?.newSession() }
    // A sheet leaves these menu shortcuts live; they must not act on the window beneath it.
    @objc func newTab() {
        if let active, active.window.attachedSheet == nil { active.newHorizontalTab() }
    }
    @objc func closeCurrentTab() {
        if let active, active.window.attachedSheet == nil { active.closeCurrentTab() }
    }
    @objc func reviewFullDiskAccess() {
        if let window = active?.window { FullDiskAccess.present(in: window) }
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
    func applicationWillTerminate(_ notification: Notification) {
        agentMonitor?.cancel()
        for controller in windows { controller.shutdown() }
        server?.stop()
        runtime?.shutdown()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum SessionLaunchError: LocalizedError {
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
let updateChecker = UpdateChecker()
applicationItem.submenu?.addItem(withTitle: "Check for Updates…", action: #selector(UpdateChecker.check), keyEquivalent: "").target = updateChecker
applicationItem.submenu?.addItem(withTitle: "Full Disk Access…", action: #selector(AppDelegate.reviewFullDiskAccess), keyEquivalent: "").target = delegate
applicationItem.submenu?.addItem(.separator())
applicationItem.submenu?.addItem(withTitle: "Quit Seance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
let tabMenu = NSMenu(title: "Tab")
tabMenu.addItem(withTitle: "New Session…", action: #selector(AppDelegate.newSession), keyEquivalent: "n").target = delegate
let newWindow = tabMenu.addItem(withTitle: "New Window", action: #selector(AppDelegate.newWindow), keyEquivalent: "n")
newWindow.keyEquivalentModifierMask = [.option, .command]
newWindow.target = delegate
tabMenu.addItem(withTitle: "New Tab", action: #selector(AppDelegate.newTab), keyEquivalent: "t").target = delegate
tabMenu.addItem(withTitle: "Close Tab", action: #selector(AppDelegate.closeCurrentTab), keyEquivalent: "w").target = delegate
menu.addItem(withTitle: "Tab", action: nil, keyEquivalent: "").submenu = tabMenu
app.mainMenu = menu
app.run()
