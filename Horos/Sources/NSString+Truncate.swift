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
import IsiXImaging

// NSString (Truncate), with the selectors of the former category: the series
// list and the series menu shorten the comments of the studies with it. The
// truncation itself is IsiXImaging's TextTruncation.

extension NSString {
    /// The text cut in the middle to `length` units with "…".
    @objc(stringWithTruncatingToLength:)
    public func withTruncatingToLength(_ length: UInt32) -> String! {
        return truncated(toLength: length, direction: TextTruncation.Direction.middle.rawValue)
    }

    /// The text cut to `length` units with "…", at the start (0), in the
    /// middle (1) or at the end (2).
    @objc(stringTruncatedToLength:direction:)
    public func truncated(toLength length: UInt32, direction truncateFrom: UInt32) -> String! {
        return truncated(toLength: length, direction: truncateFrom, withEllipsisString: "…")
    }

    /// The text cut to `length` units with `ellipsis`, at the start (0), in the
    /// middle (1) or at the end (2); an empty text for another direction.
    @objc(stringTruncatedToLength:direction:withEllipsisString:)
    public func truncated(toLength length: UInt32, direction truncateFrom: UInt32, withEllipsisString ellipsis: String!) -> String! {
        return TextTruncation.truncate(self, toLength: length, direction: truncateFrom, ellipsis: ellipsis as NSString) as String
    }
}
