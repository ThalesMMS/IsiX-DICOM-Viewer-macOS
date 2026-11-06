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

// The number a person types to calibrate a viewer (a slice interval, a
// pixel spacing, the length of a ROI): read in their locale, then in
// en_US_POSIX, as a whole entry, finite and within float.

public enum CalibrationNumber {

    /// The float `text` stands for, nil when it is empty, not a whole number
    /// in `locale` nor in en_US_POSIX, not finite, beyond float, or a nonzero
    /// value float rounds to zero.
    public static func parse(_ text: String, locale: Locale) -> Float? {
        let entry = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if entry.isEmpty { return nil }
        for candidate in [locale, Locale(identifier: "en_US_POSIX")] {
            let scanner = Scanner(string: entry)
            scanner.locale = candidate
            if let number = scanner.scanDouble(), scanner.isAtEnd, number.isFinite, abs(number) <= Double(Float.greatestFiniteMagnitude) {
                let result = Float(number)
                if number != 0 && result == 0 { return nil }
                return result
            }
        }
        return nil
    }
}
