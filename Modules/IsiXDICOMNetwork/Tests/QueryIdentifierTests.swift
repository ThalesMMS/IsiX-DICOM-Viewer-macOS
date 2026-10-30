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

/// The identifiers the query nodes send. Their comparison with the
/// Objective-C++ they replaced, element by element through DCMTK, is
/// tests/test-query-identifier-equivalence.py.
struct QueryIdentifierTests {
    private func summary(_ identifier: DICOMQueryIdentifier) -> [String] {
        identifier.elements.map { "\($0.tag)=\(String(decoding: $0.value, as: UTF8.self))" }
    }

    @Test func settingAgainReplacesAndNilLeavesEmpty() {
        var identifier = DICOMQueryIdentifier()
        identifier.requestReturn(.studyInstanceUID)
        identifier.set(.studyInstanceUID, utf8: "1.2.3")
        identifier.set(.patientName, bytes: nil)
        #expect(summary(identifier) == ["(0010,0010)=", "(0020,000d)=1.2.3"])
        identifier.requestReturn(.studyInstanceUID)
        #expect(identifier.value(.studyInstanceUID) == [])
        #expect(identifier.string(.seriesInstanceUID) == nil)
    }

    @Test func theStudyLevelFollowsThePreferences() {
        let plain = QueryIdentifiers.studies(options: QueryReturnKeyOptions())
        #expect(plain.contains(.modality) && !plain.contains(.modalitiesInStudy))
        #expect(!plain.contains(.bodyPartExamined) && !plain.contains(.studyComments))
        #expect(plain.string(.queryRetrieveLevel) == "STUDY")
        #expect(plain.elements.count == 15)
        let all = QueryIdentifiers.studies(options: QueryReturnKeyOptions(bodyPartExamined: true, commentsAndStatus: true,
                                                                          modalitiesInStudy: true))
        #expect(all.contains(.modalitiesInStudy) && !all.contains(.modality))
        #expect(all.contains(.bodyPartExamined) && all.contains(.studyComments) && all.contains(.interpretationStatusID))
    }

    @Test func eachLevelNamesItsParents() {
        let series = QueryIdentifiers.series(ofStudy: "1.2", options: QueryReturnKeyOptions(commentsAndStatus: true))
        #expect(series.string(.studyInstanceUID) == "1.2" && series.string(.queryRetrieveLevel) == "SERIES")
        #expect(series.contains(.studyComments) && series.value(.seriesInstanceUID) == [])
        let images = QueryIdentifiers.images(ofSeries: "1.2.3", study: "1.2", options: QueryReturnKeyOptions(commentsAndStatus: true))
        #expect(images.string(.seriesInstanceUID) == "1.2.3" && images.string(.studyInstanceUID) == "1.2")
        #expect(images.contains(.imageComments) && images.string(.queryRetrieveLevel) == "IMAGE")
        let unknown = QueryIdentifiers.images(ofSeries: nil, study: nil, options: QueryReturnKeyOptions())
        #expect(unknown.value(.seriesInstanceUID) == [] && unknown.value(.studyInstanceUID) == [])
    }

    @Test func retrievesNameWhatTheyAskFor() {
        #expect(summary(QueryIdentifiers.retrieve(study: "1")) == ["(0008,0052)=STUDY", "(0020,000d)=1"])
        #expect(summary(QueryIdentifiers.retrieve(series: "2", study: "1"))
                == ["(0008,0052)=SERIES", "(0020,000d)=1", "(0020,000e)=2"])
        #expect(summary(QueryIdentifiers.retrieve(image: "3")) == ["(0008,0018)=3"])
        #expect(summary(QueryIdentifiers.retrieve(instances: ["3", "4"], series: "2", study: "1"))
                == ["(0008,0018)=3\\4", "(0008,0052)=IMAGE", "(0020,000d)=1", "(0020,000e)=2"])
        #expect(summary(QueryIdentifiers.retrieve(instances: ["3"], series: nil, study: "1"))
                == ["(0008,0018)=3", "(0008,0052)=IMAGE", "(0020,000d)=1"])
    }

    @Test func theWalkListsSeriesThenInstances() {
        let series = QueryIdentifiers.seriesListing(study: "1")
        #expect(series.elements.count == 9 && series.contains(.modality) && series.string(.queryRetrieveLevel) == "SERIES")
        let instances = QueryIdentifiers.instanceListing(series: "2", study: "1")
        #expect(summary(instances) == ["(0008,0016)=", "(0008,0018)=", "(0008,0052)=IMAGE", "(0020,000d)=1",
                                       "(0020,000e)=2", "(0020,0013)="])
        #expect(!QueryIdentifiers.instanceListing(series: "2", study: "1", instanceNumbers: false).contains(.instanceNumber))
        #expect(summary(QueryIdentifiers.relationalInstanceListing(study: "1"))
                == ["(0008,0018)=", "(0008,0052)=IMAGE", "(0020,000d)=1", "(0020,000e)="])
    }

    @Test func requestedInstancesComeFromAnImageLevelRequest() {
        #expect(QueryIdentifiers.requestedInstances(level: "IMAGE", series: "2", sopInstanceUIDs: "3\\4") == (["3", "4"], "2"))
        let none = QueryIdentifiers.requestedInstances(level: "IMAGE", series: "2", sopInstanceUIDs: "")
        #expect(none.instances == nil)
        let study = QueryIdentifiers.requestedInstances(level: "STUDY", series: nil, sopInstanceUIDs: nil)
        #expect(study.instances == [] && study.series == "")
    }

    @Test func filtersMapToAttributes() {
        #expect(QueryFilterAttribute.named("PatientsName") == .text(.patientName))
        #expect(QueryFilterAttribute.named("Comments") == .text(.imageComments))
        #expect(QueryFilterAttribute.named("PatientBirthDate") == .dateRange(.patientBirthDate))
        #expect(QueryFilterAttribute.named("PatientsBirthDate") == .dateRange(.patientBirthDate))
        #expect(QueryFilterAttribute.named("ModalitiesinStudy") == .text(.modalitiesInStudy))
        #expect(QueryFilterAttribute.named("BodyPartExamined") == nil)
        #expect(QueryRetrieveService.getPatientStudyOnly.isGet && !QueryRetrieveService.moveStudyRoot.isGet)
    }
}

struct DICOMwebSearchTests {
    @Test func theResourceFollowsTheLevel() {
        #expect(DICOMwebSearch.path(level: "STUDY", study: "1", series: "") == "studies")
        #expect(DICOMwebSearch.path(level: "SERIES", study: "1", series: "") == "studies/1/series")
        #expect(DICOMwebSearch.path(level: "SERIES", study: "", series: "") == "series")
        #expect(DICOMwebSearch.path(level: "IMAGE", study: "1", series: "2") == "studies/1/series/2/instances")
        #expect(DICOMwebSearch.path(level: "IMAGE", study: "1", series: "") == "instances")
    }

    @Test func uidsOfThePathAreNotRepeated() throws {
        let elements: [(tag: DICOMTag, value: [UInt8]?)] = [
            (.specificCharacterSet, Array("ISO_IR 100".utf8)), (.sopInstanceUID, nil), (.queryRetrieveLevel, Array("IMAGE".utf8)),
            (.patientName, Array("DOE*".utf8)), (.studyInstanceUID, Array("1".utf8)), (.seriesInstanceUID, Array("2".utf8)),
            (.instanceNumber, [])]
        let search = try DICOMwebSearch.make(level: "IMAGE", study: "1", series: "2", elements: elements) {
            String(bytes: $0, encoding: .isoLatin1)
        }.get()
        #expect(search.path == "studies/1/series/2/instances")
        #expect(search.parameters == ["00100010": "DOE*", "includefield": "00080018,00200013"])
        let refused = DICOMwebSearch.make(level: "STUDY", study: "", series: "", elements: [(.patientName, [0xff])]) { _ in nil }
        #expect(refused == .failure(.unencodableFilter))
        #expect(DICOMwebSearch.identity(ofLevel: "SERIES") == .seriesInstanceUID)
        #expect(DICOMwebSearch.identity(ofLevel: "IMAGE") == .sopInstanceUID)
    }
}

struct RetrieveRulesTests {
    @Test func wadoAsksForTheNodesSyntax() {
        #expect(WADOURITransferSyntax.parameter(forSetting: 0) == ("&transferSyntax=1.2.840.10008.1.2.1", 100))
        #expect(WADOURITransferSyntax.parameter(forSetting: 3) == ("&transferSyntax=1.2.840.10008.1.2.4.91", 70))
        #expect(WADOURITransferSyntax.parameter(forSetting: 16) == ("&transferSyntax=1.2.840.10008.1.2.4.81", 50))
        #expect(WADOURITransferSyntax.parameter(forSetting: 12) == ("&transferSyntax=*&useOrig=true", 100))
    }

    @Test func aPeerThatCountsLeadsTheBar() {
        var progress = RetrieveProgress()
        #expect(progress.update(counted: false, accounted: 0, finished: 0) { nil } == nil)
        let first = progress.update(counted: true, accounted: 10, finished: 2) { (5, 5) }
        #expect(first?.accounted == 10 && first?.finished == 2 && progress.peerCounts)
        // Once the peer counts, the listing is not asked again.
        let wait = progress.update(counted: false, accounted: 0, finished: 0) { Issue.record("asked"); return (1, 1) }
        #expect(wait == nil)
    }

    @Test func aConfirmedListingMovesTheBarForwardOnly() {
        var progress = RetrieveProgress()
        let listed = progress.update(counted: false, accounted: 0, finished: 0) { (3, 10) }
        #expect(listed?.accounted == 10 && listed?.finished == 3 && progress.listingShown)
        #expect(progress.update(counted: false, accounted: 0, finished: 0) { (2, 10) } == nil)
        // A response without counts does not take the bar back to nothing.
        #expect(progress.update(counted: true, accounted: 0, finished: 0) { nil } == nil)
        #expect(RetrieveProgress.fraction(accounted: 0, finished: 0) == 0)
    }
}
