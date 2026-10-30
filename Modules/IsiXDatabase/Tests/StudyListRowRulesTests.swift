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
@testable import IsiXDatabase

@Suite struct StudyListRowRulesTests {

    private func row(_ values: [String: Any], study: Bool = true, distant: Bool = false) -> StudyListCell.Row {
        StudyListCell.Row(value: { values[$0] }, isDistant: { distant }, isStudyObject: { study },
                          reportPluginDate: { "plugin" }, latestReportDate: { "latest" }, note: { "note" },
                          displayName: { "[\($0 ?? "nil")]" }, numberOfImageSeries: { 4 }, localized: { "<\($0)>" })
    }

    private func value(_ identifier: String, _ values: [String: Any], reportsMode: Int32 = 0, hide: Bool = false, age: Int = 0,
                       study: Bool = true, distant: Bool = false) -> Any? {
        StudyListCell.objectValue(identifier: identifier, reportsMode: reportsMode, hidePatientName: { hide }, ageDisplay: { age },
                                  row: row(values, study: study, distant: distant))
    }

    @Test func cellsOfStudiesAndSeries() {
        #expect(value("reportURL", ["type": "Study"], reportsMode: 3) as? String == "plugin")
        #expect(value("reportURL", ["type": "Study", "reportURL": "/r"]) as? String == "latest")
        #expect(value("reportURL", ["type": "Study"]) == nil)
        #expect(value("stateText", ["stateText": "0"]) == nil)
        #expect(value("stateText", ["stateText": 2]) as? Int == 2)
        #expect(value("name", ["type": "Study", "name": "Doe"]) as? String == "[Doe]")
        #expect(value("name", ["type": "Study", "name": "Doe"], hide: true, distant: true) as? String == "<Name hidden>")
        #expect(value("patientID", ["type": "Series", "patientID": "P"]) as? String == "")
        #expect(value("noSeries", ["type": "Study"]) as? String == "4")
        #expect(value("noSeries", ["type": "Study", "imageSeries": [1, 2] as NSArray], study: false) as? String == "2")
        #expect(value("studyName", ["type": "Series", "seriesDescription": ""]) as? String == "<unknown>")
        #expect(value("studyName", ["type": "Series", "seriesDescription": "Axial"]) as? String == "Axial")
    }

    @Test func ageColumn() {
        #expect(StudyListCell.age(display: 2, yearOld: { "45 y" }, acquisition: { "46 y" }, suffix: " y") as? String == "45/46 y")
        #expect(StudyListCell.age(display: 2, yearOld: { "45 y" }, acquisition: { "45 y" }, suffix: " y") as? String == "45 y")
        #expect(StudyListCell.age(display: 7, yearOld: { nil }, acquisition: { "3 m" }, suffix: " y") as? String == "(null)/3 m")
        #expect(StudyListCell.age(display: 1, yearOld: { "a" }, acquisition: { "b" }, suffix: " y") as? String == "b")
    }

    @Test func drawingARow() {
        #expect(StudyListRowStyle.font(isStudy: false, isDistant: { true }, listed: { nil }) == .series)
        #expect(StudyListRowStyle.font(isStudy: true, isDistant: { true }, listed: { false }) == .distant)
        #expect(StudyListRowStyle.font(isStudy: true, isDistant: { false }, listed: { false }) == .regular)
        #expect(StudyListRowStyle.font(isStudy: true, isDistant: { false }, listed: { nil }) == .bold)
        #expect(StudyListRowStyle.samePatientBackground(enabled: true, selectionIsStudy: { true }, isSelection: false,
                                                        patientUID: { "AB" }, selectedPatientUID: { "ab" }))
        #expect(!StudyListRowStyle.samePatientBackground(enabled: true, selectionIsStudy: { true }, isSelection: false,
                                                         patientUID: { "A" }, selectedPatientUID: { "a" }))
        #expect(StudyListRowStyle.recency(dateSinceNow: nil, date: nil, todayStart: { 0 }, added: { (false, nil) }) == .tenMinutes)
        #expect(StudyListRowStyle.recency(dateSinceNow: -2 * 86400, date: 0, todayStart: { 0 }, added: { (true, -30) }) == .received)
        #expect(StudyListRowStyle.reportIcon(url: "https://x", databaseIsLocal: true) == .web)
        #expect(StudyListRowStyle.reportIcon(url: "https://x", databaseIsLocal: false) == .file)
        #expect(StudyListRowStyle.reportIcon(url: "", databaseIsLocal: true) == nil)
        // Without a date the tool tip says today, as the message to nil answered 0.
        #expect(StudyListRowStyle.toolTip(now: 1_000_000, acquired: nil, added: nil) == .today)
        #expect(StudyListRowStyle.toolTip(now: 1_000_000, acquired: 1_000_000 - 30, added: nil) == .tenMinutes)
    }

    @Test func editsColumnsAndTree() {
        #expect(StudyListEdit.write(key: "stateText", value: -1, rowType: { "Study" }) == .skip)
        #expect(StudyListEdit.write(key: "lockedStudy", value: "1", rowType: { "Series" }) == .skip)
        #expect(StudyListEdit.write(key: "lockedStudy", value: 1, rowType: { "Study" }) == .locked(true))
        #expect(StudyListColumns.menuOrder(titles: ["b", "a", "c"]) == [1, 0, 2])
        #expect((StudyListColumns.saved(titles: ["A", "", "B"], states: [1, 1, 0]) as NSDictionary) == ["A": 1, "B": 0] as NSDictionary)
        #expect(StudyListColumns.change(visible: true, saved: 1, isSelectedColumn: { true }) == nil)
        #expect(StudyListColumns.change(visible: true, saved: 0, isSelectedColumn: { true })
                == StudyListColumns.Change(visible: false, selectFirstColumn: true, scrollToColumn: false))
        #expect(StudyListTree.isExpandable(surgicalRow: false, isDistant: { true }, isStudyNode: { false }, type: { "Study" }) == false)
        #expect(StudyListTree.childCount(type: "Study", noFiles: { 9 }, imageSeries: { [1, 2, 3] as NSArray }) == 3)
    }

    @Test func historyMergeAndDeletion() {
        #expect(ComparativeHistory.patientChanged(selected: nil, shown: "x") == false)
        #expect(ComparativeHistory.patientChanged(selected: "ABC", shown: nil) == true)
        #expect(ComparativeHistory.row(of: "1", in: nil) == 0)
        #expect(ComparativeHistory.row(of: nil, in: ["1"]) == nil)
        #expect(ComparativeHistory.newStudy("1", uids: ["1", "2", "1"], isQueryNode: { $0 == 2 }) == (true, [2]))
        #expect(StudyMerge.destinationSeries(count: 3, isSeries: { _ in true }, imageExtension: { $0 == 2 ? "jpg" : "dcm" }) == 1)
        #expect(StudyMerge.formerIdentity(otherNames: "Old", otherIDs: "", name: "New", patientID: nil) == ("Old - New", ""))
        #expect(StudyMerge.changesPatient(destinationID: nil, destinationName: nil, studyID: nil, studyName: nil))
        #expect(StudyDeletion.locked(2, of: 2) == .all && StudyDeletion.locked(0, of: 0) == .none)
        #expect(StudyDeletion.companionFile(of: "/a/b.hdr") == "/a/b.img")
        #expect(StudyDeletion.removesFolder(contents: [".ds_store"]) && !StudyDeletion.removesFolder(contents: ["a", ".DS_Store"]))
        #expect(StudyDeletion.question(albumRow: 1, thumbnails: false, smartAlbum: { false }) == .deleteOrRemove)
    }
}
