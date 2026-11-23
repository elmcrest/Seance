import Foundation
import Observation

public struct TabID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct Tab: Identifiable, Equatable, Sendable {
    public let id: TabID
    public fileprivate(set) var directory: URL
    public fileprivate(set) var programTitle: String?
    public fileprivate(set) var titleOverride: String?

    public var title: String {
        titleOverride ?? programTitle ?? directory.lastPathComponent
    }

    public var secondaryTitle: String? {
        guard titleOverride != nil, programTitle != title else { return nil }
        return programTitle
    }

    public init(id: TabID = TabID(), directory: URL) {
        self.id = id
        self.directory = directory
    }
}

public enum TabStoreError: Error, Equatable {
    case unknownTab(TabID)
}

@MainActor @Observable
public final class TabStore {
    public private(set) var tabs: [Tab] = []
    public private(set) var selectedID: TabID?

    public init() {}

    @discardableResult
    public func open(directory: URL) -> TabID {
        let tab = Tab(directory: directory)
        tabs.append(tab)
        selectedID = tab.id
        return tab.id
    }

    public func tab(_ id: TabID) throws -> Tab {
        tabs[try index(of: id)]
    }

    public func select(_ id: TabID) throws {
        _ = try index(of: id)
        selectedID = id
    }

    public func selectRelative(_ offset: Int) {
        guard let selectedID, let current = tabs.firstIndex(where: { $0.id == selectedID }) else {
            return
        }
        let destination = (current + offset % tabs.count + tabs.count) % tabs.count
        self.selectedID = tabs[destination].id
    }

    public func tabs(matching query: String) -> [Tab] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return tabs }
        return tabs.filter { tab in
            tab.title.localizedStandardContains(term)
                || tab.programTitle?.localizedStandardContains(term) == true
                || tab.directory.path.localizedStandardContains(term)
        }
    }

    /// Replace the order in just the displayed slots. Tabs hidden by a filter keep their positions.
    public func reorderVisibleTabs(_ ids: [TabID]) throws {
        let positions = Dictionary(uniqueKeysWithValues: tabs.indices.map { (tabs[$0].id, $0) })
        let requestedSlots = try ids.map { id in
            guard let index = positions[id] else { throw TabStoreError.unknownTab(id) }
            return index
        }
        guard Set(requestedSlots).count == requestedSlots.count else { return }
        var reordered = tabs
        for (destination, source) in zip(requestedSlots.sorted(), requestedSlots) {
            reordered[destination] = tabs[source]
        }
        tabs = reordered
    }

    public func rename(_ id: TabID, to title: String?) throws {
        tabs[try index(of: id)].titleOverride = normalized(title)
    }

    public func updateProgramTitle(_ title: String?, for id: TabID) throws {
        tabs[try index(of: id)].programTitle = normalized(title)
    }

    public func updateDirectory(_ directory: URL, for id: TabID) throws {
        tabs[try index(of: id)].directory = directory
    }

    public func close(_ id: TabID) throws {
        let index = try index(of: id)
        tabs.remove(at: index)
        if selectedID == id {
            selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    private func index(of id: TabID) throws -> Int {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            throw TabStoreError.unknownTab(id)
        }
        return index
    }

    private func normalized(_ title: String?) -> String? {
        guard let value = title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
