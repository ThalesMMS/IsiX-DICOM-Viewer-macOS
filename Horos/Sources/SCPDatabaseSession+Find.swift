/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import IsiXContracts
import IsiXDICOMNetwork
import IsiXDICOMFile
import IsiXPreferences

/// The C-FIND the listener answers: the request's keys become conditions on
/// the index (IsiXDICOMNetwork's SCPQueryMatching), the matches are read once
/// through `LocalMetadataQuerying` (SCPLocalQuery), and each response is built
/// from the values of one match (SCPResponseIdentifier) in the response
/// character set.
extension SCPDatabaseSession {

    func startFind(withSOPClass sopClass: String, identifier: IsiXDCMTKDataset) -> IsiXDCMTKSCPRequestStart {
        let elements = Self.elements(of: identifier)
        if let refused = Self.start(SCPRequestCheck.check(service: .find, sopClass: sopClass, elements: elements)) {
            return refused
        }
        let level = Self.level(of: identifier)
        let predicates = fetchPredicates(identifier, elements: elements, level: level)
        findKeys = SCPResponseIdentifier.keys(of: elements.map(\.tag))
        findRecords = nil
        findPosition = 0
        // Only STUDY, SERIES and IMAGE are read.
        guard let queryLevel = level.flatMap(SCPQueryLevel.init(rawValue:)) else { return .failed }
        let maximum = processGraph.preferences[NetworkPreferences.maximumNumberOfCFindObjects]
        let query = SCPLocalQuery.find(level: queryLevel, predicates: predicates, keys: findKeys, maximumCount: maximum)
        do {
            let result = try localMetadata.records(matching: query) { read in
                if Thread.current.isCancelled { return false }
                // The images of the matching series count once they are read.
                if read.total != 0 { Thread.current.progress = CGFloat(Float(read.stage == .series ? 0 : read.read) / Float(read.total)) }
                return true
            }
            if query.limit != nil, result.matchCount > maximum {
                NSLog("----- C-Find maximumNumberOfCFindObjects reached: %d, %d", Int32(result.matchCount), Int32(maximum))
            }
            findRecords = result.records
        } catch LocalMetadataQueryError.raised(let description) {
            // A condition the database could not evaluate: no match.
            NSLog("prepareFindForDataSet exception")
            NSLog("%@", description)
        } catch {
            return .failed
        }
        return findRecords != nil ? .matches : .noMatch
    }

    func nextFindResponse(_ response: IsiXDCMTKDataset) -> Bool {
        var answered = false
        let records = findRecords ?? []
        if findPosition < records.count {
            let record = records[findPosition]
            fill(response, level: SCPQueryLevel(record.level), record: record)
            answered = true
        }
        if !records.isEmpty { Thread.current.progress = CGFloat(Float(findPosition) / Float(records.count)) }
        findPosition += 1
        if Thread.current.isCancelled { answered = false }
        return answered
    }

    /// The conditions of a request; sets the response character set to the request's.
    func fetchPredicates(_ identifier: IsiXDCMTKDataset, elements: [SCPIdentifierElement], level: String?) -> SCPFetchPredicates {
        let declared = identifier.rawValue(forTag: DICOMTag.specificCharacterSet.rawValue).map { Array($0) }
        let characterSet = SCPQueryMatching.characterSet(ofSpecificCharacterSet: declared)
        let encoding = declared == nil ? String.Encoding.isoLatin1.rawValue : NSString.encoding(forDICOMCharacterSet: characterSet)
        responseCharacterSet = SCPResponseCharacterSet(name: characterSet, encoding: encoding)
        return SCPQueryMatching.predicates(level: level, elements: elements, characterSet: characterSet,
                                           environment: ListenerMatchingEnvironment())
    }

    /// One response: each key asked for, then the level and the character set.
    private func fill(_ response: IsiXDCMTKDataset, level: SCPQueryLevel, record: LocalMetadataRecord) {
        let listened = ListenerRecord(record: record)
        // The file whose character sets a value may need, looked up once, when one does.
        var file: String??
        let representative = { () -> String? in
            if file == nil { file = .some((try? self.localMetadata.representativeFile(of: record.identifier)) ?? nil) }
            return file ?? nil
        }
        for key in findKeys {
            for entry in SCPResponseIdentifier.entries(level: level, keys: [key], record: listened) {
                apply(entry, to: response, file: representative)
            }
        }
        try? response.putValue(Data(level.rawValue.utf8), forTag: DICOMTag.queryRetrieveLevel.rawValue)
        if let name = responseCharacterSet.name {
            try? response.putValue(Data(name.utf8), forTag: DICOMTag.specificCharacterSet.rawValue)
        }
    }

    private func apply(_ entry: SCPResponseEntry, to response: IsiXDCMTKDataset, file: () -> String?) {
        switch entry {
        case .empty(let tag):
            try? response.insertEmptyElement(withTag: tag.rawValue)
        case .omitted(_, let failure):
            if let failure {
                NSLog("%@", failure)
                response.printToStandardOutput()
            }
        case .put(let tag, let text):
            let bytes: [UInt8]?
            switch text {
            case .ascii(let value): bytes = Array(value.utf8)
            case .latin1(let value): bytes = value.flatMap { SCPResponseCharacterSet.bytes($0, String.Encoding.isoLatin1.rawValue) }
            case .encoded(let value):
                bytes = responseCharacterSet.encode(value, encodingFor: { NSString.encoding(forDICOMCharacterSet: $0) },
                    fileCharacterSets: { DicomFile.getEncodingArray(forFile: file()) as? [String] },
                    file: file, log: { NSLog("%@", $0) })
            }
            try? response.putValue(bytes.map { Data($0) }, forTag: tag.rawValue)
        }
    }
}

private extension SCPQueryLevel {
    init(_ level: LocalMetadataLevel) {
        switch level {
        case .study: self = .study
        case .series: self = .series
        case .image: self = .image
        }
    }
}

/// What the listener's matching reads through the application: DICOM character
/// sets and dates (DCM.framework), the database's patient name search, and an
/// image's compressed SOP Instance UID.
struct ListenerMatchingEnvironment: SCPMatchingEnvironment {
    typealias CalendarValue = DICOMCalendarDate

    func string(_ bytes: [UInt8], characterSet: String?) -> String? {
        let characters = bytes.map { CChar(bitPattern: $0) } + [0]
        return characters.withUnsafeBufferPointer { NSString.string(withUTF8String: $0.baseAddress, dicomEncoding: characterSet) as String? }
    }

    func patientNamePredicate(_ name: String?) -> NSPredicate? {
        PatientNameMatching.namePredicate(name, soundex: nil)
    }

    func sopInstanceUIDPredicate(_ uid: String) -> NSPredicate {
        NSComparisonPredicate(leftExpression: NSExpression(forKeyPath: "compressedSopInstanceUID"),
                              rightExpression: NSExpression(forConstantValue: DicomImage.sopInstanceUIDEncode(uid)),
                              customSelector: NSSelectorFromString("isEqualToSopInstanceUID:"))
    }

    func date(_ string: String?) -> DICOMCalendarDate? { DICOMCalendarDate.dicomDate(string) }
    func time(_ string: String?) -> DICOMCalendarDate? { DICOMCalendarDate.dicomTime(string) }
    func isQuery(_ value: DICOMCalendarDate) -> Bool { value.isQuery() }
    func queryString(_ value: DICOMCalendarDate) -> String? { value.queryString() }

    func startOfDay(_ value: DICOMCalendarDate?) -> TimeInterval {
        Self.midnight(value)?.timeIntervalSinceReferenceDate ?? 0
    }

    func endOfDay(_ value: DICOMCalendarDate?) -> TimeInterval {
        let next = Self.midnight(value)?.date(byAddingYears: 0, months: 0, days: 1, hours: 0, minutes: 0, seconds: 0) as? NSDate
        return next?.timeIntervalSinceReferenceDate ?? 0
    }

    func timeNumber(_ value: DICOMCalendarDate) -> NSNumber? { value.dateAsNumber() }

    func instant(date: String, time: String) -> TimeInterval {
        let day = DICOMCalendarDate.dicomDate(date)
        let clock = DICOMCalendarDate.dicomTime(time)
        let moment = day?.date(byAddingYears: 0, months: 0, days: 0, hours: clock?.hourOfDay() ?? 0,
                                      minutes: clock?.minuteOfHour() ?? 0, seconds: clock?.secondOfMinute() ?? 0) as? NSDate
        return moment?.timeIntervalSinceReferenceDate ?? 0
    }

    func log(_ message: String) {
        print(message, terminator: "")
    }

    /// The start of the day `value` falls on, in the default time zone.
    private static func midnight(_ value: DICOMCalendarDate?) -> DICOMCalendarDate? {
        DICOMCalendarDate.date(withYear: value?.yearOfCommonEra() ?? 0, month: UInt(value?.monthOfYear() ?? 0),
                             day: UInt(value?.dayOfMonth() ?? 0), hour: 0, minute: 0, second: 0, timeZone: nil)
    }
}

/// A study, series or image of the index as a C-FIND response reads it: the
/// values the find read of it.
struct ListenerRecord: SCPResponseRecord {
    let record: LocalMetadataRecord

    func value(at keyPath: String) -> Any? { record.object(at: keyPath) }
    func primitiveValue(of key: String) -> Any? { record.primitiveObject(of: key) }
    func dicomDate(_ date: Any) -> String? { (DICOMCalendarDate.dicomDate(with: date as? Date))?.dateString() }
    func dicomTime(_ date: Any) -> String? { (DICOMCalendarDate.dicomTime(with: date as? Date))?.timeString() }
    func isImageStorage(_ uid: Any?) -> Bool { DICOMSOPClass.isImageStorage(uid as? String) }
}
