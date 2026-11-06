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

/// How the XML-RPC methods read a RIS request. Their use by the methods is
/// read by tests/test-horos-scheme-url.py and tests/test-ris-request-servers.py,
/// and tools/compare-web-portal-http.py --xmlrpc-methods compares the answers.
struct RISRequestRulesTests {

    private func lookup(_ parameters: [String: Any]) -> (String) -> Any? {
        { parameters[$0] }
    }

    @Test func aStudyIsFoundByEachIdentifierAndItsLowercaseAlias() {
        let all = RISRequestRules.StudyIdentifiers(lookup([
            "PatientID": "P1", "studyInstanceUID": "1.2.3", "AccessionNumber": "A1", "studyID": "S1"]))
        #expect(all.equalities.map(\.attribute) == ["patientID", "studyInstanceUID", "accessionNumber", "id"])
        #expect(all.predicate?.predicateFormat
                == "patientID == \"P1\" AND studyInstanceUID == \"1.2.3\" AND accessionNumber == \"A1\" AND id == \"S1\"")
        #expect(all.queryKeys == ["PatientID": "P1", "StudyInstanceUID": "1.2.3", "AccessionNumber": "A1", "StudyID": "S1"])

        // The alias is read only when the name is absent: an empty name wins.
        let empty = RISRequestRules.StudyIdentifiers(lookup(["PatientID": "", "patientID": "P2", "StudyID": "S"]))
        #expect(empty.patientID == "")
        #expect(empty.equalities.map(\.attribute) == ["id"])
        #expect(empty.queryKeys == ["StudyID": "S"])

        // No identifier, or one that is not text, is a bad request.
        #expect(RISRequestRules.StudyIdentifiers(lookup([:])).predicate == nil)
        #expect(RISRequestRules.StudyIdentifiers(lookup(["PatientID": 12])).predicate == nil)
    }

    @Test func aSeriesIsFoundByPatientAndSeriesUID() {
        let series = RISRequestRules.SeriesIdentifiers(lookup(["PatientID": "P1", "SeriesInstanceUID": "1.2.3.4"]))
        #expect(series.predicate?.predicateFormat == "study.patientID == \"P1\" AND seriesDICOMUID == \"1.2.3.4\"")
        #expect(RISRequestRules.SeriesIdentifiers(lookup(["seriesInstanceUID": "1.2"])).predicate == nil)
    }

    @Test func findObjectAsksANodeForTheEqualitiesOfItsRequest() {
        let and = NSPredicate(format: "patientID == 'P1' AND 'A1' == accessionNumber AND date > %@ AND name LIKE 'X*'",
                              Date(timeIntervalSinceReferenceDate: 0) as NSDate)
        let keys = RISRequestRules.equalityKeys(of: and)
        #expect(keys.count == 2)
        #expect(keys["patientID"] as? String == "P1" && keys["accessionNumber"] as? String == "A1")
        #expect(RISRequestRules.equalityKeys(of: NSPredicate(format: "studyInstanceUID == '1.2'"))["studyInstanceUID"] as? String == "1.2")
        // An OR, a modifier and a nil constant ask for nothing.
        #expect(RISRequestRules.equalityKeys(of: NSPredicate(format: "patientID == 'P1' OR id == 'S'")).isEmpty)
        #expect(RISRequestRules.equalityKeys(of: NSPredicate(format: "ANY series.name == 'CT'")).isEmpty)
        #expect(RISRequestRules.equalityKeys(of: NSPredicate(format: "name == nil")).isEmpty)
    }

    @Test func retrieveTakesUpToNineFilterPairs() {
        var parameters: [String: Any] = ["filterKey": "PatientID", "filterValue": "P1",
                                         "filterKey3": "StudyDate", "filterValue3": 20260101,
                                         "filterKey4": "Modality", "filterKey10": "X", "filterValue10": "Y"]
        parameters["filterValue9"] = "lonely"
        let filters = RISRequestRules.retrieveFilters(lookup(parameters))
        #expect(filters.count == 2)
        #expect(filters[0].name as? String == "PatientID" && filters[0].value as? String == "P1")
        #expect(filters[1].name as? String == "StudyDate" && filters[1].value as? Int == 20260101)
    }

    @Test func cMoveWritesTheAccessionNumberAsText() {
        #expect(RISRequestRules.accessionNumber("A1") == "A1")
        #expect(RISRequestRules.accessionNumber(NSNumber(value: 876410)) == "876410")
        #expect(RISRequestRules.accessionNumber(nil) == "(null)")
        #expect(RISRequestRules.accessionFilterValue(" A1\n") == "A1")
    }

    @Test func aRetrieveUsesTheNodesModeUnlessAskedForCGetOrWADO() {
        #expect(RISRequestRules.retrieveMode(node: 0, requested: 0) == 0)
        #expect(RISRequestRules.retrieveMode(node: 0, requested: 1) == 1)
        #expect(RISRequestRules.retrieveMode(node: 1, requested: 2) == 2)
        #expect(RISRequestRules.retrieveMode(node: 3, requested: 3) == 3)
        #expect(RISRequestRules.retrieveMode(node: 2, requested: 0) == 2)
    }

    @Test func aWADOURLNamesItsStudyAndSeries() {
        let url = "http://127.0.0.1:3333/wado?requestType=WADO&studyUID=1.2&seriesUID=1.2.3&objectUID=1.2.3.4"
        let uids = RISRequestRules.wadoIdentifiers(ofURL: url)
        #expect(uids.studyUID == "1.2" && uids.seriesUID == "1.2.3")
        // The last value of a name wins; the value is what follows its first '='.
        let twice = RISRequestRules.wadoIdentifiers(ofURL: "x?studyUID=1&studyUID=2=3&flag")
        #expect(twice.studyUID == "2=3" && twice.seriesUID == nil)
        // Without a query the whole text is read as one.
        #expect(RISRequestRules.wadoIdentifiers(ofURL: "studyUID=9").studyUID == "9")
    }

    @Test func aRequestIsNamedByItsFilters() {
        #expect(RISRequestRules.describe(filters: ["PatientID": "P1", "AccessionNumber": "A1"])
                == "AccessionNumber = A1, PatientID = P1")
        #expect(RISRequestRules.describe(filters: [:]) == "-")
        #expect(RISRequestRules.describe(method: "retrieve", parameters: ["methodName": "retrieve", "serverName": "Cloud"])
                == "retrieve (serverName = Cloud)")
        #expect(RISRequestRules.describe(method: nil, parameters: [:]) == "image")
    }
}
