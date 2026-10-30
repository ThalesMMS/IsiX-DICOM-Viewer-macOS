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

// DicomImage (key objects): what an image that is a structured report, a key
// object selection, says of itself, read through
// Adapters/DCMTK/IsiXDCMTKStructuredReportReader. Each call reads the file.

extension DicomImage {

    /// The meaning of the report's title, the kind of key object selection;
    /// nil when the file is not a readable report.
    @objc public func keyObjectType() -> String? {
        guard let path = completePath() else { return nil }
        return try? IsiXDCMTKStructuredReportReader.titleMeaning(ofReportAtPath: path)
    }

    /// The SOP Instance UIDs of the images the report references, in its
    /// order; empty when the file is not a readable report.
    @objc public func referencedObjects() -> [String] {
        guard let path = completePath() else { return [] }
        return IsiXDCMTKStructuredReportReader.referencedImageInstances(ofReportAtPath: path)
    }
}
