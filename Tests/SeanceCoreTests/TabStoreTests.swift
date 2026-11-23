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
