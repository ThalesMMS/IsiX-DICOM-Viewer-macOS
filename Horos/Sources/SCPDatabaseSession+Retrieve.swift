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

/// The C-MOVE and C-GET the listener answers: the files of the matching
/// studies, series or images, read through `LocalMetadataQuerying`
/// (SCPLocalQuery), each once, in path order, with the network log entry of
/// the retrieve.
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
        autoreleasepool { prepareRetrieve(identifier, elements: elements) }
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

    /// Reads the files of a retrieve. Nothing when the request's level is
    /// none the database reads, the database cannot be read, or the log entry
    /// misses a value.
    private func prepareRetrieve(_ identifier: IsiXDCMTKDataset, elements: [SCPIdentifierElement]) {
        let level = Self.level(of: identifier)
        let predicates = fetchPredicates(identifier, elements: elements, level: level)
        // The condition is made of the values the peer asked for, a patient's
        // identifier among them: the log is told the level and the keys.
        let asked = elements.map { $0.name }.joined(separator: ", ")
        func failed(_ what: String) {
            NSLog("prepareMoveForDataSet exception")
            NSLog("%@", what)
            NSLog("%@ level, keys %@", level ?? "(null)", asked)
        }
        guard let queryLevel = level.flatMap(SCPQueryLevel.init(rawValue:)) else {
            failed("no entity for the level \(level ?? "(null)")")
            return
        }
        let logged = networkLogsActive
        let query = SCPLocalQuery.retrieve(level: queryLevel, predicates: predicates, logged: logged)
        let records: [LocalMetadataRecord]
        do {
            records = try localMetadata.records(matching: query) { read in
                if Thread.current.isCancelled { return false }
                if read.total != 0 { Thread.current.progress = CGFloat(Float(read.read) / Float(read.total)) }
                return true
            }.records
        } catch LocalMetadataQueryError.raised(let description) {
            // What the database raised quotes the condition.
            failed("the database raised " + LogText.shape(of: description))
            return
        } catch {
            // No database, or a read that failed: nothing to send.
            return
        }
        do {
            try updateRetrieveLog(records, level: queryLevel, logged: logged)
        } catch {
            failed("*** setObjectForKey: object cannot be nil (key: \((error as? MissingLogValue)?.key ?? ""))")
            return
        }
        retrievePaths = SCPLocalQuery.files(of: records)
    }

    /// The network log entry of a retrieve: who asked, for whom, what.
    private func updateRetrieveLog(_ records: [LocalMetadataRecord], level: SCPQueryLevel, logged: Bool) throws {
        guard logged, let record = records.first else { return }
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
        let names = SCPLocalQuery.logKeyPaths(level: level)
        try set(record.object(at: names.patientName), "logPatientName")
        try set(record.object(at: names.studyDescription), "logStudyDescription")
        // A study or series counts its files; images count themselves.
        let total = names.fileCount.map { Self.int(record.object(at: $0)) } ?? Int32(truncatingIfNeeded: records.count)
        try set(NSNumber(value: total), "logNumberTotal")
        (LogManager.currentLogManager() as? LogManager)?.addLogLine(log)
    }
}
