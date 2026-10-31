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
import IsiXPreferences
@testable import IsiXDICOMNetwork

/// The filters of the Query window and the C-FIND they build. Their comparison
/// with the window's former dictionaries is tests/test-query-window-filters-equivalence.py.
struct QueryWindowFiltersTests {
    private let utc = TimeZone(identifier: "UTC")!
    // 2026-10-28 14:05:09.75 UTC
    private let now = Date(timeIntervalSince1970: 1_793_196_309.75)
    private let allFields = Set(QueryWindowField.allCases)

    private func filters(_ field: QueryWindowField, _ build: (inout QueryWindowFilters) -> Void = { _ in }) -> QueryWindowFilters {
        var filters = QueryWindowFilters()
        filters.fieldIndex = Int32(field.rawValue)
        build(&filters)
        return filters
    }

    private func query(_ filters: QueryWindowFilters, _ settings: QueryWindowQuerySettings? = nil,
                       keyword: String? = nil) -> QueryWindowQuery {
        filters.query(settings: settings ?? QueryWindowQuerySettings(allowedFields: allFields), customFieldKeyword: keyword,
                      now: now, timeZone: utc)
    }

    private func pairs(_ query: QueryWindowQuery) -> [String] {
        query.filters.map { "\($0.key ?? "nil")=\($0.value)" }
    }

    // MARK: The preset dictionary

    private var fullPreset: [String: Any] {
        ["DICOMNodes": ["pacs:104", "web:80"], "DICOMNodesAETitle": ["PACS", "DICOMweb"],
         "searchFieldName": "doe", "searchFieldRefPhysician": "house", "searchInstitutionName": "general",
         "searchStatus": NSNumber(value: 3), "searchFieldID": "123", "searchFieldAN": "A1",
         "searchFieldStudyDescription": "chest ", "searchFieldComments": " urgent", "searchCustomField": "BODY",
         "searchCustomFieldDICOM": "Body Part Examined", "dateFilterMatrix": NSNumber(value: 5),
         "birthdateFilterMatrix": NSNumber(value: -1), "modalityStrings": ["CT", "MR"], "PatientModeMatrix": NSNumber(value: 2),
         "fromDate": NSNumber(value: 783_000_000.5), "toDate": NSNumber(value: 783_600_000.0), "searchBirth": NSNumber(value: -86_400.0),
         "autoRefreshQueryResults": NSNumber(value: -30), "autoRetrieving": true, "NumberOfPreviousStudyToRetrieve": 2,
         "retrieveSameModality": false, "retrieveSameDescription": true]
    }

    @Test func aPresetIsWrittenBackWithTheSameKeysAndValues() {
        let read = QueryWindowFilters(propertyList: fullPreset)
        let written = PropertyListValue.dictionary(read.propertyList)
        #expect(written != nil && written == PropertyListValue.dictionary(fullPreset))
        #expect(QueryWindowFilters(propertyList: read.propertyList) == read)
        #expect(read.field == .accessionNumber && read.nodes == ["pacs:104", "web:80"] && read.interpretationStatus == 3)
        #expect(read.modalities == .titles(["CT", "MR"]) && read.refreshSetting == -30)
        #expect(read.retrieveSettings["NumberOfPreviousStudyToRetrieve"] == .integer(2))
    }

    @Test func numbersMayBeTextAndOtherTypesCountAsMissing() {
        let read = QueryWindowFilters(propertyList: ["dateFilterMatrix": "7 days", "PatientModeMatrix": "9", "fromDate": "12.5",
                                                     "searchFieldName": NSNumber(value: 4), "DICOMNodes": ["a", 1],
                                                     "searchStatus": "x", "modalityStrings": "CT"])
        #expect(read.dateChoice == 7 && read.field == .interpretationStatus && read.fromDate.timeIntervalSinceReferenceDate == 12.5)
        #expect(read.patientName == nil && read.nodes == nil && read.interpretationStatus == 0 && read.modalities == .none)
        // An empty preset reads as the window's empty choices; it names no nodes.
        let empty = QueryWindowFilters(propertyList: [:])
        #expect(empty == QueryWindowFilters() && empty.propertyList["DICOMNodes"] == nil && empty.propertyList["searchStatus"] == nil)
    }

    @Test func formerModalityChoicesAreKept() {
        let cells = QueryWindowFilters(propertyList: ["modalityFilterMatrixString": "1 0 2 1 "])
        #expect(cells.modalities == .formerCells("1 0 2 1 ") && cells.propertyList["modalityFilterMatrixString"] as? String == "1 0 2 1 ")
        let cell = QueryWindowFilters(propertyList: ["modalityFilterMatrixRow": "3", "modalityFilterMatrixColumn": NSNumber(value: 1)])
        #expect(cell.modalities == .formerCell(row: 3, column: 1))
        // The titles win over the former forms, as the window read them.
        let both = QueryWindowFilters(propertyList: ["modalityStrings": ["US"], "modalityFilterMatrixString": "0 0 "])
        #expect(both.modalities == .titles(["US"]))
        // None of the former forms is a modality filter of the query.
        #expect(query(cells, QueryWindowQuerySettings(allowsModality: true)).filters.isEmpty)
    }

    // MARK: The search fields

    @Test func textFieldsAreSentAsTheWindowSendsThem() {
        let name = query(filters(.patientName) { $0.patientName = "  doe^jo " })
        #expect(pairs(name) == ["PatientsName=doe^jo*"] && name.asksForSomething && name.patientName == "doe^jo" && name.typedValue == "  doe^jo ")
        #expect(pairs(query(filters(.patientID) { $0.patientID = " 12* " })) == ["PatientID=12*"])
        #expect(pairs(query(filters(.accessionNumber) { $0.accessionNumber = "A 1" })) == ["AccessionNumber=A 1"])
        #expect(pairs(query(filters(.studyDescription) { $0.studyDescription = " chest " })) == ["StudyDescription= chest *"])
        #expect(pairs(query(filters(.studyComments) { $0.studyComments = "urgent\n" })) == ["StudyComments=urgent\n*"])
        #expect(pairs(query(filters(.referringPhysician) { $0.referringPhysician = "house" })) == ["ReferringPhysiciansName=house*"])
        #expect(pairs(query(filters(.institutionName) { $0.institutionName = " general" })) == ["InstitutionName=general*"])
        // Only the name is tried again in other spellings.
        #expect(query(filters(.patientID) { $0.patientID = "12" }).patientName == nil)
    }

    @Test func anEmptyFieldOrOneNotAllowedSendsNothing() {
        let blank = query(filters(.patientName) { $0.patientName = "   " })
        #expect(blank.filters.isEmpty && !blank.asksForSomething && blank.field == .patientName && blank.patientName == nil)
        let refused = query(filters(.patientName) { $0.patientName = "doe" }, QueryWindowQuerySettings(allowedFields: [.patientID]))
        #expect(refused.filters.isEmpty && refused.field == nil && refused.typedValue == nil)
        let outOfRange = filters(.patientName) { $0.fieldIndex = 12; $0.patientName = "doe" }
        #expect(query(outOfRange).filters.isEmpty && query(outOfRange).field == nil)
    }

    @Test func theCustomFieldTakesTheKeywordOfItsAttribute() {
        let custom = filters(.customField) { $0.customField = " HEAD " }
        #expect(pairs(query(custom, keyword: "BodyPartExamined")) == ["BodyPartExamined=HEAD"])
        // Without a keyword the filter has no name, which the query manager
        // drops; the query still counts as asking for something.
        let unnamed = query(custom)
        #expect(pairs(unnamed) == ["nil=HEAD"] && unnamed.asksForSomething)
    }

    @Test func theStateIsSentAsItsNumber() {
        #expect(pairs(query(filters(.interpretationStatus) { $0.interpretationStatus = 4 })) == ["InterpretationStatusID=4"])
        let missing = query(filters(.interpretationStatus))
        #expect(pairs(missing) == ["InterpretationStatusID=0"] && missing.typedValue == "0")
    }

    @Test func theBirthDateMatchesOnBeforeOrAfter() {
        let birth = Date(timeIntervalSince1970: 315_576_000) // 1980-01-01 12:00 UTC
        func sent(_ choice: Int32) -> QueryWindowQuery {
            query(filters(.patientBirthDate) { $0.birthDate = birth; $0.birthDateChoice = choice })
        }
        #expect(pairs(sent(0)) == ["PatientBirthDate=19800101"] && pairs(sent(-1)) == ["PatientBirthDate=-19800101"])
        #expect(pairs(sent(1)) == ["PatientBirthDate=19800101-"])
        // Another choice sends no filter, but the query asks for the field.
        #expect(sent(2).filters.isEmpty && sent(2).asksForSomething && sent(2).typedValue == nil)
    }

    // MARK: Dates, modalities and the character set

    @Test func theDateChoiceIsSentWhenAllowed() {
        let allowed = QueryWindowQuerySettings(allowsStudyDate: true)
        func sent(_ choice: Int32, future: Bool = false, _ build: (inout QueryWindowFilters) -> Void = { _ in }) -> [String] {
            var settings = allowed
            settings.allowsFutureQuery = future
            var value = QueryWindowFilters()
            value.dateChoice = choice
            build(&value)
            return pairs(query(value, settings))
        }
        let later = now.addingTimeInterval(3 * 86_400)
        #expect(sent(QueryDateFilter.between) { $0.fromDate = later; $0.toDate = now } == ["StudyDate=20261028-20261031"])
        #expect(sent(QueryDateFilter.on) { $0.fromDate = later } == ["StudyDate=20261031-20261031"])
        #expect(sent(QueryDateFilter.today) == ["StudyDate=20261028-20261028"])
        #expect(sent(QueryDateFilter.last7Days) == ["StudyDate=20261021-20261028"])
        #expect(sent(QueryDateFilter.last7Days, future: true) == ["StudyDate=20261021-"])
        #expect(sent(QueryDateFilter.todayAM) == ["StudyDate=20261028-20261028", "StudyTime=000000.000-120000.000"])
        #expect(sent(QueryDateFilter.hoursBase + 2) == ["StudyDate=20261028-20261028", "StudyTime=120509.000-140509.000"])
        #expect(sent(QueryDateFilter.anyDate).isEmpty)
        // Not allowed, no date is sent; an unknown choice is reported either way.
        var value = QueryWindowFilters()
        value.dateChoice = 77
        #expect(query(value).filters.isEmpty && query(value).unknownDateChoice && !query(value).asksForSomething)
    }

    @Test func modalitiesFollowAnotherFilterOrTheirPreference() {
        var value = filters(.patientID) { $0.patientID = "12"; $0.modalities = .titles(["CT", "MR"]) }
        #expect(pairs(query(value)) == ["PatientID=12", "Modality=CT\\MR"])
        var settings = QueryWindowQuerySettings(allowedFields: allFields, supportsModalitiesInStudy: true)
        #expect(query(value, settings).value(of: "ModalitiesinStudy") == "CT\\MR")
        value.patientID = ""
        #expect(query(value, settings).filters.isEmpty)
        settings.allowsModality = true
        let alone = query(value, settings)
        #expect(pairs(alone) == ["ModalitiesinStudy=CT\\MR"] && alone.asksForSomething)
        value.modalities = .titles([])
        #expect(query(value, settings).filters.isEmpty)
    }

    @Test func theCharacterSetIsSentUnlessLatin1() {
        let name = filters(.patientName) { $0.patientName = "doe" }
        var settings = QueryWindowQuerySettings(allowedFields: allFields, characterSet: "ISO_IR 192")
        #expect(pairs(query(name, settings)) == ["SpecificCharacterSet=ISO_IR 192", "PatientsName=doe*"])
        settings.characterSet = "ISO_IR 100"
        #expect(pairs(query(name, settings)) == ["PatientsName=doe*"])
    }

    @Test func settingsAreReadFromThePreferences() throws {
        // Preferences in memory, the factory values beneath: no domain is written.
        let defaults = MemoryPreferences(["allow_qr_name": true, "allow_qr_custom_dicom_field": true, "allow_qr_study_date": true,
                                          "STRINGENCODING": "ISO_IR 192"],
                                         registered: ["allow_qr_id": "0", "allow_qr_modality": "0", "SupportQRModalitiesinStudy": "0",
                                                      "DICOMQueryAllowFutureQuery": "0"])
        let settings = QueryWindowQuerySettings(defaults: defaults)
        #expect(settings == QueryWindowQuerySettings(allowedFields: [.patientName, .customField], allowsStudyDate: true,
                                                     characterSet: "ISO_IR 192"))
    }

    // MARK: The sources

    private func source(_ address: String?, _ title: String?, _ checked: Bool, _ name: String?) -> QueryWindowSource {
        QueryWindowSource(addressAndPort: address, aeTitle: title, activated: checked,
                          server: name.map { DICOMNode(entry: ["Description": .string($0)]) })
    }

    @Test func theNodesOfAPresetAreFoundAmongTheSources() {
        var state = QueryWindowState()
        state.sources = [source("pacs:104", "A", false, "first"), source("pacs:104", "B", true, "second"),
                         source("web:80", "DICOMweb", false, nil), source("other:11112", "C", false, "third")]
        func names(_ nodes: [String], _ titles: [String]) -> [String?] {
            state.servers(forNodes: nodes, aeTitles: titles).map(\.nodeDescription)
        }
        // The last source with the address answers when no AE title is given.
        #expect(names(["pacs:104"], []) == ["second"])
        #expect(names(["pacs:104", "other:11112"], ["A"]) == ["first", "third"])
        // A source without a node, or no source at all, is left out.
        #expect(names(["web:80", "gone:1", "pacs:104"], ["DICOMweb", "X", "B"]) == ["second"])
    }

    @Test func theCheckedSourcesOrTheSelectedOneAreAsked() {
        var state = QueryWindowState()
        state.sources = [source("a:1", "A", false, "a"), source("b:2", "B", true, "b"), source("c:3", nil, true, "c")]
        state.selectedSourceRow = 0
        #expect(state.sourcesForPatientQuery().map(\.addressAndPort) == ["b:2", "c:3"])
        #expect(state.checkedNodes().nodes == ["b:2", "c:3"] && state.checkedNodes().aeTitles == ["B", ""])
        for index in state.sources.indices { state.sources[index].activated = false }
        #expect(state.sourcesForPatientQuery().map(\.addressAndPort) == ["a:1"])
        #expect(state.checkedNodes().nodes == ["a:1"])
        state.selectedSourceRow = -1
        #expect(state.sourcesForPatientQuery().isEmpty && state.checkedNodes().nodes.isEmpty)

        let run = QueryWindowRun(filters: QueryWindowFilters(propertyList: ["DICOMNodes": ["c:3", "b:2"]]),
                                 customFieldKeyword: nil, sources: state)
        #expect(run.servers.map(\.nodeDescription) == ["c", "b"])
    }
}
