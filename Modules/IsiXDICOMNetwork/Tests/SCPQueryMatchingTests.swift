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

/// How the listener checks a request and turns its keys into the conditions
/// it fetches with. What it answers through the application, against the
/// revision before the conversion, is the in-app comparison recorded with the
/// change; here the rules are checked on their own, with dates written as
/// their text.
struct SCPQueryMatchingTests {

    /// Dates and times as their text; a range is one with a dash.
    final class Environment: SCPMatchingEnvironment {
        var logged: [String] = []
        func string(_ bytes: [UInt8], characterSet: String?) -> String? { String(decoding: bytes, as: UTF8.self) }
        func patientNamePredicate(_ name: String?) -> NSPredicate? { NSPredicate(format: "name LIKE[cd] %@", name ?? "") }
        func sopInstanceUIDPredicate(_ uid: String) -> NSPredicate { NSPredicate(format: "uid == %@", uid) }
        func date(_ string: String?) -> String? { string }
        func time(_ string: String?) -> String? { string }
        func isQuery(_ value: String) -> Bool { value.contains("-") }
        func queryString(_ value: String) -> String? { value }
        func startOfDay(_ value: String?) -> TimeInterval { Double(value ?? "") ?? 0 }
        func endOfDay(_ value: String?) -> TimeInterval { (Double(value ?? "") ?? 0) + 1 }
        func timeNumber(_ value: String) -> NSNumber? { NSNumber(value: Int(value) ?? 0) }
        func instant(date: String, time: String) -> TimeInterval { (Double(date) ?? 0) + (Double(time) ?? 0) / 1_000_000 }
        func log(_ message: String) { logged.append(message) }
    }

    static func element(_ tag: DICOMTag, _ value: String?, name: String = "Key") -> SCPIdentifierElement {
        SCPIdentifierElement(tag: tag, value: value.map { Array($0.utf8) }, length: value?.utf8.count ?? 0, name: name)
    }

    @Test func aRequestNeedsTheStudyRootModelAndALevel() {
        let find = QueryRetrieveService.findStudyRoot.rawValue
        let level = Self.element(.queryRetrieveLevel, "STUDY")
        #expect(SCPRequestCheck.check(service: .find, sopClass: find, elements: [level]) == .accepted)
        #expect(SCPRequestCheck.check(service: .find, sopClass: "1.2.840.10008.5.1.4.1.2.1.1", elements: [level]) == .sopClassNotSupported)
        #expect(SCPRequestCheck.check(service: .retrieve, sopClass: find, elements: [level]) == .sopClassNotSupported)
        #expect(SCPRequestCheck.check(service: .retrieve, sopClass: QueryRetrieveService.getStudyRoot.rawValue, elements: [level]) == .accepted)
        #expect(SCPRequestCheck.check(service: .find, sopClass: find, elements: []) == .missingLevel)
        #expect(SCPRequestCheck.check(service: .find, sopClass: find, elements: [Self.element(.queryRetrieveLevel, "study")]) == .accepted)
        #expect(SCPRequestCheck.check(service: .find, sopClass: find, elements: [Self.element(.queryRetrieveLevel, "STUDYX")]) == .accepted)
        #expect(SCPRequestCheck.check(service: .find, sopClass: find, elements: [Self.element(.queryRetrieveLevel, "WORKLIST")]) == .unknownLevel)
        #expect(SCPRequestCheck.check(service: .find, sopClass: find, elements: [Self.element(.queryRetrieveLevel, nil)]) == .unknownLevel)
    }

    @Test func theCharacterSetIsTheFirstOfTheRequests() {
        #expect(SCPQueryMatching.characterSet(ofSpecificCharacterSet: nil) == "ISO_IR 100")
        #expect(SCPQueryMatching.characterSet(ofSpecificCharacterSet: Array("ISO_IR 192".utf8)) == "ISO_IR 192")
        #expect(SCPQueryMatching.characterSet(ofSpecificCharacterSet: Array("\\ISO 2022 IR 87".utf8)) == "")
        #expect(SCPQueryMatching.characterSet(ofSpecificCharacterSet: [0xFF, 0xFE]) == nil)
    }

    @Test func wildcardsChooseTheComparison() {
        func format(_ text: String?) -> String { SCPQueryMatching.wildcardPredicate(text, field: "patientID").predicateFormat }
        #expect(format("AB*") == #"patientID BEGINSWITH[cd] "AB""#)
        #expect(format("*AB") == #"patientID ENDSWITH[cd] "AB""#)
        #expect(format("*AB*") == #"patientID CONTAINS[cd] "AB""#)
        #expect(format("A*BC") == #"patientID LIKE[cd] "A*BC""#)
        #expect(format("AB") == #"patientID BEGINSWITH[cd] "AB" AND patientID ENDSWITH[cd] "AB""#)
        #expect(format("*") == "TRUEPREDICATE")
        #expect(format(nil) == "TRUEPREDICATE")
        #expect(SCPQueryMatching.wildcardPredicate("CT", field: "series.modality", any: true).predicateFormat
                == #"ANY series.modality BEGINSWITH[cd] "CT" AND ANY series.modality ENDSWITH[cd] "CT""#)
    }

    @Test func aStudyRequestKeepsOnlyStudiesWithDICOMFiles() {
        let environment = Environment()
        let none = SCPQueryMatching.predicates(level: "STUDY", elements: [Self.element(.patientName, nil)],
                                               characterSet: "ISO_IR 100", environment: environment)
        #expect(none.predicate?.predicateFormat == "hasDICOM == 1")
        let keyed = SCPQueryMatching.predicates(level: "STUDY", elements: [Self.element(.patientID, "AB*"),
                                                                            Self.element(.studyInstanceUID, "1.2.3")],
                                                characterSet: "ISO_IR 100", environment: environment)
        #expect(keyed.predicate?.predicateFormat == #"(patientID BEGINSWITH[cd] "AB" AND studyInstanceUID == "1.2.3") AND hasDICOM == 1"#)
        let series = SCPQueryMatching.predicates(level: "SERIES", elements: [Self.element(.studyInstanceUID, "1.2.3")],
                                                 characterSet: nil, environment: environment)
        #expect(series.predicate?.predicateFormat == #"study.studyInstanceUID == "1.2.3" AND study.hasDICOM == 1"#)
    }

    @Test func dateRangesBoundTheFetch() {
        let environment = Environment()
        let range = SCPQueryMatching.predicates(level: "STUDY", elements: [Self.element(.studyDate, "100-200")],
                                                characterSet: nil, environment: environment)
        #expect(range.predicate?.predicateFormat.contains("date >= CAST(100") == true)
        #expect(range.predicate?.predicateFormat.contains("date < CAST(201") == true)
        #expect(range.predicate?.predicateFormat.hasSuffix("hasDICOM == 1") == true)
        let after = SCPQueryMatching.predicates(level: "STUDY", elements: [Self.element(.studyDate, "100-")],
                                                characterSet: nil, environment: environment)
        #expect(after.predicate?.predicateFormat.contains("date >= CAST(100") == true)
        #expect(after.predicate?.predicateFormat.contains("date <") == false)
        let day = SCPQueryMatching.predicates(level: "STUDY", elements: [Self.element(.studyDate, "100")],
                                              characterSet: nil, environment: environment)
        #expect(day.predicate?.predicateFormat.contains("date >= CAST(100") == true
                && day.predicate?.predicateFormat.contains("date < CAST(101") == true)
    }

    @Test func imageRequestsMatchSeriesAndInstances() {
        let environment = Environment()
        let image = SCPQueryMatching.predicates(level: "IMAGE", elements: [Self.element(.studyInstanceUID, "1.2"),
                                                                            Self.element(.seriesInstanceUID, "1.2.3"),
                                                                            Self.element(.sopInstanceUID, "1.2.3.4\\1.2.3.5")],
                                                characterSet: nil, environment: environment)
        #expect(image.seriesLevel?.predicateFormat == #"study.studyInstanceUID == "1.2" AND seriesDICOMUID == "1.2.3""#)
        #expect(image.compressedSOPInstance?.predicateFormat == #"uid == "1.2.3.4" OR uid == "1.2.3.5""#)
        #expect(image.predicate?.predicateFormat == "compressedSopInstanceUID != nil AND series.study.hasDICOM == 1")
    }

    @Test func unknownKeysAndLevelsAreLogged() {
        let environment = Environment()
        _ = SCPQueryMatching.predicates(level: "STUDY", elements: [Self.element(DICOMTag(0x0009, 0x0010), "X", name: "Private")],
                                        characterSet: nil, environment: environment)
        #expect(environment.logged == ["***** DICOM SCP - STUDY LEVEL: unknown key: Private\r"])
        let none = SCPQueryMatching.predicates(level: "PATIENT", elements: [Self.element(.patientID, "1")],
                                               characterSet: nil, environment: environment)
        #expect(none.predicate == nil)
        #expect(environment.logged.last == "***** DICOM SCP supports ONLY STUDY, SERIES, IMAGE levels ! Current level: PATIENT\r")
    }
}
