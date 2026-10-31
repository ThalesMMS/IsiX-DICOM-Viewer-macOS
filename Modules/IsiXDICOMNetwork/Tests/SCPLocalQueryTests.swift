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
import IsiXContracts
@testable import IsiXDICOMNetwork

/// A local database of a few records held in memory, read the way the port
/// reads: the conditions evaluated on each record, the series of an image
/// query first, then the filter, the order, the limit and the distinct files.
private struct MemoryMetadata: LocalMetadataQuerying {
    /// Each record's level and its attributes, by the database's key paths.
    let records: [(level: LocalMetadataLevel, attributes: [String: any Sendable])]

    /// The attribute at a dotted key path of nested attributes.
    static func lookup(_ attributes: [String: any Sendable], _ keyPath: String) -> Any? {
        var current: Any? = attributes
        for key in keyPath.split(separator: ".") { current = (current as? [String: Any])?[String(key)] }
        return current
    }

    func records(matching query: LocalMetadataQuery,
                 progress: @Sendable (LocalMetadataProgress) -> Bool) throws -> LocalMetadataResult {
        func matches(_ condition: NSPredicate?, _ attributes: [String: any Sendable]) -> Bool {
            condition?.evaluate(with: attributes) ?? true
        }
        var found = records.enumerated().filter { $0.element.level == query.level }
        if let series = query.seriesPredicate {
            found = found.filter { matches(series, ($0.element.attributes["series"] as? [String: any Sendable]) ?? [:]) }
        }
        found = found.filter { matches(query.predicate, $0.element.attributes) && matches(query.filter, $0.element.attributes) }
        _ = progress(LocalMetadataProgress(stage: .records, read: found.count, total: found.count))
        if let key = query.sortKeyPath {
            found = found.sorted { a, b in
                let x = Self.lookup(a.element.attributes, key) as? NSNumber
                let y = Self.lookup(b.element.attributes, key) as? NSNumber
                return (x?.intValue ?? .min, a.offset) < (y?.intValue ?? .min, b.offset)
            }
        }
        let count = found.count
        if let limit = query.limit { found = Array(found.prefix(limit)) }
        if let key = query.distinctKeyPath {
            var seen = Set<String>()
            found = found.filter { ($0.element.attributes[key] as? String).map { seen.insert($0).inserted } ?? true }
        }
        let read = found.map { offset, record -> LocalMetadataRecord in
            var values: [String: LocalMetadataValue] = [:]
            for path in query.keyPaths {
                switch Self.lookup(record.attributes, path) {
                case let text as String: values[path] = .text(text)
                case let number as NSNumber: values[path] = .number(number)
                case let list as [String]: values[path] = .collection(list.map { .text($0) })
                default: break
                }
            }
            return LocalMetadataRecord(identifier: LocalRecordIdentifier(uri: URL(string: "x-coredata://STORE/R/p\(offset)")!),
                                       level: record.level, values: values,
                                       files: query.includesFiles ? (record.attributes["files"] as? [String] ?? []) : [])
        }
        return LocalMetadataResult(records: read, matchCount: count)
    }

    func representativeFile(of record: LocalRecordIdentifier) throws -> String? { nil }
}

/// What the listener asks the local database for a C-FIND, a C-MOVE and a
/// C-GET, and what it keeps of the answer, checked without a database.
struct SCPLocalQueryTests {

    typealias Environment = SCPQueryMatchingTests.Environment

    static func element(_ tag: DICOMTag, _ value: String?) -> SCPIdentifierElement {
        SCPQueryMatchingTests.element(tag, value)
    }

    static func predicates(_ level: String, _ elements: [SCPIdentifierElement], characterSet: String? = "ISO_IR 100")
        -> SCPFetchPredicates {
        SCPQueryMatching.predicates(level: level, elements: elements, characterSet: characterSet, environment: Environment())
    }

    @Test func aFindReadsWhatItsResponsesAnswerAndTheLevelsOrder() {
        let keys: [DICOMTag] = [.patientName, .studyDate, .modalitiesInStudy, .numberOfStudyRelatedSeries]
        let study = SCPLocalQuery.find(level: .study, predicates: Self.predicates("STUDY", []), keys: keys, maximumCount: 50)
        #expect(study.level == .study && study.sortKeyPath == nil && study.distinctKeyPath == nil && study.limit == 50)
        #expect(study.keyPaths == ["name", "date", "modality", "series.modality", "series"])
        #expect(study.primitiveKeys == ["name"])
        #expect(!study.includesFiles && study.filter == nil && study.seriesPredicate == nil)

        let series = SCPLocalQuery.find(level: .series, predicates: Self.predicates("SERIES", []), keys: [.seriesNumber],
                                        maximumCount: 0)
        #expect(series.sortKeyPath == "date" && series.limit == nil && series.keyPaths == ["id"])

        let elements = [Self.element(.seriesInstanceUID, "1.2.3"), Self.element(.sopInstanceUID, "1.2.3.4")]
        let image = SCPLocalQuery.find(level: .image, predicates: Self.predicates("IMAGE", elements),
                                       keys: [.numberOfFrames, .imageComments], maximumCount: 50)
        // Images are never limited; one answers per file, in Instance Number order.
        #expect(image.limit == nil && image.sortKeyPath == "instanceNumber" && image.distinctKeyPath == "completePath")
        #expect(image.keyPaths == ["numberOfFrames", "series.seriesSOPClassUID", "series.comment", "series.study.comment"])
        #expect(image.seriesPredicate?.predicateFormat == #"seriesDICOMUID == "1.2.3""#)
        #expect(image.filter?.predicateFormat == #"uid == "1.2.3.4""#)
    }

    @Test func aRetrieveReadsFilesAndTheLogNamesOnlyWhenLogged() {
        let quiet = SCPLocalQuery.retrieve(level: .series, predicates: Self.predicates("SERIES", []), logged: false)
        #expect(quiet.includesFiles && quiet.keyPaths.isEmpty && quiet.sortKeyPath == nil && quiet.limit == nil)
        let logged = SCPLocalQuery.retrieve(level: .series, predicates: Self.predicates("SERIES", []), logged: true)
        #expect(logged.keyPaths == ["study.name", "study.studyName", "rawNoFiles"])
        let images = SCPLocalQuery.retrieve(level: .image, predicates: Self.predicates("IMAGE", []), logged: true)
        #expect(images.keyPaths == ["series.study.name", "series.study.studyName"])
        #expect(SCPLocalQuery.logKeyPaths(level: .image).fileCount == nil)
    }

    @Test func aRetrieveSendsEachFileOnceInPathOrder() {
        func record(_ files: [String]) -> LocalMetadataRecord {
            LocalMetadataRecord(identifier: LocalRecordIdentifier(uri: URL(string: "x-coredata://S/Image/p1")!), level: .image,
                                values: [:], files: files)
        }
        let composed = "/d/\u{E9}.dcm", decomposed = "/d/e\u{301}.dcm"
        let files = SCPLocalQuery.files(of: [record(["/d/b.dcm", "/d/a.dcm"]), record(["/d/a.dcm", "/d/c.dcm"]),
                                             record([composed, decomposed])])
        #expect(Array(files.prefix(3)) == ["/d/a.dcm", "/d/b.dcm", "/d/c.dcm"])
        // Two spellings of one name are two paths, as NSString keeps them.
        #expect(files.count == 5 && files.contains(composed) && files.contains(decomposed))
        #expect(SCPLocalQuery.files(of: []).isEmpty)
    }

    @Test func valuesReadBackAsTheDatabaseGaveThem() {
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let record = LocalMetadataRecord(
            identifier: LocalRecordIdentifier(uri: URL(string: "x-coredata://S/Study/p1")!), level: .study,
            values: ["name": .text("DOE^JANE"), "rawNoFiles": .number(4), "date": .date(date),
                     "series": .collection([.record, .record]), "series.modality": .collection([.text("CT"), .null])],
            primitiveValues: ["name": .text("DOE^JANE")])
        #expect(record.object(at: "name") as? String == "DOE^JANE")
        #expect((record.object(at: "rawNoFiles") as? NSNumber)?.int32Value == 4)
        #expect(record.object(at: "date") as? Date == date)
        #expect(record.object(at: "missing") == nil)
        #expect(record.primitiveObject(of: "name") as? String == "DOE^JANE")
        // A to-many key path is an array: its count, and NSNull for a member without a value.
        #expect((record.object(at: "series") as? [Any])?.count == 2)
        #expect(SCPResponseIdentifier.modalitiesInStudy(record.object(at: "series.modality") as? [Any] ?? []) == nil)
    }

    @Test func aFindMatchesWildcardsUIDListsAndDatesWithoutADatabase() throws {
        let day = { (offset: Double) in Date(timeIntervalSinceReferenceDate: offset) }
        let port = MemoryMetadata(records: [
            (.study, ["patientID": "P100", "studyInstanceUID": "1.1", "hasDICOM": true, "date": day(150), "studyName": "CT HEAD"]),
            (.study, ["patientID": "P200", "studyInstanceUID": "1.2", "hasDICOM": true, "date": day(300), "studyName": "MR KNEE"]),
            (.study, ["patientID": "Q100", "studyInstanceUID": "1.3", "hasDICOM": true, "date": day(160), "studyName": "CT CHEST"]),
            (.study, ["patientID": "P300", "studyInstanceUID": "1.4", "hasDICOM": false, "date": day(150), "studyName": "CT"]),
            (.series, ["seriesDICOMUID": "1.1.1", "study": ["hasDICOM": true], "id": NSNumber(value: 2)]),
            (.series, ["seriesDICOMUID": "1.1.2", "study": ["hasDICOM": true], "id": NSNumber(value: 1)]),
            (.series, ["seriesDICOMUID": "1.1.3", "study": ["hasDICOM": true], "id": NSNumber(value: 3)]),
        ])
        func uids(_ level: SCPQueryLevel, _ elements: [SCPIdentifierElement], keys: [DICOMTag], maximum: Int = 0) throws -> [String] {
            let query = SCPLocalQuery.find(level: level, predicates: Self.predicates(level.rawValue, elements), keys: keys,
                                           maximumCount: maximum)
            return try port.records(matching: query) { _ in true }.records.compactMap {
                ($0.object(at: "studyInstanceUID") ?? $0.object(at: "seriesDICOMUID")) as? String
            }
        }
        // A leading wildcard, a trailing one, and only studies with DICOM files.
        #expect(try uids(.study, [Self.element(.patientID, "P*")], keys: [.studyInstanceUID]) == ["1.1", "1.2"])
        #expect(try uids(.study, [Self.element(.patientID, "*100")], keys: [.studyInstanceUID]) == ["1.1", "1.3"])
        #expect(try uids(.study, [Self.element(.studyDescription, "ct*")], keys: [.studyInstanceUID]) == ["1.1", "1.3"])
        // A date range: from day 140 up to the end of day 200.
        #expect(try uids(.study, [Self.element(.studyDate, "140-200")], keys: [.studyInstanceUID]) == ["1.1", "1.3"])
        #expect(try uids(.study, [Self.element(.studyDate, "-155")], keys: [.studyInstanceUID]) == ["1.1"])
        // A list of Series Instance UIDs matches each of them.
        #expect(try uids(.series, [Self.element(.seriesInstanceUID, "1.1.1\\1.1.3")], keys: [.seriesInstanceUID]) == ["1.1.1", "1.1.3"])
        // The maximum count stops the studies.
        #expect(try uids(.study, [], keys: [.studyInstanceUID], maximum: 2) == ["1.1", "1.2"])
    }

    @Test func aRequestValueIsReadInItsCharacterSet() {
        // The values of the keys a person types are read in the request's
        // character set; UIDs and codes never are.
        final class Latin: SCPMatchingEnvironment {
            func string(_ bytes: [UInt8], characterSet: String?) -> String? {
                characterSet == nil ? String(decoding: bytes, as: UTF8.self) : String(bytes: bytes, encoding: .isoLatin1)
            }
            func patientNamePredicate(_ name: String?) -> NSPredicate? { NSPredicate(format: "name == %@", name ?? "") }
            func sopInstanceUIDPredicate(_ uid: String) -> NSPredicate { NSPredicate(value: true) }
            func date(_ string: String?) -> String? { nil }
            func time(_ string: String?) -> String? { nil }
            func isQuery(_ value: String) -> Bool { false }
            func queryString(_ value: String) -> String? { nil }
            func startOfDay(_ value: String?) -> TimeInterval { 0 }
            func endOfDay(_ value: String?) -> TimeInterval { 0 }
            func timeNumber(_ value: String) -> NSNumber? { nil }
            func instant(date: String, time: String) -> TimeInterval { 0 }
            func log(_ message: String) {}
        }
        let name = SCPIdentifierElement(tag: .patientName, value: [0x4D, 0xDC, 0x4C, 0x4C, 0x45, 0x52], length: 6, name: "PatientName")
        let predicates = SCPQueryMatching.predicates(level: "STUDY", elements: [name], characterSet: "ISO_IR 100", environment: Latin())
        #expect(predicates.predicate?.evaluate(with: ["name": "M\u{DC}LLER", "hasDICOM": true]) == true)
        let uid = SCPIdentifierElement(tag: .studyInstanceUID, value: Array("1.2".utf8), length: 3, name: "StudyInstanceUID")
        let byUID = SCPQueryMatching.predicates(level: "STUDY", elements: [uid], characterSet: "ISO_IR 100", environment: Latin())
        #expect(byUID.predicate?.evaluate(with: ["studyInstanceUID": "1.2", "hasDICOM": true]) == true)
    }
}
