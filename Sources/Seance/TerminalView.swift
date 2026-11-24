import AppKit
import GhosttyKit
import SeanceCore

@MainActor
final class TerminalView: NSView, @preconcurrency NSTextInputClient {
    let runtime: GhosttyRuntime
    let id: TabID
    let closesOnShellExit: Bool
    private(set) var surface: ghostty_surface_t?
    private var marked = ""
    private var input: [String]?
    private var mouseTracking: NSTrackingArea?

    init(runtime: GhosttyRuntime, tab: Tab, resuming: Bool) throws {
        self.runtime = runtime
        id = tab.id
        closesOnShellExit = resuming && !runtime.waitAfterCommand
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        guard let app = runtime.app else { throw TerminalError.initialization }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = pointer
        config.userdata = pointer
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 1)
        var environment = runtime.environment
        environment["TAB_ID"] = id.rawValue.uuidString
        if resuming { environment["SEANCE_RESUME_DIRECTORY"] = tab.directory.path }
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { for pointer in strings { free(pointer) } }
        func copy(_ string: String) throws -> UnsafePointer<CChar> {
            guard !string.utf8.contains(0), let pointer = strdup(string) else { throw TerminalError.surface }
            strings.append(pointer)
            return UnsafePointer(pointer)
        }
        var variables = try environment.map { key, value in
            ghostty_env_var_s(key: try copy(key), value: try copy(value))
        }
        config.working_directory = try copy(tab.directory.path)
        if resuming {
            // Ghostty's configured command can be a TUI or SSH connection. Send
            // startup input only to a local interactive shell that understands it.
            let accountShell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
            let supported = ["sh", "bash", "zsh", "ksh", "fish"]
            let shell = supported.contains(URL(fileURLWithPath: accountShell).lastPathComponent) ? accountShell : "/bin/zsh"
            let safeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./+-")
            let command = shell.rangeOfCharacter(from: safeCharacters.inverted) == nil
                ? shell : "'" + shell.replacingOccurrences(of: "'", with: "'\\''") + "'"
            config.command = try copy(command)
            config.initial_input = try copy("cd -- \"$SEANCE_RESUME_DIRECTORY\"; \"$SEANCE_HELPER\" run-resume\n")
        }
        surface = variables.withUnsafeMutableBufferPointer {
            config.env_vars = $0.baseAddress
            config.env_var_count = $0.count
            return ghostty_surface_new(app, &config)
        }
        guard surface != nil else { throw TerminalError.surface }
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    static func from(_ pointer: UnsafeMutableRawPointer?) -> TerminalView? {
        pointer.map { Unmanaged<TerminalView>.fromOpaque($0).takeUnretainedValue() }
    }

    func requestClose() {
        if let surface { ghostty_surface_request_close(surface) }
    }

    func shutdown() {
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        // A background window gains terminal focus when it becomes key.
        if let surface, window?.isKeyWindow == true { ghostty_surface_set_focus(surface, true) }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }

    override func layout() {
        super.layout()
        updateGeometry()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateGeometry()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGeometry()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }
    private func updateAppearance() {
        guard let surface else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_surface_set_color_scheme(surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }
    func updateGeometry() {
        guard let surface, let window, !bounds.isEmpty else { return }
        let size = convertToBacking(bounds).size
        let scale = window.backingScaleFactor
        layer?.contentsScale = scale
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(max(1, size.width)), UInt32(max(1, size.height)))
        if let display = window.screen?.deviceDescription[.init("NSScreenNumber")] as? NSNumber {
            ghostty_surface_set_display_id(surface, display.uint32Value)
        }
    }

    func show(_ visible: Bool) {
        isHidden = !visible
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
        if visible {
            updateGeometry()
            ghostty_surface_refresh(surface)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let mouseTracking { removeTrackingArea(mouseTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited], owner: self)
        mouseTracking = area
        addTrackingArea(area)
    }
    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, Self.modifiers(event.modifierFlags))
    }
    override func mouseExited(with event: NSEvent) {
        if let surface, NSEvent.pressedMouseButtons == 0 {
            ghostty_surface_mouse_pos(surface, -1, -1, Self.modifiers(event.modifierFlags))
        }
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_LEFT, GHOSTTY_MOUSE_PRESS) }
    override func mouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_LEFT, GHOSTTY_MOUSE_RELEASE) }
    override func rightMouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RIGHT, GHOSTTY_MOUSE_PRESS) }
    override func rightMouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_RIGHT, GHOSTTY_MOUSE_RELEASE) }
    override func otherMouseDown(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_MIDDLE, GHOSTTY_MOUSE_PRESS) }
    override func otherMouseUp(with event: NSEvent) { mouseButton(event, GHOSTTY_MOUSE_MIDDLE, GHOSTTY_MOUSE_RELEASE) }
    private func mouseButton(_ event: NSEvent, _ button: ghostty_input_mouse_button_e, _ state: ghostty_input_mouse_state_e) {
        guard let surface else { return }
        if state == GHOSTTY_MOUSE_PRESS { window?.makeFirstResponder(self) }
        mouseMoved(with: event)
        ghostty_surface_mouse_button(surface, state, button, Self.modifiers(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let momentum: ghostty_input_mouse_momentum_e
        switch event.momentumPhase {
        case .began: momentum = GHOSTTY_MOUSE_MOMENTUM_BEGAN
        case .changed: momentum = GHOSTTY_MOUSE_MOMENTUM_CHANGED
        case .ended: momentum = GHOSTTY_MOUSE_MOMENTUM_ENDED
        case .cancelled: momentum = GHOSTTY_MOUSE_MOMENTUM_CANCELLED
        case .mayBegin: momentum = GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
        case .stationary: momentum = GHOSTTY_MOUSE_MOMENTUM_STATIONARY
        default: momentum = GHOSTTY_MOUSE_MOMENTUM_NONE
        }
        let precise = event.hasPreciseScrollingDeltas
        let flags = Int32(momentum.rawValue << 1) | (precise ? 1 : 0)
        let multiplier = precise ? 2.0 : 1.0
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX * multiplier, event.scrollingDeltaY * multiplier, flags)
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var bits: UInt32 = 0
        for (flag, modifier): (NSEvent.ModifierFlags, ghostty_input_mods_e) in [
            (.shift, GHOSTTY_MODS_SHIFT), (.control, GHOSTTY_MODS_CTRL), (.option, GHOSTTY_MODS_ALT),
            (.command, GHOSTTY_MODS_SUPER), (.capsLock, GHOSTTY_MODS_CAPS),
            (.init(rawValue: UInt(NX_DEVICERSHIFTKEYMASK)), GHOSTTY_MODS_SHIFT_RIGHT),
            (.init(rawValue: UInt(NX_DEVICERCTLKEYMASK)), GHOSTTY_MODS_CTRL_RIGHT),
            (.init(rawValue: UInt(NX_DEVICERALTKEYMASK)), GHOSTTY_MODS_ALT_RIGHT),
            (.init(rawValue: UInt(NX_DEVICERCMDKEYMASK)), GHOSTTY_MODS_SUPER_RIGHT),
        ] where flags.contains(flag) { bits |= modifier.rawValue }
        return ghostty_input_mods_e(bits)
    }

    private func keyEvent(_ event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = Self.modifiers(event.modifierFlags)
        key.consumed_mods = Self.modifiers(event.modifierFlags.subtracting([.control, .command]))
        if event.type != .flagsChanged {
            key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        }
        return key
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown, !hasMarkedText(), let surface else { return false }
        var key = keyEvent(event, action: GHOSTTY_ACTION_PRESS)
        let bound = (event.charactersIgnoringModifiers ?? "").withCString {
            key.text = $0
            return ghostty_surface_key_is_binding(surface, key)
        }
        if bound { keyDown(with: event) }
        return bound
    }

    override func keyDown(with event: NSEvent) {
        guard let surface else { return }
        var key = keyEvent(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
        var translation = event
        let mods = ghostty_surface_key_translation_mods(surface, key.mods)
        if event.modifierFlags.contains(.option), mods.rawValue & GHOSTTY_MODS_ALT.rawValue == 0 {
            let flags = event.modifierFlags.subtracting(.option)
            translation = NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow, modifierFlags: flags,
                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                characters: event.characters(byApplyingModifiers: flags) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
            key.consumed_mods = Self.modifiers(flags.subtracting([.command, .control]))
        }
        let wasMarked = hasMarkedText()
        input = []
        interpretKeyEvents([translation])
        let committed = input ?? []
        input = nil
        key.composing = committed.isEmpty && (wasMarked || hasMarkedText())
        var text = committed.isEmpty ? translation.characters : committed.joined()
        if let scalar = text?.unicodeScalars.first, scalar.value < 32 {
            text = translation.characters(byApplyingModifiers: translation.modifierFlags.subtracting(.control))
        }
        if let text, let scalar = text.unicodeScalars.first, scalar.value >= 32,
           !(0xF700...0xF8FF).contains(scalar.value) {
            _ = text.withCString { key.text = $0; return ghostty_surface_key(surface, key) }
        } else {
            ghostty_surface_key(surface, key)
        }
    }
    override func keyUp(with event: NSEvent) {
        if let surface { ghostty_surface_key(surface, keyEvent(event, action: GHOSTTY_ACTION_RELEASE)) }
    }
    override func flagsChanged(with event: NSEvent) {
        // The shared flag stays set while the other side's key is held, so the
        // device bit for this key's own side decides press versus release.
        let flag: NSEvent.ModifierFlags
        let side: Int32, otherSide: Int32
        switch event.keyCode {
        case 54: (flag, side, otherSide) = (.command, NX_DEVICERCMDKEYMASK, NX_DEVICELCMDKEYMASK)
        case 55: (flag, side, otherSide) = (.command, NX_DEVICELCMDKEYMASK, NX_DEVICERCMDKEYMASK)
        case 56: (flag, side, otherSide) = (.shift, NX_DEVICELSHIFTKEYMASK, NX_DEVICERSHIFTKEYMASK)
        case 60: (flag, side, otherSide) = (.shift, NX_DEVICERSHIFTKEYMASK, NX_DEVICELSHIFTKEYMASK)
        case 58: (flag, side, otherSide) = (.option, NX_DEVICELALTKEYMASK, NX_DEVICERALTKEYMASK)
        case 61: (flag, side, otherSide) = (.option, NX_DEVICERALTKEYMASK, NX_DEVICELALTKEYMASK)
        case 59: (flag, side, otherSide) = (.control, NX_DEVICELCTLKEYMASK, NX_DEVICERCTLKEYMASK)
        case 62: (flag, side, otherSide) = (.control, NX_DEVICERCTLKEYMASK, NX_DEVICELCTLKEYMASK)
        case 57: (flag, side, otherSide) = (.capsLock, 0, 0)
        default: return
        }
        guard !hasMarkedText(), let surface else { return }
        let raw = event.modifierFlags.rawValue
        // Synthetic events may carry no device bits; fall back to the shared flag.
        let pressed = event.modifierFlags.contains(flag)
            && (raw & UInt(side) != 0 || raw & UInt(side | otherSide) == 0)
        let action = pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        ghostty_surface_key(surface, keyEvent(event, action: action))
    }

    override func doCommand(by selector: Selector) {} // Ghostty encodes Return, arrows, etc. from the physical key.
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func markedRange() -> NSRange { NSRange(location: marked.isEmpty ? NSNotFound : 0, length: marked.utf16.count) }
    func selectedRange() -> NSRange {
        guard let surface else { return NSRange(location: NSNotFound, length: 0) }
        var selected = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &selected) else { return NSRange(location: NSNotFound, length: 0) }
        defer { ghostty_surface_free_text(surface, &selected) }
        return NSRange(location: Int(selected.offset_start), length: Int(selected.offset_len))
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let rect = NSRect(x: x, y: bounds.height - y, width: width, height: height)
        return window.convertToScreen(convert(rect, to: nil))
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        if let surface { ghostty_surface_preedit(surface, marked, UInt(marked.utf8.count)) }
    }
    func unmarkText() {
        marked = ""
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = (string as? NSAttributedString)?.string ?? string as? String else { return }
        if hasMarkedText() { unmarkText() }
        if input != nil { input?.append(text) }
        else if let surface { ghostty_surface_text(surface, text, UInt(text.utf8.count)) }
    }
}
