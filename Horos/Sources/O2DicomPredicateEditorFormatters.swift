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

/// The formatter of AS (age string) values in the smart album editor: a
/// number from 0 to 999 and an optional Y, M, W or D, written "NNNL".
///
/// Implemented in Swift since #713: the Objective-C name, the selectors and
/// <Horos/O2DicomPredicateEditorFormatters.h> are those of the former class.
@objc(O2DicomPredicateEditorAgeStringFormatter)
public final class O2DicomPredicateEditorAgeStringFormatter: Formatter {
    /// The value, which the former class returned as it was. The fields hold strings.
    public override func string(for obj: Any?) -> String? {
        return obj as? String
    }

    public override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let s = Scanner(string: string)

        var num = 0
        if !s.o2_scanInteger(&num) {
            error?.pointee = NSLocalizedString("This field must contain a numeric value.", comment: "") as NSString
            return false
        }

        if num > 999 || num < 0 {
            error?.pointee = NSLocalizedString("The numeric value in this field must be between 0 and 999.", comment: "") as NSString
            return false
        }

        let cfs = s.scanCharacters(from: .letters) as NSString?

        var t: unichar = 0
        if let cfs = cfs, cfs.length > 0 {
            switch cfs.uppercased.utf16.first ?? 0 {
            case unichar(UInt8(ascii: "Y")),
                 unichar(UInt8(ascii: "M")),
                 unichar(UInt8(ascii: "W")),
                 unichar(UInt8(ascii: "D")):
                t = cfs.character(at: 0)
            default:
                error?.pointee = NSLocalizedString("The postfixed letter must be either Y, M, W or D.", comment: "") as NSString
                return false
            }
        }

        if t == 0 {
            t = unichar(UInt8(ascii: "Y"))
        }

        obj?.pointee = String(format: "%03d%c", Int32(truncatingIfNeeded: num), t) as NSString
        return true
    }
}

/// The formatter of multi-valued IS and DS values: each component, between
/// backslashes, must be accepted by monoFormatter. The value is the string.
@objc(O2DicomPredicateEditorMultiplicityFormatter)
public final class O2DicomPredicateEditorMultiplicityFormatter: Formatter {
    /// Retained, as before. The former property was atomic; it is set once,
    /// when O2DicomPredicateEditorView makes the shared formatter.
    @objc public var monoFormatter: Formatter?

    public override func string(for obj: Any?) -> String? {
        return obj as? String
    }

    public override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String, errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let parts = (string as NSString).components(separatedBy: "\\")
        for (i, part) in parts.enumerated() {
            var partObj: AnyObject?
            var err: NSString?
            if !(monoFormatter?.getObjectValue(&partObj, for: part, errorDescription: &err) ?? false) {
                // %@ wrote (null) for a nil description.
                error?.pointee = String(format: NSLocalizedString("On component %d: %@", comment: ""), Int32(truncatingIfNeeded: i + 1), (err as String?) ?? "(null)") as NSString
                return false
            }
        }

        obj?.pointee = string as NSString
        return true
    }
}

extension Scanner {
    /// -scanInteger:, which the Swift name of the former call deprecates.
    func o2_scanInteger(_ value: inout Int) -> Bool {
        guard let scanned = scanInt() else {
            return false
        }
        value = scanned
        return true
    }
}
