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

// BrowserController (transcoding): the name of a transfer syntax and a file
// in the transfer syntax the web portal asks for are ArchiveImport's
// (ArchiveImport.swift); the deprecated compression entry points are
// answered by the database.

extension BrowserController {

    /// The name of a transfer syntax. Any thread.
    @objc(compressionString:)
    nonisolated dynamic class func compressionString(_ string: String!) -> String! {
        return ArchiveImport.name(ofTransferSyntax: string)
    }

    /// The file in a transfer syntax (ArchiveImport), on the calling thread.
    @objc(getDICOMFile:inSyntax:quality:)
    nonisolated func getDICOMFile(_ file: String!, inSyntax syntax: String!, quality: Int32) -> Data! {
        return ArchiveImport.file(file, inSyntax: syntax, quality: quality)
    }

    @available(*, deprecated)
    @objc(needToCompressFile:)
    nonisolated func needToCompressFile(_ path: String!) -> Bool {
        return DatabaseFileConversion.isWorthCompressing(path)
    }

    @available(*, deprecated)
    @objc(compressDICOMWithJPEG:)
    nonisolated func compressDICOMWithJPEG(_ paths: [Any]!) -> Bool {
        return DatabaseIngest.process.fileConverting(of: database).convertNow((paths ?? []).map { "\($0)" }, mode: .compress, into: nil)
    }

    @available(*, deprecated)
    @objc(compressDICOMWithJPEG:to:)
    nonisolated func compressDICOMWithJPEG(_ paths: [Any]!, to dest: String!) -> Bool {
        return DatabaseIngest.process.fileConverting(of: database).convertNow((paths ?? []).map { "\($0)" }, mode: .compress, into: dest)
    }

    @available(*, deprecated)
    @objc(decompressDICOMList:to:)
    nonisolated func decompressDICOMList(_ files: [Any]!, to dest: String!) -> Bool {
        return DatabaseIngest.process.fileConverting(of: database).convertNow((files ?? []).map { "\($0)" }, mode: .decompress, into: dest)
    }

    @available(*, deprecated)
    @objc(testFiles:)
    nonisolated func testFiles(_ files: [Any]!) -> Bool {
        return DicomDatabase.testFiles(files)
    }
}
