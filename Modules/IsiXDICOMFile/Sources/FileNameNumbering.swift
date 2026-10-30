/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// The number at the end of a file's name, which turns scan001.jpg,
/// scan002.jpg... into the images of one series: the files that are not DICOM
/// carry no identifiers of their own, so the series and the study are the name
/// without the number, and the number is the image's.
public enum FileNameNumbering {

    /// The trailing number of `name`: its digits (one to four) and where they
    /// start; nil when the name does not end in a digit.
    ///
    /// The last four characters are taken as the Objective-C took them, each
    /// cut to its low byte (a `char` of a `unichar`), so a character outside
    /// ASCII whose low byte is a digit counts as that digit.
    public static func trailingNumber(of name: NSString) -> (digits: String, start: Int)? {
        let length = name.length
        func byte(_ back: Int) -> UInt8 {
            length >= back ? UInt8(truncatingIfNeeded: name.character(at: length - back)) : 0
        }
        let bytes = [byte(4), byte(3), byte(2), byte(1)]
        func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
        let count: Int
        if bytes.allSatisfy(isDigit) {
            count = 4
        } else if bytes[1...].allSatisfy(isDigit) {
            count = 3
        } else if bytes[2...].allSatisfy(isDigit) {
            count = 2
        } else if isDigit(bytes[3]) {
            count = 1
        } else {
            return nil
        }
        let digits = String(decoding: bytes[(4 - count)...], as: UTF8.self)
        return (digits, length - count)
    }
}
