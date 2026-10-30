//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// What a plugin may read and change in the database, in the terms of the
// database's model (the Study, Series, Image and Album entities and their
// attribute names). The application's adapter of the plugin API turns the
// API's requests into these, so that what is accepted, how a search becomes a
// fetch and how a change is applied are decided here, once, and tested on a
// store of their own.

import CoreData
import Foundation

/// Why the database refused a plugin's request. Nothing was changed.
public enum PluginDatabaseRefusal: Error, Equatable, Sendable {
    /// A value the database does not accept.
    case invalid(String)
    /// No object with this identifier or name.
    case notFound(String)
}

/// The changes of what the user edits, checked before anything is changed.
public enum PluginDatabaseEdits {
    /// The comment fields, by index.
    public static let commentKeys = ["comment", "comment2", "comment3", "comment4"]
    /// The states of a study or a series: empty, unread, reviewed, dictated, validated.
    public static let stateRange = 0...4
    /// The longest comment: a Long Text value of DICOM, where the comments are also written.
    public static let maximumCommentLength = 10240

    /// The attribute values of the comment fields, or why they are refused.
    /// An empty text clears the field (nil value).
    static func commentValues(_ comments: [Int: String]) throws(PluginDatabaseRefusal) -> [String: Any?] {
        var values: [String: Any?] = [:]
        for (index, text) in comments {
            guard commentKeys.indices.contains(index) else {
                throw .invalid("There is no comment field \(index + 1); the fields are 1 to \(commentKeys.count).")
            }
            guard text.count <= maximumCommentLength else {
                throw .invalid("A comment has at most \(maximumCommentLength) characters.")
            }
            guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
                throw .invalid("A comment cannot contain a null character.")
            }
            values.updateValue(text.isEmpty ? nil : text, forKey: commentKeys[index])
        }
        return values
    }

    static func stateValue(_ state: Int) throws(PluginDatabaseRefusal) -> NSNumber {
        guard stateRange.contains(state) else {
            throw .invalid("The state \(state) does not exist; states go from \(stateRange.lowerBound) to \(stateRange.upperBound).")
        }
        return NSNumber(value: state)
    }

    /// A report is a web address (http or https) or the path of an existing
    /// file; an empty text removes it from the study.
    static func reportValue(_ report: String, fileExists: (String) -> Bool) throws(PluginDatabaseRefusal) -> String? {
        if report.isEmpty { return nil }
        if let url = URL(string: report), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            guard url.host?.isEmpty == false else { throw .invalid("The report address \(report) has no host.") }
            return report
        }
        guard report.hasPrefix("/") else {
            throw .invalid("A report is a web address (http or https) or the full path of a file: \(report)")
        }
        guard fileExists(report) else { throw .invalid("The report file \(report) does not exist.") }
        return report
    }

    /// The study's attribute values for the change.
    public static func studyValues(comments: [Int: String], state: Int?, report: String?, isLocked: Bool?,
                                   fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        throws(PluginDatabaseRefusal) -> [String: Any?] {
        var values = try commentValues(comments)
        if let state { values["stateText"] = try stateValue(state) }
        if let report { values.updateValue(try reportValue(report, fileExists: fileExists), forKey: "reportURL") }
        if let isLocked { values["lockedStudy"] = NSNumber(value: isLocked) }
        return values
    }

    /// The series' attribute values for the change.
    public static func seriesValues(comments: [Int: String], state: Int?) throws(PluginDatabaseRefusal) -> [String: Any?] {
        var values = try commentValues(comments)
        if let state { values["stateText"] = try stateValue(state) }
        return values
    }

    /// The image's attribute values for the change. The key image is the
    /// image's `isKeyImage`, which also updates its series' count.
    public static func imageValues(isKeyImage: Bool?, comments: [Int: String]) throws(PluginDatabaseRefusal) -> [String: Any?] {
        var values = try commentValues(comments)
        if let isKeyImage { values["isKeyImage"] = NSNumber(value: isKeyImage) }
        return values
    }

    /// Sets the values through the object's own setters, so the application
    /// does what it does when the user edits them, and saves. When the save
    /// fails, the object gets back the values it had and the error is
    /// thrown; the other unsaved changes of the context are left alone.
    public static func apply(_ values: [String: Any?], to object: NSManagedObject, save: () throws -> Void) throws {
        let keys = values.keys.sorted()
        let previous: [String: Any?] = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, object.value(forKey: key == "isKeyImage" ? "storedIsKeyImage" : key))
        })
        for key in keys { object.setValue(values[key] ?? nil, forKey: key) }
        do {
            try save()
        } catch {
            for key in keys {
                let stored = key == "isKeyImage" ? "storedIsKeyImage" : key
                object.willChangeValue(forKey: stored)
                object.setPrimitiveValue(previous[key] ?? nil, forKey: stored)
                object.didChangeValue(forKey: stored)
            }
            throw error
        }
    }
}

/// A search of studies, in the terms of the plugin API.
public struct PluginStudyQuery: Equatable, Sendable {
    public var studyInstanceUID: String?
    public var patientID: String?
    public var patientName: String?
    public var accessionNumber: String?
    public var studyDescription: String?
    public var modality: String?
    public var comment: String?
    public var dateFrom: Date?
    public var dateTo: Date?
    public var state: Int?
    public var limit: Int?

    public init(studyInstanceUID: String? = nil, patientID: String? = nil, patientName: String? = nil,
                accessionNumber: String? = nil, studyDescription: String? = nil, modality: String? = nil,
                comment: String? = nil, dateFrom: Date? = nil, dateTo: Date? = nil, state: Int? = nil, limit: Int? = nil) {
        self.studyInstanceUID = studyInstanceUID
        self.patientID = patientID
        self.patientName = patientName
        self.accessionNumber = accessionNumber
        self.studyDescription = studyDescription
        self.modality = modality
        self.comment = comment
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.state = state
        self.limit = limit
    }

    /// The fetch of the Study entity: every criterion given, the newest study
    /// first. Text criteria match a part of the value, ignoring case and
    /// accents; identifiers and the modality the whole value.
    public func predicate() throws(PluginDatabaseRefusal) -> NSPredicate {
        if let limit, limit < 0 { throw .invalid("A search limit cannot be negative.") }
        if let dateFrom, let dateTo, dateFrom > dateTo { throw .invalid("The search dates end before they start.") }
        var parts: [NSPredicate] = []
        if let studyInstanceUID { parts.append(NSPredicate(format: "studyInstanceUID == %@", studyInstanceUID)) }
        if let patientID { parts.append(NSPredicate(format: "patientID == %@", patientID)) }
        if let accessionNumber { parts.append(NSPredicate(format: "accessionNumber == %@", accessionNumber)) }
        if let patientName, !patientName.isEmpty { parts.append(NSPredicate(format: "name CONTAINS[cd] %@", patientName)) }
        if let studyDescription, !studyDescription.isEmpty {
            parts.append(NSPredicate(format: "studyName CONTAINS[cd] %@", studyDescription))
        }
        if let modality { parts.append(NSPredicate(format: "ANY series.modality ==[c] %@", modality)) }
        if let comment, !comment.isEmpty {
            parts.append(NSCompoundPredicate(orPredicateWithSubpredicates: PluginDatabaseEdits.commentKeys.map {
                NSPredicate(format: "%K CONTAINS[cd] %@", $0, comment)
            }))
        }
        if let dateFrom { parts.append(NSPredicate(format: "date >= %@", dateFrom as NSDate)) }
        if let dateTo { parts.append(NSPredicate(format: "date <= %@", dateTo as NSDate)) }
        if let state {
            parts.append(state == 0 ? NSPredicate(format: "stateText == nil OR stateText == 0")
                                    : NSPredicate(format: "stateText == %d", state))
        }
        return parts.isEmpty ? NSPredicate(value: true) : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    /// The fetch request of the Study entity for this search.
    public func fetchRequest() throws(PluginDatabaseRefusal) -> NSFetchRequest<NSManagedObject> {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Study")
        request.predicate = try predicate()
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false),
                                   NSSortDescriptor(key: "studyInstanceUID", ascending: true)]
        if let limit { request.fetchLimit = limit }
        return request
    }
}

/// What a plugin may do with albums.
public enum PluginAlbumRules {
    public static let maximumNameLength = 128

    /// The name of a new album, or why it is refused: a name is not empty, has
    /// no line break, and no album has it already.
    public static func newAlbumName(_ name: String, existing: [String]) throws(PluginDatabaseRefusal) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw .invalid("An album needs a name.") }
        guard trimmed.count <= maximumNameLength else { throw .invalid("An album name has at most \(maximumNameLength) characters.") }
        guard trimmed.rangeOfCharacter(from: .newlines) == nil else { throw .invalid("An album name is one line.") }
        guard !existing.contains(trimmed) else { throw .invalid("There is already an album named \(trimmed).") }
        return trimmed
    }

    /// Studies are added to and removed from albums that are not smart: a
    /// smart album holds what its rule selects.
    public static func checkMembershipChange(albumName: String, isSmart: Bool) throws(PluginDatabaseRefusal) {
        if isSmart { throw .invalid("The album \(albumName) is a smart album: its rule chooses its studies.") }
    }
}
