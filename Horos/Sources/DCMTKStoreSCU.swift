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
import IsiXDICOMNetwork

/// What ends a send: the exception -run: raises, by name and reason.
/// `recorded` is false for a failure that only stops the send and is logged
/// (it was an exception the send did not raise itself): the exception raised
/// at the end is then the report's, if files are missing.
struct StoreSendFailure: Error {
    let name: String
    let reason: String
    var recorded = true

    static let store = "DICOM Network Failure (STORE-SCU)"
    static let secureStore = "DICOM Network Failure (STORE-SCU TLS)"
    static let network = "DICOM Network Failure"
}

/// The diagnostics a send prints to the standard error, under storescu's name.
func storeSCUDiagnostic(_ message: String) {
    FileHandle.standardError.write(Data("storescu: \(message)\n".utf8))
}

/// N2LocalizedSingularPluralCount of N2Stuff.h.
func storeSCUCount(_ count: Int, _ singular: String, _ plural: String) -> String {
    "\(NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)) \(count == 1 ? singular : plural)"
}

/// DICOM send: the files go to a node over one association, each in the
/// transfer syntax of the send's setting when the node accepts it. The
/// association, the C-STOREs and the conversions are DCMTK's, through the
/// adapter (Adapters/DCMTK); the rules of what to propose and when to convert
/// are IsiXDICOMNetwork's; this class keeps the files, the report, the
/// progress, the notifications and the network log.
///
/// -run: raises an NSException when files were not sent, as the callers
/// (the Send sheet, routing, Bonjour, the web portal) expect.
@objc(DCMTKStoreSCU)
public final class DCMTKStoreSCU: NSObject, @unchecked Sendable {
    let callingAET: String?
    let calledAET: String?
    let port: Int32
    let hostname: String?
    let transferSyntax: Int32
    let compression: Float
    let tls: TLSNodeSettings

    private let filesToSend: [String]
    private let numberOfFiles: Int
    private var numberSent = 0
    private var numberErrors = 0
    /// Readable by key, as the Objective-C++ ivar was: the native send
    /// diagnostics attribute each reported path to its own send through it.
    @objc let report = StoreReport()
    private var patientName: String?
    private var studyDescription: String?
    private var logEntry: NSMutableDictionary?

    /// The send setting that matches the listener's preferred syntax for
    /// incoming images, an E_TransferSyntax value.
    @objc(sendSyntaxForListenerSyntax:)
    public static func sendSyntax(forListenerSyntax listenerSyntax: Int32) -> Int32 {
        let uid = IsiXDCMTKTransferSyntax(dcmtkValue: Int(listenerSyntax)).uid
        return Int32(StoreSendSyntax.setting(forListenerTransferSyntax: uid))
    }

    @objc(initWithCallingAET:calledAET:hostname:port:filesToSend:transferSyntax:compression:extraParameters:)
    public init(callingAET: String?, calledAET: String?, hostname: String?, port: Int32, filesToSend: [Any]?,
                transferSyntax: Int32, compression: Float, extraParameters: [AnyHashable: Any]?) {
        self.callingAET = callingAET
        self.calledAET = calledAET
        self.hostname = hostname
        self.port = port
        self.transferSyntax = transferSyntax
        self.compression = compression
        if extraParameters == nil { NSLog("--- DCMTKStoreSCU extraParameters == nil : TLS support not available") }
        tls = TLSNodeSettings(extraParameters: extraParameters)

        // Absent paths stay in the inventory: the send records their read
        // failure with the other per-file outcomes.
        let files = NSMutableArray(array: filesToSend ?? [])
        files.removeDuplicatedStrings()
        self.filesToSend = files.compactMap { $0 as? String }
        numberOfFiles = self.filesToSend.count
        super.init()
        if let first = self.filesToSend.first { readNames(ofFileAtPath: first) }
    }

    /// The patient's name and the study's description the network log shows,
    /// from the first file, in its character sets.
    private func readNames(ofFileAtPath path: String) {
        guard let dataset = try? IsiXDCMTKDataset.dataset(ofFileAtPath: path, transferSyntax: nil) else { return }
        var encodings = [UInt](repeating: 0, count: 10)
        encodings[0] = String.Encoding.isoLatin1.rawValue
        if let raw = dataset.rawValue(forTag: DICOMTag.specificCharacterSet.rawValue),
           let characterSet = String(data: raw, encoding: .utf8) {
            let names = characterSet.components(separatedBy: "\\")
            if names.count >= 10 { NSLog("Encoding number >= 10 ???") }
            if names.count < 10 {
                for (index, name) in names.enumerated() { encodings[index] = NSString.encoding(forDICOMCharacterSet: name) }
            }
        }
        patientName = dataset.text(.patientName, encodings: encodings) ?? "Unnamed"
        studyDescription = dataset.text(.studyDescription, encodings: encodings) ?? "Unnamed"
    }

    private func cancelled(_ operation: Operation?) -> Bool {
        if let operation { return operation.isCancelled }
        return Thread.current.isCancelled
    }

    @objc(run:)
    public func run(_ operation: Operation?) {
        var failure: StoreSendFailure?
        let files = StoreTemporaryFiles()
        autoreleasepool {
            failure = send(operation, temporaryFiles: files)
        }
        files.remove()
        if let failure {
            NSException(name: NSExceptionName(failure.name), reason: failure.reason, userInfo: nil).raise()
        }
    }

    /// The send itself; the failure -run: raises, if any.
    private func send(_ operation: Operation?, temporaryFiles: StoreTemporaryFiles) -> StoreSendFailure? {
        AppController.shared()?.notificationTitle(
            NSLocalizedString("DICOM Send", comment: ""),
            description: String(format: NSLocalizedString("Sending %@...\rTo: %@ - %@", comment: ""),
                                storeSCUCount(filesToSend.count, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: "")),
                                calledAET ?? "(null)", hostname ?? "(null)"),
            name: "send")

        // Never verbose: the setting is cleared before it is read.
        UserDefaults.standard.set(false, forKey: "verbose_dcmtkStoreScu")
        let verbose = UserDefaults.standard.bool(forKey: "verbose_dcmtkStoreScu")
        let network = StoreSendSyntax.network(forSetting: Int(transferSyntax))
        IsiXDCMTKAssociation.configureForSending(verbose: verbose, deflateLevel: Int(compression),
                                                        deflated: network.transferSyntax == TransferSyntaxUID.deflatedExplicitLittleEndian)

        var recorded: StoreSendFailure?
        let link = StoreAssociation(store: self)
        do {
            try sendFiles(over: link, network: network, temporaryFiles: temporaryFiles, operation: operation)
        } catch let stopped as StoreSendFailure {
            if stopped.recorded { recorded = stopped }
            NSLog("********* Store Exception: %@", stopped.reason)
        } catch {
            NSLog("********* Store Exception: %@", error.localizedDescription)
        }

        // Other threads may still be using the association.
        Thread.sleep(forTimeInterval: 1)
        if let closing = link.close() { recorded = closing }

        var userInfo: [String: Any] = ["SendTotal": numberOfFiles, "NumberSent": numberSent, "ErrorCount": numberErrors, "Sent": 0]
        if numberSent != numberOfFiles || recorded != nil {
            userInfo["Message"] = cancelled(operation) ? "Aborted" : "Incomplete"
            numberErrors = numberOfFiles - numberSent
            userInfo["ErrorCount"] = numberErrors
            AppController.shared()?.notificationTitle(
                NSLocalizedString("DICOM Send", comment: ""),
                description: String(format: NSLocalizedString("Errors ! %@ of %@ generated errors.", comment: ""),
                                    NumberFormatter.localizedString(from: NSNumber(value: numberErrors), number: .decimal),
                                    storeSCUCount(numberOfFiles, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: ""))),
                name: "send")
            NSLog("DCMTKStoreSCU: _numberSent: %d / _numberOfFiles : %d", numberSent, numberOfFiles)
            NSLog("DCMTKStoreSCU: %@", report.detail(limit: 20))
            // The reason used to be "see Console.app for more detailed
            // informations", and what was there to see was the standard error
            // of a released application.
            if recorded == nil { recorded = StoreSendFailure(name: StoreSendFailure.store, reason: report.detail(limit: 5)) }
        } else {
            userInfo["Message"] = "Complete"
        }
        updateLogEntry(NSMutableDictionary(dictionary: userInfo))
        if numberOfFiles >= 1 {
            let extraInfo = tls.enabled ? " (TLS Activated)" : ""
            Thread.current.status = String(format: NSLocalizedString("%@%@", comment: ""),
                                           storeSCUCount(numberOfFiles - numberSent, NSLocalizedString("file", comment: ""),
                                                         NSLocalizedString("files", comment: "")), extraInfo)
            Thread.current.progress = CGFloat(Float(numberSent) / Float(numberOfFiles))
            ActivityProgressCount.set(done: numberSent, total: numberOfFiles, on: Thread.current)
        }
        return recorded
    }

    /// Opens the association and sends each file on it; throws what stops the
    /// send. A file the node will not take does not stop it; a transmission
    /// that failed does, as nothing after it would arrive on the association.
    private func sendFiles(over link: StoreAssociation, network: StoreNetworkSyntax, temporaryFiles: StoreTemporaryFiles,
                           operation: Operation?) throws {
        // Every selected path is reported on; the readable storage objects
        // among them decide the presentation contexts.
        let classes = filesToSend.compactMap { IsiXDCMTKStoreFile.storageSOPClassOfFile(atPath: $0) }
        let association = try link.open(classes: classes, network: network)

        let sender = StoreFileSender(association: association, report: report, network: network, temporaryFiles: temporaryFiles)
        var condition: (any Error)?
        var associationLost = false
        for path in filesToSend {
            condition = try sender.send(path)
            if condition == nil {
                numberSent += 1
            } else {
                numberErrors += 1
                if report.lastFailureIsFileLevel {
                    condition = nil  // carry on with the next file
                } else {
                    associationLost = true
                    numberErrors = numberOfFiles - numberSent
                }
            }

            let userInfo = NSMutableDictionary(dictionary: ["SendTotal": numberOfFiles, "NumberSent": numberSent,
                                                            "ErrorCount": numberErrors, "Sent": 0, "Message": "In Progress"])
            if cancelled(operation) { userInfo["Message"] = "Incomplete" }
            updateLogEntry(userInfo)
            if numberOfFiles >= 1 {
                let extraInfo = tls.enabled ? NSLocalizedString(" (TLS)", comment: "don't remove leading space") : ""
                let remaining = numberOfFiles - numberSent
                Thread.current.status = String(format: "%d %@%@", remaining,
                                               remaining != 1 ? NSLocalizedString("files", comment: "") : NSLocalizedString("file", comment: ""),
                                               extraInfo)
                Thread.current.progress = CGFloat(Float(numberSent) / Float(numberOfFiles))
                ActivityProgressCount.set(done: numberSent, total: numberOfFiles, on: Thread.current)
            }
            if associationLost || cancelled(operation) { break }
        }

        if report.failedCount > 0 { NSLog("**** DICOM send: %@", report.detail(limit: 20)) }
        try link.end(after: condition)
    }

    /// The entry of this send in the network log, when the log is on.
    @objc(updateLogEntry:)
    public func updateLogEntry(_ userInfo: NSMutableDictionary) {
        guard BrowserController.currentBrowser()?.isNetworkLogsActive() == true else { return }
        if logEntry == nil {
            let entry = NSMutableDictionary()
            entry.setValue(String(format: "%lf", Date().timeIntervalSince1970), forKey: "logUID")
            entry.setValue(Date(), forKey: "logStartTime")
            entry.setValue("Send", forKey: "logType")
            entry.setValue(calledAET, forKey: "logCalledAET")
            entry.setValue(callingAET, forKey: "logCallingAET")
            if let patientName { entry.setValue(patientName, forKey: "logPatientName") }
            if let studyDescription { entry.setValue(studyDescription, forKey: "logStudyDescription") }
            logEntry = entry
        }
        guard let logEntry else { return }
        logEntry.setValue(NSNumber(value: numberOfFiles), forKey: "logNumberTotal")
        logEntry.setValue(NSNumber(value: numberSent), forKey: "logNumberReceived")
        logEntry.setValue(NSNumber(value: numberErrors), forKey: "logNumberError")
        logEntry.setValue(Date(), forKey: "logEndTime")
        logEntry.setValue(userInfo.value(forKey: "Message"), forKey: "logMessage")
        (LogManager.currentLogManager() as? LogManager)?.addLogLine(logEntry)
    }
}

/// The folder the converted copies of one send are written to, made in the
/// database's temporary folder for the first file and removed when the send
/// ends; each copy has a name of its own.
final class StoreTemporaryFiles {
    private var folder: String?
    private var seed: UInt = 0

    /// The path of the next copy; nil when it would be too long for DCMTK.
    func nextPath() -> String? {
        if folder == nil {
            folder = FileManager.default.tmpDirectoryPath(inDir: DicomDatabase.activeLocal()?.tempDirPath())
        }
        let path = "\(folder ?? "(null)")/\(seed).dcm"
        seed += 1
        return strlen((path as NSString).fileSystemRepresentation) >= 4096 ? nil : path
    }

    func remove() {
        if let folder { try? FileManager.default.removeItem(atPath: folder) }
        folder = nil
    }
}
