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

/// What a computer that shares its database announces over Bonjour, in the
/// form released Horos and OsiriX instances read.
public struct SharedDatabaseAnnouncement: Sendable, Equatable {

    /// The service type every Horos and OsiriX instance browses for.
    public static let serviceType = "_osirixdb._tcp."

    /// The port the database is shared on.
    public static let port: UInt16 = 8780

    /// The AE title of the DICOM listener (`AETITLE`); "OSIRIX" when unset.
    public var aeTitle: String?
    /// The port of the DICOM listener (`AEPORT`), as stored; "11112" when unset.
    public var dicomPort: String?
    /// The identifier of this installation, when it has one.
    public var uid: String?
    /// The direct transfer between Horos peers, when it is offered: both are
    /// announced only when not empty.
    public var directTransferVersion: String?
    public var directTransferPort: String?

    public init(aeTitle: String?, dicomPort: String?, uid: String?,
                directTransferVersion: String? = nil, directTransferPort: String? = nil) {
        self.aeTitle = aeTitle
        self.dicomPort = dicomPort
        self.uid = uid
        self.directTransferVersion = directTransferVersion
        self.directTransferPort = directTransferPort
    }

    /// The TXT record: its keys and their texts.
    public var txtRecord: [String: String] {
        var record = ["AETitle": aeTitle ?? "OSIRIX", "port": dicomPort ?? "11112"]
        if let uid {
            record["UID"] = uid
        }
        if let directTransferVersion, !directTransferVersion.isEmpty {
            record["HorosDirectTransferVersion"] = directTransferVersion
        }
        if let directTransferPort, !directTransferPort.isEmpty {
            record["HorosDirectTransferPort"] = directTransferPort
        }
        return record
    }

    /// Whether an advertisement made earlier must go: when the listener is not
    /// ready (port zero: a service created then kept port zero forever), or
    /// when it was made for another port or under another name than the one
    /// the preferences hold now. Names are compared literally, and a missing
    /// name never matches.
    public static func mustWithdraw(advertisedPort: Int?, advertisedName: String?, listenerPort: Int, name: String?) -> Bool {
        if listenerPort == 0 { return true }
        guard let advertisedPort else { return false }
        guard let advertisedName, let name else { return true }
        return advertisedPort != listenerPort || !(advertisedName as NSString).isEqual(to: name)
    }
}

/// The TXT record of a shared database that Bonjour found, as the Sources
/// list keeps it: the AE title, the DICOM port and the identifier as text, the
/// other keys as they came. NSNetService's encoder writes a key whose value is
/// empty without its `=`, as RFC 6763 allows; such a text key is read as empty
/// text, so a peer that announces an empty AE title, port or identifier is
/// still listed with the rest of what it announced.
public enum SharedDatabaseServiceRecord {

    /// The keys read as UTF-8 text.
    public static let textKeys: Set<String> = ["AETitle", "port", "UID"]

    /// A value of a TXT record: bytes, or a key that came without any.
    public enum Value: Sendable, Equatable {
        case data(Data)
        case none
    }

    /// A value as the Sources list keeps it.
    public enum Decoded: Sendable, Equatable {
        case text(String)
        case data(Data)
        case none
    }

    /// Why a record cannot be kept: one of the text keys came with bytes that
    /// are not UTF-8.
    public enum Failure: Error, Sendable, Equatable {
        case notUTF8(key: String)
    }

    /// The record's entries, decoded; keys are looked at in order, so the
    /// failure names the first offending key.
    public static func decode(_ entries: [String: Value]) throws(Failure) -> [String: Decoded] {
        var decoded: [String: Decoded] = [:]
        for key in entries.keys.sorted() {
            let value = entries[key]!
            guard textKeys.contains(key) else {
                switch value {
                case .data(let data): decoded[key] = .data(data)
                case .none: decoded[key] = Decoded.none
                }
                continue
            }
            guard case .data(let data) = value else {
                decoded[key] = .text("")
                continue
            }
            // Foundation's decoding, as the record was always read.
            guard let text = NSString(data: data, encoding: String.Encoding.utf8.rawValue) else {
                throw .notUTF8(key: key)
            }
            decoded[key] = .text(text as String)
        }
        return decoded
    }
}

/// The sources the database window lists besides the local database, in the
/// order it lists them.
public enum DatabaseSourceKind: String, Sendable, CaseIterable {
    /// Another local database folder.
    case localPath
    /// A shared database entered by address.
    case fixedIP
    /// A DICOM node to send to.
    case dicomDestination

    /// `items` grouped by kind in the order above, each group in its own
    /// order; an item of no listed kind is left out.
    public static func arranged<Item>(_ items: [Item], kind: (Item) -> String?) -> [Item] {
        var arranged: [Item] = []
        arranged.reserveCapacity(items.count)
        for each in allCases {
            arranged += items.filter { kind($0).map { ($0 as NSString).isEqual(to: each.rawValue) } ?? false }
        }
        return arranged
    }
}
