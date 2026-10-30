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
import IsiXDICOMFile

/// The DICOMDIR of an export folder. Which files it indexes is
/// DicomDirExportRules (IsiXDICOMFile); DCMTK lists the folder and writes the
/// directory in the adapter (IsiXDCMTKDicomDir). The file is written to a
/// staging archive and replaces the folder's DICOMDIR only once complete.
@objc @implementation extension DicomDir {

    @objc(createDicomDirAtDir:)
    class func createDicomDir(atDir path: String!) {
        try? createDicomDirReportingError(atDir: path)
    }

    @objc(createDicomDirAtDir:error:)
    class func createDicomDirReportingError(atDir path: String!) throws {
        let folder = path ?? ""
        var outcome: NSError?
        var written = false
        // What the former @try handled: an Objective-C exception raised on the
        // way is logged and the export fails with its reason.
        do {
            try caughtObjCException {
                try writeDicomDir(in: folder)
                written = true
            }
        } catch let raised as RaisedObjCException {
            _N2LogExceptionImpl(raised.exception, false, "+[DicomDir createDicomDirAtDir:error:]")
            outcome = dicomDirExportError(reason: raised.exception.reason ?? "", folder: folder)
        } catch {
            outcome = error as NSError
        }
        if written { return }
        throw outcome ?? dicomDirExportError(reason: "", folder: folder)
    }
}

/// Lists the folder, writes the DICOMDIR into a staging archive and commits it.
private func writeDicomDir(in folder: String) throws {
    var relativePaths: [String] = []
    do {
        try caughtObjCException { relativePaths = try IsiXDCMTKDicomDir.relativePathsOfFiles(inFolder: folder) }
    } catch let raised as RaisedObjCException {
        throw raised
    } catch {
        throw dicomDirFailure(error as NSError, folder: folder)
    }
    let dicomDirPath = (folder as NSString).appendingPathComponent(DicomDirExportRules.dicomDirName)
    // The staging archive is released, and its folder removed, whatever ends
    // the export: an Objective-C exception is caught before it can unwind
    // past this frame, which holds it.
    let replacement = try ExportArchive(destinationPath: dicomDirPath)
    do {
        try caughtObjCException {
            try IsiXDCMTKDicomDir.writeDicomDir(atPath: replacement.archivePath, folder: folder,
                                                relativePaths: relativePaths.filter(DicomDirExportRules.indexes))
        }
    } catch let raised as RaisedObjCException {
        throw raised
    } catch {
        throw dicomDirFailure(error as NSError, folder: folder)
    }
    try replacement.commit()
}

/// An Objective-C exception raised in `body`, which Swift cannot unwind
/// through, caught at its call and thrown on as an error. The exception is
/// only read on the thread that caught it.
private struct RaisedObjCException: Error, @unchecked Sendable {
    let exception: NSException
}

private func caughtObjCException(_ body: () throws -> Void) throws {
    var thrown: Error?
    do {
        try HorosObjCException.perform {
            do { try body() } catch { thrown = error }
        }
    } catch {
        if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
            throw RaisedObjCException(exception: exception)
        }
        throw error
    }
    if let thrown { throw thrown }
}

/// The export's error for what the adapter refused: a DCMTK condition, which
/// the former code raised and logged as an exception, or a C++ exception,
/// whose text is the reason.
private func dicomDirFailure(_ error: NSError, folder: String) -> NSError {
    if IsiXDCMTKError.kind(ofError: error) == .exception {
        let reason = error.userInfo[IsiXDCMTKConditionTextKey] as? String ?? error.localizedDescription
        return dicomDirExportError(reason: reason, folder: folder)
    }
    let reason = error.localizedDescription
    _N2LogExceptionImpl(NSException(name: .genericException, reason: reason, userInfo: nil), false,
                        "+[DicomDir createDicomDirAtDir:error:]")
    return dicomDirExportError(reason: reason, folder: folder)
}

private func dicomDirExportError(reason: String, folder: String) -> NSError {
    NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
        NSLocalizedDescriptionKey: NSLocalizedString("DICOMDIR export could not be completed.", comment: ""),
        NSLocalizedFailureReasonErrorKey: reason,
        NSFilePathErrorKey: folder,
    ])
}
