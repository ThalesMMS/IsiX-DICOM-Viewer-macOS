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

/// A DIMSE node of Locations: one entry of the `SERVERS` preference.
///
/// The entry is kept whole, every key with the value and the kind it was
/// stored with: the Locations pane edits it through bindings, plugins read it
/// by key, and keys this version does not read (TLS, WADO, a send's thread
/// count, the direct transfer of a Horos peer) must come back unchanged. The
/// typed properties read and write the keys the network code uses, with the
/// defaults it has always given a missing key.
public struct DICOMNode: Sendable, Hashable {
    /// The keys of a stored node.
    public enum Key {
        public static let aeTitle = "AETitle"
        public static let address = "Address"
        public static let port = "Port"
        public static let description = "Description"
        public static let activated = "Activated"
        public static let send = "Send"
        public static let queryRetrieve = "QR"
        public static let retrieveMode = "retrieveMode"
        public static let transferSyntax = "TransferSyntax"
        public static let tlsEnabled = "TLSEnabled"
        /// The node's Modality Worklist is listed in the Modality Worklist window.
        public static let modalityWorklist = "MWL"
        /// The retrieve method before `retrieveMode`: true for C-GET.
        public static let legacyCGet = "CGET"
        /// The retrieve method before `retrieveMode`: true for C-MOVE.
        public static let legacyCMove = "CMOVE"
        /// The retrieve method before `retrieveMode`: true for WADO.
        public static let legacyWADO = "WADO"
    }

    /// The entry as stored, every key included.
    public var entry: [String: PropertyListValue]

    public init(entry: [String: PropertyListValue] = [:]) {
        self.entry = entry
    }

    /// The node an entry of `SERVERS` describes; nil for an entry that is not
    /// a dictionary of property-list values.
    public init?(propertyList: Any) {
        guard let dictionary = propertyList as? [String: Any],
              let entry = PropertyListValue.dictionary(dictionary) else { return nil }
        self.entry = entry
    }

    /// The entry as the preferences store it.
    public var propertyList: [String: Any] {
        entry.mapValues(\.object)
    }

    public subscript(key: String) -> PropertyListValue? {
        get { entry[key] }
        set { entry[key] = newValue }
    }

    // MARK: Typed settings

    /// The called AE title, when stored as text.
    public var aeTitle: String? {
        get { entry[Key.aeTitle]?.stringValue }
        set { entry[Key.aeTitle] = newValue.map(PropertyListValue.string) }
    }

    /// The host name or address, when stored as text.
    public var address: String? {
        get { entry[Key.address]?.stringValue }
        set { entry[Key.address] = newValue.map(PropertyListValue.string) }
    }

    /// The port, stored as text by the Locations pane and as a number by
    /// others: its integer value, 0 when missing or not a number.
    public var port: Int {
        entry[Key.port]?.intValue ?? 0
    }

    /// The port as `-intValue` reads the stored value, as associations and
    /// the web portal take it: the 32-bit value of a number, the leading
    /// integer of text, 0 when missing or not a number.
    public var associationPort: Int32 {
        switch entry[Key.port] {
        case .string(let text): return (text as NSString).intValue
        case .integer(let number): return NSNumber(value: number).int32Value
        case .real(let number): return NSNumber(value: number).int32Value
        case .boolean(let flag): return flag ? 1 : 0
        default: return 0
        }
    }

    /// The description the user gave the node, when stored as text.
    public var nodeDescription: String? {
        get { entry[Key.description]?.stringValue }
        set { entry[Key.description] = newValue.map(PropertyListValue.string) }
    }

    /// Whether the node is turned on; a node without the key is.
    public var isActivated: Bool {
        entry[Key.activated]?.boolValue ?? true
    }

    /// Whether the node is a send destination; a node without the key is.
    public var sends: Bool {
        entry[Key.send]?.boolValue ?? true
    }

    /// Whether the node is queried and retrieved from; a node without the key is.
    public var queriesAndRetrieves: Bool {
        entry[Key.queryRetrieve]?.boolValue ?? true
    }

    /// Whether the Modality Worklist window asks the node for its worklist; a
    /// node without the key is not asked.
    public var providesModalityWorklist: Bool {
        entry[Key.modalityWorklist]?.boolValue ?? false
    }

    /// How the node is retrieved from; nil when the key is missing.
    public var retrieveModeValue: Int? {
        entry[Key.retrieveMode]?.intValue
    }

    /// The transfer syntax chosen for sending to the node, as the node editor
    /// numbers them; nil when the key is missing.
    public var transferSyntax: Int? {
        entry[Key.transferSyntax]?.intValue
    }

    /// Whether the node's association uses TLS.
    public var usesTLS: Bool {
        entry[Key.tlsEnabled]?.boolValue ?? false
    }

    /// Whether the entry is a DIMSE node: one with an AE title that is not
    /// blank, and not of the former DICOMweb mode, whose entries move to
    /// `DICOMWEB_SERVERS` at launch.
    public var isDIMSE: Bool {
        if retrieveModeValue == DICOMRetrieveMode.dicomWeb.rawValue { return false }
        let title = aeTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !title.isEmpty
    }

    /// Whether the node is listed: a DIMSE node, turned on, and a send
    /// destination or queried when only those are asked for.
    public func isListed(sendOnly: Bool, queryRetrieveOnly: Bool) -> Bool {
        isDIMSE && isActivated && (!sendOnly || sends) && (!queryRetrieveOnly || queriesAndRetrieves)
    }

    /// Gives an entry of an earlier version what this one reads: `Activated`
    /// on when missing, and `retrieveMode` in place of the former CGET, CMOVE
    /// and WADO flags (C-GET when CGET was on, else C-MOVE). Returns whether
    /// the entry changed.
    @discardableResult
    public mutating func normalize() -> Bool {
        var changed = false
        if entry[Key.activated] == nil {
            entry[Key.activated] = .boolean(true)
            changed = true
        }
        if entry[Key.retrieveMode] == nil {
            let getting = entry[Key.legacyCGet]?.boolValue ?? false
            entry[Key.retrieveMode] = .integer((getting ? DICOMRetrieveMode.cGet : DICOMRetrieveMode.cMove).rawValue)
            entry[Key.legacyCGet] = nil
            entry[Key.legacyCMove] = nil
            entry[Key.legacyWADO] = nil
            changed = true
        }
        return changed
    }
}

/// Encoded as the stored entry: a node encoded with PropertyListEncoder is the
/// dictionary `SERVERS` holds.
extension DICOMNode: Codable {
    public init(from decoder: Decoder) throws {
        entry = try decoder.singleValueContainer().decode([String: PropertyListValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entry)
    }
}
