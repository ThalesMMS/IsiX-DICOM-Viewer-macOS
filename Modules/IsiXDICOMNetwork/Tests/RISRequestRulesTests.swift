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

    @Test func aParameterIsReadWhateverTheCaseOfItsName() {
        // A link a PACS writes, with ServerName and then=Open.
        let link: [AnyHashable: Any] = ["methodName": "Retrieve", "retrieveOnlyIfNeeded": "yes", "ServerName": "Main PACS",
                                        "filterKey": "StudyInstanceUID", "filterValue": "1.2.3", "then": "Open"]
        let parameter = RISRequestRules.parameters(link)
        #expect(parameter("serverName") as? String == "Main PACS")
        #expect(parameter("SERVERNAME") as? String == "Main PACS")
        #expect(parameter("retrieveonlyifneeded") as? String == "yes")
        #expect(parameter("server") == nil)
        let filters = RISRequestRules.retrieveFilters(RISRequestRules.parameters(["FilterKey": "PatientID", "FILTERVALUE": "P1",
                                                                                  "filterkey2": "Modality", "filterValue2": "CT"]))
        #expect(filters.map { "\($0.name)=\($0.value)" } == ["PatientID=P1", "Modality=CT"])
        // The name as it is asked for comes first; of two that differ from it
        // in case only, the first in the order of the names.
        let both = RISRequestRules.parameters(["serverName": "exact", "ServerName": "other", "SERVERNAME": "upper"])
        #expect(both("serverName") as? String == "exact")
        #expect(both("servername") as? String == "upper")
        // DisplayStudy's identifiers, which the link parser takes in any case.
        let study = RISRequestRules.StudyIdentifiers(RISRequestRules.parameters(["studyinstanceuid": "1.2", "PATIENTID": "P"]))
        #expect(study.studyInstanceUID == "1.2" && study.patientID == "P")
        #expect(RISRequestRules.parameters(nil)("serverName") == nil)
        // methodName is no parameter of a method: the parser of the link reads
        // it under that exact spelling, and naming a request leaves out only that one.
        #expect(RISRequestRules.describe(method: "Retrieve", parameters: ["methodName": "Retrieve", "MethodName": "x"])
                == "Retrieve (MethodName = x)")
    }

    @Test func thenOpensOrSelectsInAnyCaseAndAnythingElseOnlyRetrieves() {
        typealias FollowUp = RISRequestRules.RetrieveFollowUp
        #expect(FollowUp(then: "Open") == .open && FollowUp(then: "open") == .open && FollowUp(then: " OPEN ") == .open)
        #expect(FollowUp(then: "display") == .open && FollowUp(then: "Display") == .open)
        #expect(FollowUp(then: "select") == .select && FollowUp(then: "Select") == .select)
        // A value this app does not know only retrieves, as every Retrieve did before `then` was read.
        #expect(FollowUp(then: "show") == .none && FollowUp(then: "") == .none && FollowUp(then: nil) == .none && FollowUp(then: 1) == .none)
    }

    @Test func aFlagIsReadAsBoolValueReadsIt() {
        for yes in ["yes", "YES", "true", "1", "Y"] as [Any] + [1, true] { #expect(RISRequestRules.flag(yes)) }
        for no in ["no", "false", "0", "", "maybe"] as [Any] + [0, false] { #expect(!RISRequestRules.flag(no)) }
        #expect(!RISRequestRules.flag(nil))
    }

    @Test func aRetrieveWithNoFilterTheNodeCanBeAskedForIsNotSent() {
        let known: (String) -> Bool = { ["PatientID", "StudyInstanceUID", "AccessionNumber", "StudyDate"].contains($0) }
        func refusal(_ filters: [(name: Any, value: Any)]) -> RISRequestRules.RetrieveFilterRefusal? {
            RISRequestRules.refusal(ofRetrieveFilters: filters, isAttribute: known)
        }
        #expect(refusal([("StudyInstanceUID", "1.2.3")]) == nil)
        #expect(refusal([("PatientID", ""), ("StudyDate", 20260101)]) == nil)
        // No pair at all, and pairs whose values ask for everything.
        #expect(refusal([]) == .noValue)
        #expect(refusal([("PatientID", "")]) == .noValue)
        #expect(refusal([("PatientID", "*"), ("AccessionNumber", " ? ")]) == .noValue)
        // A key the query would leave out: in another case, misspelt, or no text.
        #expect(refusal([("studyInstanceUID", "1.2.3")]) == .unknownKeys(["studyInstanceUID"]))
        #expect(refusal([("PatientID", "P1"), ("StudyInstanceUDI", "1.2.3"), (7, "x")]) == .unknownKeys(["StudyInstanceUDI", "7"]))
    }

    @Test func aStudyWholeHereIsNotRetrievedWhenOnlyIfNeeded() {
        // Retrieved when fewer instances are here than the node counts, or when the node gives no count.
        #expect(!RISRequestRules.retrieveIsNeeded(localInstances: 120, reportedInstances: 120))
        #expect(!RISRequestRules.retrieveIsNeeded(localInstances: 121, reportedInstances: 120))
        #expect(RISRequestRules.retrieveIsNeeded(localInstances: 119, reportedInstances: 120))
        #expect(RISRequestRules.retrieveIsNeeded(localInstances: 0, reportedInstances: 120))
        // A node that counts nothing says nothing of what it has: the study
        // goes the usual way, even when instances of it are here.
        #expect(RISRequestRules.retrieveIsNeeded(localInstances: 120, reportedInstances: 0))
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
        // The URL of a download is named without its query, its user and its fragment.
        #expect(RISRequestRules.describe(method: "DownloadURL", parameters: ["methodName": "DownloadURL", "Display": "YES",
                                                                             "URL": "https://pacs.example.com:8443/wado?requestType=WADO&studyUID=1.2.3&token=secret"])
                == "DownloadURL (Display = YES, URL = https://pacs.example.com:8443/wado?…)")
        #expect(RISRequestRules.describe(method: "downloadurl", parameters: ["url": "https://user:secret@pacs.example.com/a.dcm#part"])
                == "downloadurl (url = https://pacs.example.com/a.dcm)")
        #expect(RISRequestRules.addressWithoutQuery("https://pacs.example.com/wado") == "https://pacs.example.com/wado")
        #expect(RISRequestRules.addressWithoutQuery("https://pacs.example.com/a@b?x=1#y?z") == "https://pacs.example.com/a@b?…")
        #expect(RISRequestRules.addressWithoutQuery("not a url ?token=secret") == "not a url ?…")
        #expect(RISRequestRules.addressWithoutQuery("") == "")
        // Another method's parameters read as they came.
        #expect(RISRequestRules.describe(method: "Retrieve", parameters: ["URL": "https://a.example/?x=1"]) == "Retrieve (URL = https://a.example/?x=1)")
    }
}
