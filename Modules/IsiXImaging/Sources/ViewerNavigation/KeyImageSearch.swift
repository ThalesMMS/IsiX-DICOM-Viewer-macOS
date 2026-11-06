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

/// The "next" and "previous key image" buttons of the 2D viewer: which way
/// they look through the images shown, and where they land in the series
/// they move to when the current one has no further key image.
public enum KeyImageSearch {
    /// Whether the search runs towards the end of the images shown: "next"
    /// (`isPrevious` false) does, and a flipped series shows its images in
    /// reverse.
    public static func runsForward(isPrevious: Bool, flipped: Bool) -> Bool {
        isPrevious == flipped
    }

    /// Whether the series moved to is searched from its last image backwards
    /// (otherwise from its first image forwards): moving to the next series of
    /// a flipped viewer, or to the previous series of an unflipped one.
    public static func startsFromLastImage(nextSeries: Bool, flipped: Bool) -> Bool {
        nextSeries == flipped
    }

    /// The first of `indices` for which `isKey` holds, asking no further.
    public static func firstKeyImage<S: Sequence>(in indices: S, isKey: (Int) -> Bool) -> Int? where S.Element == Int {
        for index in indices where isKey(index) {
            return index
        }
        return nil
    }
}
