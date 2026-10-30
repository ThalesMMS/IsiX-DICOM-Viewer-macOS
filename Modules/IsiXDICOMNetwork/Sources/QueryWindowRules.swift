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

// The rules the Query window applies to what the user typed and chose before a
// C-FIND: which attribute each search field fills and how, what a date choice
// asks for, which attribute carries the modalities, which filters a query of
// the web portal or the browser keeps, and how the answers of several nodes
// become one list. The window itself, its controls and the query nodes stay in
// the app.

// MARK: - Dates

/// The date choices of the Query window, by the tag of their cell, and the
/// StudyDate and StudyTime filters each one asks for.
public enum QueryDateFilter {
    public static let anyDate: Int32 = 0
    public static let today: Int32 = 1
    public static let yesterday: Int32 = 2
    public static let last7Days: Int32 = 3
    public static let lastMonth: Int32 = 4
    public static let between: Int32 = 5
    public static let on: Int32 = 6
    public static let last2Days: Int32 = 7
    public static let last3Months: Int32 = 8
    public static let dayBeforeYesterday: Int32 = 9
    public static let todayAM: Int32 = 10
    public static let todayPM: Int32 = 11
    public static let after: Int32 = 12
    public static let last2Months: Int32 = 13
    public static let lastYear: Int32 = 14
    /// Tags 100 to 200 are the last (tag - 100) hours; 200 to 300 the last
    /// (tag - 200) minutes. 200 itself is read as 100 hours.
    public static let hoursBase: Int32 = 100
    public static let minutesBase: Int32 = 200

    /// How a StudyDate filter matches, as the search types of QueryFilter.
    public enum Match: Int32, Sendable {
        case exactMatch = 3
        case after = 7
        case exactDate = 9
    }

    /// The object of a StudyDate filter: none, an instant, or a range already
    /// written as the query string.
    public enum Value: Equatable, Sendable {
        case none
        case date(Date)
        case text(String)
    }

    public struct StudyDate: Equatable, Sendable {
        public var value: Value
        public var match: Match
    }

    /// What one date choice asks for: always a StudyDate filter, and a
    /// StudyTime range for a half day or the last hours or minutes.
    public struct Criteria: Equatable, Sendable {
        public var date: StudyDate
        public var time: String?
        /// The tag is none of the choices above; the date filter is empty.
        public var unknownTag = false
    }

    /// The filters of the choice `tag`. `from` and `to` are the two date
    /// pickers; `now` is the instant of the query; `allowFutureQuery` leaves a
    /// time range open at its end (DICOMQueryAllowFutureQuery). Dates are
    /// written in the Gregorian calendar of `timeZone`, with the containing
    /// second, as DCMCalendarDate writes them.
    public static func criteria(tag: Int32, from: Date, to: Date, now: Date, allowFutureQuery: Bool,
                                timeZone: TimeZone) -> Criteria {
        let calendar = gregorian(timeZone)
        if tag == between {
            let earlier = min(from, to), later = max(from, to)
            let range = format(earlier, "yyyyMMdd", calendar) + "-" + format(later, "yyyyMMdd", calendar)
            return Criteria(date: StudyDate(value: .text(range), match: .exactMatch))
        }
        if tag == on {
            return Criteria(date: StudyDate(value: .date(from), match: .exactDate))
        }

        var value = Value.none
        var match = Match.after
        var time: String?
        var unknownTag = false
        let day: TimeInterval = 60 * 60 * 24

        func daysAgo(_ days: Int) -> Date {
            calendar.date(byAdding: DateComponents(year: 0, month: 0, day: -days, hour: 0, minute: 0, second: 0), to: now) ?? now
        }
        func since(_ start: Date) -> String {
            let begin = format(start, "HHmmss", calendar) + ".000-"
            return allowFutureQuery ? begin : begin + format(now, "HHmmss", calendar) + ".000"
        }

        switch tag {
        case anyDate: break
        case today: value = .date(now); match = .exactDate
        case yesterday: value = .date(daysAgo(1)); match = .exactDate
        case dayBeforeYesterday: value = .date(daysAgo(2)); match = .exactDate
        case after: value = .date(from)
        case last2Days: value = .date(now.addingTimeInterval(-day * 2 - 1))
        case last7Days: value = .date(now.addingTimeInterval(-day * 7 - 1))
        case lastMonth: value = .date(now.addingTimeInterval(-day * 31 - 1))
        case last3Months: value = .date(now.addingTimeInterval(-day * 31 * 3 - 1))
        case last2Months: value = .date(now.addingTimeInterval(-day * 31 * 2 - 1))
        case lastYear: value = .date(now.addingTimeInterval(-day * 365 - 1))
        case todayAM, todayPM:
            value = .date(now)
            match = .exactDate
            time = tag == todayAM ? "000000.000-120000.000" : "120000.000-235959.000"
        default:
            if tag >= hoursBase && tag <= minutesBase {
                let start = now.addingTimeInterval(-60 * 60 * TimeInterval(tag - hoursBase))
                value = .date(start)
                time = since(start)
            } else if tag >= minutesBase && tag <= 300 {
                let start = now.addingTimeInterval(-60 * TimeInterval(tag - minutesBase))
                value = .date(start)
                time = since(start)
            } else {
                unknownTag = true
            }
        }
        return Criteria(date: StudyDate(value: value, match: match), time: time, unknownTag: unknownTag)
    }

    /// The format of the patient's birth date for the choice `tag` of its
    /// matrix: on (0), before (-1) or after (1) the date; nil for any other.
    public static func birthDateFormat(forTag tag: Int) -> String? {
        switch tag {
        case 0: return "%Y%m%d"
        case -1: return "-%Y%m%d"
        case 1: return "%Y%m%d-"
        default: return nil
        }
    }

    private static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        formatter.isLenient = false
        return formatter.string(from: Date(timeIntervalSinceReferenceDate: floor(date.timeIntervalSinceReferenceDate)))
    }
}

// MARK: - Modalities

/// The attribute that carries the modalities of a study query, and its value.
public enum QueryModalityFilter {
    /// ModalitiesInStudy when the node supports it (SupportQRModalitiesinStudy),
    /// Modality otherwise.
    public static func key(supportsModalitiesInStudy: Bool) -> String {
        supportsModalitiesInStudy ? "ModalitiesinStudy" : "Modality"
    }

    /// The modalities as one value, separated by backslashes; nil for none.
    public static func value(_ modalities: [String]) -> String? {
        modalities.isEmpty ? nil : modalities.joined(separator: "\\")
    }
}

// MARK: - Search fields

/// The search fields of the Query window, by the index of their tab, and the
/// filter each one sends.
public enum QueryWindowField: Int, CaseIterable, Sendable {
    case patientName = 0
    case patientID = 1
    case accessionNumber = 2
    case patientBirthDate = 3
    case studyDescription = 4
    case referringPhysician = 5
    case studyComments = 6
    case institutionName = 7
    case customField = 8
    case interpretationStatus = 9

    /// The filter's name; nil for the custom field, which takes the keyword
    /// of the attribute chosen in its menu.
    public var key: String? {
        switch self {
        case .patientName: return "PatientsName"
        case .patientID: return "PatientID"
        case .accessionNumber: return "AccessionNumber"
        case .patientBirthDate: return "PatientBirthDate"
        case .studyDescription: return "StudyDescription"
        case .referringPhysician: return "ReferringPhysiciansName"
        case .studyComments: return "StudyComments"
        case .institutionName: return "InstitutionName"
        case .customField: return nil
        case .interpretationStatus: return "InterpretationStatusID"
        }
    }

    /// The preference that lets the field be queried.
    public var preference: String {
        switch self {
        case .patientName: return "allow_qr_name"
        case .patientID: return "allow_qr_id"
        case .accessionNumber: return "allow_qr_accession_number"
        case .patientBirthDate: return "allow_qr_birthdate"
        case .studyDescription: return "allow_qr_description"
        case .referringPhysician: return "allow_qr_referring_physician"
        case .studyComments: return "allow_qr_comments"
        case .institutionName: return "allow_qr_institution"
        case .customField: return "allow_qr_custom_dicom_field"
        case .interpretationStatus: return "allow_qr_status"
        }
    }

    /// Whether a value that the query's character set cannot write is
    /// reported, with the offer to switch to UTF-8.
    public var checksEncoding: Bool {
        switch self {
        case .patientID, .accessionNumber, .patientBirthDate: return false
        default: return true
        }
    }

    /// The filter sent for `typed`, or nil when there is none. Fields matched
    /// from their start get a trailing wildcard; the description and the
    /// comments are sent as typed, the others without surrounding white space.
    /// The birth date is not a text: see `QueryDateFilter.birthDateFormat`.
    public func filterValue(_ typed: String?) -> String? {
        guard self != .patientBirthDate, let typed else { return nil }
        let trims = self != .studyDescription && self != .studyComments
        let value = trims ? typed.trimmingCharacters(in: .whitespacesAndNewlines) : typed
        guard (value as NSString).length > 0 else { return nil }
        switch self {
        case .patientName, .referringPhysician, .institutionName, .studyDescription, .studyComments:
            return value + "*"
        default:
            return value
        }
    }
}

// MARK: - Study queries of the portal, the browser and the routing rules

/// The filters a study query of the web portal, the browser's distant search
/// or the routing rules sends, from a dictionary of their own keys.
public enum QueryStudyFilters {
    /// The allow_qr_* preferences, and whether the node supports
    /// ModalitiesInStudy.
    public struct Permissions: Sendable {
        public var accessionNumber = false
        public var description = false
        public var comments = false
        public var identifiers = false
        public var name = false
        public var birthDate = false
        public var studyDate = false
        public var modality = false
        public var modalitiesInStudy = false

        public init(accessionNumber: Bool = false, description: Bool = false, comments: Bool = false,
                    identifiers: Bool = false, name: Bool = false, birthDate: Bool = false, studyDate: Bool = false,
                    modality: Bool = false, modalitiesInStudy: Bool = false) {
            self.accessionNumber = accessionNumber
            self.description = description
            self.comments = comments
            self.identifiers = identifiers
            self.name = name
            self.birthDate = birthDate
            self.studyDate = studyDate
            self.modality = modality
            self.modalitiesInStudy = modalitiesInStudy
        }

        /// The preferences as stored in `defaults`.
        public init(defaults: UserDefaults) {
            self.init(accessionNumber: defaults.bool(forKey: "allow_qr_accession_number"),
                      description: defaults.bool(forKey: "allow_qr_description"),
                      comments: defaults.bool(forKey: "allow_qr_comments"),
                      identifiers: defaults.bool(forKey: "allow_qr_id"),
                      name: defaults.bool(forKey: "allow_qr_name"),
                      birthDate: defaults.bool(forKey: "allow_qr_birthdate"),
                      studyDate: defaults.bool(forKey: "allow_qr_study_date"),
                      modality: defaults.bool(forKey: "allow_qr_modality"),
                      modalitiesInStudy: defaults.bool(forKey: "SupportQRModalitiesinStudy"))
        }
    }

    /// A filter left out, and why: a value of wildcards and two characters or
    /// fewer, or nothing but wildcards.
    public enum Removal: Equatable, Sendable {
        case tooShort(key: String, value: String)
        case empty(key: String)
    }

    /// The filters for `filters`, keyed by the names the query nodes read.
    ///
    /// `birthDate` turns the PatientBirthDate value into the filter's object;
    /// `studyDateAndTime` turns a date choice (the "date" code, "fromDate",
    /// "toDate") into the StudyDate and StudyTime objects. Text values made only
    /// of wildcards, or of wildcards and two characters or fewer, are removed;
    /// `removed` lists them in the order they were met.
    public static func build(_ filters: [String: Any], permissions: Permissions,
                             birthDate: (Any) -> Any?,
                             studyDateAndTime: (_ code: Int32, _ from: Any?, _ to: Any?) -> (date: Any?, time: Any?))
        -> (filters: [String: Any], removed: [Removal]) {
        var result: [(key: String, value: Any)] = []
        func set(_ key: String, _ value: Any?) {
            guard let value else { return }
            if let index = result.firstIndex(where: { $0.key == key }) {
                result[index].value = value
            } else {
                result.append((key, value))
            }
        }

        if permissions.accessionNumber { set("AccessionNumber", filters["AccessionNumber"]) }
        if permissions.accessionNumber { set("AccessionNumber", filters["accessionNumber"]) }
        if permissions.description { set("StudyDescription", filters["StudyDescription"]) }
        if permissions.comments { set("StudyComments", filters["Comments"]) }
        if permissions.identifiers { set("StudyID", filters["StudyID"]) }
        if permissions.identifiers { set("StudyID", filters["studyID"]) }
        if permissions.identifiers { set("StudyInstanceUID", filters["StudyInstanceUID"]) }
        if permissions.identifiers { set("StudyInstanceUID", filters["studyInstanceUID"]) }
        if permissions.name { set("PatientsName", filters["PatientsName"]) }
        if permissions.name { set("PatientsName", filters["patientName"]) }
        if permissions.identifiers { set("PatientID", filters["PatientID"]) }
        if permissions.identifiers { set("PatientID", filters["patientID"]) }
        if permissions.birthDate, let birth = filters["PatientBirthDate"] { set("PatientBirthDate", birthDate(birth)) }

        let code = intValue(filters["date"])
        if code != 0 && permissions.studyDate {
            let (date, time) = studyDateAndTime(code, filters["fromDate"], filters["toDate"])
            set("StudyDate", date)
            set("StudyTime", time)
        }

        if let modalities = filters["modality"] as? [Any], !modalities.isEmpty,
           !result.isEmpty || permissions.modality {
            set(QueryModalityFilter.key(supportsModalitiesInStudy: permissions.modalitiesInStudy),
                QueryModalityFilter.value(modalities.map { String(describing: $0) }))
        }

        var removed: [Removal] = []
        var removedKeys: Set<String> = []
        for (key, value) in result {
            guard let text = value as? String else { continue }
            if text.contains("*") && (text.replacingOccurrences(of: "*", with: "") as NSString).length <= 2 {
                removed.append(.tooShort(key: key, value: text))
                removedKeys.insert(key)
            }
            if (text.replacingOccurrences(of: "*", with: "") as NSString).length == 0 {
                removed.append(.empty(key: key))
                removedKeys.insert(key)
            }
        }
        var kept: [String: Any] = [:]
        for (key, value) in result where !removedKeys.contains(key) {
            kept[key] = value
        }
        return (kept, removed)
    }

    private static func intValue(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        if let text = value as? NSString { return text.intValue }
        return 0
    }
}

// MARK: - Answers of several nodes

/// How the studies found by several queries become one list.
public enum QueryResultMerge {
    /// Adds the studies of `found` to `studies`: a study whose UID is already
    /// there is kept once, the copy that reports more images winning; a study
    /// without a UID is always added. With `indexingAdditions`, a study added
    /// from `found` is matched by the ones after it, so `found` itself is
    /// deduplicated too; without it, only the studies already there are.
    public static func merge<Study>(_ found: [Study], into studies: inout [Study], indexingAdditions: Bool,
                                    uid: (Study) -> AnyHashable?, images: (Study) -> Int32?) {
        var uids = studies.map(uid)
        for study in found {
            let key = uid(study)
            let index = key.flatMap { key in uids.firstIndex(where: { $0 == key }) }
            guard let index else {
                studies.append(study)
                if indexingAdditions { uids.append(key) }
                continue
            }
            if let kept = images(studies[index]), let offered = images(study), kept < offered {
                studies[index] = study
            }
        }
    }
}
