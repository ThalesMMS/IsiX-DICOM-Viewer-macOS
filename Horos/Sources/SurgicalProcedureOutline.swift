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

/// Study-level SURG row for the database outline.
///
/// Ordinary structured reports stay in the study list. These rows are extra,
/// not expandable into images, and never replace a vendor SR.
@objc(HorosSurgicalProcedureOutlineRow)
public final class SurgicalProcedureOutlineRow: NSObject {
    @objc public let eventID: String
    @objc public let name: String
    @objc public let studyName: String
    @objc public let patientName: String
    @objc public let patientID: String
    @objc public let modality: String
    @objc public let date: Date
    @objc public let type: String
    @objc public let noFiles: NSNumber
    @objc public let isExpandable: Bool
    @objc public let studyInstanceUID: String

    @objc public var imageSeries: [Any] { [] }

    public init(event: [String: Any]) {
        eventID = event["eventID"] as? String ?? ""
        let operation = event["operation"] as? String ?? ""
        name = operation.isEmpty ? "Surgery" : "Surgery: \(operation)"
        studyName = event["diagnosis"] as? String ?? ""
        patientName = event["patientName"] as? String ?? ""
        patientID = event["patientID"] as? String ?? ""
        modality = event["displayModality"] as? String ?? "SURG"
        date = event["date"] as? Date ?? Date.distantPast
        type = "Study"
        noFiles = 0
        isExpandable = false
        studyInstanceUID = "procedure:\(eventID)"
        super.init()
    }

    public override func value(forUndefinedKey key: String) -> Any? { nil }
}

@objc(HorosSurgicalProcedureOutline)
public final class SurgicalProcedureOutline: NSObject {
    @objc public static func hidesOrdinaryStructuredReports() -> Bool { false }

    /// The studies, each patient's events after that patient's last study. The
    /// list may be filtered, and an event whose patient it does not show stays
    /// out. This runs at every refresh of the list, on the main thread: the
    /// studies are read once, however many events there are.
    @objc(arrayByInsertingEvents:intoStudies:)
    public static func array(insertingEvents events: [[String: Any]], intoStudies studies: [Any]) -> [Any] {
        var seen = Set<String>()
        var lastStudy: [String: Int] = [:]
        for (index, study) in studies.enumerated() {
            if let identifier = eventID(of: study) { seen.insert(identifier) }
            lastStudy[patientKey(of: study)] = index
        }
        var rowsAfter: [Int: [SurgicalProcedureOutlineRow]] = [:]
        for event in events {
            let identifier = event["eventID"] as? String ?? ""
            if identifier.isEmpty || seen.contains(identifier) { continue }
            let row = SurgicalProcedureOutlineRow(event: event)
            guard let index = lastStudy[patientKey(of: row)] else { continue }
            seen.insert(identifier)
            rowsAfter[index, default: []].append(row)
        }
        if rowsAfter.isEmpty { return studies }
        var merged: [Any] = []
        merged.reserveCapacity(studies.count + rowsAfter.count)
        for (index, study) in studies.enumerated() {
            merged.append(study)
            merged.append(contentsOf: rowsAfter[index] ?? [])
        }
        return merged
    }

    /// The studies, less those made only to hold the report of an event whose
    /// patient has another study here: that event is the SURG row beside it, and
    /// its report's study is not a study more. A patient left with nothing else
    /// keeps it, or the record would have no row at all.
    @objc(studies:hidingReportsOfEvents:)
    public static func studies(_ studies: [Any], hidingReportsOf events: [[String: Any]]) -> [Any] {
        var patientOfReport: [String: String] = [:]
        for event in events {
            guard let study = event["reportStudyInstanceUID"] as? String, study.isEmpty == false else { continue }
            patientOfReport[study] = patientKey(of: SurgicalProcedureOutlineRow(event: event))
        }
        if patientOfReport.isEmpty { return studies }
        let uids = studies.map { studyText("studyInstanceUID", of: $0) }
        var patientsWithStudies = Set<String>()
        for (study, uid) in zip(studies, uids) where patientOfReport[uid] == nil {
            patientsWithStudies.insert(patientKey(of: study))
        }
        return zip(studies, uids).filter { _, uid in
            patientOfReport[uid].map(patientsWithStudies.contains) != true
        }.map(\.0)
    }

    static func eventID(of item: Any) -> String? {
        if let row = item as? SurgicalProcedureOutlineRow { return row.eventID }
        if let dict = item as? [String: Any] { return dict["eventID"] as? String }
        return nil
    }

    static func patientID(of item: Any) -> String {
        if let row = item as? SurgicalProcedureOutlineRow { return row.patientID }
        return studyText("patientID", of: item)
    }

    static func patientName(of item: Any) -> String {
        if let row = item as? SurgicalProcedureOutlineRow { return row.patientName }
        return studyText("name", of: item)
    }

    private static func studyText(_ key: String, of item: Any) -> String {
        if let dict = item as? [String: Any] { return dict[key] as? String ?? "" }
        return (item as? NSObject)?.value(forKey: key) as? String ?? ""
    }

    /// The patient ID, or the name of a patient who has none.
    static func patientKey(of item: Any) -> String {
        let identifier = patientID(of: item)
        return identifier.isEmpty ? "name:\(patientName(of: item))" : "id:\(identifier)"
    }
}
