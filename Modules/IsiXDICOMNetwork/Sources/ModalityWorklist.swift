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

/// The Modality Worklist window's C-FIND: the nodes it asks, the identifier it
/// sends in the Modality Worklist Information Model - FIND, and the days it
/// asks for.
///
/// The identifier is the plugin API's worklist identifier, so that the window
/// and the plugins ask a node the same thing, with the Scheduled Station Name
/// added for the window's Station column.
public enum ModalityWorklistQuery {
    /// Modality Worklist Information Model - FIND.
    public static let abstractSyntax = PluginQueryKeys.worklistAbstractSyntax

    static let scheduledStationName = DICOMTag(0x0040, 0x0010)

    /// The days of the scheduled procedure steps asked for.
    public enum DateWindow: Int, CaseIterable, Sendable {
        /// The steps scheduled for today.
        case today = 0
        /// Today and the six days after it.
        case nextSevenDays = 1
        /// Every step the node has, whatever its date.
        case anyDate = 2

        /// The first and last day of the window, nil for no date matching.
        public func days(around now: Date, calendar: Calendar = .current) -> (from: Date, to: Date)? {
            switch self {
            case .today: return (now, now)
            case .nextSevenDays: return (now, calendar.date(byAdding: .day, value: 6, to: now) ?? now)
            case .anyDate: return nil
            }
        }
    }

    /// What the window filters on: the days, and optionally a modality and the
    /// AE title of the scheduled station. Blank texts do not filter.
    public struct Filter: Equatable, Sendable {
        public var dateWindow: DateWindow
        public var modality: String?
        public var stationAETitle: String?

        public init(dateWindow: DateWindow = .today, modality: String? = nil, stationAETitle: String? = nil) {
            self.dateWindow = dateWindow
            self.modality = modality
            self.stationAETitle = stationAETitle
        }
    }

    /// The keys of the identifier, each with its filter or empty to ask for it
    /// back. Throws for a filter DICOM cannot carry.
    public static func keys(for filter: Filter, now: Date = Date(), calendar: Calendar = .current)
        throws(PluginQueryKeys.Failure) -> [PluginQueryKeys.Key] {
        let days = filter.dateWindow.days(around: now, calendar: calendar)
        var keys = try PluginQueryKeys.identifier(level: .worklist, filters: .init(
            modality: nonBlank(filter.modality), dateFrom: days?.from, dateTo: days?.to,
            scheduledStationAETitle: nonBlank(filter.stationAETitle)))
        keys.append(.init(scheduledStationName, "ScheduledStationName", inScheduledStep: true))
        return keys
    }

    /// The Locations entries the window asks: DIMSE nodes that are turned on,
    /// with an address, a port and the Worklist column checked, in the order
    /// of Locations.
    public static func nodes(_ nodes: [DICOMNode]) -> [DICOMNode] {
        nodes.filter { node in
            let address = node.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return node.isDIMSE && node.isActivated && node.providesModalityWorklist && !address.isEmpty
                && node.port > 0 && node.port < 65536
        }
    }

    /// The name a node is shown by: its description, else its AE title.
    public static func name(of node: DICOMNode) -> String {
        let description = node.nodeDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return description.isEmpty ? (node.aeTitle ?? "") : description
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// One scheduled procedure step of a worklist answer, as the window lists it.
public struct ScheduledProcedure: Equatable, Hashable, Sendable, Identifiable {
    /// The name of the node that answered it.
    public var node: String
    public var patientName: String
    public var patientID: String
    public var patientBirthDate: String
    public var patientSex: String
    public var accessionNumber: String
    public var studyInstanceUID: String
    public var referringPhysicianName: String
    public var requestedProcedureID: String
    public var requestedProcedureDescription: String
    public var stationAETitle: String
    public var stationName: String
    /// The DICOM date (DA) and time (TM) of the step's start, as answered.
    public var startDate: String
    public var startTime: String
    public var modality: String
    public var performingPhysicianName: String
    public var stepDescription: String
    public var stepID: String

    /// A match read as the values of its keys, by keyword; a missing key is
    /// empty. The values are trimmed of the spaces DICOM pads them with.
    public init(values: [String: String], node: String) {
        func value(_ keyword: String) -> String {
            values[keyword]?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))) ?? ""
        }
        self.node = node
        patientName = value("PatientName")
        patientID = value("PatientID")
        patientBirthDate = value("PatientBirthDate")
        patientSex = value("PatientSex")
        accessionNumber = value("AccessionNumber")
        studyInstanceUID = value("StudyInstanceUID")
        referringPhysicianName = value("ReferringPhysicianName")
        requestedProcedureID = value("RequestedProcedureID")
        requestedProcedureDescription = value("RequestedProcedureDescription")
        stationAETitle = value("ScheduledStationAETitle")
        stationName = value("ScheduledStationName")
        startDate = value("ScheduledProcedureStepStartDate")
        startTime = value("ScheduledProcedureStepStartTime")
        modality = value("Modality")
        performingPhysicianName = value("ScheduledPerformingPhysicianName")
        stepDescription = value("ScheduledProcedureStepDescription")
        stepID = value("ScheduledProcedureStepID")
    }

    /// The same step answered twice by one node, or by a node listed twice,
    /// has one identity.
    public var id: String {
        [node, patientID, accessionNumber, requestedProcedureID, stepID, studyInstanceUID, startDate, startTime]
            .joined(separator: "\u{1F}")
    }

    /// The patient's name with the separators of its components as spaces.
    public var displayPatientName: String {
        patientName.split(separator: "=", omittingEmptySubsequences: false).first.map { alphabetic in
            alphabetic.split(separator: "^").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .joined(separator: " ")
        } ?? ""
    }

    /// What is done: the step's description, else the requested procedure's.
    public var procedureDescription: String {
        stepDescription.isEmpty ? requestedProcedureDescription : stepDescription
    }

    /// The day the step is scheduled for, at midnight in `calendar`'s time zone.
    public func scheduledDay(calendar: Calendar = .current) -> Date? {
        DICOMDateTime.day(startDate, calendar: calendar)
    }

    /// The start of the step in `calendar`'s time zone: its day, at its time
    /// when it has one.
    public func scheduledStart(calendar: Calendar = .current) -> Date? {
        guard let day = scheduledDay(calendar: calendar) else { return nil }
        guard let time = DICOMDateTime.time(startTime) else { return day }
        return calendar.date(bySettingHour: time.hour, minute: time.minute, second: time.second, of: day) ?? day
    }

    /// The answers of every node in one list: a step answered twice once, in
    /// the order they start, those without a date last.
    public static func merged(_ answers: [[ScheduledProcedure]], calendar: Calendar = .current) -> [ScheduledProcedure] {
        var seen = Set<String>()
        let unique = answers.joined().filter { seen.insert($0.id).inserted }
        let starts = Dictionary(unique.map { ($0.id, $0.scheduledStart(calendar: calendar)) }, uniquingKeysWith: { first, _ in first })
        return unique.enumerated().sorted { left, right in
            switch (starts[left.element.id] ?? nil, starts[right.element.id] ?? nil) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.offset < right.offset
            }
        }.map(\.element)
    }
}

/// The reading of DICOM dates (DA, YYYYMMDD) and times (TM, HH, HHMM or HHMMSS
/// with an optional fraction) of a worklist answer.
enum DICOMDateTime {
    static func day(_ text: String, calendar: Calendar) -> Date? {
        let digits = text.trimmingCharacters(in: .whitespaces)
        guard digits.count == 8, digits.allSatisfy(\.isASCII), let year = Int(digits.prefix(4)),
              let month = Int(digits.dropFirst(4).prefix(2)), let day = Int(digits.suffix(2)),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day, calendar.component(.month, from: date) == month else { return nil }
        return date
    }

    static func time(_ text: String) -> (hour: Int, minute: Int, second: Int)? {
        let whole = text.trimmingCharacters(in: .whitespaces).split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        let digits = whole.replacingOccurrences(of: ":", with: "")
        guard [2, 4, 6].contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let parts = stride(from: 0, to: digits.count, by: 2).map { offset -> Int in
            let start = digits.index(digits.startIndex, offsetBy: offset)
            return Int(digits[start..<digits.index(start, offsetBy: 2)]) ?? 0
        }
        let hour = parts[0], minute = parts.count > 1 ? parts[1] : 0, second = parts.count > 2 ? parts[2] : 0
        guard hour < 24, minute < 60, second < 61 else { return nil }
        return (hour, minute, min(second, 59))
    }
}

/// A study of the database, as the worklist's matching sees it.
public struct ReceivedStudy: Hashable, Sendable {
    public var studyInstanceUID: String
    public var accessionNumber: String
    public var patientID: String
    /// The study's date and time, nil when the study has none.
    public var date: Date?

    public init(studyInstanceUID: String?, accessionNumber: String?, patientID: String?, date: Date?) {
        self.studyInstanceUID = studyInstanceUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.accessionNumber = accessionNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.patientID = patientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.date = date
    }
}

/// How a scheduled procedure step was found among the received studies, from
/// the surest to the weakest. Nothing is written to the database: the window
/// only shows it.
public enum WorklistStudyMatch: Int, Comparable, Sendable {
    /// A study of the step's Patient ID was made on the day it is scheduled for.
    case patientIDOnScheduledDay = 1
    /// A study has the step's Accession Number, and no other Patient ID.
    case accessionNumber = 2
    /// A study has the Study Instance UID the worklist assigned to the step.
    case studyInstanceUID = 3

    public static func < (left: WorklistStudyMatch, right: WorklistStudyMatch) -> Bool { left.rawValue < right.rawValue }
}

/// The rules that say whether a scheduled procedure step has arrived.
public enum ModalityWorklistMatching {
    /// The surest match of `procedure` among `studies`, nil when none matches.
    ///
    /// - The Study Instance UID, when the worklist assigned one, identifies
    ///   the study the modality was asked to make.
    /// - The Accession Number identifies the order; a study with the same
    ///   number but another patient's ID is a different order of another
    ///   information system, not this one.
    /// - The Patient ID alone matches only a study made on the scheduled day,
    ///   since a patient has studies on other days too.
    public static func match(_ procedure: ScheduledProcedure, among studies: [ReceivedStudy],
                             calendar: Calendar = .current) -> WorklistStudyMatch? {
        let day = procedure.scheduledDay(calendar: calendar)
        var best: WorklistStudyMatch?
        for study in studies {
            var found: WorklistStudyMatch?
            if !procedure.studyInstanceUID.isEmpty && study.studyInstanceUID == procedure.studyInstanceUID {
                found = .studyInstanceUID
            } else if !procedure.accessionNumber.isEmpty && study.accessionNumber == procedure.accessionNumber
                        && (procedure.patientID.isEmpty || study.patientID.isEmpty || study.patientID == procedure.patientID) {
                found = .accessionNumber
            } else if !procedure.patientID.isEmpty && study.patientID == procedure.patientID,
                      let day, let date = study.date, calendar.isDate(date, inSameDayAs: day) {
                found = .patientIDOnScheduledDay
            }
            if let found, best.map({ found > $0 }) ?? true { best = found }
            if best == .studyInstanceUID { break }
        }
        return best
    }

    /// The values the database is searched by for `procedures`: their Study
    /// Instance UIDs, Accession Numbers and Patient IDs, blanks left out. A
    /// study that has none of them cannot match.
    public static func lookupValues(of procedures: [ScheduledProcedure])
        -> (studyInstanceUIDs: [String], accessionNumbers: [String], patientIDs: [String]) {
        func distinct(_ path: KeyPath<ScheduledProcedure, String>) -> [String] {
            var seen = Set<String>()
            return procedures.map { $0[keyPath: path] }.filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        return (distinct(\.studyInstanceUID), distinct(\.accessionNumber), distinct(\.patientID))
    }
}

/// How often the Modality Worklist window asks its nodes again, as Settings ›
/// Locations offers it: minutes, 0 for only when asked.
public enum ModalityWorklistRefresh {
    /// The intervals offered, in minutes; 0 is Manually.
    public static let choices = [0, 1, 5, 10, 15, 30, 60]

    /// The stored value within what a timer can count: negative is off, and
    /// at most one day.
    public static func minutes(fromStored stored: Int) -> Int {
        min(max(stored, 0), 24 * 60)
    }

    /// The timer's interval, nil when the window refreshes only when asked.
    public static func interval(fromStored stored: Int) -> TimeInterval? {
        let minutes = minutes(fromStored: stored)
        return minutes > 0 ? TimeInterval(minutes * 60) : nil
    }

    /// The choice the popup shows for a stored value: the value itself when
    /// offered, else the nearest choice above it, else the last.
    public static func choice(forStored stored: Int) -> Int {
        let minutes = minutes(fromStored: stored)
        return choices.first { $0 >= minutes } ?? choices[choices.count - 1]
    }
}
