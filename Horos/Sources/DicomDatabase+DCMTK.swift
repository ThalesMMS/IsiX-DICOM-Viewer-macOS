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
import IsiXDatabase
import IsiXDICOMFile

// DicomDatabase (DCMTK): whether a file is worth compressing, compressing and
// decompressing files in the Decompress service, reading the report a DICOM
// structured report carries, and the validation of files before importing
// them. DCMTK reads the files through Adapters/DCMTK/IsiXDCMTKTranscoding and
// IsiXDCMTKStructuredReportReader.

@objc(DCMTK) @implementation extension DicomDatabase {

    class func fileNeedsDecompression(_ path: String!) -> Bool {
        guard let path, let facts = try? IsiXDCMTKTranscoding.compressionFacts(ofFileAtPath: path) else { return false }
        if facts.pixelDataCompressed { return false }
        let sopClassUID = facts.sopClassUID
        // Images only: not an encapsulated PDF or CDA, nor a structured report.
        guard DICOMSOPClass.isImageStorage(sopClassUID),
              !((sopClassUID as NSString?)?.isEqual(to: DICOMSOPClass.pdfStorageClassUID()) ?? false),
              !((sopClassUID as NSString?)?.isEqual(to: DICOMSOPClass.encapsulatedCDAStorage()) ?? false),
              !DICOMSOPClass.isStructuredReport(sopClassUID) else { return false }
        var resolution: Int32 = 0
        for side in [facts.rows, facts.columns] {
            guard let side = side?.int32Value else { continue }
            if resolution == 0 || resolution > side { resolution = side }
        }
        var quality: Int32 = 0
        let compression = BrowserController.compression(forModality: facts.modality, quality: &quality, resolution: resolution)
        return compression != Int32(compression_none)
    }

    class func compressDicomFiles(atPaths paths: [Any]!) -> Bool {
        return compressDicomFiles(atPaths: paths, intoDirAtPath: nil)
    }

    class func decompressDicomFiles(atPaths paths: [Any]!) -> Bool {
        return decompressDicomFiles(atPaths: paths, intoDirAtPath: nil)
    }

    class func compressDicomFiles(atPaths paths: [Any]!, intoDirAtPath destDir: String!) -> Bool {
        return runHelper("compress", on: paths ?? [], intoDirAtPath: destDir)
    }

    class func decompressDicomFiles(atPaths paths: [Any]!, intoDirAtPath destDir: String!) -> Bool {
        return runHelper("decompressList", on: paths ?? [], intoDirAtPath: destDir)
    }

    /// Converts `paths` in `mode` through the Decompress service, 200 files at
    /// a time, from the calling thread, whose progress it reports. NO when a
    /// chunk times out, ends the service or fails.
    private final class func runHelper(_ mode: String, on paths: [Any], intoDirAtPath destDir: String?) -> Bool {
        let thread = Thread.current
        thread.enterOperation()
        defer { thread.exitOperation() }
        let environment = CompressionHelperRun.Environment(
            progress: { thread.progress = CGFloat($0) },
            now: { Date.timeIntervalSinceReferenceDate },
            sleep: { Thread.sleep(forTimeInterval: $0) },
            logStackTrace: { N2LogStackTraceMessage($0) },
            logLaunchFailure: { error in
                NSLog("%@: %@", mode == "compress" ? "+[DicomDatabase(DCMTK) compressDicomFilesAtPaths:intoDirAtPath:]"
                                                   : "+[DicomDatabase(DCMTK) decompressDicomFilesAtPaths:intoDirAtPath:]",
                      error.localizedDescription)
            },
            crashed: { files in
                guard UserDefaults.standard.bool(forKey: "DELETEFILELISTENER") else { return }
                for path in files {
                    let errors = DicomDatabase.default()?.errorsDirPath() ?? ""
                    try? FileManager.default.moveItem(atPath: path,
                                                      toPath: (errors as NSString).appendingPathComponent((path as NSString).lastPathComponent))
                }
            })
        // The service has no preferences of its own: the conversion reads the
        // application's.
        let defaults = UserDefaults.standard
        let settings = DecompressConversion.settings(from: defaults)
        let moveIfUnreadable = defaults.bool(forKey: "DecompressMoveIfFail")
        return CompressionHelperRun.run(paths.map { "\($0)" }, mode: mode, destination: destDir, environment: environment) {
            DecompressConversionTask(arguments: $0, settings: settings, moveIfUnreadable: moveIfUnreadable,
                                     service: DecompressService.shared)
        }
    }

    // The legacy entry point retains its nil-on-failure contract for callers that
    // only open reports. Importers need to distinguish a cleared report from damage.
    class func extractReportSR(_ dicomSR: String!, contentDate date: Date!) -> String! {
        return extractReportSR(dicomSR, contentDate: date, error: nil)
    }

    class func extractReportSR(_ dicomSR: String!, contentDate date: Date!, error: NSErrorPointer) -> String! {
        guard let dicomSR, !dicomSR.isEmpty, (try? IsiXDCMTKStructuredReportReader.canReadReport(atPath: dicomSR)) != nil else {
            error?.pointee = NSError(domain: "HorosReportExtraction", code: 1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("The DICOM structured report could not be read.", comment: "")])
            return nil
        }
        let report = SRAnnotation(contentsOfFile: dicomSR)
        if let url = report?.reportURL(), (url as NSString).length > 8, url.hasPrefix("http://") || url.hasPrefix("https://") {
            return url
        }
        // An intentionally empty SR clears the report; an invalid archive must not.
        guard let archive = report?.dataEncapsulated(), !archive.isEmpty else { return nil }
        let path = DicomDatabaseExtractReportArchive(archive, date)
        if path == nil {
            error?.pointee = NSError(domain: "HorosReportExtraction", code: 2, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("The report archive could not be extracted completely.", comment: "")])
        }
        return path
    }

    // The validation before importing. The Decompress service loads each file
    // as the viewer would; a file that cannot be read is refused, and only that
    // file: IsiXImportValidation tests a chunk again file by file when the
    // service ended without naming one.
    class func filesRefused(byValidation files: [Any]!) -> [Any]! {
        let files = files ?? []
        guard let service = DecompressService.shared, !files.isEmpty else { return [] }

        var splash: WaitRendering? = nil
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                let shown = WaitRendering(NSLocalizedString("Validating files...", comment: ""))
                shown?.showWindow(nil)
                shown?.setCancel(true)
                shown?.start()
                splash = shown
            }
        }
        let shown = splash.map { UncheckedSendable($0) }

        var refused: [String] = []
        do {
            try HorosObjCException.perform {
                refused = ImportValidation.refusedFiles(files.map { "\($0)" }, tester: service,
                    shouldStop: { shown.map { s in MainActor.assumeIsolated { s.value.aborted() } } ?? false },
                    whileWaiting: { if let shown { MainActor.assumeIsolated { _ = shown.value.run() } } })
            }
        } catch {
            if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                NSLog("***** testList exception : %@", exception)
            }
        }
        if let shown {
            MainActor.assumeIsolated {
                shown.value.end()
                shown.value.close()
            }
        }

        if !refused.isEmpty {
            NSLog("******* test Files: %lu of %lu files cannot be read and are refused: %@",
                  refused.count, files.count, refused as NSArray)
        }
        return refused
    }

    class func testFiles(_ files: [Any]!) -> Bool {
        return filesRefused(byValidation: files).isEmpty
    }
}

/// A main-thread object carried through closures the validation calls on
/// the main thread only (the splash exists only when it runs there).
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
