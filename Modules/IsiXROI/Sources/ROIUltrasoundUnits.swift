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

/// The units of an ultrasound region's axes: Physical Units X Direction
/// (0018,6024) and Y Direction (0018,6026). Each axis is named for itself; a
/// code outside the table is "unknown".
public enum ROIUltrasoundUnits {
    /// The units by DICOM code, 0 to 12, as the labels write them.
    public static var names: [String] {
        [NSLocalizedString("none", comment: ""), "%", NSLocalizedString("dB", comment: "decibel"), NSLocalizedString("cm", comment: ""),
         NSLocalizedString("sec", comment: "second"), NSLocalizedString("hertz", comment: ""), NSLocalizedString("dB/sec", comment: "decibel per second"),
         NSLocalizedString("cm/sec", comment: ""), NSLocalizedString("cm\u{00B2}", comment: "cm2"), NSLocalizedString("cm\u{00B2}/sec", comment: "cm2/sec"),
         NSLocalizedString("cm\u{00B3}", comment: ""), NSLocalizedString("cm\u{00B3}/sec", comment: "cm3/sec"), "\u{00B0}"]
    }

    /// The unit of `code`.
    public static func name(of code: Int32) -> String {
        (code < 0 || code > 12) ? NSLocalizedString("unknown", comment: "") : names[Int(code)]
    }
}
