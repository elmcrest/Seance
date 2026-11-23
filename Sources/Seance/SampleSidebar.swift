import SeanceCore
import SwiftUI

struct SampleSidebar: View {
    let store: TabStore

    var body: some View {
        List(store.tabs, selection: Binding(
            get: { store.selectedID },
            set: { if let id = $0 { try? store.select(id) } }
        )) { tab in
            VStack(alignment: .leading) {
                Text(tab.title)
                Text(tab.directory.path).font(.caption).foregroundStyle(.secondary)
            }
            .tag(tab.id)
        }
        .listStyle(.sidebar)
    }
}
