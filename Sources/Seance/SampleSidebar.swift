import SeanceCore
import SwiftUI

struct SampleSidebar: View {
    let workspace: TerminalWindow
    private var store: TabStore { workspace.store }

    @State private var query = ""
    @State private var editingID: TabID?
    @State private var draft = ""
    @State private var originalDraft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        // A session matches when any of its tabs does.
        let matching = Set(store.tabs(matching: query).compactMap { workspace.root(of: $0.id) })
        let visible = store.tabs.filter { matching.contains($0.id) }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter sessions", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear filter")
                }
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .padding(8)

            List(selection: Binding(
                get: { workspace.selectedRoot },
                set: { id in
                    guard let id, editingID != id else { return }
                    workspace.selectSession(id)
                }
            )) {
                ForEach(visible) { tab in
                    row(for: tab)
                        .tag(tab.id)
                }
                .onMove { offsets, destination in
                    var order = visible.map(\.id)
                    order.move(fromOffsets: offsets, toOffset: destination)
                    try? store.reorderVisibleTabs(order)
                }
            }
            .listStyle(.sidebar)
            .contextMenu(forSelectionType: TabID.self) { selection in
                if let id = selection.first, let tab = try? store.tab(id) {
                    Button("Rename…") { beginRename(tab) }
                    Button("Close Session") { close(id) }
                }
            } primaryAction: { selection in
                guard let id = selection.first, let tab = try? store.tab(id) else { return }
                beginRename(tab)
            }
            .overlay {
                if visible.isEmpty && !query.isEmpty {
                    Text("No matching sessions").foregroundStyle(.secondary)
                }
            }

            Divider()
            Button(action: newTab) {
                Label("New Session", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
        }
        .frame(minWidth: 170, idealWidth: 220)
        .onChange(of: renameFocused) { _, focused in
            if !focused { finishRename() }
        }
    }

    @ViewBuilder private func row(for tab: SeanceCore.Tab) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if editingID == tab.id {
                TextField("Session title", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFocused)
                    .onSubmit { finishRename() }
                    .onExitCommand { editingID = nil }
                    .onAppear { renameFocused = true }
            } else {
                HStack(spacing: 5) {
                    ForEach(workspace.providers(inSession: tab.id), id: \.self) { provider in
                        ProviderMark(provider: provider)
                    }
                    Text(tab.title).lineLimit(1)
                }
            }
            if let secondary = tab.secondaryTitle {
                Text(secondary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(tab.directory.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
        .help(tab.directory.path)
    }

    private func beginRename(_ tab: SeanceCore.Tab) {
        finishRename()
        draft = tab.title
        originalDraft = draft
        editingID = tab.id
    }

    private func finishRename() {
        guard let editingID else { return }
        if draft != originalDraft {
            try? store.rename(editingID, to: draft)
        }
        self.editingID = nil
    }

    private func newTab() {
        finishRename()
        query = ""
        workspace.newSession()
    }

    private func close(_ id: TabID) {
        if editingID == id { editingID = nil }
        workspace.closeSession(id)
    }
}
