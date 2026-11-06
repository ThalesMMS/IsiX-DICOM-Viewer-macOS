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

/// The report a DICOM structured report carries.
enum StructuredReportExtraction {
    /// Where the report of `dicomSR` is: the URL it names or a file extracted
    /// from the archive it holds. nil for a report that was cleared on purpose
    /// and for damage, which `error` tells apart: callers that only open
    /// reports pass nil, and an importer needs to know.
    static func report(_ dicomSR: String?, contentDate date: Date?, error: NSErrorPointer) -> String? {
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
}
