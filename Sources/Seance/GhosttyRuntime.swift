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
    private(set) var waitAfterCommand = false
    private var config: ghostty_config_t?
    var newTab: (TabID?) -> Void = { _ in }
    var newWindow: () -> Void = {}
    var goToTab: (TabID?, ghostty_action_goto_tab_e) -> Bool = { _, _ in false }
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
        _ = ghostty_config_get(config, &waitAfterCommand, "wait-after-command", UInt("wait-after-command".utf8.count))

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
            let detail = request == GHOSTTY_CLIPBOARD_REQUEST_PASTE ? String(text.prefix(800)) : ""
            nonisolated(unsafe) let state = state
            // The modal alert must run after the call into libghostty returns.
            DispatchQueue.main.async { [weak view] in
                guard let view, view.surface != nil else { return }
                let allow = GhosttyRuntime.confirm(message, detail: detail)
                if let surface = view.surface {
                    ghostty_surface_complete_clipboard_request(surface, allow ? text : "", state, true)
                }
            }
        }
        runtime.write_clipboard_cb = { pointer, value, location, needsConfirmation in
            guard location == GHOSTTY_CLIPBOARD_STANDARD, let value, let view = TerminalView.from(pointer) else { return }
            let text = String(cString: value)
            let pasteboard = view.runtime.pasteboard
            guard needsConfirmation else {
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                return
            }
            // The modal alert must run after the call into libghostty returns.
            DispatchQueue.main.async {
                guard GhosttyRuntime.confirm("Allow the terminal program to replace the clipboard?", detail: String(text.prefix(800))) else { return }
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        }
        runtime.close_surface_cb = { pointer, alive in
            guard let view = TerminalView.from(pointer) else { return }
            // Teardown must run after the call into libghostty returns.
            DispatchQueue.main.async { [weak view] in
                guard let view, view.surface != nil else { return }
                let title = (try? view.runtime.store.tab(view.id).title) ?? "this tab"
                if !alive || GhosttyRuntime.confirm("Close “\(title)” and its running process?", detail: "", action: "Close") {
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

    func tabShortcutLabel(position: Int) -> String? {
        guard (1...9).contains(position), let config else { return nil }
        let action = "goto_tab:\(position)"
        let trigger = ghostty_config_trigger(config, action, UInt(action.utf8.count))
        let key: String
        switch trigger.tag {
        case GHOSTTY_TRIGGER_UNICODE:
            guard let scalar = Unicode.Scalar(trigger.key.unicode),
                  !CharacterSet.controlCharacters.contains(scalar) else { return nil }
            key = scalar == " " ? "Space" : String(scalar).uppercased()
        case GHOSTTY_TRIGGER_PHYSICAL:
            let physical = trigger.key.physical
            switch physical {
            case GHOSTTY_KEY_ARROW_LEFT: key = "←"
            case GHOSTTY_KEY_ARROW_RIGHT: key = "→"
            case GHOSTTY_KEY_ARROW_UP: key = "↑"
            case GHOSTTY_KEY_ARROW_DOWN: key = "↓"
            case GHOSTTY_KEY_TAB: key = "⇥"
            case GHOSTTY_KEY_ENTER: key = "↩"
            case GHOSTTY_KEY_ESCAPE: key = "⎋"
            default:
                let code = physical.rawValue
                guard (GHOSTTY_KEY_F1.rawValue...GHOSTTY_KEY_F25.rawValue).contains(code) else { return nil }
                key = "F\(code - GHOSTTY_KEY_F1.rawValue + 1)"
            }
        default: return nil
        }
        let modifiers = trigger.mods.rawValue
        var label = ""
        for (flag, symbol) in [(GHOSTTY_MODS_CTRL, "⌃"), (GHOSTTY_MODS_ALT, "⌥"),
                               (GHOSTTY_MODS_SHIFT, "⇧"), (GHOSTTY_MODS_SUPER, "⌘")] {
            if modifiers & flag.rawValue != 0 { label += symbol }
        }
        return label + key
    }

    func setFocus(_ focused: Bool) {
        if let app { ghostty_app_set_focus(app, focused) }
    }

    func shutdown() {
        if let app { self.app = nil; ghostty_app_free(app) }
        if let config { self.config = nil; ghostty_config_free(config) }
    }

    /// Whether any terminal still runs a process that quitting would end.
    var needsConfirmQuit: Bool {
        app.map(ghostty_app_needs_confirm_quit) ?? false
    }

    static func confirm(_ message: String, detail: String, action: String = "Allow") -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action)
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
            let id = view?.id
            DispatchQueue.main.async { self.newTab(id) }
        case GHOSTTY_ACTION_NEW_WINDOW:
            DispatchQueue.main.async { self.newWindow() }
        case GHOSTTY_ACTION_CLOSE_TAB:
            guard action.action.close_tab_mode == GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS, let view else { return false }
            DispatchQueue.main.async { [weak view] in view?.requestClose() }
        case GHOSTTY_ACTION_GOTO_TAB:
            return goToTab(view?.id, action.action.goto_tab)
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            if let view {
                childExited(view.id)
                // The embedding API forces wait-after-command for a surface
                // command. Honor the user's normal behavior when its shell exits.
                if view.closesOnShellExit {
                    DispatchQueue.main.async { self.closeTab(view.id) }
                    return true
                }
            }
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
