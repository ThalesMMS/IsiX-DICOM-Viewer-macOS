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

/// The C-MOVE and C-GET the listener answers: the files of the matching
/// studies, series or images, each once, in path order, with the network log
/// entry of the retrieve.
extension SCPDatabaseSession {

    /// Why the log entry of a retrieve could not be written: one of its values is missing.
    private struct MissingLogValue: Error { let key: String }

    func startRetrieve(withSOPClass sopClass: String, identifier: IsiXDCMTKDataset,
                       moveDestination destination: Data?) -> IsiXDCMTKSCPRequestStart {
        let elements = Self.elements(of: identifier)
        if let refused = Self.start(SCPRequestCheck.check(service: .retrieve, sopClass: sopClass, elements: elements)) {
            return refused
        }
        moveDestination = destination.map { Array($0) } ?? []
        // An association can ask for several retrieves: nothing of the
        // previous one stays, even when this one matches nothing.
        retrievePaths = nil
        retrievePosition = 0
        guard let context else { return .noMatch }
        // Used on this thread only, inside the queue it waits for.
        nonisolated(unsafe) let request = identifier
        let _: Bool = context.performAndWait {
            prepareRetrieve(request, elements: elements, in: context)
            return true
        }
        return retrieveCount > 0 ? .matches : .noMatch
    }

    var retrieveCount: Int { retrievePaths?.count ?? 0 }

    func nextRetrievePath() -> String? {
        if Thread.current.isCancelled { return nil }
        guard let paths = retrievePaths, retrievePosition < paths.count else { return nil }
        let path = paths[retrievePosition]
        retrievePosition += 1
        if let log = retrieveLog {
            if retrievePosition >= paths.count { log["logMessage"] = "Complete" }
            log["logNumberReceived"] = NSNumber(value: Self.int(log["logNumberReceived"]) + 1)
            log["logEndTime"] = Date()
            (LogManager.currentLogManager() as? LogManager)?.addLogLine(log)
        }
        if retrievePosition >= paths.count { retrieveLog = nil }
        return path
    }

    func cancelRetrieve() {
        if let log = retrieveLog {
            log["logMessage"] = "Cancelled"
            log["logEndTime"] = Date()
            (LogManager.currentLogManager() as? LogManager)?.addLogLine(log)
        }
        retrievePaths = nil
        retrievePosition = 0
    }

    /// Reads the files of a retrieve, inside the context's queue.
    private func prepareRetrieve(_ identifier: IsiXDCMTKDataset, elements: [SCPIdentifierElement],
                                 in context: NSManagedObjectContext) {
        autoreleasepool {
            let level = identifier.rawValue(forTag: DICOMTag.queryRetrieveLevel.rawValue).map { String(decoding: $0, as: UTF8.self) }
            let predicates = fetchPredicates(identifier, elements: elements, level: level)
            let queryLevel = level.flatMap(SCPQueryLevel.init(rawValue:))
            let entity = queryLevel.flatMap { context.persistentStoreCoordinator?.managedObjectModel.entitiesByName[$0.entityName] }
            var failure: Error?
            do {
                try HorosObjCException.perform {
                    guard let entity else {
                        // A fetch without an entity raises, as it always did here.
                        NSException(name: .invalidArgumentException, reason: "no entity for the level \(level ?? "(null)")").raise()
                        return
                    }
                    var found = fetch(entity, predicates, in: context, failure: &failure, progressOfSeries: true)
                    if queryLevel == .image, let uids = predicates.compressedSOPInstance {
                        found = (found as NSArray).filtered(using: uids) as? [NSManagedObject] ?? []
                    }
                    guard failure == nil else { return }
                    do { try updateRetrieveLog(found) } catch {
                        NSException(name: .invalidArgumentException, reason: "*** setObjectForKey: object cannot be nil (key: \((error as? MissingLogValue)?.key ?? ""))").raise()
                    }
                    let files = NSMutableSet()
                    for object in found {
                        if let paths = object.value(forKey: "pathsForForkedProcess") as? NSSet { files.union(paths as! Set<AnyHashable>) }
                    }
                    retrievePaths = (files.allObjects as NSArray).sortedArray(using: #selector(NSString.compare(_:))) as? [String]
                }
            } catch {
                NSLog("prepareMoveForDataSet exception")
                NSLog("%@", Self.description(of: error))
                NSLog("%@", predicates.predicate?.description ?? "(null)")
            }
        }
    }

    /// The network log entry of a retrieve: who asked, for whom, what.
    private func updateRetrieveLog(_ objects: [NSManagedObject]) throws {
        guard Self.networkLogsActive, let object = objects.first else { return }
        retrieveLog?.removeAllObjects()
        let log = retrieveLog ?? NSMutableDictionary()
        retrieveLog = log
        func set(_ value: Any?, _ key: String) throws {
            guard let value else { throw MissingLogValue(key: key) }
            log[key] = value
        }
        try set(ListenerLogRules.retrieveParties(callingAETitle: callingAETitle, moveDestination: moveDestination), "logCallingAET")
        try set(Date(), "logStartTime")
        try set(Date(), "logEndTime")
        try set("In Progress", "logMessage")
        try set(NSNumber(value: 0), "logNumberReceived")
        try set("Move", "logType")
        try set("UTF-8", "logEncoding")
        let patient = log["logPatientName"].map { "\($0)" } ?? "(null)"
        try set("\(Int32(bitPattern: UInt32(truncatingIfNeeded: time(nil))))\(Int32(bitPattern: UInt32(truncatingIfNeeded: arc4random())))\(patient)", "logUID")
        switch object.value(forKey: "type") as? String {
        case "Series":
            try set(object.value(forKeyPath: "study.name"), "logPatientName")
            try set(object.value(forKeyPath: "study.studyName"), "logStudyDescription")
            try set(NSNumber(value: Self.int(object.value(forKey: "rawNoFiles"))), "logNumberTotal")
        case "Study":
            try set(object.value(forKeyPath: "name"), "logPatientName")
            try set(object.value(forKeyPath: "studyName"), "logStudyDescription")
            try set(NSNumber(value: Self.int(object.value(forKey: "rawNoFiles"))), "logNumberTotal")
        case "Image":
            try set(object.value(forKeyPath: "series.study.name"), "logPatientName")
            try set(object.value(forKeyPath: "series.study.studyName"), "logStudyDescription")
            try set(NSNumber(value: Int32(truncatingIfNeeded: objects.count)), "logNumberTotal")
        default:
            break
        }
        (LogManager.currentLogManager() as? LogManager)?.addLogLine(log)
    }
}
