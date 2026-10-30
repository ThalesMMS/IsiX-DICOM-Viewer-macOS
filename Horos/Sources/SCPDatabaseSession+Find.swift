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

import CoreData
import Foundation
import IsiXDICOMNetwork
import IsiXDICOMFile

/// The C-FIND the listener answers: the request's keys become conditions on
/// the index (IsiXDICOMNetwork's SCPQueryMatching), the matches are fetched in
/// batches, and each response is built from one match (SCPResponseIdentifier)
/// in the response character set.
extension SCPDatabaseSession {

    /// How many objects a fetch reads at a time.
    static let fetchBatch = 100

    func startFind(withSOPClass sopClass: String, identifier: IsiXDCMTKDataset) -> IsiXDCMTKSCPRequestStart {
        let elements = Self.elements(of: identifier)
        if let refused = Self.start(SCPRequestCheck.check(service: .find, sopClass: sopClass, elements: elements)) {
            return refused
        }
        guard let context else { return .failed }
        // Used on this thread only, inside the queue it waits for.
        nonisolated(unsafe) let request = identifier
        let prepared: Bool = context.performAndWait { prepareFind(request, elements: elements, in: context) }
        guard prepared else { return .failed }
        return findObjects != nil ? .matches : .noMatch
    }

    func nextFindResponse(_ response: IsiXDCMTKDataset) -> Bool {
        guard let context else { return false }
        nonisolated(unsafe) let dataset = response
        return context.performAndWait { () -> Bool in
            var answered = false
            do {
                try HorosObjCException.perform {
                    let objects = findObjects ?? []
                    if findPosition < objects.count {
                        let object = objects[findPosition]
                        if let level = SCPQueryLevel(entityType: object.value(forKey: "type") as? String) {
                            fill(dataset, level: level, object: object)
                        }
                        answered = true
                    }
                    if !objects.isEmpty { Thread.current.progress = CGFloat(Float(findPosition) / Float(objects.count)) }
                    findPosition += 1
                    if Thread.current.isCancelled { answered = false }
                }
            } catch {
                NSLog("******* nextFindObject exception : %@", Self.caught(error))
            }
            return answered
        }
    }

    /// Reads the matches of a C-FIND, inside the context's queue. NO when the
    /// level is unknown or the index could not be read.
    private func prepareFind(_ identifier: IsiXDCMTKDataset, elements: [SCPIdentifierElement],
                             in context: NSManagedObjectContext) -> Bool {
        let level = identifier.rawValue(forTag: DICOMTag.queryRetrieveLevel.rawValue).map { String(decoding: $0, as: UTF8.self) }
        let predicates = fetchPredicates(identifier, elements: elements, level: level)
        findKeys = SCPResponseIdentifier.keys(of: elements.map(\.tag))
        findObjects = nil
        findPosition = 0
        guard let queryLevel = level.flatMap(SCPQueryLevel.init(rawValue:)),
              let entity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName[queryLevel.entityName] else {
            return false
        }
        var failure: Error?
        do {
            try HorosObjCException.perform {
                var found = fetch(entity, predicates, in: context, failure: &failure, progressOfSeries: false)
                if queryLevel == .image, let uids = predicates.compressedSOPInstance { found = (found as NSArray).filtered(using: uids) as? [NSManagedObject] ?? [] }
                if queryLevel == .image {
                    found = (found as NSArray).sortedArray(using: [NSSortDescriptor(key: "instanceNumber", ascending: true)]) as? [NSManagedObject] ?? []
                }
                if queryLevel == .series {
                    found = (found as NSArray).sortedArray(using: [NSSortDescriptor(key: "date", ascending: true)]) as? [NSManagedObject] ?? []
                }
                let maximum = UserDefaults.standard.integer(forKey: "maximumNumberOfCFindObjects")
                if queryLevel != .image, maximum > 0, found.count > maximum {
                    NSLog("----- C-Find maximumNumberOfCFindObjects reached: %d, %d", Int32(found.count), Int32(maximum))
                    found = Array(found.prefix(maximum))
                }
                if queryLevel == .image {
                    // One DICOM instance per file: a multi-frame file is several objects of the index.
                    let objects = NSMutableArray(array: found)
                    let paths = NSMutableArray(array: (found as NSArray).value(forKey: "completePath") as? [Any] ?? [])
                    paths.removeDuplicatedStrings(inSyncWithThisArray: objects)
                    found = objects as? [NSManagedObject] ?? []
                }
                findObjects = found
            }
        } catch {
            NSLog("prepareFindForDataSet exception")
            NSLog("%@", Self.description(of: error))
        }
        if failure != nil {
            findObjects = nil
            return false
        }
        return true
    }

    /// The objects of `entity` that `predicates` match, read in batches; the
    /// images of the matching series when the request names its series.
    /// `failure` keeps the last error of a read, which ends that loop.
    func fetch(_ entity: NSEntityDescription, _ predicates: SCPFetchPredicates, in context: NSManagedObjectContext,
               failure: inout Error?, progressOfSeries: Bool) -> [NSManagedObject] {
        func batches(_ request: NSFetchRequest<NSManagedObject>, progress: ([NSManagedObject]) -> Int) -> [NSManagedObject] {
            var total = 0
            do { total = try context.count(for: request) } catch { failure = error }
            var found: [NSManagedObject] = []
            request.fetchLimit = Self.fetchBatch
            var batch: [NSManagedObject]
            repeat {
                do { batch = try context.fetch(request) } catch { failure = error; batch = [] }
                found += batch
                request.fetchOffset += Self.fetchBatch
                if Thread.current.isCancelled { break }
                if total != 0 { Thread.current.progress = CGFloat(Float(progress(found)) / Float(total)) }
            } while !batch.isEmpty
            return found
        }
        if let seriesLevel = predicates.seriesLevel, let seriesEntity = context.persistentStoreCoordinator?.managedObjectModel.entitiesByName["Series"] {
            // The series first, then their images.
            let request = NSFetchRequest<NSManagedObject>()
            request.entity = seriesEntity
            request.predicate = seriesLevel
            var images: [Any] = []
            let series = batches(request) { progressOfSeries ? $0.count : images.count }
            for one in series { images += ((one.value(forKey: "images") as? NSSet)?.allObjects ?? []) }
            return (images as NSArray).filtered(using: predicates.predicate ?? NSPredicate(value: true)) as? [NSManagedObject] ?? []
        }
        let request = NSFetchRequest<NSManagedObject>()
        request.entity = entity
        request.predicate = predicates.predicate
        return batches(request) { $0.count }
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
    private func fill(_ response: IsiXDCMTKDataset, level: SCPQueryLevel, object: NSManagedObject) {
        let record = ListenerRecord(object: object)
        for key in findKeys {
            do {
                try HorosObjCException.perform {
                    for entry in SCPResponseIdentifier.entries(level: level, keys: [key], record: record) {
                        apply(entry, to: response, object: object)
                    }
                }
            } catch {
                NSLog("%@", Self.description(of: error))
                response.printToStandardOutput()
            }
        }
        try? response.putValue(Data(level.rawValue.utf8), forTag: DICOMTag.queryRetrieveLevel.rawValue)
        if let name = responseCharacterSet.name {
            try? response.putValue(Data(name.utf8), forTag: DICOMTag.specificCharacterSet.rawValue)
        }
    }

    private func apply(_ entry: SCPResponseEntry, to response: IsiXDCMTKDataset, object: NSManagedObject) {
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
                    fileCharacterSets: { DicomFile.getEncodingArray(forFile: Self.file(of: object)) as? [String] },
                    file: { Self.file(of: object) }, log: { NSLog("%@", $0) })
            }
            try? response.putValue(bytes.map { Data($0) }, forTag: tag.rawValue)
        }
    }

    /// The file of the record a response reads its character set from: the
    /// image itself, one of a series, or one of a study's series.
    private static func file(of object: NSManagedObject) -> String? {
        var image: AnyObject? = object
        switch object.value(forKey: "type") as? String {
        case "Study": image = ((object.value(forKey: "series") as? NSSet)?.anyObject() as AnyObject?)?.value(forKey: "images").flatMap { ($0 as? NSSet)?.anyObject() as AnyObject? }
        case "Series": image = (object.value(forKey: "images") as? NSSet)?.anyObject() as AnyObject?
        default: break
        }
        return image?.value(forKey: "completePathResolved") as? String
    }
}

/// What the listener's matching reads through the application: DICOM character
/// sets and dates (DCM.framework), the browser's patient name search, and an
/// image's compressed SOP Instance UID.
struct ListenerMatchingEnvironment: SCPMatchingEnvironment {
    typealias CalendarValue = DICOMCalendarDate

    func string(_ bytes: [UInt8], characterSet: String?) -> String? {
        let characters = bytes.map { CChar(bitPattern: $0) } + [0]
        return characters.withUnsafeBufferPointer { NSString.string(withUTF8String: $0.baseAddress, dicomEncoding: characterSet) as String? }
    }

    func patientNamePredicate(_ name: String?) -> NSPredicate? {
        BrowserController.currentBrowser()?.patientsnamePredicate(name, soundex: false)
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

/// A study, series or image of the index as a C-FIND response reads it, on
/// the queue of its context.
struct ListenerRecord: SCPResponseRecord {
    let object: NSManagedObject

    func value(forKeyPath keyPath: String) -> Any? { object.value(forKeyPath: keyPath) }
    func primitiveValue(forKey key: String) -> Any? { object.primitiveValue(forKey: key) }
    func dicomDate(_ date: Any) -> String? { (DICOMCalendarDate.dicomDate(with: date as? Date))?.dateString() }
    func dicomTime(_ date: Any) -> String? { (DICOMCalendarDate.dicomTime(with: date as? Date))?.timeString() }
    func isImageStorage(_ uid: Any?) -> Bool { DICOMSOPClass.isImageStorage(uid as? String) }
}
