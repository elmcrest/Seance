import AppKit
import GhosttyKit
import Observation
import SeanceCore
import SeanceMCP
import SwiftUI

// Resolve Seance's creation shortcuts before a focused Ghostty surface handles them.
private final class SessionWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.characters(byApplyingModifiers: [])?.lowercased() ?? event.charactersIgnoringModifiers?.lowercased()
        if (flags == .command && (key == "t" || key == "n")) || (flags == [.command, .option] && key == "n") {
            if attachedSheet != nil { return true }
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor @Observable
final class TerminalWindow: NSObject, NSWindowDelegate {
    struct Session {
        var tabs: [TabID]
        var selected: TabID
    }

    let window: NSWindow
    let store: TabStore
    let attachments: SessionAttachments
    private let runtime: GhosttyRuntime
    private let server: TabMCPServer
    private let container = NSView()
    private(set) var surfaces: [TabID: TerminalView] = [:]
    private var pending: [TabID: SavedAgent] = [:]
    private var restoreTask: Task<Void, Never>?
    private var restorePanel: NSHostingView<RestoreMessage>?
    private var sessions: [Session] = []
    private(set) var visibleID: TabID?
    var onClose: () -> Void = {}

    private func index(of id: TabID?) -> Int? {
        guard let id else { return nil }
        return sessions.firstIndex { $0.tabs.contains(id) }
    }

    func shortcutLabel(forPosition position: Int) -> String? {
        runtime.tabShortcutLabel(position: position)
    }

    var selectedRoot: TabID? { index(of: visibleID).flatMap { sessions[$0].tabs.first } }
    var roots: Set<TabID> { Set(sessions.compactMap { $0.tabs.first }) }
    func root(of id: TabID) -> TabID? { index(of: id).flatMap { sessions[$0].tabs.first } }
    var horizontalTabs: [TabID] { index(of: visibleID).map { sessions[$0].tabs } ?? [] }

    init(runtime: GhosttyRuntime, server: TabMCPServer, attachments: SessionAttachments) {
        self.runtime = runtime
        self.server = server
        self.attachments = attachments
        store = runtime.store
        let split = NSSplitViewController()
        window = SessionWindow(contentViewController: split)
        super.init()
        let sidebar = NSHostingController(rootView: SampleSidebar(workspace: self))
        let item = NSSplitViewItem(sidebarWithViewController: sidebar)
        item.minimumThickness = 150
        item.maximumThickness = 380
        split.addSplitViewItem(item)
        let content = NSViewController()
        let strip = NSHostingView(rootView: HorizontalTabBar(workspace: self))
        strip.sizingOptions = [.intrinsicContentSize]
        let stack = NSStackView(views: [strip, container])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        strip.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        strip.setContentHuggingPriority(.required, for: .vertical)
        strip.setContentCompressionResistancePriority(.required, for: .vertical)
        content.view = stack
        split.addSplitViewItem(.init(viewController: content))
        window.title = "Seance"
        window.tabbingMode = .disallowed
        window.setContentSize(.init(width: 920, height: 590))
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    private var directory: URL {
        visibleID.flatMap { try? store.tab($0).directory } ?? FileManager.default.homeDirectoryForCurrentUser
    }

    @discardableResult
    func openTerminal(directory: URL, inSessionOf parent: TabID? = nil,
                      resume: (SessionKey, SessionLaunch)? = nil) throws -> TabID {
        let previous = store.selectedID
        let id = store.open(directory: directory)
        do {
            try createSurface(id, resume: resume)
            if let i = index(of: parent) {
                sessions[i].tabs.append(id)
            } else {
                sessions.append(Session(tabs: [id], selected: id))
            }
            focus(id)
            return id
        } catch {
            server.forgetResume(in: id)
            attachments.close(id)
            try? store.close(id)
            if let previous { try? store.select(previous) }
            throw error
        }
    }

    private func createSurface(_ id: TabID, resume: (SessionKey, SessionLaunch)?) throws {
        if let (key, launch) = resume {
            guard attachments.reserve(key, for: id) else { throw SessionLaunchError.alreadyAttached }
            server.prepareResume(launch, in: id) { [attachments] in attachments.detach(key, from: id) }
        }
        let view = try TerminalView(runtime: runtime, tab: store.tab(id), resuming: resume != nil)
        surfaces[id] = view
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
    }

    func savedAgents() -> (agents: [SavedAgent], selected: SessionKey?) {
        var agents: [SavedAgent] = []
        var selected: SessionKey?
        let windowRoots = roots
        for root in store.tabs where windowRoots.contains(root.id) {
            guard let i = index(of: root.id) else { continue }
            for id in sessions[i].tabs {
                guard let tab = try? store.tab(id) else { continue }
                let keys = pending[id].map { [$0.key] } ?? attachments.attachedKeys(in: id)
                agents += keys.map { SavedAgent(key: $0, tab: tab) }
                if id == visibleID { selected = keys.first }
            }
        }
        return (agents, selected)
    }

    func restore(_ workspace: AgentWorkspace) {
        var selection: TabID?
        for agent in workspace.agents {
            let id = store.open(directory: agent.directory)
            pending[id] = agent
            attachments.deferResume(agent.key, in: id)
            try? store.updateProgramTitle(agent.title, for: id)
            try? store.rename(id, to: agent.titleOverride)
            sessions.append(Session(tabs: [id], selected: id))
            if agent.key == workspace.selected { selection = id }
        }
        if let selection { focus(selection) }
    }

    private func showRestoreMessage(_ text: String, retry: (() -> Void)? = nil) {
        restorePanel?.removeFromSuperview()
        let panel = NSHostingView(rootView: RestoreMessage(text: text, retry: retry))
        panel.frame = container.bounds
        panel.autoresizingMask = [.width, .height]
        container.addSubview(panel)
        restorePanel = panel
    }

    private func startRestore(_ agent: SavedAgent, in id: TabID) {
        showRestoreMessage("Opening conversation…")
        restoreTask = Task { [weak self] in
            let provider: any AgentSessionProvider = agent.key.providerID == "claude"
                ? ClaudeSessionProvider() : CodexSessionProvider()
            do {
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: agent.directory.path, isDirectory: &directory), directory.boolValue
                else { throw RestoreError.missingDirectory(agent.directory.path) }
                let saved = AgentSession(id: agent.key, title: agent.title, directory: agent.directory, modifiedAt: .distantPast)
                // A running Codex session is deliberately absent from discovery. Check it first
                // so that we can explain that case, then recheck at launch after the async scan.
                _ = try provider.launch(for: saved)
                let available = try await provider.listSessions()
                try Task.checkCancellation()
                guard let self, self.visibleID == id, self.pending[id] != nil else { return }
                guard !self.attachments.isAttached(agent.key) else { throw SessionLaunchError.alreadyAttached }
                guard let session = available.first(where: { $0.id == agent.key }) else { throw RestoreError.unavailable }
                let launch = try provider.launch(for: session)
                try self.store.updateDirectory(launch.directory, for: id)
                do {
                    try self.createSurface(id, resume: (agent.key, launch))
                } catch {
                    self.server.forgetResume(in: id)
                    self.attachments.detach(agent.key, from: id)
                    throw error
                }
                self.pending[id] = nil
                self.attachments.deferResume(nil, in: id)
                self.focus(id)
            } catch {
                guard !Task.isCancelled, let self, self.visibleID == id, self.pending[id] != nil else { return }
                self.showRestoreMessage(error.localizedDescription) { [weak self] in self?.focus(id) }
            }
        }
    }

    func newSession() {
        presentNewTabPicker(in: window, attachments: attachments, newTerminal: { [weak self] in
            guard let self else { return }
            do { try openTerminal(directory: directory) }
            catch { NSAlert(error: error).runModal() }
        }, resume: { [weak self] session, launch in
            do { try self?.openTerminal(directory: launch.directory, resume: (session.id, launch)) }
            catch { NSAlert(error: error).runModal() }
        })
    }

    func newHorizontalTab(from id: TabID? = nil) {
        let parent = id ?? visibleID
        let cwd = parent.flatMap { try? store.tab($0).directory } ?? directory
        do { try openTerminal(directory: cwd, inSessionOf: parent) }
        catch { NSAlert(error: error).runModal() }
    }

    func providers(inSession root: TabID) -> [String] {
        guard let i = index(of: root) else { return [] }
        var providers = Set(sessions[i].tabs.flatMap { attachments.providers(in: $0) })
        providers.formUnion(sessions[i].tabs.compactMap { pending[$0]?.key.providerID })
        return providers.sorted()
    }

    func selectSession(_ root: TabID) {
        if let i = index(of: root) { focus(sessions[i].selected) }
    }

    func focus(_ id: TabID) {
        guard let i = index(of: id) else { return }
        restoreTask?.cancel()
        restorePanel?.removeFromSuperview()
        restorePanel = nil
        if let previous = visibleID, previous != id { surfaces[previous]?.show(false) }
        sessions[i].selected = id
        visibleID = id
        if window.isKeyWindow || window.isMainWindow { try? store.select(id) }
        if let view = surfaces[id] {
            view.show(true)
            window.makeFirstResponder(view)
        } else if let agent = pending[id] {
            window.makeFirstResponder(nil)
            startRestore(agent, in: id)
        }
    }

    func goToTab(from id: TabID?, destination: ghostty_action_goto_tab_e) -> Bool {
        guard let current = id ?? visibleID, let session = index(of: current) else { return false }
        if destination == GHOSTTY_GOTO_TAB_NEXT || destination == GHOSTTY_GOTO_TAB_PREVIOUS {
            let tabsByRoot = Dictionary(uniqueKeysWithValues: sessions.map { ($0.tabs[0], $0.tabs) })
            let cycle = store.tabs.compactMap { tabsByRoot[$0.id] }.flatMap { $0 }
            guard let i = cycle.firstIndex(of: current) else { return false }
            let offset = destination == GHOSTTY_GOTO_TAB_NEXT ? 1 : cycle.count - 1
            focus(cycle[(i + offset) % cycle.count])
            return true
        }
        let siblings = sessions[session].tabs
        let ids = siblings.count > 1 ? siblings : store.tabs.map(\.id).filter(roots.contains)
        let next = destination == GHOSTTY_GOTO_TAB_LAST ? ids.count - 1 : Int(destination.rawValue) - 1
        guard ids.indices.contains(next) else { return false }
        if siblings.count > 1 { focus(ids[next]) } else { selectSession(ids[next]) }
        return true
    }

    func closeCurrentTab() {
        if let visibleID { requestClose(visibleID) }
    }

    func requestClose(_ id: TabID) {
        if let view = surfaces[id] { view.requestClose() } else { closeTab(id) }
    }

    private func confirmClose(_ ids: [TabID], action: String) -> Bool {
        let busy = ids.contains { id in surfaces[id]?.surface.map(ghostty_surface_needs_confirm_quit) == true }
        return !busy || GhosttyRuntime.confirm(action + " and end its running processes?", detail: "", action: "Close")
    }

    func closeSession(_ root: TabID) {
        guard let i = index(of: root) else { return }
        let ids = sessions[i].tabs
        guard confirmClose(ids, action: "Close this session") else { return }
        for id in ids.reversed() { closeTab(id) }
    }

    func closeTab(_ id: TabID) {
        guard let i = index(of: id), let position = sessions[i].tabs.firstIndex(of: id) else { return }
        let orderedRoots = store.tabs.map(\.id).filter(roots.contains)
        let rootPosition = orderedRoots.firstIndex(of: sessions[i].tabs[0]) ?? 0
        let wasVisible = visibleID == id
        if position == 0, sessions[i].tabs.count > 1 {
            // The sidebar shows a session through its first tab. Hand the session's
            // name and sidebar position to the tab that takes over.
            let successor = sessions[i].tabs[1]
            if let name = try? store.tab(id).titleOverride { try? store.rename(successor, to: name) }
            let order = store.tabs.map(\.id)
            if let old = order.firstIndex(of: id), let new = order.firstIndex(of: successor) {
                try? store.reorderVisibleTabs(old < new ? [successor, id] : [id, successor])
            }
        }
        discard(id)
        sessions[i].tabs.remove(at: position)
        let removedSession = sessions[i].tabs.isEmpty
        if removedSession {
            sessions.remove(at: i)
        } else if sessions[i].selected == id {
            sessions[i].selected = sessions[i].tabs[min(position, sessions[i].tabs.count - 1)]
        }
        guard wasVisible else { return }
        visibleID = nil
        if sessions.isEmpty { window.close(); return }
        if !removedSession {
            focus(sessions[i].selected)
        } else {
            let remaining = store.tabs.map(\.id).filter(roots.contains)
            selectSession(remaining[min(rootPosition, remaining.count - 1)])
        }
    }

    private func discard(_ id: TabID) {
        pending[id] = nil
        server.forgetResume(in: id)
        attachments.close(id)
        try? store.close(id)
        let view = surfaces.removeValue(forKey: id)
        view?.removeFromSuperview()
        view?.shutdown()
    }

    func shutdown() {
        restoreTask?.cancel()
        restorePanel?.removeFromSuperview()
        restorePanel = nil
        for id in sessions.flatMap(\.tabs) { discard(id) }
        sessions.removeAll()
        visibleID = nil
        onClose = {}
        window.contentViewController = nil
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let visibleID { try? store.select(visibleID) }
        if let terminal = window.firstResponder as? TerminalView, let surface = terminal.surface {
            ghostty_surface_set_focus(surface, true)
        }
    }
    func windowDidResignKey(_ notification: Notification) {
        if let terminal = window.firstResponder as? TerminalView, let surface = terminal.surface {
            ghostty_surface_set_focus(surface, false)
        }
    }
    func windowDidChangeScreen(_ notification: Notification) {
        for view in surfaces.values { view.updateGeometry() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmClose(Array(surfaces.keys), action: "Close this window")
    }
    func windowWillClose(_ notification: Notification) {
        onClose()
        shutdown()
    }
}

private struct HorizontalTabBar: View {
    let workspace: TerminalWindow

    var body: some View {
        let tabs = workspace.horizontalTabs
        if tabs.count > 1 {
            HStack(spacing: 0) {
                GeometryReader { geometry in
                    let width = max(110, geometry.size.width / CGFloat(tabs.count))
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(spacing: 0) {
                                ForEach(Array(tabs.enumerated()), id: \.element) { index, id in
                                    if let tab = try? workspace.store.tab(id) {
                                        TerminalTabItem(tab: tab, shortcut: workspace.shortcutLabel(forPosition: index + 1),
                                                        selected: id == workspace.visibleID,
                                                        select: { workspace.focus(id) },
                                                        close: { workspace.requestClose(id) })
                                            .frame(width: width)
                                            .id(id)
                                    }
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        .onChange(of: workspace.visibleID, initial: true) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                        .onChange(of: geometry.size.width) {
                            if let id = workspace.visibleID { proxy.scrollTo(id) }
                        }
                    }
                }
                Divider()
                Button { workspace.newHorizontalTab() } label: {
                    Image(systemName: "plus")
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Tab")
                .help("New Tab (⌘T)")
            }
            .frame(height: 28)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider().allowsHitTesting(false) }
        }
    }
}

private struct TerminalTabItem: View {
    let tab: SeanceCore.Tab
    let shortcut: String?
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .leading) {
            Button(action: select) {
                HStack(spacing: 0) {
                    Text(tab.title)
                        .font(.system(size: 12, weight: selected ? .medium : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 26)
                        .padding(.trailing, 5)
                        .frame(maxWidth: .infinity)
                    if let shortcut {
                        Text(shortcut)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .padding(.trailing, 7)
                    }
                }
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.title)
            .accessibilityHint(shortcut ?? "")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(tab.title + "\n" + tab.directory.path)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 3)
            .opacity(hovered || selected ? 1 : 0)
            .allowsHitTesting(hovered || selected)
            .accessibilityLabel("Close " + tab.title)
        }
        .background {
            if selected {
                Color(nsColor: .controlBackgroundColor)
            } else {
                Color.primary.opacity(hovered ? 0.06 : 0.025)
            }
        }
        .overlay(alignment: .trailing) {
            Divider().frame(height: 16).allowsHitTesting(false)
        }
        .onHover { hovered = $0 }
    }
}

private struct RestoreMessage: View {
    let text: String
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Text(text).multilineTextAlignment(.center)
            if let retry { Button("Retry", action: retry) } else { ProgressView().controlSize(.small) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum RestoreError: LocalizedError {
    case missingDirectory(String)
    case unavailable
    var errorDescription: String? {
        switch self {
        case .missingDirectory(let path): "The session’s working directory is unavailable: " + path
        case .unavailable: "This conversation could not be found in the agent’s local session history."
        }
    }
}
