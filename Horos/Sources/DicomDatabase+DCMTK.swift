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

// DicomDatabase (DCMTK): the selectors of the contract. Whether a file is worth
// compressing and converting it are DatabaseFileConversion, reading the report
// a structured report carries is StructuredReportExtraction, and the validation
// of files before importing them is ImportFileValidation.

@objc(DCMTK) @implementation extension DicomDatabase {

    class func fileNeedsDecompression(_ path: String!) -> Bool {
        return DatabaseFileConversion.isWorthCompressing(path)
    }

    class func compressDicomFiles(atPaths paths: [Any]!) -> Bool {
        return compressDicomFiles(atPaths: paths, intoDirAtPath: nil)
    }

    class func decompressDicomFiles(atPaths paths: [Any]!) -> Bool {
        return decompressDicomFiles(atPaths: paths, intoDirAtPath: nil)
    }

    class func compressDicomFiles(atPaths paths: [Any]!, intoDirAtPath destDir: String!) -> Bool {
        return DatabaseIngest.process.fileConversion(of: nil).convertNow((paths ?? []).map { "\($0)" }, mode: .compress, into: destDir)
    }

    class func decompressDicomFiles(atPaths paths: [Any]!, intoDirAtPath destDir: String!) -> Bool {
        return DatabaseIngest.process.fileConversion(of: nil).convertNow((paths ?? []).map { "\($0)" }, mode: .decompress, into: destDir)
    }

    class func extractReportSR(_ dicomSR: String!, contentDate date: Date!) -> String! {
        return StructuredReportExtraction.report(dicomSR, contentDate: date, error: nil)
    }

    class func extractReportSR(_ dicomSR: String!, contentDate date: Date!, error: NSErrorPointer) -> String! {
        return StructuredReportExtraction.report(dicomSR, contentDate: date, error: error)
    }

    class func filesRefused(byValidation files: [Any]!) -> [Any]! {
        return ImportFileValidation.refusedFiles(files ?? [])
    }

    class func testFiles(_ files: [Any]!) -> Bool {
        return ImportFileValidation.refusedFiles(files ?? []).isEmpty
    }
}
