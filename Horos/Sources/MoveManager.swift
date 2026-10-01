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

// MoveManager is implemented in Swift since #716: the Objective-C name, the
// selectors and <Horos/MoveManager.h> are those of the former class. Every
// @synchronized (self) of the Objective-C is objcSynchronized below, around
// the same statements.

/// `@synchronized (object) { … }`: the same recursive lock, left before an
/// exception raised inside goes on.
@inline(__always)
fileprivate func objcSynchronized<T>(_ object: AnyObject, _ body: () -> T) -> T {
    objc_sync_enter(object)
    var result: T?
    var raised: NSException?
    do {
        try HorosObjCException.perform { result = body() }
    } catch {
        raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    objc_sync_exit(object)
    if let raised { raised.raise() }
    return result!
}

/// \brief move manager
// @unchecked Sendable: the query threads share +sharedManager. `_set`, its only
// mutable state, is read and changed only inside objcSynchronized(self), as in
// the Objective-C.
@objc(MoveManager)
public final class MoveManager: NSObject, @unchecked Sendable {
    /// Made once, by whichever thread asks first: a global `let`. The lazy
    /// `var` it replaces could make two when two query threads asked first.
    private static let sharedManagerInstance = MoveManager()

    private let _set = NSMutableSet()

    @objc(sharedManager)
    public class func sharedManager() -> Any! {
        return sharedManagerInstance
    }

    public override init() {
        super.init()
    }

    @objc(addMove:)
    public func addMove(_ move: Any!) {
        objcSynchronized(self) {
            if let move {
                _set.add(move)
            } else {
                // -addObject:nil raised NSInvalidArgumentException.
                _ = _set.perform(#selector(NSMutableSet.add(_:)), with: nil)
            }
        }
    }

    @objc(removeMove:)
    public func removeMove(_ move: Any!) {
        objcSynchronized(self) {
            if let move {
                _set.remove(move)
            } else {
                // -removeObject:nil raised NSInvalidArgumentException.
                _ = _set.perform(#selector(NSMutableSet.remove(_:)), with: nil)
            }
        }
    }

    @objc(containsMove:)
    public func containsMove(_ move: Any!) -> Bool {
        return objcSynchronized(self) {
            // -containsObject:nil answered NO.
            guard let move else { return false }
            return _set.contains(move)
        }
    }
}
