//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import CryptoKit

/// A per-export snapshot. Only the ordinary export panel opts into these names.
@objc(HorosExportFolderNaming)
public final class ExportFolderNaming: NSObject {
    private let patient: Int
    private let study: Int
    private let series: Int

    @objc public init(options: NSDictionary) {
        patient = Self.selection(options["patient"], maximum: 1)
        study = Self.selection(options["study"], maximum: 2)
        series = Self.selection(options["series"], maximum: 3)
        super.init()
    }

    /// Anonymous output paths accept no patient/study/series metadata at all.
    @objc(anonymousPathForBatch:studyIndex:seriesIndex:)
    public static func anonymousPath(batch: NSUUID, studyIndex: Int, seriesIndex: Int) -> String {
        "Anonymized-\(batch.uuidString)/" + String(format: "Study-%04ld/Series-%04ld", studyIndex, seriesIndex)
    }

    private static func selection(_ value: Any?, maximum: Int) -> Int {
        guard let value = value as? NSNumber, (0...maximum).contains(value.intValue) else { return 0 }
        return value.intValue
    }

    /// A bounded single component; retain readable Unicode without permitting traversal.
    static func clean(_ value: String?) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:<>|?*\""))
        let replaced = (value ?? "").precomposedStringWithCanonicalMapping.unicodeScalars.map {
            forbidden.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0) ? "_" : String($0)
        }.joined().trimmingCharacters(in: CharacterSet(charactersIn: " ._"))
        var result = ""
        for character in replaced {
            guard result.utf8.count + String(character).utf8.count <= 96 else { break }
            result.append(character)
        }
        return result
    }

    private static func reference(_ identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func component(_ value: String?, identity: String, kind: String) -> String {
        let name = clean(value)
        // Full digest avoids leaking a patient identity used by the database as a key.
        // All configured names carry identity, including nonempty descriptions.
        return (name.isEmpty ? kind : name) + "-" + reference(identity)
    }

    @objc(patientFolderWithName:patientID:identity:)
    public func patientFolder(name: String?, patientID: String?, identity: String) -> String {
        Self.component(patient == 1 ? patientID : name, identity: identity, kind: "Patient")
    }

    @objc(studyFolderWithName:studyID:uid:identity:)
    public func studyFolder(name: String?, studyID: String?, uid: String?, identity: String) -> String {
        let value: String?
        switch study {
        case 1: value = name
        case 2: value = uid
        default: value = [name, studyID].compactMap { $0 }.filter { !Self.clean($0).isEmpty }.joined(separator: " - ")
        }
        return Self.component(value, identity: uid?.isEmpty == false ? uid! : identity, kind: "Study")
    }

    @objc(seriesFolderWithName:number:uid:identity:)
    public func seriesFolder(name: String?, number: NSNumber?, uid: String?, identity: String) -> String {
        let value: String?
        switch series {
        case 1: value = name
        case 2: value = number?.stringValue
        case 3: value = uid
        default: value = [name, number?.stringValue].compactMap { $0 }.filter { !Self.clean($0).isEmpty }.joined(separator: "_")
        }
        return Self.component(value, identity: uid?.isEmpty == false ? uid! : identity, kind: "Series")
    }
}

/// The folders one export hands out. A source that reaches a folder another
/// source of the same export already holds gets a numbered sibling, so nothing
/// is asked about a folder the export itself just made.
@objc(HorosExportFolderClaims)
public final class ExportFolderClaims: NSObject {
    private var holders: [String: String] = [:]
    private var granted: [String: String] = [:]

    /// Default volumes fold case and normalization: such names are one folder.
    private static func key(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func sibling(of path: String, copy: Int, limit: Int) -> String {
        let suffix = "_\(copy)"
        var name = (path as NSString).lastPathComponent
        if limit > suffix.count, name.count + suffix.count > limit {
            name = String(name.prefix(limit - suffix.count))
        }
        return ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name + suffix)
    }

    /// The same source always gets the same folder back. `componentLimit` bounds
    /// a sibling's name, as DICOMDIR file IDs require; 0 leaves it free.
    @objc(folderForSource:proposedPath:componentLimit:)
    public func folder(source: String, proposed: String, componentLimit: Int) -> String {
        let request = Self.key(proposed) + "\u{0}" + source
        if let path = granted[request] { return path }
        var path = proposed
        var copy = 2
        while let holder = holders[Self.key(path)], holder != source {
            path = Self.sibling(of: proposed, copy: copy, limit: componentLimit)
            copy += 1
        }
        holders[Self.key(path)] = source
        granted[request] = path
        return path
    }
}
