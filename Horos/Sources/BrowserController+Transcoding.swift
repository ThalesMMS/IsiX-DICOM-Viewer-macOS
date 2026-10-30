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
import Synchronization

// BrowserController (transcoding): the name of a transfer syntax, a file in
// the transfer syntax the web portal asks for, recompressed through
// Adapters/DCMTK/IsiXDCMTKTranscoding when it is in another, and the
// deprecated compression entry points, which the database answers.

/// Numbers the web portal's temporary recompressed files, from 1.
private let wadoTemporaryFileNumber = Mutex<Int>(1)

extension BrowserController {

    /// The name of a transfer syntax: a pure lookup, called from the loading
    /// threads too. Any thread.
    @objc(compressionString:)
    nonisolated dynamic class func compressionString(_ string: String!) -> String! {
        let uid = string as NSString?
        if uid?.isEqual(to: "1.2.840.10008.1.2") == true { return NSLocalizedString("Uncompressed", comment: "") }
        if uid?.isEqual(to: "1.2.840.10008.1.2.1") == true { return NSLocalizedString("Uncompressed", comment: "") }
        if uid?.isEqual(to: "1.2.840.10008.1.2.2") == true { return NSLocalizedString("Uncompressed BigEndian", comment: "") }
        if let string, let name = IsiXDCMTKTranscoding.name(ofUID: string) { return name }
        return NSLocalizedString("Unknown UID", comment: "")
    }

    /// The file in a transfer syntax, recompressed by DCMTK when it is in
    /// another the syntax cannot be served from; the original file when the
    /// copy cannot be made. nil when DCMTK cannot load the file. On the
    /// calling thread (the web portal's).
    @objc(getDICOMFile:inSyntax:quality:)
    nonisolated func getDICOMFile(_ file: String!, inSyntax syntax: String!, quality: Int32) -> Data! {
        guard let file else { return nil }
        let number = wadoTemporaryFileNumber.withLock { next in
            defer { next += 1 }
            return next
        }
        let temporary = FileManager.default.tmpDirPath().appendingFormat("/wado-recompress-%ld.dcm", number) as String
        try? FileManager.default.removeItem(atPath: temporary)

        let outcome = IsiXDCMTKTranscoding.transcodeFile(atPath: file, toTransferSyntax: syntax ?? "", quality: quality,
                                                         destination: temporary,
                                                         servesOriginal: { original, requested in
            TransferSyntaxServing.servesOriginal(original: original, requested: requested)
        }, error: nil)
        switch outcome {
        case .unreadable:
            return nil
        case .servesOriginal:
            return NSData(contentsOfFile: file) as Data?
        case .saveFailed:
            NSLog("getDICOMFile:(NSString*) file inSyntax:(NSString*) syntax quality: (int) quality failed")
        case .written, .cannotWrite:
            break
        @unknown default:
            break
        }
        let data = NSData(contentsOfFile: temporary) as Data?
        try? FileManager.default.removeItem(atPath: temporary)
        return data ?? NSData(contentsOfFile: file) as Data? // Original file
    }

    @available(*, deprecated)
    @objc(needToCompressFile:)
    nonisolated func needToCompressFile(_ path: String!) -> Bool {
        return DicomDatabase.fileNeedsDecompression(path)
    }

    @available(*, deprecated)
    @objc(compressDICOMWithJPEG:)
    nonisolated func compressDICOMWithJPEG(_ paths: [Any]!) -> Bool {
        return database.compressFiles(atPaths: paths)
    }

    @available(*, deprecated)
    @objc(compressDICOMWithJPEG:to:)
    nonisolated func compressDICOMWithJPEG(_ paths: [Any]!, to dest: String!) -> Bool {
        return database.compressFiles(atPaths: paths, intoDirAtPath: dest)
    }

    @available(*, deprecated)
    @objc(decompressDICOMList:to:)
    nonisolated func decompressDICOMList(_ files: [Any]!, to dest: String!) -> Bool {
        return database.decompressFiles(atPaths: files, intoDirAtPath: dest)
    }

    @available(*, deprecated)
    @objc(testFiles:)
    nonisolated func testFiles(_ files: [Any]!) -> Bool {
        return DicomDatabase.testFiles(files)
    }
}
