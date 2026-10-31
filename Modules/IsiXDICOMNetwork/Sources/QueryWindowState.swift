//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// A node listed in the sources of the Query window.
public struct QueryWindowSource: Equatable, Sendable {
    /// "address:port", as presets name the node.
    public var addressAndPort: String?
    public var aeTitle: String?
    /// Whether its box is checked.
    public var activated: Bool
    /// The node's entry, as Locations keeps it; nil when the window has none
    /// for the row.
    public var server: DICOMNode?

    public init(addressAndPort: String?, aeTitle: String?, activated: Bool, server: DICOMNode?) {
        self.addressAndPort = addressAndPort
        self.aeTitle = aeTitle
        self.activated = activated
        self.server = server
    }
}

/// What work off the main thread reads of the Query window, copied on the main
/// thread: when the window changes it, before a query or a retrieve starts,
/// and every second by the countdown of the automatic refresh. The window's
/// own state stays on the main actor; a query thread, a retrieve thread or a
/// sort run by one reads this copy instead.
public struct QueryWindowState: Equatable, Sendable {
    /// A sort descriptor of the results list, by its parts.
    public struct SortKey: Equatable, Sendable {
        public var key: String?
        public var ascending: Bool
        /// The name of the comparison selector; nil for `compare:`.
        public var selector: String?

        public init(key: String?, ascending: Bool, selector: String?) {
            self.key = key
            self.ascending = ascending
            self.selector = selector
        }
    }

    /// The order of the results list.
    public var sortKeys: [SortKey] = []
    /// Whether the window is on screen.
    public var visible = false
    /// The destination of a retrieve: 0 for this computer, then after a
    /// separator the nodes of Locations, as the "retrieve to" menu lists them.
    public var sendToIndex = 0
    /// The row selected in the sources, -1 for none.
    public var selectedSourceRow = -1
    /// The two date pickers, which every query of the window reads.
    public var fromDate = Date()
    public var toDate = Date()
    /// The sources, in the order of the table.
    public var sources: [QueryWindowSource] = []

    public init() {}

    /// The entry of each node a preset names, in its order: the last source
    /// with that "address:port" and, when the preset gives one, that AE title.
    /// A node no source lists is left out.
    public func servers(forNodes nodes: [String], aeTitles: [String]) -> [DICOMNode] {
        var servers: [DICOMNode] = []
        for (index, node) in nodes.enumerated() {
            let aeTitle: String? = index < aeTitles.count ? aeTitles[index] : nil
            var found: DICOMNode??
            for source in sources where source.addressAndPort == node && (aeTitle == nil || source.aeTitle == aeTitle) {
                found = .some(source.server)
            }
            if case .some(.some(let server)) = found {
                servers.append(server)
            }
        }
        return servers
    }

    /// The sources a query of one patient asks, by their row: the checked
    /// ones, or the selected row when none is checked.
    public func sourcesForPatientQuery() -> [QueryWindowSource] {
        let anyChecked = sources.contains { $0.activated }
        return sources.enumerated().filter { $0.element.activated || (!anyChecked && $0.offset == selectedSourceRow) }
            .map(\.element)
    }

    /// The nodes the window lists, as "address:port" and AE title, that a
    /// preset saves: the checked ones, or the selected row when none is checked.
    public func checkedNodes() -> (nodes: [String], aeTitles: [String]) {
        var chosen = sources.filter(\.activated)
        if chosen.isEmpty && selectedSourceRow >= 0 && selectedSourceRow < sources.count {
            chosen = [sources[selectedSourceRow]]
        }
        return (chosen.map { $0.addressAndPort ?? "" }, chosen.map { $0.aeTitle ?? "" })
    }
}

/// One query of the Query window, as the thread that runs it receives it: the
/// filters, the keyword of the custom field's attribute, and the sources as
/// they were when it started. Made on the main thread.
public struct QueryWindowRun: Equatable, Sendable {
    public var filters: QueryWindowFilters
    public var customFieldKeyword: String?
    public var sources: QueryWindowState

    public init(filters: QueryWindowFilters, customFieldKeyword: String?, sources: QueryWindowState) {
        self.filters = filters
        self.customFieldKeyword = customFieldKeyword
        self.sources = sources
    }

    /// The entries of the nodes to ask, in the order the filters name them.
    public var servers: [DICOMNode] {
        sources.servers(forNodes: filters.nodes ?? [], aeTitles: filters.nodeAETitles ?? [])
    }
}
