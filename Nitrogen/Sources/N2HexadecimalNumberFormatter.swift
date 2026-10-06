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

import Cocoa

/// Shows a number as "0x" and hexadecimal digits, and reads hexadecimal.
/// Named by AnonymizationCustomTagPanel.xib as a custom class.
///
/// Implemented in Swift: the Objective-C name and
/// <Horos/N2HexadecimalNumberFormatter.h> are those of the former class.
// @unchecked Sendable, restated from NumberFormatter's: the class adds no state.
@objc(N2HexadecimalNumberFormatter)
public final class N2HexadecimalNumberFormatter: NumberFormatter, @unchecked Sendable {
    @objc public override init() {
        super.init()
    }

    /// From the xib; the former class had no -initWithCoder: of its own.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func string(for obj: Any?) -> String? {
        guard let number = obj as? NSNumber else {
            return nil
        }

        let format = String(format: "0x%%0%dX", Int32(truncatingIfNeeded: formatWidth))

        return String(format: format, number.int32Value)
    }

    public override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let scanner = Scanner(string: string)

        guard let value = scanner.scanUInt64(representation: .hexadecimal) else { return false }
        obj?.pointee = NSNumber(value: UInt32(clamping: value))
        return true
    }

    public override func attributedString(for obj: Any, withDefaultAttributes attrs: [NSAttributedString.Key: Any]? = nil) -> NSAttributedString? {
        /*if (![number isKindOfClass:[NSNumber class]])
            return NULL;

        return [[[NSAttributedString alloc] initWithString:[self stringForObjectValue:number] attributes:attributes] autorelease];*/

        return nil
    }
}
