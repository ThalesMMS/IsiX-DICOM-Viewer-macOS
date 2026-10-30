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

/// A study, series or image of the database as a C-FIND response reads it.
/// Values come through key-value coding, on the queue of the object's context.
public protocol SCPResponseRecord {
    func value(forKeyPath keyPath: String) -> Any?
    func primitiveValue(forKey key: String) -> Any?
    /// The DA and TM values of a date (DCM.framework's dateString and timeString).
    func dicomDate(_ date: Any) -> String?
    func dicomTime(_ date: Any) -> String?
    /// Whether the SOP class `uid` stores images.
    func isImageStorage(_ uid: Any?) -> Bool
}

/// The text of one attribute of a response, before it is encoded.
public enum SCPResponseText: Equatable, Sendable {
    /// In the response's character set (SCPResponseCharacterSet).
    case encoded(String?)
    /// In ISO-8859-1: dates, times, UIDs and numbers of the database.
    case latin1(String?)
    /// A number written as it is.
    case ascii(String)
}

/// What a response does with one requested key.
public enum SCPResponseEntry: Equatable, Sendable {
    /// Sets the attribute `tag` to the text.
    case put(DICOMTag, SCPResponseText)
    /// Answers the key with an empty value.
    case empty(DICOMTag)
    /// Leaves the key out. `failure`: why reading it failed, which the log
    /// reports with the response as built so far; nil when the key is simply
    /// not answered.
    case omitted(DICOMTag, failure: String?)
}

/// How the listener answers a C-FIND from the records of its database.
public enum SCPResponseIdentifier {

    /// The keys of a request in the order the listener answers them: that of
    /// a dictionary keyed by "element,group", in which it kept them. The order
    /// matters only where two keys set one attribute.
    public static func keys(of tags: [DICOMTag]) -> [DICOMTag] {
        let template = NSMutableDictionary()
        for tag in tags { template[String(format: "%d,%d", Int32(tag.element), Int32(tag.group))] = NSNumber(value: true) }
        return template.allKeys.compactMap { key -> DICOMTag? in
            let parts = (key as? String)?.components(separatedBy: ",") ?? []
            guard parts.count == 2 else { return nil }
            return DICOMTag(UInt16(truncatingIfNeeded: (parts[1] as NSString).intValue),
                            UInt16(truncatingIfNeeded: (parts[0] as NSString).intValue))
        }
    }

    /// What answers each of `keys` for `record` at `level`. A key whose source
    /// is absent from the record, or that the level does not know, is answered
    /// empty.
    public static func entries(level: SCPQueryLevel, keys: [DICOMTag], record: some SCPResponseRecord) -> [SCPResponseEntry] {
        let table = rules[level] ?? [:]
        return keys.map { key in
            guard let rule = table[key] else { return .empty(key) }
            if let condition = rule.condition, record.value(forKeyPath: condition) == nil { return .empty(key) }
            return entry(rule.source, tag: rule.target ?? key, record: record)
        }
    }

    /// The Modalities in Study of a study's series modalities, `values` in the
    /// order of their set: each once, SC and SR last, backslash-separated. nil
    /// when one is not a string (a series without a modality).
    public static func modalitiesInStudy(_ values: [Any]) -> String? {
        var modalities: [String] = []
        var sc = false, sr = false
        for value in values {
            guard let modality = value as? String else { return nil }
            if modalities.contains(modality) { continue }
            if modality == "SR" { sr = true } else if modality == "SC" { sc = true } else { modalities.append(modality) }
        }
        if sc { modalities.append("SC") }
        if sr { modalities.append("SR") }
        return modalities.joined(separator: "\\")
    }

    // MARK: - The rules of each level

    private enum Source {
        /// The value at the key path, in the response's character set.
        case encoded(String)
        /// The stored value of the key, without its accessor.
        case encodedPrimitive(String)
        /// -stringValue of the number at the key path, in the response's character set.
        case encodedNumber(String)
        case latin1(String)
        /// -stringValue of the number at the key path, in ISO-8859-1.
        case latin1Number(String)
        case date(String)
        case time(String)
        /// -intValue of the value at the key path.
        case integer(String)
        /// The number of objects of the to-many key path.
        case count(String)
        /// The set of modalities at the key path.
        case modalities(String)
        /// The study's own modality, a string, read as a set: the key is left out.
        case studyModalityAsSet
        /// The SOP classes of the study's series, backslash-separated.
        case sopClasses(String)
        /// An image's number of frames, only for image storage.
        case numberOfFrames
        /// The series' comment, or else the study's, or else empty.
        case imageComments
    }

    private struct Rule {
        /// The key path that must have a value; nil: none.
        let condition: String?
        let source: Source
        /// The attribute set, when it is not the key's.
        var target: DICOMTag? = nil
    }

    private static func entry(_ source: Source, tag: DICOMTag, record: some SCPResponseRecord) -> SCPResponseEntry {
        func string(_ value: Any?) -> String? { value as? String }
        func number(_ value: Any?) -> String? { (value as? NSNumber)?.stringValue ?? (value as? String) }
        switch source {
        case .encoded(let path): return .put(tag, .encoded(string(record.value(forKeyPath: path))))
        case .encodedPrimitive(let key): return .put(tag, .encoded(string(record.primitiveValue(forKey: key))))
        case .encodedNumber(let path): return .put(tag, .encoded(number(record.value(forKeyPath: path))))
        case .latin1(let path): return .put(tag, .latin1(string(record.value(forKeyPath: path))))
        case .latin1Number(let path): return .put(tag, .latin1(number(record.value(forKeyPath: path))))
        case .date(let path): return .put(tag, .latin1(record.value(forKeyPath: path).flatMap(record.dicomDate)))
        case .time(let path): return .put(tag, .latin1(record.value(forKeyPath: path).flatMap(record.dicomTime)))
        case .integer(let path):
            let value = record.value(forKeyPath: path) as? NSNumber
            return .put(tag, .ascii(String(value?.int32Value ?? 0)))
        case .count(let path):
            let value = record.value(forKeyPath: path)
            let count = (value as? NSSet)?.count ?? (value as? NSArray)?.count ?? (value as? NSOrderedSet)?.count ?? 0
            return .put(tag, .ascii(String(Int32(truncatingIfNeeded: count))))
        case .modalities(let path):
            guard let modalities = modalitiesInStudy(allObjects(record.value(forKeyPath: path))) else {
                return .omitted(tag, failure: "a series of the study has no modality")
            }
            return .put(tag, .latin1(modalities))
        case .studyModalityAsSet:
            return .omitted(tag, failure: "-[NSString allObjects]: the study's modality is a string, not a set")
        case .sopClasses(let path):
            return .put(tag, .latin1((allObjects(record.value(forKeyPath: path)) as NSArray).componentsJoined(by: "\\")))
        case .numberOfFrames:
            guard record.isImageStorage(record.value(forKeyPath: "series.seriesSOPClassUID")) else {
                return .omitted(tag, failure: nil)
            }
            return .put(tag, .latin1(number(record.value(forKeyPath: "numberOfFrames"))))
        case .imageComments:
            if let comment = string(record.value(forKeyPath: "series.comment")), !comment.isEmpty { return .put(tag, .encoded(comment)) }
            if let comment = string(record.value(forKeyPath: "series.study.comment")), !comment.isEmpty { return .put(tag, .encoded(comment)) }
            return .empty(tag)
        }
    }

    /// -allObjects of a set, the objects of an array.
    private static func allObjects(_ value: Any?) -> [Any] {
        if let set = value as? NSSet { return set.allObjects }
        if let array = value as? NSArray { return array as [AnyObject] }
        return []
    }

    /// The keys each level answers from its records. `prefix` reaches the
    /// study from a series ("study.") or an image ("series.study.").
    private static func studyRules(_ prefix: String) -> [DICOMTag: Rule] {
        let p = prefix
        return [
            .patientID: Rule(condition: p + "patientID", source: .encoded(p + "patientID")),
            .patientSex: Rule(condition: p + "patientSex", source: .encoded(p + "patientSex")),
            .accessionNumber: Rule(condition: p + "accessionNumber", source: .encoded(p + "accessionNumber")),
            .studyDescription: Rule(condition: p + "studyName", source: .encoded(p + "studyName")),
            .patientBirthDate: Rule(condition: p + "dateOfBirth", source: .date(p + "dateOfBirth")),
            .studyDate: Rule(condition: p + "date", source: .date(p + "date")),
            .studyTime: Rule(condition: p + "date", source: .time(p + "date")),
            .studyInstanceUID: Rule(condition: p + "studyInstanceUID", source: .latin1(p + "studyInstanceUID")),
            .studyID: Rule(condition: p + "id", source: .latin1(p + "id")),
            .referringPhysicianName: Rule(condition: p + "referringPhysician", source: .encoded(p + "referringPhysician")),
            .performingPhysicianName: Rule(condition: p + "performingPhysician", source: .encoded(p + "performingPhysician")),
            .institutionName: Rule(condition: p + "institutionName", source: .encoded(p + "institutionName")),
            .numberOfStudyRelatedInstances: Rule(condition: p + "noFiles", source: .integer(p + "rawNoFiles")),
        ]
    }

    private static let rules: [SCPQueryLevel: [DICOMTag: Rule]] = {
        var study = studyRules("")
        study[.patientName] = Rule(condition: "name", source: .encodedPrimitive("name"))
        study[.imageComments] = Rule(condition: "comment", source: .encoded("comment"))
        study[.interpretationStatusID] = Rule(condition: nil, source: .encodedNumber("stateText"))
        study[.studyComments] = Rule(condition: "comment", source: .encoded("comment"))
        for (tag, time) in [(DICOMTag.contentDate, false), (.contentTime, true), (.seriesDate, false),
                            (.seriesTime, true), (.acquisitionDate, false), (.acquisitionTime, true)] {
            study[tag] = Rule(condition: "date", source: time ? .time("date") : .date("date"))
        }
        study[.sopClassUID] = Rule(condition: "series.seriesSOPClassUID", source: .sopClasses("series.seriesSOPClassUID"))
        study[.modalitiesInStudy] = Rule(condition: "modality", source: .modalities("series.modality"))
        study[.numberOfStudyRelatedSeries] = Rule(condition: "series", source: .count("series"))

        var series = studyRules("study.")
        series[.seriesDescription] = Rule(condition: "name", source: .encoded("name"))
        for (tag, time) in [(DICOMTag.seriesDate, false), (.seriesTime, true), (.acquisitionDate, false), (.acquisitionTime, true)] {
            series[tag] = Rule(condition: "date", source: time ? .time("date") : .date("date"))
        }
        series[.modality] = Rule(condition: "modality", source: .latin1("modality"))
        series[.seriesNumber] = Rule(condition: "id", source: .latin1Number("id"))
        series[.seriesInstanceUID] = Rule(condition: "seriesDICOMUID", source: .latin1("seriesDICOMUID"))
        series[.numberOfSeriesRelatedInstances] = Rule(condition: "noFiles", source: .integer("rawNoFiles"))
        series[.patientName] = Rule(condition: "study.name", source: .encoded("study.name"))
        series[.imageComments] = Rule(condition: "comment", source: .encoded("comment"))
        series[.interpretationStatusID] = Rule(condition: "study.stateText", source: .encodedNumber("study.stateText"))
        series[.studyComments] = Rule(condition: "study.comment", source: .encoded("study.comment"))
        series[.sopClassUID] = Rule(condition: "seriesSOPClassUID", source: .latin1("seriesSOPClassUID"))
        series[.modalitiesInStudy] = Rule(condition: "study.modality", source: .studyModalityAsSet)
        series[.numberOfStudyRelatedSeries] = Rule(condition: nil, source: .count("study.series"))

        var image = studyRules("series.study.")
        image[.sliceLocation] = Rule(condition: "sliceLocation", source: .latin1Number("sliceLocation"))
        image[.sopInstanceUID] = Rule(condition: "sopInstanceUID", source: .latin1("sopInstanceUID"))
        image[.instanceNumber] = Rule(condition: "instanceNumber", source: .latin1Number("instanceNumber"))
        image[.numberOfFrames] = Rule(condition: "numberOfFrames", source: .numberOfFrames)
        for (tag, time) in [(DICOMTag.contentDate, false), (.contentTime, true), (.acquisitionDate, false), (.acquisitionTime, true)] {
            image[tag] = Rule(condition: "date", source: time ? .time("date") : .date("date"))
        }
        image[.imageComments] = Rule(condition: nil, source: .imageComments)
        image[.seriesDescription] = Rule(condition: "series.name", source: .encoded("series.name"))
        image[.seriesDate] = Rule(condition: "series.date", source: .date("series.date"))
        image[.seriesTime] = Rule(condition: "series.date", source: .time("series.date"))
        image[.modality] = Rule(condition: "series.modality", source: .latin1("series.modality"))
        image[.seriesNumber] = Rule(condition: "series.id", source: .latin1Number("series.id"))
        image[.seriesInstanceUID] = Rule(condition: "series.seriesDICOMUID", source: .latin1("series.seriesDICOMUID"))
        image[.numberOfSeriesRelatedInstances] = Rule(condition: "series.noFiles", source: .integer("series.rawNoFiles"))
        image[.patientName] = Rule(condition: "series.study.name", source: .encoded("series.study.name"))
        image[.interpretationStatusID] = Rule(condition: "series.study.stateText", source: .encodedNumber("series.study.stateText"))
        // The study's comment answers as Image Comments, as the listener always did.
        image[.studyComments] = Rule(condition: "series.study.comment", source: .encoded("series.study.comment"), target: .imageComments)
        image[.sopClassUID] = Rule(condition: "series.seriesSOPClassUID", source: .latin1("series.seriesSOPClassUID"))
        image[.modalitiesInStudy] = Rule(condition: "series.study.modality", source: .modalities("series.study.series.modality"))
        image[.numberOfStudyRelatedSeries] = Rule(condition: nil, source: .count("series.study.series"))
        return [.study: study, .series: series, .image: image]
    }()
}

/// The character set a C-FIND's responses are written in. It starts as the
/// request's; a value it cannot carry turns it to UTF-8 (ISO_IR 192), then, if
/// that fails too, to the first character set of the record's file that can,
/// and it stays so for the rest of the find.
public struct SCPResponseCharacterSet {
    /// The Specific Character Set the responses declare; nil: none.
    public private(set) var name: String?
    private var encoding: UInt

    public init(name: String?, encoding: UInt) {
        self.name = name
        self.encoding = encoding
    }

    /// The bytes of `text` in the current character set, which changes as
    /// above when it cannot carry them; nil when no character set can, or for
    /// no text. `encodingFor` maps a DICOM character set to a string encoding;
    /// `fileCharacterSets` gives those of the record's file; `log` reports a
    /// change and a failure, `file` naming the record's file.
    public mutating func encode(_ text: String?, encodingFor: (String) -> UInt,
                                fileCharacterSets: () -> [String]?, file: () -> String?,
                                log: (String) -> Void) -> [UInt8]? {
        guard let text else { return nil }
        if let bytes = Self.bytes(text, encoding) { return bytes }
        log("--- cannot encode \(text) -> switch to UTF-8 (ISO_IR 192) encoding")
        name = "ISO_IR 192"
        encoding = encodingFor("ISO_IR 192")
        if let bytes = Self.bytes(text, encoding) { return bytes }
        log("--- cannot encode \(text) -> switch to dcm file encoding")
        for set in fileCharacterSets() ?? [] where Self.bytes(text, encodingFor(set)) != nil {
            name = set
            encoding = encodingFor(set)
            if let bytes = Self.bytes(text, encoding) { return bytes }
            break
        }
        log("***** encodeString FAILED for: \(file() ?? "(null)")")
        return nil
    }

    /// -[NSString cStringUsingEncoding:], up to its terminating NUL.
    public static func bytes(_ text: String, _ encoding: UInt) -> [UInt8]? {
        guard let characters = (text as NSString).cString(using: encoding) else { return nil }
        return Array(UnsafeRawBufferPointer(start: characters, count: strlen(characters)))
    }
}
