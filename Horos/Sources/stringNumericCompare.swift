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

// NSString (stringNumericCompare) is implemented in Swift since #716; the
// selector and <Horos/stringNumericCompare.h> are those of the former category.
// NSString (stringAdditions), from stringAdditions.m, declared the same
// -numericCompare: with the same body. Swift allows one method per selector:
// this one answers for both, and <Horos/stringAdditions.h> brings in the same
// generated interface.

public extension NSString {

    @objc(numericCompare:)
    func numericCompare(_ aString: NSString?) -> ComparisonResult {
        let options: NSString.CompareOptions = [.numeric, .caseInsensitive]
        guard let aString else {
            // A sort descriptor passes nil for an attribute that is not set.
            // Swift cannot hand nil to -compare:options:, so the call goes
            // through the method itself, which answers as it did before.
            typealias Compare = @convention(c) (NSString, Selector, NSString?, NSString.CompareOptions) -> ComparisonResult
            let selector = #selector(NSString.compare(_:options:))
            let compare = unsafeBitCast(method(for: selector), to: Compare.self)
            return compare(self, selector, nil, options)
        }
        return compare(aString as String, options: options)
    }
}
