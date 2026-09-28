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

/// Locks an object (an NSLocking one, such as a persistent store coordinator)
/// for as long as the N2Locker lives: it unlocks it when it is released.
///
/// Implemented in Swift since #710: the Objective-C name, the selectors
/// and <Horos/N2Locker.h> are those of the former class.
@objc(N2Locker)
public final class N2Locker: NSObject {
    private let lockedObject: AnyObject?

    @objc(lock:)
    @discardableResult
    public static func lock(_ lockedObject: Any?) -> N2Locker {
        return N2Locker(lockedObject: lockedObject)
    }

    /// Not in the header; kept reachable by its selector.
    @objc(initWithLockedObject:)
    public init(lockedObject: Any?) {
        self.lockedObject = lockedObject.map { $0 as AnyObject }
        super.init()
        // -lock and -unlock are sent by message, as before, to whatever object
        // was given.
        _ = self.lockedObject?.perform(#selector(NSLocking.lock))
    }

    deinit {
        _ = lockedObject?.perform(#selector(NSLocking.unlock))
    }
}
