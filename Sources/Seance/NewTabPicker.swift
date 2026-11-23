import AppKit
import SeanceCore
import SwiftUI

struct NewTabPicker: View {
    let providers: [String: any AgentSessionProvider]
    let attachments: SessionAttachments
    let onNewTerminal: () -> Void
    let onResume: (AgentSession, SessionLaunch) -> Void
    var onCancel: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [AgentSession] = []
    @State private var query = ""
    @State private var selection = Choice.terminal
    @State private var loading = true
    @State private var errorMessage: String?

    private enum Choice: Hashable {
        case terminal
        case session(SessionKey)
    }

    private var matches: [AgentSession] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter { session in
            !attachments.isAttached(session.id) && (
                term.isEmpty || session.title.localizedStandardContains(term)
                    || session.directory.path.localizedStandardContains(term)
                    || session.id.sessionID.localizedStandardContains(term)
                    || ProviderMark.name(for: session.id.providerID).localizedStandardContains(term)
            )
        }
    }

    var body: some View {
        let visible = matches
        let choices = [.terminal] + visible.map { Choice.session($0.id) }
        VStack(spacing: 0) {
            PickerSearchField(query: $query, move: { offset in
                let current = choices.firstIndex(of: selection) ?? 0
                selection = choices[min(max(current + offset, 0), choices.count - 1)]
            }, submit: { choose(selection) }, cancel: {
                if let onCancel { onCancel() } else { dismiss() }
            })
            .frame(height: 26)
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        row(.terminal, title: "New terminal", detail: nil)
                        ForEach(visible) { session in
                            row(.session(session.id), title: session.title, detail: session.directory.path)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) { _, current in proxy.scrollTo(current) }
            }
            if loading { ProgressView().controlSize(.small).padding(8) }
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .frame(width: 500, height: 320)
        .onChange(of: query) { _, value in
            selectFirstMatch(for: value)
        }
        .onChange(of: choices) { _, current in
            if !current.contains(selection) { selection = .terminal }
        }
        .task {
            await withTaskGroup(of: (String, Result<[AgentSession], Error>).self) { group in
                for (id, provider) in providers {
                    group.addTask {
                        do { return (id, .success(try await provider.listSessions())) }
                        catch { return (id, .failure(error)) }
                    }
                }
                for await (id, result) in group {
                    guard !Task.isCancelled else { return }
                    switch result {
                    case .success(let found):
                        sessions.append(contentsOf: found)
                        sessions.sort {
                            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                            if $0.id.providerID != $1.id.providerID { return $0.id.providerID < $1.id.providerID }
                            return $0.id.sessionID < $1.id.sessionID
                        }
                        if selection == .terminal { selectFirstMatch(for: query) }
                    case .failure(let error):
                        errorMessage = "Couldn’t read " + ProviderMark.name(for: id) + " sessions. " + error.localizedDescription
                    }
                }
            }
            loading = false
        }
    }

    private func selectFirstMatch(for text: String) {
        let term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty, !"New terminal".localizedStandardContains(term), let first = matches.first {
            selection = .session(first.id)
        } else {
            selection = .terminal
        }
    }

    private func row(_ choice: Choice, title: String, detail: String?) -> some View {
        Button { choose(choice) } label: {
            HStack(spacing: 10) {
                switch choice {
                case .terminal:
                    Image(systemName: "terminal").foregroundStyle(.secondary).frame(width: 20)
                case .session(let key):
                    ProviderMark(provider: key.providerID).frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                if case .session(let key) = choice {
                    Text(ProviderMark.name(for: key.providerID))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(8)
            .background(choice == selection ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(choice == selection ? .isSelected : [])
        .id(choice)
    }

    private func choose(_ choice: Choice) {
        switch choice {
        case .terminal:
            onNewTerminal()
        case .session(let key):
            guard let session = matches.first(where: { $0.id == key }), let provider = providers[key.providerID] else { return }
            do {
                onResume(session, try provider.launch(for: session))
            } catch {
                errorMessage = "Couldn’t resume this session. " + error.localizedDescription
            }
        }
    }
}

private struct PickerSearchField: NSViewRepresentable {
    @Binding var query: String
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = InitialFocusSearchField()
        field.placeholderString = "Search sessions"
        field.setAccessibilityLabel("Search sessions")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != query { field.stringValue = query }
    }

    final class InitialFocusSearchField: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.initialFirstResponder = self
            window?.makeFirstResponder(self)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: PickerSearchField

        init(_ parent: PickerSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField {
                parent.query = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }
}
