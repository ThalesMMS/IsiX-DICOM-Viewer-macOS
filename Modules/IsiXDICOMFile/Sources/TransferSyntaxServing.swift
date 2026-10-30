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

/// Whether a stored DICOM file can be served as it is for a transfer syntax
/// asked of it, as the web portal's WADO answers: the same syntax, or the
/// lossless and lossy flavours of JPEG 2000 or of JPEG-LS for each other.
public enum TransferSyntaxServing {

    static let jpeg2000 = "1.2.840.10008.1.2.4.91"
    static let jpeg2000Lossless = "1.2.840.10008.1.2.4.90"
    static let jpegLSLossless = "1.2.840.10008.1.2.4.80"
    static let jpegLSLossy = "1.2.840.10008.1.2.4.81"

    /// `original` is the syntax the file was read in, `requested` the one asked
    /// for, both as UIDs.
    public static func servesOriginal(original: String, requested: String) -> Bool {
        let original = original as NSString
        if original.isEqual(to: requested) { return true }
        let pairs: [(String, String)] = [(jpeg2000, jpeg2000Lossless), (jpeg2000Lossless, jpeg2000),
                                          (jpegLSLossy, jpegLSLossless), (jpegLSLossless, jpegLSLossy)]
        return pairs.contains { original.isEqual(to: $0.0) && (requested as NSString).isEqual(to: $0.1) }
    }
}
