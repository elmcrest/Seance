import Foundation
import Testing
import SeanceCore

@MainActor
@Test func backgroundUpdatesAndStaleCallers() throws {
    let store = TabStore()
    let a = store.open(directory: URL(fileURLWithPath: "/tmp/alpha"))
    let b = store.open(directory: URL(fileURLWithPath: "/tmp/beta"))
    try store.rename(a, to: "Build")
    try store.updateProgramTitle("vim", for: a)
    try store.updateDirectory(URL(fileURLWithPath: "/tmp/gamma"), for: a)
    #expect(try store.tab(a).title == "Build")
    #expect(try store.tab(b).title == "beta")
    try store.rename(a, to: " ")
    #expect(try store.tab(a).title == "vim")
    try store.updateProgramTitle(nil, for: a)
    #expect(try store.tab(a).title == "gamma")
    #expect(store.selectedID == b)
    try store.close(a)
    #expect(throws: TabStoreError.unknownTab(a)) { try store.rename(a, to: "Late") }
    #expect(try store.tab(b).title == "beta")
}

@MainActor
@Test func closingSelectedTabChoosesANeighbor() throws {
    let store = TabStore()
    let directory = URL(fileURLWithPath: "/tmp")
    let a = store.open(directory: directory)
    let b = store.open(directory: directory)
    try store.select(a)
    try store.close(a)
    #expect(store.selectedID == b)
    try store.close(b)
    #expect(store.selectedID == nil)
}

@MainActor
@Test func searchIncludesOverriddenProgramTitleAndFullDirectory() throws {
    let store = TabStore()
    let a = store.open(directory: URL(fileURLWithPath: "/projects/team/docs"))
    let b = store.open(directory: URL(fileURLWithPath: "/projects/lab"))
    try store.updateProgramTitle("Editor", for: a)
    try store.rename(a, to: "Specs")

    #expect(store.tabs(matching: "spec").map(\.id) == [a])
    #expect(store.tabs(matching: "  EDITOR ").map(\.id) == [a])
    #expect(store.tabs(matching: "team/doc").map(\.id) == [a])
    #expect(store.tabs(matching: " ").map(\.id) == [a, b])
    #expect(try store.tab(a).secondaryTitle == "Editor")
    #expect(store.selectedID == b)

    try store.updateProgramTitle("Specs", for: a)
    #expect(try store.tab(a).secondaryTitle == nil)
}

@MainActor
@Test func filteredReorderKeepsHiddenSlotsAndSelection() throws {
    let store = TabStore()
    let directory = URL(fileURLWithPath: "/tmp")
    let a = store.open(directory: directory)
    let b = store.open(directory: directory)
    let c = store.open(directory: directory)
    try store.reorderVisibleTabs([c, a])
    #expect(store.tabs.map(\.id) == [c, b, a])
    #expect(store.selectedID == c)

    // A background shell can exit between the start and end of a drag.
    try store.close(b)
    #expect(throws: TabStoreError.unknownTab(b)) { try store.reorderVisibleTabs([a, c, b]) }
    #expect(store.tabs.map(\.id) == [c, a])
}

@MainActor
@Test func relativeSelectionWrapsInTabOrder() throws {
    let store = TabStore()
    store.selectRelative(-1)
    #expect(store.selectedID == nil)

    let directory = URL(fileURLWithPath: "/tmp")
    let a = store.open(directory: directory)
    let b = store.open(directory: directory)
    store.selectRelative(1)
    #expect(store.selectedID == a)
    store.selectRelative(-1)
    #expect(store.selectedID == b)
    try store.reorderVisibleTabs([b, a])
    store.selectRelative(1)
    #expect(store.selectedID == a)
}
