import AppKit
import GhosttyKit
import SeanceCore

/// Owns the single libghostty app. All handles except wakeup callbacks live on the main thread.
@MainActor
final class GhosttyRuntime {
    let store: TabStore
    let environment: [String: String]
    let pasteboard: NSPasteboard
    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    var newTab: () -> Void = {}
    var closeTab: (TabID) -> Void = { _ in }
    var childExited: (TabID) -> Void = { _ in }

    init(store: TabStore, environment: [String: String], pasteboard: NSPasteboard = .general) throws {
        self.store = store
        self.pasteboard = pasteboard
        self.environment = environment
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("ghostty") {
            setenv("GHOSTTY_RESOURCES_DIR", resources.path, 1)
        }
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS,
              let config = ghostty_config_new() else { throw TerminalError.initialization }
        self.config = config
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.wakeup_cb = wakeGhostty
        runtime.action_cb = { app, target, action in
            guard let pointer = ghostty_app_userdata(app) else { return false }
            let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(pointer).takeUnretainedValue()
            return runtime.handle(target: target, action: action)
        }
        runtime.read_clipboard_cb = { pointer, location, state in
            guard let view = TerminalView.from(pointer), let surface = view.surface else { return }
            let text = location == GHOSTTY_CLIPBOARD_STANDARD ? view.runtime.pasteboard.string(forType: .string) : nil
            ghostty_surface_complete_clipboard_request(surface, text ?? "", state, false)
        }
        runtime.confirm_read_clipboard_cb = { pointer, value, state, request in
            guard let view = TerminalView.from(pointer), let value else { return }
            let message = request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
                ? "Paste this text into the terminal?" : "Allow the terminal program to read the clipboard?"
            let text = String(cString: value)
            let allow = GhosttyRuntime.confirm(message, detail: request == GHOSTTY_CLIPBOARD_REQUEST_PASTE ? String(text.prefix(800)) : "")
            if let surface = view.surface {
                ghostty_surface_complete_clipboard_request(surface, allow ? text : "", state, true)
            }
        }
        runtime.write_clipboard_cb = { pointer, value, location, needsConfirmation in
            guard location == GHOSTTY_CLIPBOARD_STANDARD, let value, let view = TerminalView.from(pointer) else { return }
            let text = String(cString: value)
            if needsConfirmation && !GhosttyRuntime.confirm("Allow the terminal program to replace the clipboard?", detail: String(text.prefix(800))) {
                return
            }
            view.runtime.pasteboard.clearContents()
            view.runtime.pasteboard.setString(text, forType: .string)
        }
        runtime.close_surface_cb = { pointer, alive in
            guard let view = TerminalView.from(pointer) else { return }
            // Teardown must run after the call into libghostty returns.
            DispatchQueue.main.async { [weak view] in
                guard let view, view.surface != nil else { return }
                if !alive || GhosttyRuntime.confirm("Close this tab and its running process?", detail: "") {
                    view.runtime.closeTab(view.id)
                }
            }
        }
        guard let app = ghostty_app_new(&runtime, config) else {
            ghostty_config_free(config)
            self.config = nil
            throw TerminalError.initialization
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
    }

    func setFocus(_ focused: Bool) {
        if let app { ghostty_app_set_focus(app, focused) }
    }

    func shutdown() {
        if let app { self.app = nil; ghostty_app_free(app) }
        if let config { self.config = nil; ghostty_config_free(config) }
    }

    static func confirm(_ message: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Allow")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func handle(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        let view = target.tag == GHOSTTY_TARGET_SURFACE
            ? TerminalView.from(ghostty_surface_userdata(target.target.surface)) : nil
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let id = view?.id else { return false }
            try? store.updateProgramTitle(action.action.set_title.title.map(String.init(cString:)), for: id)
        case GHOSTTY_ACTION_PWD:
            guard let id = view?.id, let path = action.action.pwd.pwd else { return false }
            let directory = String(cString: path)
            if directory.hasPrefix("/") { try? store.updateDirectory(URL(fileURLWithPath: directory), for: id) }
        case GHOSTTY_ACTION_NEW_TAB:
            DispatchQueue.main.async { self.newTab() }
        case GHOSTTY_ACTION_CLOSE_TAB:
            guard action.action.close_tab_mode == GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS, let view else { return false }
            DispatchQueue.main.async { [weak view] in view?.requestClose() }
        case GHOSTTY_ACTION_GOTO_TAB:
            guard let id = view?.id ?? store.selectedID,
                  let index = store.tabs.firstIndex(where: { $0.id == id }) else { return false }
            let count = store.tabs.count
            let destination = action.action.goto_tab
            let offset: Int
            switch destination {
            case GHOSTTY_GOTO_TAB_PREVIOUS: offset = (index + count - 1) % count
            case GHOSTTY_GOTO_TAB_NEXT: offset = (index + 1) % count
            case GHOSTTY_GOTO_TAB_LAST: offset = count - 1
            default: offset = Int(destination.rawValue) - 1
            }
            guard store.tabs.indices.contains(offset) else { return false }
            try? store.select(store.tabs[offset].id)
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            if let id = view?.id { childExited(id) }
            // Ghostty still renders the exit status when the tab stays open.
            return false
        case GHOSTTY_ACTION_RING_BELL: NSSound.beep()
        case GHOSTTY_ACTION_QUIT: DispatchQueue.main.async { NSApp.terminate(nil) }
        default: return false
        }
        return true
    }
}

enum TerminalError: LocalizedError {
    case initialization, surface
    var errorDescription: String? {
        switch self {
        case .initialization: "Ghostty could not initialize its runtime."
        case .surface: "Ghostty could not open the terminal surface."
        }
    }
}

private func wakeGhostty(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(pointer).takeUnretainedValue()
    DispatchQueue.main.async {
        if let app = runtime.app { ghostty_app_tick(app) }
    }
}
