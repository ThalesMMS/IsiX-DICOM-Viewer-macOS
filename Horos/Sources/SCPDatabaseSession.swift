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

import Darwin
import Foundation
import IsiXContracts
import IsiXDICOMNetwork
import IsiXPreferences

/// The listener's database for one association: the C-FIND, C-MOVE and C-GET
/// requests it answers from the index (SCPDatabaseSession+Find.swift and
/// +Retrieve.swift), and the C-STOREs it receives, which it hands to the
/// active database's incoming folder. The C-STORE sub-operations a C-GET of
/// the query nodes receives use one too. The DCMTK adapter calls it on its
/// association's thread only. The index is read through `LocalMetadataQuerying`,
/// on a private-queue context of the default database made for each read,
/// never in the UI's context; only values come back.
final class SCPDatabaseSession: NSObject, IsiXDCMTKSCPDatabase, @unchecked Sendable {

    /// The peer's AE title; for a C-GET's own sub-operations, the title it called.
    let callingAETitle: String

    /// What the process shares: the default database, the preferences and the
    /// browser's network-log switch.
    let processGraph: ProcessGraph

    /// The records the finds and retrieves read, from the default database.
    let localMetadata: any LocalMetadataQuerying

    // The current find: its matches, the next one to answer, the keys asked
    // for, and the character set of its responses.
    var findRecords: [LocalMetadataRecord]?
    var findPosition = 0
    var findKeys: [DICOMTag] = []
    var responseCharacterSet = SCPResponseCharacterSet(name: nil, encoding: 0)

    // The current retrieve: the files to send, the next one, its log entry and
    // the AE title of its move destination.
    var retrievePaths: [String]?
    var retrievePosition = 0
    var retrieveLog: NSMutableDictionary?
    var moveDestination: [UInt8] = []

    // The log entry of what this association received.
    private var receiveLog: NSMutableDictionary?
    private var receivedCount: Int32 = 0
    private var incomplete = false

    /// The session of an association: the listener's, and a C-GET's for its
    /// own sub-operations.
    convenience init(callingAETitle: String) {
        self.init(callingAETitle: callingAETitle, processGraph: ProcessGraph.process)
    }

    init(callingAETitle: String, processGraph: ProcessGraph) {
        self.callingAETitle = callingAETitle
        self.processGraph = processGraph
        localMetadata = processGraph.localStudyReader(reading: .defaultDatabase)
        super.init()
    }

    /// Whether the network log records anything.
    var networkLogsActive: Bool {
        processGraph.networkLogsActive
    }

    // MARK: - Received instances

    var receivingDirectory: String {
        processGraph.databaseIngest.receivingFolder
    }

    /// Moves a complete received file into the incoming folder, where the
    /// database imports it, before the C-STORE response promises Success.
    func publishReceivedFile(atPath path: String) -> String? {
        let ingest = processGraph.databaseIngest
        let name = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
        let publication = ingest.publish(fileAt: path, named: name, into: ingest.listenerFolder(), preset: .listener)
        guard !publication.succeeded else { return nil }
        let failure = publication.errorNumber
        let folder = String(decoding: publication.folder.path.utf8.prefix(2048), as: UTF8.self)
        return "Cannot publish received DICOM to import directory \(folder): \(String(cString: strerror(failure))) (errno \(failure))"
    }

    var namesSenderInReceivedFiles: Bool {
        processGraph.preferences[NetworkPreferences.putsSourceAETitleInSourceApplicationEntityTitle]
    }

    var namesCalledTitleInReceivedFiles: Bool {
        processGraph.preferences[NetworkPreferences.putsDestinationAETitleInPrivateInformationCreatorUID]
    }

    func didStoreInstance(attributes: [NSNumber: Data]?) {
        // The sender does not say how many it will send: the count alone.
        ActivityProgressCount.countOne(on: Thread.current)
        if let attributes { updateReceiveLog(attributes) }
    }

    func didEndStore(ofInstance sopInstanceUID: String, study studyInstanceUID: String, series seriesInstanceUID: String,
                     status: UInt16) {
        NotificationCenter.default.post(name: Notification.Name("HorosDICOMStoreCompleted"), object: nil, userInfo: [
            "uid": sopInstanceUID, "study": studyInstanceUID, "series": seriesInstanceUID, "status": NSNumber(value: status)])
    }

    /// One network log entry per association: what it received, and from whom.
    private func updateReceiveLog(_ attributes: [NSNumber: Data]) {
        guard networkLogsActive else { return }
        func value(_ tag: DICOMTag) -> [UInt8]? { attributes[NSNumber(value: tag.rawValue)].map { Array($0) } }
        // The values come from the sender: each is bounded, as the log's buffers were.
        let characterSet = value(.specificCharacterSet).map { NSString(bytes: $0, length: $0.count, encoding: String.Encoding.utf8.rawValue) as String? } ?? "ISO_IR 100"
        let patientName = ListenerLogRules.bounded(value(.patientName))
        let studyDescription = ListenerLogRules.receivedDescription(study: value(.studyDescription), series: value(.seriesDescription))
        let seriesUID = value(.seriesInstanceUID).map { ListenerLogRules.bounded($0) } ?? patientName

        if receiveLog == nil {
            let log = NSMutableDictionary()
            var encodings = [UInt](repeating: 0, count: 10)
            encodings[0] = String.Encoding.isoLatin1.rawValue
            for (index, set) in ListenerLogRules.receivedCharacterSets(characterSet).enumerated() {
                encodings[index] = NSString.encoding(forDICOMCharacterSet: set)
            }
            let name = Self.string(patientName, encodings: &encodings) ?? ""
            log["logPatientName"] = name
            log["logStudyDescription"] = Self.string(studyDescription, encodings: &encodings) ?? ""
            log["logCallingAET"] = callingAETitle
            log["logStartTime"] = Date()
            log["logMessage"] = "In Progress"
            log["logType"] = "Receive"
            log["logUID"] = "\(Int32(bitPattern: UInt32(truncatingIfNeeded: time(nil))))\(Int32(bitPattern: UInt32(truncatingIfNeeded: arc4random())))\(name)\(String(decoding: seriesUID, as: UTF8.self))"
            receiveLog = log
        }
        guard let log = receiveLog else { return }
        receivedCount += 1
        log["logNumberReceived"] = NSNumber(value: receivedCount)
        log["logNumberTotal"] = log["logNumberReceived"]
        log["logEndTime"] = Date()
        (LogManager.currentLogManager() as? LogManager)?.addLogLine(log)
    }

    /// +[DicomFile stringWithBytes:encodings:] of `bytes`.
    private static func string(_ bytes: [UInt8], encodings: inout [UInt]) -> String? {
        var characters = bytes.map { CChar(bitPattern: $0) } + [0]
        return characters.withUnsafeMutableBufferPointer { buffer in
            encodings.withUnsafeMutableBufferPointer { DicomFile.string(withBytes: buffer.baseAddress, encodings: $0.baseAddress) as String? }
        }
    }

    // MARK: - The end of the association

    func associationEndedIncomplete() {
        incomplete = true
    }

    /// The log entries say how the association and its retrieve ended.
    func close() {
        if let log = receiveLog {
            log["logMessage"] = incomplete ? "Incomplete" : "Complete"
            log["logEndTime"] = Date()
            (LogManager.currentLogManager() as? LogManager)?.addLogLine(log)
            receiveLog = nil
        }
        if let log = retrieveLog {
            if retrievePosition < (retrievePaths?.count ?? 0) { log["logMessage"] = "Incomplete" }
            log["logEndTime"] = Date()
            (LogManager.currentLogManager() as? LogManager)?.addLogLine(log)
            retrieveLog = nil
        }
    }

    // MARK: - Shared by the find and the retrieve

    /// The attributes of a request identifier as DCMTK holds them.
    static func elements(of identifier: IsiXDCMTKDataset) -> [SCPIdentifierElement] {
        var elements: [SCPIdentifierElement] = []
        try? identifier.enumerateRawElements { tag, value, length, name in
            elements.append(SCPIdentifierElement(tag: DICOMTag(rawValue: tag), value: value.map { Array($0) },
                                                 length: Int(length), name: name))
        }
        return elements
    }

    /// The Query/Retrieve Level of a request identifier, as it came.
    static func level(of identifier: IsiXDCMTKDataset) -> String? {
        identifier.rawValue(forTag: DICOMTag.queryRetrieveLevel.rawValue).map { String(decoding: $0, as: UTF8.self) }
    }

    /// -[value intValue]: 0 for nil.
    static func int(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        if let string = value as? NSString { return string.intValue }
        return 0
    }

    /// The adapter's start of a request that did not pass the checks.
    static func start(_ outcome: SCPRequestCheck.Outcome) -> IsiXDCMTKSCPRequestStart? {
        switch outcome {
        case .accepted: return nil
        case .sopClassNotSupported: return .sopClassNotSupported
        case .missingLevel: return .missingLevel
        case .unknownLevel: return .unknownLevel
        }
    }
}
