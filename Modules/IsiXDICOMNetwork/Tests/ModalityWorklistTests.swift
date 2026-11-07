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
import Testing
@testable import IsiXDICOMNetwork

/// The Modality Worklist window's query, the reading of its answers and the
/// matching of the scheduled steps with the received studies.
struct ModalityWorklistTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        return calendar
    }()

    func procedure(_ values: [String: String], node: String = "RIS") -> ScheduledProcedure {
        ScheduledProcedure(values: values, node: node)
    }

    @Test func onlyActivatedDIMSENodesWithTheWorklistColumnAreAsked() {
        let entries: [[String: Any]] = [
            ["AETitle": "RIS", "Address": "ris.local", "Port": "104", "Description": "Scheduling", "MWL": true],
            ["AETitle": "PACS", "Address": "pacs.local", "Port": "104"],
            ["AETitle": "OFF", "Address": "ris.local", "Port": "105", "MWL": true, "Activated": false],
            ["AETitle": "WEB", "Address": "web.local", "Port": "80", "MWL": true, "retrieveMode": 3],
            ["AETitle": "NOPORT", "Address": "ris.local", "MWL": "1"],
            ["AETitle": "TEXT", "Address": "127.0.0.1", "Port": 11112, "MWL": "1"],
        ]
        let nodes = ModalityWorklistQuery.nodes(entries.compactMap { DICOMNode(propertyList: $0) })
        #expect(nodes.map(\.aeTitle) == ["RIS", "TEXT"])
        #expect(nodes.map(ModalityWorklistQuery.name(of:)) == ["Scheduling", "TEXT"])
        #expect(DICOMNode(propertyList: entries[1])?.providesModalityWorklist == false)
    }

    @Test func theIdentifierAsksForTheScheduledStepsOfTheDays() throws {
        let now = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 11, day: 8, hour: 9).date!
        let today = try ModalityWorklistQuery.keys(for: .init(dateWindow: .today, modality: " CT ", stationAETitle: ""), now: now,
                                                   calendar: calendar)
        let date = today.first { $0.keyword == "ScheduledProcedureStepStartDate" }
        #expect(date?.inScheduledStep == true)
        #expect(date?.value == PluginQueryKeys.dateRange(from: now, to: now))
        #expect(today.first { $0.keyword == "Modality" }?.value == "CT")
        #expect(today.first { $0.keyword == "ScheduledStationAETitle" }?.value == "")
        #expect(today.contains { $0.keyword == "ScheduledStationName" && $0.inScheduledStep && $0.value.isEmpty })
        for keyword in ["PatientName", "PatientID", "AccessionNumber", "StudyInstanceUID", "RequestedProcedureDescription",
                        "ScheduledProcedureStepStartTime", "ScheduledProcedureStepDescription", "ScheduledProcedureStepID"] {
            #expect(today.contains { $0.keyword == keyword && $0.value.isEmpty }, "\(keyword)")
        }
        #expect(!today.contains { $0.keyword == "QueryRetrieveLevel" })

        let week = ModalityWorklistQuery.DateWindow.nextSevenDays.days(around: now, calendar: calendar)
        #expect(week.map { calendar.dateComponents([.day], from: $0.from, to: $0.to).day } == 6)
        let any = try ModalityWorklistQuery.keys(for: .init(dateWindow: .anyDate), now: now, calendar: calendar)
        #expect(any.first { $0.keyword == "ScheduledProcedureStepStartDate" }?.value == "")
        #expect(throws: PluginQueryKeys.Failure.invalidFilter("C\\T")) {
            try ModalityWorklistQuery.keys(for: .init(modality: "C\\T"))
        }
    }

    @Test func anAnswerIsReadByKeyword() {
        let step = procedure(["PatientName": "DOE^JANE^^^ ", "PatientID": "P1 ", "AccessionNumber": "A100",
                              "ScheduledProcedureStepStartDate": "20261108", "ScheduledProcedureStepStartTime": "093015.250",
                              "RequestedProcedureDescription": "CT HEAD", "Modality": "CT", "ScheduledStationAETitle": "CT1"])
        #expect(step.displayPatientName == "DOE JANE")
        #expect(step.patientID == "P1" && step.accessionNumber == "A100" && step.modality == "CT" && step.stationAETitle == "CT1")
        #expect(step.procedureDescription == "CT HEAD")
        #expect(step.studyInstanceUID.isEmpty && step.stepID.isEmpty)
        let start = step.scheduledStart(calendar: calendar)
        #expect(start.map { calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0) }
                == DateComponents(year: 2026, month: 11, day: 8, hour: 9, minute: 30, second: 15))
        #expect(procedure(["ScheduledProcedureStepDescription": "Step", "RequestedProcedureDescription": "Requested"])
            .procedureDescription == "Step")
        #expect(procedure(["PatientName": "YAMADA^TARO=山田^太郎"]).displayPatientName == "YAMADA TARO")
    }

    @Test func datesAndTimesTheWorklistCannotMeanAreNotRead() {
        #expect(procedure(["ScheduledProcedureStepStartDate": "20261131"]).scheduledDay(calendar: calendar) == nil)
        #expect(procedure(["ScheduledProcedureStepStartDate": "2026-11-08"]).scheduledDay(calendar: calendar) == nil)
        let noTime = procedure(["ScheduledProcedureStepStartDate": "20261108", "ScheduledProcedureStepStartTime": "2575"])
        #expect(noTime.scheduledStart(calendar: calendar) == noTime.scheduledDay(calendar: calendar))
        #expect(DICOMDateTime.time("14") ?? (0, 0, 0) == (14, 0, 0))
        #expect(DICOMDateTime.time("14:05") ?? (0, 0, 0) == (14, 5, 0))
        #expect(DICOMDateTime.time("1405x") == nil)
    }

    @Test func theAnswersOfEveryNodeAreOneListInStartOrder() {
        let late = procedure(["PatientID": "P1", "ScheduledProcedureStepStartDate": "20261108", "ScheduledProcedureStepStartTime": "1500"])
        let early = procedure(["PatientID": "P2", "ScheduledProcedureStepStartDate": "20261108", "ScheduledProcedureStepStartTime": "0800"])
        let undated = procedure(["PatientID": "P3"])
        let other = procedure(["PatientID": "P2", "ScheduledProcedureStepStartDate": "20261108", "ScheduledProcedureStepStartTime": "0800"],
                              node: "Other RIS")
        let merged = ScheduledProcedure.merged([[late, undated, early], [early, other]], calendar: calendar)
        #expect(merged.map(\.patientID) == ["P2", "P2", "P1", "P3"])
        #expect(merged.map(\.node) == ["RIS", "Other RIS", "RIS", "RIS"])
    }

    @Test func aStepMatchesTheStudyItsWorklistNamed() {
        let day = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 11, day: 8, hour: 10).date!
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
        let step = procedure(["PatientID": "P1", "AccessionNumber": "A100", "StudyInstanceUID": "1.2.3",
                              "ScheduledProcedureStepStartDate": "20261108"])
        let byUID = ReceivedStudy(studyInstanceUID: "1.2.3", accessionNumber: "OTHER", patientID: "P9", date: nextDay)
        let byAccession = ReceivedStudy(studyInstanceUID: "9.9", accessionNumber: "A100 ", patientID: "P1", date: nextDay)
        let otherPatientsOrder = ReceivedStudy(studyInstanceUID: "9.8", accessionNumber: "A100", patientID: "P2", date: day)
        let sameDay = ReceivedStudy(studyInstanceUID: "9.7", accessionNumber: "", patientID: "P1", date: day)
        let otherDay = ReceivedStudy(studyInstanceUID: "9.6", accessionNumber: "", patientID: "P1", date: nextDay)

        #expect(ModalityWorklistMatching.match(step, among: [sameDay, byAccession, byUID], calendar: calendar) == .studyInstanceUID)
        #expect(ModalityWorklistMatching.match(step, among: [sameDay, byAccession], calendar: calendar) == .accessionNumber)
        #expect(ModalityWorklistMatching.match(step, among: [otherPatientsOrder], calendar: calendar) == nil)
        #expect(ModalityWorklistMatching.match(step, among: [otherDay, sameDay], calendar: calendar) == .patientIDOnScheduledDay)
        #expect(ModalityWorklistMatching.match(step, among: [otherDay], calendar: calendar) == nil)
        #expect(ModalityWorklistMatching.match(step, among: [], calendar: calendar) == nil)

        // Blank values match nothing, and a step without a date matches no
        // study by its Patient ID.
        let blank = procedure([:])
        #expect(ModalityWorklistMatching.match(blank, among: [ReceivedStudy(studyInstanceUID: "", accessionNumber: "", patientID: "",
                                                                            date: day)], calendar: calendar) == nil)
        let undated = procedure(["PatientID": "P1"])
        #expect(ModalityWorklistMatching.match(undated, among: [sameDay], calendar: calendar) == nil)
        let noPatient = procedure(["AccessionNumber": "A100"])
        #expect(ModalityWorklistMatching.match(noPatient, among: [otherPatientsOrder], calendar: calendar) == .accessionNumber)
    }

    @Test func theDatabaseIsSearchedByTheStepsIdentifiers() {
        let values = ModalityWorklistMatching.lookupValues(of: [
            procedure(["PatientID": "P1", "AccessionNumber": "A1", "StudyInstanceUID": "1.2"]),
            procedure(["PatientID": "P1", "AccessionNumber": "A2"]),
            procedure([:]),
        ])
        #expect(values.studyInstanceUIDs == ["1.2"])
        #expect(values.accessionNumbers == ["A1", "A2"])
        #expect(values.patientIDs == ["P1"])
    }

    @Test func theRefreshIntervalIsKeptWithinADay() {
        #expect(ModalityWorklistRefresh.interval(fromStored: 0) == nil)
        #expect(ModalityWorklistRefresh.interval(fromStored: -5) == nil)
        #expect(ModalityWorklistRefresh.interval(fromStored: 5) == 300)
        #expect(ModalityWorklistRefresh.interval(fromStored: Int.max) == 86_400)
        #expect(ModalityWorklistRefresh.choice(forStored: 5) == 5)
        #expect(ModalityWorklistRefresh.choice(forStored: 7) == 10)
        #expect(ModalityWorklistRefresh.choice(forStored: 600) == 60)
        #expect(ModalityWorklistRefresh.choice(forStored: -1) == 0)
    }
}
