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
            if let (key, launch) = resume {
                guard attachments.reserve(key, for: id) else { throw SessionLaunchError.alreadyAttached }
                server.prepareResume(launch, in: id) { [attachments] in attachments.detach(key, from: id) }
            }
            let view = try TerminalView(runtime: runtime, tab: store.tab(id), resuming: resume != nil)
            surfaces[id] = view
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
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
        return Set(sessions[i].tabs.flatMap { attachments.providers(in: $0) }).sorted()
    }

    func selectSession(_ root: TabID) {
        if let i = index(of: root) { focus(sessions[i].selected) }
    }

    func focus(_ id: TabID) {
        guard let view = surfaces[id], let i = index(of: id) else { return }
        if let previous = visibleID, previous != id { surfaces[previous]?.show(false) }
        sessions[i].selected = id
        visibleID = id
        if window.isKeyWindow || window.isMainWindow { try? store.select(id) }
        view.show(true)
        window.makeFirstResponder(view)
    }

    func goToTab(from id: TabID?, destination: ghostty_action_goto_tab_e) -> Bool {
        guard let current = id ?? visibleID, let session = index(of: current) else { return false }
        let siblings = sessions[session].tabs
        let ids = siblings.count > 1 ? siblings : store.tabs.map(\.id).filter(roots.contains)
        guard let i = ids.firstIndex(of: current) else { return false }
        let next: Int
        switch destination {
        case GHOSTTY_GOTO_TAB_PREVIOUS: next = (i + ids.count - 1) % ids.count
        case GHOSTTY_GOTO_TAB_NEXT: next = (i + 1) % ids.count
        case GHOSTTY_GOTO_TAB_LAST: next = ids.count - 1
        default: next = Int(destination.rawValue) - 1
        }
        guard ids.indices.contains(next) else { return false }
        if siblings.count > 1 { focus(ids[next]) } else { selectSession(ids[next]) }
        return true
    }

    func closeCurrentTab() {
        if let id = visibleID { surfaces[id]?.requestClose() }
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
        server.forgetResume(in: id)
        attachments.close(id)
        try? store.close(id)
        let view = surfaces.removeValue(forKey: id)
        view?.removeFromSuperview()
        view?.shutdown()
    }

    func shutdown() {
        for id in Array(surfaces.keys) { discard(id) }
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
        let notify = onClose
        shutdown()
        notify()
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
                                                        close: { workspace.surfaces[id]?.requestClose() })
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
