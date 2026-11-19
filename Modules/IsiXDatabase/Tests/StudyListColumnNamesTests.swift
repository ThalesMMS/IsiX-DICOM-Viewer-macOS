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

/// The columns the study list shows are saved by the identifier of each
/// column, and a preference saved by the titles of the headers, in whatever
/// language, is still read.
@Suite struct StudyListColumnNamesTests {

    // The columns of the list in the order of the main nib, and their headers
    // in four of its languages.
    private let identifiers = ["name", "reportURL", "lockedStudy", "patientID", "yearOld", "accessionNumber",
        "studyName", "modality", "id", "comment", "stateText", "date", "noFiles", "noSeries", "dateAdded",
        "dateOpened", "referringPhysician", "performingPhysician", "institutionName", "albumsNames", "dateOfBirth",
        "localstring", "comment2", "comment3", "comment4", "note"]
    private let english = ["Patient name", "Report", "Lock", "Patient ID", "Age", "Accession Number",
        "Study Description", "Modality", "ID", "Comments", "Status", "Date Acquired", "# im", "# series",
        "Date Added", "Date Opened", "Referring Physician", "Performing Physician", "Institution", "Albums",
        "Date of Birth", "∆", "Comments 2", "Comments 3", "Comments 4", "Note"]
    private let german = ["Patientenname", "Befund", "Sperren", "Patienten-ID", "Alter", "Zugangsnummer",
        "Studienbeschreibung", "Modalität", "ID", "Kommentare", "Status", "Aufnahmedatum", "# im", "# Serien",
        "Hinzugefügt am", "Geöffnet am", "Überweisender Arzt", "Durchführender Arzt", "Einrichtung", "Alben",
        "Geburtsdatum", "∆", "Kommentare 2", "Kommentare 3", "Kommentare 4", "Notiz"]
    private let spanish = ["Nombre del paciente", "Informe", "Bloquear", "ID del paciente", "Edad",
        "Número de acceso", "Descripción del estudio", "Modalidad", "ID", "Comentarios", "Estado",
        "Fecha de adquisición", "N.º im.", "N.º series", "Fecha de incorporación", "Fecha de apertura",
        "Médico solicitante", "Médico responsable", "Institución", "Álbumes", "Fecha de nacimiento", "∆",
        "Comentarios 2", "Comentarios 3", "Comentarios 4", "Nota"]
    private let korean = ["환자 이름", "보고서", "잠금", "환자 ID", "나이", "접수 번호", "검사 설명", "검사 유형", "ID", "메모", "상태", "취득 날짜",
        "# im", "# 시리즈", "추가 날짜", "열어 본 날짜", "의뢰 의사", "검사 의사", "기관", "앨범", "생년월일", "∆", "댓글 2", "댓글 3", "댓글 4", "메모"]

    private func read(_ saved: [(String, Any)], titles: [String]) -> StudyListColumns.Reading {
        StudyListColumns.read(saved.map { (key: $0.0, state: $0.1) }, identifiers: identifiers, titles: titles)
    }

    private func states(_ reading: StudyListColumns.Reading) -> [String] {
        reading.states.map { "\($0.identifier)=\(RowValues.int($0.state))" }
    }

    private func stored(_ reading: StudyListColumns.Reading) -> [String: Int32]? {
        reading.byIdentifier?.mapValues { RowValues.int($0) }
    }

    @Test func theListsOfTheTestAreTheColumnsOfTheList() {
        #expect(identifiers.count == 26 && Set(identifiers).count == 26)
        for titles in [english, german, spanish, korean] {
            #expect(titles.count == identifiers.count)
        }
    }

    // MARK: What is saved

    @Test func theColumnsAreSavedByIdentifier() {
        #expect(StudyListColumns.saved(identifiers: ["name", "reportURL", "lockedStudy"], states: [1, 0, 1])
                == ["name": 1, "reportURL": 0, "lockedStudy": 1])
        // A column without an identifier is left out, as an item without a title was.
        #expect(StudyListColumns.saved(identifiers: ["name", "", "note"], states: [1, 1, 0]) == ["name": 1, "note": 0])
        #expect(StudyListColumns.saved(identifiers: ["name"], states: [256]) == ["name": 256])
    }

    @Test func twoColumnsWithTheSameTitleKeepAStateEach() throws {
        // The comments and the note have one title in Korean: saved by title,
        // the state of the second replaced that of the first.
        let comment = try #require(identifiers.firstIndex(of: "comment")), note = try #require(identifiers.firstIndex(of: "note"))
        #expect(korean[comment] == korean[note])
        var shown = [Int](repeating: 1, count: identifiers.count)
        shown[note] = 0
        let saved = StudyListColumns.saved(identifiers: identifiers, states: shown)
        #expect(saved.count == identifiers.count)
        #expect(saved["comment"] == 1 && saved["note"] == 0)

        let reading = read(saved.map { ($0.key, $0.value as Any) }, titles: korean)
        #expect(reading.byIdentifier == nil)
        #expect(Dictionary(uniqueKeysWithValues: reading.states.map { ($0.identifier, RowValues.int($0.state)) }) == saved)
    }

    // MARK: What is read

    @Test func aPreferenceSavedByIdentifierReadsTheSameInEveryLanguage() {
        let saved: [(String, Any)] = [("reportURL", 0), ("patientID", 1), ("lockedStudy", 0)]
        for titles in [english, german, spanish, korean] {
            let reading = read(saved, titles: titles)
            #expect(states(reading) == ["reportURL=0", "patientID=1", "lockedStudy=0"])
            // Nothing to store again.
            #expect(reading.byIdentifier == nil)
        }
    }

    @Test func aPreferenceSavedWithTheTitlesOfAnotherLanguageIsRead() {
        // Saved in German with the report and the lock hidden, read by a list
        // whose headers are Spanish.
        let saved: [(String, Any)] = [("Befund", 0), ("Patienten-ID", 1), ("Sperren", 0), ("Geburtsdatum", 1)]
        let reading = read(saved, titles: spanish)
        #expect(states(reading) == ["reportURL=0", "patientID=1", "lockedStudy=0", "dateOfBirth=1"])
        // Stored again by identifier, with the states it gave: what was hidden stays hidden.
        #expect(stored(reading) == ["reportURL": 0, "patientID": 1, "lockedStudy": 0, "dateOfBirth": 1])
        // Read again, it says the same and is left as it is.
        let again = read(reading.byIdentifier?.map { ($0.key, $0.value) } ?? [], titles: english)
        #expect(Set(states(again)) == Set(states(reading)))
        #expect(again.byIdentifier == nil)
    }

    @Test func aPreferenceSavedWithTheTitlesOfTheListIsReadAndStoredByIdentifier() {
        let saved: [(String, Any)] = zip(spanish, identifiers).map { ($0.0, $0.1 == "note" ? 0 : 1) }
        let reading = read(saved, titles: spanish)
        #expect(reading.states.map(\.identifier) == identifiers)
        #expect(stored(reading) == Dictionary(uniqueKeysWithValues: identifiers.map { ($0, Int32($0 == "note" ? 0 : 1)) }))
    }

    @Test func everyTitleAColumnEverHadNamesIt() {
        // The titles two columns shared name the first of them in the list.
        let shared: [String: String] = ["메모": "comment", "备注": "comment"]
        var checked = 0
        for identifier in identifiers {
            let titles = StudyListColumnTitles.former[identifier] ?? []
            #expect(!titles.isEmpty, "\(identifier) has no title")
            for title in titles {
                let index = StudyListColumns.column(named: title, identifiers: identifiers, titles: english)
                #expect(index.map { identifiers[$0] } == (shared[title] ?? identifier), "\(title) of \(identifier)")
                checked += 1
            }
        }
        #expect(checked > 290)
        #expect(Set(StudyListColumnTitles.former.keys) == Set(identifiers))
    }

    @Test func theTitlesOfTheFourLanguagesAreKnown() {
        for titles in [english, german, spanish, korean] {
            for (identifier, title) in zip(identifiers, titles) {
                #expect(StudyListColumnTitles.names(title, column: identifier), "\(title) of \(identifier)")
            }
        }
        #expect(StudyListColumnTitles.names("Befund", column: "lockedStudy") == false)
        #expect(StudyListColumnTitles.names("Befund", column: "no such column") == false)
    }

    @Test func noTitleIsTheIdentifierOfAnotherColumn() {
        // A key is taken as an identifier first: no title may name another column that way.
        for (identifier, titles) in StudyListColumnTitles.former {
            for title in titles where identifiers.contains(title) {
                #expect(title == identifier)
            }
        }
    }

    @Test func aTitleTwoColumnsSharedNamesTheFirstOfThemInTheList() throws {
        // One state for both in the preference: applied to the first column of
        // that title in the order the list has them, as it was when the list
        // was read in the language that wrote it.
        #expect(states(read([("메모", 0)], titles: english)) == ["comment=0"])
        #expect(states(read([("메모", 0)], titles: korean)) == ["comment=0"])
        var moved = identifiers
        moved.removeAll { $0 == "note" }
        moved.insert("note", at: 1)
        let reading = StudyListColumns.read([(key: "备注", state: 0)], identifiers: moved, titles: moved)
        #expect(states(reading) == ["note=0"])
        #expect(stored(reading) == ["note": 0])
    }

    @Test func theTitleTheHeaderHasNowComesBeforeTheTitlesOfOtherDays() {
        // As the list was read by title: the first column whose header has the
        // title, compared code unit by code unit.
        #expect(StudyListColumns.column(named: "Date", identifiers: ["a", "b"], titles: ["Name", "Date"]) == 1)
        #expect(StudyListColumns.column(named: "Date", identifiers: ["a", "b", "c"], titles: ["Name", "Date", "Date"]) == 1)
        #expect(StudyListColumns.column(named: "e\u{301}", identifiers: ["a"], titles: ["\u{e9}"]) == nil)
        // The identifier before any title.
        #expect(StudyListColumns.column(named: "b", identifiers: ["a", "b"], titles: ["b", "a"]) == 1)
        // A header of today that another column had on another day.
        #expect(StudyListColumns.column(named: "Befund", identifiers: ["lockedStudy", "reportURL"], titles: ["Befund", "Bericht"]) == 0)
        #expect(StudyListColumns.column(named: "Befund", identifiers: ["lockedStudy", "reportURL"], titles: ["Sperre", "Bericht"]) == 1)
    }

    @Test func aKeyThatNamesNoColumnIsKeptAndChangesNothing() {
        let reading = read([("Befund", 0), ("A column of a plugin", 1), ("date2", 0)], titles: english)
        #expect(states(reading) == ["reportURL=0"])
        #expect(stored(reading) == ["reportURL": 0, "A column of a plugin": 1, "date2": 0])
        // With nothing named by a title, there is nothing to store again.
        let unknown = read([("A column of a plugin", 1), ("reportURL", 1)], titles: english)
        #expect(states(unknown) == ["reportURL=1"])
        #expect(unknown.byIdentifier == nil)
    }

    @Test func theIdentifierPrevailsOverATitleAndTheFirstTitleOverTheNext() {
        // The same column by its identifier and by a title, in either order.
        for saved in [[("reportURL", 1), ("Befund", 0)], [("Befund", 0), ("reportURL", 1)]] as [[(String, Any)]] {
            let reading = read(saved, titles: spanish)
            #expect(states(reading) == ["reportURL=1"])
            #expect(stored(reading) == ["reportURL": 1])
        }
        // The same column by the titles of two languages.
        let reading = read([("Informe", 0), ("Befund", 1), ("Sperren", 0)], titles: english)
        #expect(states(reading) == ["reportURL=0", "lockedStudy=0"])
        #expect(stored(reading) == ["reportURL": 0, "lockedStudy": 0])
    }

    @Test func theStatesAreKeptAsTheyWereSaved() {
        // A state that is text or another number is stored again as it was.
        let reading = read([("Befund", "1"), ("Sperren", 256)], titles: english)
        #expect(reading.byIdentifier?["reportURL"] as? String == "1")
        #expect(reading.byIdentifier?["lockedStudy"] as? Int == 256)
        #expect(read([], titles: english).states.isEmpty)
        #expect(read([], titles: english).byIdentifier == nil)
    }
}
