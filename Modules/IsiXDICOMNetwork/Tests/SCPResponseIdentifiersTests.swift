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

/// How the listener answers a C-FIND from the records of its database, and in
/// which character set.
struct SCPResponseIdentifiersTests {

    /// A record read through key paths of a dictionary.
    struct Record: SCPResponseRecord {
        let values: [String: Any]
        func value(forKeyPath keyPath: String) -> Any? { values[keyPath] }
        func primitiveValue(forKey key: String) -> Any? { values[key] }
        func dicomDate(_ date: Any) -> String? { "20260102" }
        func dicomTime(_ date: Any) -> String? { "030405" }
        func isImageStorage(_ uid: Any?) -> Bool { (uid as? String) == "1.2.840.10008.5.1.4.1.1.2" }
    }

    @Test func aStudyAnswersFromItsRecord() {
        let record = Record(values: ["name": "DOE^JANE", "patientID": "P1", "date": Date(), "studyInstanceUID": "1.2.3",
                                     "noFiles": 4, "rawNoFiles": NSNumber(value: 4), "series": NSSet(array: ["a", "b"]),
                                     "modality": "CT", "series.modality": NSArray(array: ["SR", "CT", "MR", "CT"])])
        let entries = SCPResponseIdentifier.entries(level: .study, keys: [.patientName, .patientID, .studyDate, .studyTime,
                                                                           .studyInstanceUID, .numberOfStudyRelatedInstances,
                                                                           .numberOfStudyRelatedSeries, .modalitiesInStudy,
                                                                           .accessionNumber, .seriesInstanceUID],
                                                    record: record)
        #expect(entries == [.put(.patientName, .encoded("DOE^JANE")), .put(.patientID, .encoded("P1")),
                            .put(.studyDate, .latin1("20260102")), .put(.studyTime, .latin1("030405")),
                            .put(.studyInstanceUID, .latin1("1.2.3")), .put(.numberOfStudyRelatedInstances, .ascii("4")),
                            .put(.numberOfStudyRelatedSeries, .ascii("2")), .put(.modalitiesInStudy, .latin1("CT\\MR\\SR")),
                            .empty(.accessionNumber), .empty(.seriesInstanceUID)])
    }

    @Test func whatTheListenerAlwaysAnsweredIsKept() {
        // A series' Modalities in Study reads the study's modality, a string,
        // as a set: the key is left out and the failure logged.
        let series = Record(values: ["study.modality": "CT"])
        #expect(SCPResponseIdentifier.entries(level: .series, keys: [.modalitiesInStudy], record: series)
                == [.omitted(.modalitiesInStudy, failure: "-[NSString allObjects]: the study's modality is a string, not a set")])
        // An image answers the study's comment as Image Comments.
        let image = Record(values: ["series.study.comment": "STUDY NOTE"])
        #expect(SCPResponseIdentifier.entries(level: .image, keys: [.studyComments, .imageComments], record: image)
                == [.put(.imageComments, .encoded("STUDY NOTE")), .put(.imageComments, .encoded("STUDY NOTE"))])
        // Number of Frames only for image storage.
        let document = Record(values: ["numberOfFrames": 1, "series.seriesSOPClassUID": "1.2.840.10008.5.1.4.1.1.104.1"])
        #expect(SCPResponseIdentifier.entries(level: .image, keys: [.numberOfFrames], record: document)
                == [.omitted(.numberOfFrames, failure: nil)])
        let ct = Record(values: ["numberOfFrames": NSNumber(value: 3), "series.seriesSOPClassUID": "1.2.840.10008.5.1.4.1.1.2"])
        #expect(SCPResponseIdentifier.entries(level: .image, keys: [.numberOfFrames], record: ct) == [.put(.numberOfFrames, .latin1("3"))])
    }

    @Test func modalitiesInStudyPutSecondaryCaptureAndReportsLast() {
        #expect(SCPResponseIdentifier.modalitiesInStudy(["SR", "SC", "CT", "MR", "CT"]) == "CT\\MR\\SC\\SR")
        #expect(SCPResponseIdentifier.modalitiesInStudy([]) == "")
        #expect(SCPResponseIdentifier.modalitiesInStudy(["CT", NSNull()]) == nil)
    }

    @Test func keysAreAnsweredOnceEach() {
        let keys = SCPResponseIdentifier.keys(of: [.patientName, .studyDate, .patientName, .studyInstanceUID])
        #expect(Set(keys) == [.patientName, .studyDate, .studyInstanceUID] && keys.count == 3)
    }

    @Test func theCharacterSetTurnsToUTF8OnceAndStays() {
        func encoding(_ name: String) -> UInt {
            name == "ISO_IR 192" ? String.Encoding.utf8.rawValue : String.Encoding.isoLatin1.rawValue
        }
        var set = SCPResponseCharacterSet(name: "ISO_IR 100", encoding: String.Encoding.isoLatin1.rawValue)
        var logged: [String] = []
        func encode(_ text: String?) -> [UInt8]? {
            set.encode(text, encodingFor: encoding, fileCharacterSets: { nil }, file: { "file.dcm" }, log: { logged.append($0) })
        }
        #expect(encode("Müller") == Array("Müller".data(using: .isoLatin1)!))
        #expect(set.name == "ISO_IR 100" && logged.isEmpty)
        #expect(encode("山田") == Array("山田".utf8))
        #expect(set.name == "ISO_IR 192" && logged == ["--- cannot encode 山田 -> switch to UTF-8 (ISO_IR 192) encoding"])
        #expect(encode("Müller") == Array("Müller".utf8))
        #expect(encode(nil) == nil)
    }
}
