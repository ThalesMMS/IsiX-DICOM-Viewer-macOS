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

/// The attributes the listener answers with besides those the query nodes use.
public extension DICOMTag {
    static let acquisitionDate = DICOMTag(0x0008, 0x0022)
    static let contentDate = DICOMTag(0x0008, 0x0023)
    static let acquisitionTime = DICOMTag(0x0008, 0x0032)
    static let contentTime = DICOMTag(0x0008, 0x0033)
    static let patientSex = DICOMTag(0x0010, 0x0040)
    static let numberOfStudyRelatedSeries = DICOMTag(0x0020, 0x1206)
    static let sliceLocation = DICOMTag(0x0020, 0x1041)
    static let numberOfFrames = DICOMTag(0x0028, 0x0008)
}

/// The level of a C-FIND, C-MOVE or C-GET the listener answers from its
/// database: the Query/Retrieve Level value exactly as it came. Any other
/// value finds nothing.
public enum SCPQueryLevel: String, Sendable {
    case study = "STUDY", series = "SERIES", image = "IMAGE"

    /// The entity of the database the level reads.
    public var entityName: String {
        switch self {
        case .study: return "Study"
        case .series: return "Series"
        case .image: return "Image"
        }
    }

    /// The level of a database object of entity `type` ("Study", "Series",
    /// "Image"), nil for any other.
    public init?(entityType: String?) {
        switch entityType {
        case "Study": self = .study
        case "Series": self = .series
        case "Image": self = .image
        default: return nil
        }
    }
}

/// One attribute of a request identifier as the listener reads it: its tag,
/// its value as DCMTK holds it (all values, nil when DCMTK gives none), its
/// length and its name in DCMTK's dictionary, which the log uses.
public struct SCPIdentifierElement: Sendable {
    public let tag: DICOMTag
    public let value: [UInt8]?
    public let length: Int
    public let name: String

    public init(tag: DICOMTag, value: [UInt8]?, length: Int, name: String) {
        self.tag = tag
        self.value = value
        self.length = length
        self.name = name
    }
}

/// What the listener checks of a request before it reads the database.
public enum SCPRequestCheck {

    public enum Service: Sendable { case find, retrieve }

    public enum Outcome: Int, Sendable {
        case accepted = 0
        /// Only the Study Root model is answered.
        case sopClassNotSupported
        /// The identifier has no Query/Retrieve Level.
        case missingLevel
        /// Its Query/Retrieve Level is none of PATIENT, STUDY, SERIES and IMAGE.
        case unknownLevel
    }

    /// The outcome for a request of `service` in the model `sopClass` whose
    /// identifier holds `elements`. The level is compared without case and by
    /// its start, as DCMTK's index database did ("study" and "STUDYX" pass this
    /// check; the database then answers only "STUDY", "SERIES" and "IMAGE").
    public static func check(service: Service, sopClass: String, elements: [SCPIdentifierElement]) -> Outcome {
        switch service {
        case .find:
            guard sopClass == QueryRetrieveService.findStudyRoot.rawValue else { return .sopClassNotSupported }
        case .retrieve:
            guard sopClass == QueryRetrieveService.moveStudyRoot.rawValue
                    || sopClass == QueryRetrieveService.getStudyRoot.rawValue else { return .sopClassNotSupported }
        }
        guard let level = elements.first(where: { $0.tag == .queryRetrieveLevel }) else { return .missingLevel }
        // Of the value, what fits the 50-byte buffer the index database read it in.
        let bytes = (level.value ?? []).prefix(min(level.length, 49)).prefix { $0 != 0 }
        guard !bytes.isEmpty else { return .unknownLevel }
        let upper = bytes.map { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z") ? $0 - 32 : $0 }
        for name in ["PATIENT", "STUDY", "SERIES", "IMAGE"] where upper.starts(with: Array(name.utf8)) {
            return .accepted
        }
        return .unknownLevel
    }
}

/// What the application supplies to the listener's matching: the DICOM
/// character sets and dates, which DCM.framework reads, and the browser's
/// patient name search.
public protocol SCPMatchingEnvironment {
    /// A date or time as DCM.framework reads it (a DCMCalendarDate).
    associatedtype CalendarValue

    /// `bytes` read in the DICOM character set `characterSet`, nil when they
    /// cannot be (+[NSString stringWithUTF8String:DICOMEncoding:]).
    func string(_ bytes: [UInt8], characterSet: String?) -> String?
    /// The browser's condition for the patient name `name`; nil when there is
    /// no browser.
    func patientNamePredicate(_ name: String?) -> NSPredicate?
    /// The condition that an image's compressed SOP Instance UID is `uid`.
    func sopInstanceUIDPredicate(_ uid: String) -> NSPredicate
    /// +[DCMCalendarDate dicomDate:] and +dicomTime:.
    func date(_ string: String?) -> CalendarValue?
    func time(_ string: String?) -> CalendarValue?
    func isQuery(_ value: CalendarValue) -> Bool
    func queryString(_ value: CalendarValue) -> String?
    /// The first and the last instant of the day `value` names, as reference-date intervals.
    func startOfDay(_ value: CalendarValue?) -> TimeInterval
    func endOfDay(_ value: CalendarValue?) -> TimeInterval
    /// -[DCMCalendarDate dateAsNumber]: a time of day as the database keeps it.
    func timeNumber(_ value: CalendarValue) -> NSNumber?
    /// The instant at the time of day of the TM `time` on the day of the DA `date`.
    func instant(date: String, time: String) -> TimeInterval
    /// Writes a line of the listener's diagnostics.
    func log(_ message: String)
}

/// The conditions a request identifier sets on the database: one on the
/// level's entity, one on the series when an IMAGE request names its study or
/// series (the images are then those of the matching series), and the SOP
/// Instance UIDs an IMAGE request asks for, applied after the fetch.
public struct SCPFetchPredicates {
    public var predicate: NSPredicate?
    public var seriesLevel: NSPredicate?
    public var compressedSOPInstance: NSPredicate?
}

/// How the listener turns a request identifier into conditions on its database.
public enum SCPQueryMatching {

    /// The character set a request's values are read in: the first of its
    /// Specific Character Set (raw value `value`), ISO_IR 100 when it has none.
    /// nil when the value is not UTF-8.
    public static func characterSet(ofSpecificCharacterSet value: [UInt8]?) -> String? {
        guard let value else { return "ISO_IR 100" }
        guard let text = NSString(bytes: value, length: value.count, encoding: String.Encoding.utf8.rawValue) else { return nil }
        return text.components(separatedBy: "\\").first
    }

    /// The condition that `field` matches `text` as the listener reads a
    /// value: a '*' strictly inside a value of more than three characters makes
    /// a LIKE pattern; otherwise leading and trailing '*' make it CONTAINS,
    /// ENDSWITH or BEGINSWITH and a value without one must both start and end
    /// with it. Every comparison ignores case and diacritics; no value matches
    /// everything. `any`: `field` is a to-many key path.
    public static func wildcardPredicate(_ text: String?, field: String, any: Bool = false) -> NSPredicate {
        let s = (text ?? "") as NSString
        if text != nil, s.length > 3 {
            for i in 1..<(s.length - 1) where s.character(at: i) == UInt16(UInt8(ascii: "*")) {
                return predicate(any ? "ANY %K LIKE[cd] %@" : "%K LIKE[cd] %@", field, text)
            }
        }
        let v = text.map { ($0 as NSString).replacingOccurrences(of: "*", with: "") }
        guard let v, !v.isEmpty else { return NSPredicate(value: true) }
        let star = UInt16(UInt8(ascii: "*"))
        let first = s.character(at: 0) == star, last = s.character(at: s.length - 1) == star
        let prefix = any ? "ANY " : ""
        if first && last { return predicate("\(prefix)%K CONTAINS[cd] %@", field, v) }
        if first { return predicate("\(prefix)%K ENDSWITH[cd] %@", field, v) }
        if last { return predicate("\(prefix)%K BEGINSWITH[cd] %@", field, v) }
        return predicate("(\(prefix)%K BEGINSWITH[cd] %@) AND (\(prefix)%K ENDSWITH[cd] %@)", field, v, field, v)
    }

    /// The conditions of a request whose Query/Retrieve Level value is
    /// `level`, its attributes `elements` in the identifier's order, read in
    /// `characterSet`.
    public static func predicates<Environment: SCPMatchingEnvironment>(
        level: String?, elements: [SCPIdentifierElement], characterSet: String?,
        environment: Environment) -> SCPFetchPredicates {
        typealias Value = Environment.CalendarValue
        let queryLevel = level.flatMap(SCPQueryLevel.init(rawValue:))
        var result = SCPFetchPredicates()
        var compound: NSPredicate?
        // The bounds of a date or time range: applied together after the loop.
        var startTime: String?, endTime: String?, startDate: String?, endDate: String?

        func text(_ element: SCPIdentifierElement, _ set: String?) -> String? {
            element.value.flatMap { environment.string($0, characterSet: set) }
        }
        func dashTrimmed(_ string: String?) -> String? {
            string.map { ($0 as NSString).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        }
        // A date or time of the study or the series: an exact one is a
        // condition, a range gives its bounds.
        func range(_ value: Value?, isTime: Bool) -> NSPredicate? {
            guard let value else { return nil }
            let query = environment.isQuery(value) ? environment.queryString(value) : nil
            if environment.isQuery(value), query?.hasPrefix("-") == true {
                if isTime { endTime = dashTrimmed(query) } else { endDate = dashTrimmed(query) }
            } else if environment.isQuery(value), query?.hasSuffix("-") == true {
                if isTime { startTime = dashTrimmed(query) } else { startDate = dashTrimmed(query) }
            } else if environment.isQuery(value) {
                let values = (query ?? "").components(separatedBy: "-")
                if query != nil, values.count == 2 {
                    if isTime { startTime = values[0]; endTime = values[1] } else { startDate = values[0]; endDate = values[1] }
                }
            } else if isTime {
                return predicate("dicomTime == %@", environment.timeNumber(value))
            } else {
                return NSPredicate(format: "date >= CAST(%lf, \"NSDate\") AND date < CAST(%lf, \"NSDate\")",
                                   environment.startOfDay(value), environment.endOfDay(value))
            }
            return nil
        }
        func modalities(_ element: SCPIdentifierElement) -> NSPredicate {
            let list = text(element, nil)?.components(separatedBy: "\\") ?? []
            if list.count <= 1 { return predicate("(modality CONTAINS[cd] %@)", list.last) }
            return predicate("(ANY series.modality IN %@)", list)
        }
        func unknown(_ element: SCPIdentifierElement, _ name: String) {
            if element.length > 0 { environment.log("***** DICOM SCP - \(name) LEVEL: unknown key: \(element.name)\r") }
        }

        for element in elements {
            let tag = element.tag
            if tag == .specificCharacterSet || tag == .queryRetrieveLevel || tag == .numberOfStudyRelatedInstances { continue }
            var condition: NSPredicate?
            let present = element.value != nil
            switch queryLevel {
            case .study:
                switch tag {
                case .patientName:
                    if present {
                        condition = environment.patientNamePredicate(text(element, characterSet))
                        // "*" alone narrows nothing: universal matching, as an empty value.
                        if let compoundCondition = condition as? NSCompoundPredicate, compoundCondition.subpredicates.isEmpty { condition = nil }
                    }
                case .patientID: if present { condition = wildcardPredicate(text(element, nil), field: "patientID") }
                case .accessionNumber: if present { condition = wildcardPredicate(text(element, nil), field: "accessionNumber") }
                case .studyInstanceUID: if present { condition = predicate("studyInstanceUID == %@", text(element, nil)) }
                case .studyID: if present { condition = predicate("id == %@", text(element, nil)) }
                case .studyDescription: if present { condition = wildcardPredicate(text(element, characterSet), field: "studyName") }
                case .interpretationStatusID: if present { condition = predicate("stateText == %@", text(element, nil)) }
                case .imageComments, .studyComments:
                    if present {
                        let comment = text(element, characterSet)
                        condition = NSCompoundPredicate(orPredicateWithSubpredicates: [
                            wildcardPredicate(comment, field: "comment"),
                            wildcardPredicate(comment, field: "series.comment", any: true)])
                    }
                case .institutionName: if present { condition = wildcardPredicate(text(element, characterSet), field: "institutionName") }
                case .referringPhysicianName: if present { condition = wildcardPredicate(text(element, characterSet), field: "referringPhysician") }
                case .performingPhysicianName: if present { condition = wildcardPredicate(text(element, characterSet), field: "performingPhysician") }
                case .modalitiesInStudy, .modality: if present { condition = modalities(element) }
                case .patientBirthDate:
                    let value = present ? environment.date(text(element, nil)) : nil
                    condition = birthDate(value, environment)
                case .studyDate: condition = range(present ? environment.date(text(element, nil)) : nil, isTime: false)
                case .studyTime: condition = range(present ? environment.time(text(element, nil)) : nil, isTime: true)
                default: unknown(element, "STUDY")
                }
            case .series:
                switch tag {
                case .studyInstanceUID: if present { condition = predicate("study.studyInstanceUID == %@", text(element, nil)) }
                case .seriesInstanceUID:
                    if present {
                        let uids = text(element, nil)?.components(separatedBy: "\\") ?? []
                        condition = NSCompoundPredicate(orPredicateWithSubpredicates: uids.map { predicate("seriesDICOMUID == %@", $0) })
                    }
                case .seriesDescription: if present { condition = wildcardPredicate(text(element, characterSet), field: "name") }
                case .seriesNumber: if present { condition = predicate("id == %@", text(element, characterSet)) }
                case .modality: if present { condition = predicate("study.modality CONTAINS[cd] %@", text(element, nil)) }
                case .seriesDate: condition = range(present ? environment.date(text(element, nil)) : nil, isTime: false)
                case .seriesTime: condition = range(present ? environment.time(text(element, nil)) : nil, isTime: true)
                default: unknown(element, "SERIES")
                }
            case .image:
                switch tag {
                case .studyInstanceUID:
                    if present {
                        let study = predicate("study.studyInstanceUID == %@", text(element, nil))
                        result.seriesLevel = result.seriesLevel.map { NSCompoundPredicate(andPredicateWithSubpredicates: [study, $0]) } ?? study
                    }
                case .seriesInstanceUID:
                    if present {
                        let series = predicate("seriesDICOMUID == %@", text(element, nil))
                        result.seriesLevel = result.seriesLevel.map { NSCompoundPredicate(andPredicateWithSubpredicates: [$0, series]) } ?? series
                    }
                case .sopInstanceUID:
                    if present {
                        let uids = text(element, nil)?.components(separatedBy: "\\") ?? []
                        condition = NSPredicate(format: "compressedSopInstanceUID != NIL")
                        result.compressedSOPInstance = NSCompoundPredicate(orPredicateWithSubpredicates: uids.map(environment.sopInstanceUIDPredicate))
                    }
                case .instanceNumber:
                    if present { condition = NSPredicate(format: "instanceNumber == %d", intValue(text(element, nil))) }
                case .numberOfFrames:
                    if present { condition = NSPredicate(format: "numberOfFrames == %d", intValue(text(element, nil))) }
                default: unknown(element, "IMAGE")
                }
            case nil:
                environment.log("***** DICOM SCP supports ONLY STUDY, SERIES, IMAGE levels ! Current level: \(level ?? "(null)")\r")
            }
            if let condition {
                compound = compound.map { NSCompoundPredicate(andPredicateWithSubpredicates: [$0, condition]) } ?? condition
            }
        }

        // Only studies with DICOM files: with no other condition, this one alone.
        let hasDICOM: NSPredicate?
        switch queryLevel {
        case .study: hasDICOM = NSPredicate(format: "hasDICOM == %d", Int32(1))
        case .series: hasDICOM = NSPredicate(format: "study.hasDICOM == %d", Int32(1))
        case .image: hasDICOM = NSPredicate(format: "series.study.hasDICOM == %d", Int32(1))
        case nil: hasDICOM = nil
        }
        if let hasDICOM {
            compound = compound.map { NSCompoundPredicate(andPredicateWithSubpredicates: [$0, hasDICOM]) } ?? hasDICOM
        }

        // A date range, its bounds at the times of a time range when it has one.
        var start: TimeInterval = 0, end: TimeInterval = 0
        if let startDate {
            start = startTime.map { environment.instant(date: startDate, time: $0) }
                ?? environment.startOfDay(environment.date(startDate))
        }
        if let endDate {
            end = endTime.map { environment.instant(date: endDate, time: $0) }
                ?? environment.endOfDay(environment.date(endDate))
        }
        var dates: NSPredicate?
        if start != 0 && end != 0 {
            dates = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "date >= CAST(%lf, \"NSDate\")", start),
                NSPredicate(format: "date < CAST(%lf, \"NSDate\")", end)])
        } else if start != 0 {
            dates = NSPredicate(format: "date  >= CAST(%lf, \"NSDate\")", start)
        } else if end != 0 {
            dates = NSPredicate(format: "date < CAST(%lf, \"NSDate\")", end)
        }
        if let dates {
            compound = NSCompoundPredicate(andPredicateWithSubpredicates: [dates] + (compound.map { [$0] } ?? []))
        }
        result.predicate = compound
        return result
    }

    /// The Patient's Birth Date condition: before, after or between days, or
    /// on one day.
    private static func birthDate<Environment: SCPMatchingEnvironment>(
        _ value: Environment.CalendarValue?, _ environment: Environment) -> NSPredicate? {
        guard let value else { return nil }
        let query = environment.isQuery(value) ? environment.queryString(value) : nil
        let trimmed = query.map { ($0 as NSString).trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
        if environment.isQuery(value), query?.hasPrefix("-") == true {
            return NSPredicate(format: "(dateOfBirth < CAST(%lf, \"NSDate\"))", environment.endOfDay(environment.date(trimmed)))
        }
        if environment.isQuery(value), query?.hasSuffix("-") == true {
            return NSPredicate(format: "(dateOfBirth >= CAST(%lf, \"NSDate\"))", environment.startOfDay(environment.date(trimmed)))
        }
        if environment.isQuery(value) {
            let values = (query ?? "").components(separatedBy: "-")
            guard query != nil, values.count == 2 else { return nil }
            return NSPredicate(format: "(dateOfBirth >= CAST(%lf, \"NSDate\")) AND (dateOfBirth < CAST(%lf, \"NSDate\"))",
                               environment.startOfDay(environment.date(values[0])), environment.endOfDay(environment.date(values[1])))
        }
        return NSPredicate(format: "(dateOfBirth >= CAST(%lf, \"NSDate\")) AND (dateOfBirth < CAST(%lf, \"NSDate\"))",
                           environment.startOfDay(value), environment.endOfDay(value))
    }

    /// -[NSString intValue] of a value, 0 for none.
    private static func intValue(_ text: String?) -> Int32 {
        text.map { ($0 as NSString).intValue } ?? 0
    }

    /// A predicate whose %@ arguments may be nil, as Objective-C passed them: a
    /// nil argument is the constant nil (NSNull in an argument array would be
    /// another constant).
    static func predicate(_ format: String, _ arguments: Any?...) -> NSPredicate {
        var text = "", values: [Any] = [], index = 0
        var scanner = format.makeIterator()
        while let character = scanner.next() {
            guard character == "%" else { text.append(character); continue }
            guard let specifier = scanner.next() else { text.append(character); break }
            if specifier == "@" || specifier == "K", index < arguments.count {
                if let value = arguments[index] { text += "%" + String(specifier); values.append(value) } else { text += "nil" }
                index += 1
            } else {
                text += "%" + String(specifier)
            }
        }
        return NSPredicate(format: text, argumentArray: values)
    }
}
