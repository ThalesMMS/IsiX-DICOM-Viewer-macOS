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
// The node lists, the auto-query instances and the rules of this module are
// values of the preferences: whoever reads them through this module gets the
// preferences module's types (PropertyListValue, the stores and the keys) too.
@_exported import IsiXPreferences

/// The preferences the node lists are kept in. The application gives its
/// own; a test gives `MemoryPreferences`.
public protocol DICOMNodePreferences: PreferenceStore {}

/// The node lists of the preferences, read and written as typed nodes: the
/// DIMSE nodes of `SERVERS` and the DICOMweb nodes of `DICOMWEB_SERVERS`.
/// Each node is written back with the keys and values it was read with.
public struct DICOMNodeStore: Sendable {
    /// The DIMSE nodes of Locations.
    public static let dicomNodesKey = NetworkPreferences.dicomNodes.name
    /// The DICOMweb nodes, kept apart from the DIMSE nodes.
    public static let dicomwebNodesKey = NetworkPreferences.dicomwebNodes.name
    /// Whether `SERVERS` is replaced by the list at `syncDICOMNodesURL`.
    public static let syncKey = NetworkPreferences.syncsDICOMNodes.name
    public static let syncURLKey = NetworkPreferences.syncDICOMNodesURL.name
    /// Whether the DICOM nodes Bonjour finds are listed with the stored ones.
    public static let bonjourKey = NetworkPreferences.searchDICOMBonjour.name

    private let preferences: any PreferenceStore

    public init(preferences: any PreferenceStore) {
        self.preferences = preferences
    }

    // MARK: DIMSE nodes

    /// The nodes of `SERVERS`, as stored and in their order; an entry that is
    /// not a dictionary is not a node.
    public func dicomNodes() -> [DICOMNode] {
        Self.dicomNodes(fromPropertyList: preferences.object(forKey: Self.dicomNodesKey))
    }

    /// Whether `SERVERS` was given as an argument of the launch. That list is
    /// for that launch only: written back, it would replace the list of the
    /// preferences for good.
    public var dicomNodesGivenAsArgument: Bool {
        preferences.isGivenAsLaunchArgument(Self.dicomNodesKey)
    }

    /// Writes `SERVERS`.
    public func saveDICOMNodes(_ nodes: [DICOMNode]) {
        preferences.set(nodes.map(\.propertyList), forKey: Self.dicomNodesKey)
    }

    /// The nodes of `SERVERS` with what an earlier version left normalized
    /// (`DICOMNode.normalize()`), written back when something changed, unless
    /// the list was given as an argument of the launch. An entry that is not
    /// a dictionary stays where it is in what is written.
    public func normalizedDICOMNodes() -> [DICOMNode] {
        let stored = preferences.object(forKey: Self.dicomNodesKey) as? [Any] ?? []
        var nodes: [DICOMNode] = []
        var written: [Any] = []
        var changed = false
        for element in stored {
            guard var node = DICOMNode(propertyList: element) else {
                written.append(element)
                continue
            }
            if node.normalize() {
                changed = true
                written.append(node.propertyList)
            } else {
                written.append(element)
            }
            nodes.append(node)
        }
        if changed && !dicomNodesGivenAsArgument {
            preferences.set(written, forKey: Self.dicomNodesKey)
        }
        return nodes
    }

    /// Changes the first node of `SERVERS` that `matches` and writes the list
    /// back, every other entry as it was. Returns whether a node matched;
    /// nothing is written when none did.
    @discardableResult
    public func updateFirstDICOMNode(where matches: (DICOMNode) -> Bool, _ change: (inout DICOMNode) -> Void) -> Bool {
        var stored = preferences.object(forKey: Self.dicomNodesKey) as? [Any] ?? []
        for (index, element) in stored.enumerated() {
            guard var node = DICOMNode(propertyList: element), matches(node) else { continue }
            change(&node)
            stored[index] = node.propertyList
            preferences.set(stored, forKey: Self.dicomNodesKey)
            return true
        }
        return false
    }

    /// Replaces `SERVERS` with the DIMSE nodes of a list read from
    /// `syncDICOMNodesURL`. DICOMweb nodes have a list of their own, so an
    /// entry of the former DICOMweb mode, or one without an AE title, is left out.
    public func replaceDICOMNodes(withSyncedList list: [Any]) {
        saveDICOMNodes(Self.dicomNodes(fromPropertyList: list).filter(\.isDIMSE))
    }

    /// Whether `SERVERS` is replaced by the list at `syncDICOMNodesURL`.
    public var syncsDICOMNodes: Bool {
        preferences[NetworkPreferences.syncsDICOMNodes]
    }

    /// Where `SERVERS` is synced from; nil when no URL is set, or when it is
    /// one the list may not be read from.
    public var syncURL: URL? {
        preferences[NetworkPreferences.syncDICOMNodesURL].flatMap(URL.init(string:)).flatMap {
            RemoteConfigurationURL.isAcceptable($0) ? $0 : nil
        }
    }

    /// Whether the nodes Bonjour finds are listed with the stored ones.
    public var searchesBonjour: Bool {
        preferences[NetworkPreferences.searchDICOMBonjour]
    }

    // MARK: DICOMweb nodes

    /// The nodes of `DICOMWEB_SERVERS`, valid or not, in the order the
    /// Locations pane shows them.
    public func dicomwebNodes() -> [DICOMwebNodeRecord] {
        Self.dicomwebNodes(fromPropertyList: preferences.object(forKey: Self.dicomwebNodesKey))
    }

    /// Writes `DICOMWEB_SERVERS`.
    public func saveDICOMwebNodes(_ nodes: [DICOMwebNodeRecord]) {
        preferences.set(nodes.map(\.propertyList), forKey: Self.dicomwebNodesKey)
    }

    // MARK: Conversions

    /// The DIMSE nodes of a stored list; nil or anything but an array is none.
    public static func dicomNodes(fromPropertyList list: Any?) -> [DICOMNode] {
        (list as? [Any] ?? []).compactMap(DICOMNode.init(propertyList:))
    }

    /// The DICOMweb nodes of a stored list; nil or anything but an array is none.
    public static func dicomwebNodes(fromPropertyList list: Any?) -> [DICOMwebNodeRecord] {
        (list as? [Any] ?? []).compactMap(DICOMwebNodeRecord.init(propertyList:))
    }
}
