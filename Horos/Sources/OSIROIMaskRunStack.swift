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
//
//  OISROIMaskStack.m
//  OsiriX_Lion
//
//  Created by Joël Spaltenstein on 9/25/12.
//  Copyright (c) 2012 OsiriX Team. All rights reserved.
//


import Foundation

/// A stack of mask runs over a sorted run array: pushed runs are popped first,
/// then the runs of the array in order.
///
/// Implemented in Swift since #719: the Objective-C name, the selectors and
/// <Horos/OSIROIMaskRunStack.h> are those of the former class.
@objc(OSIROIMaskRunStack)
public final class OSIROIMaskRunStack: NSObject {
    private let _maskRunData: NSData?
    private let maskRunCount: UInt
    private var _maskRunIndex: UInt = 0
    private let _maskRunArray = NSMutableArray()

    @objc(initWithMaskRunData:)
    public init(maskRunData: NSData?) {
        _maskRunData = maskRunData
        maskRunCount = UInt((maskRunData?.length ?? 0) / MemoryLayout<OSIROIMaskRun>.size)
        super.init()
    }

    /// -init of NSObject left the stack without data and empty.
    @objc public override convenience init() {
        self.init(maskRunData: nil)
    }

    @objc public func currentMaskRun() -> OSIROIMaskRun {
        if _maskRunArray.count != 0 {
            return (_maskRunArray.lastObject as! NSValue).osiroiMaskRun()
        } else if _maskRunIndex < maskRunCount {
            return _maskRunData!.bytes.assumingMemoryBound(to: OSIROIMaskRun.self)[Int(_maskRunIndex)]
        } else {
            cprVolumeDataAssert(false)
            return OSIROIMaskRunZero
        }
    }

    @objc(pushMaskRun:)
    public func pushMaskRun(_ maskRun: OSIROIMaskRun) {
        _maskRunArray.add(NSValue(osiroiMaskRun: maskRun)!)
    }

    @discardableResult
    @objc public func popMaskRun() -> OSIROIMaskRun {
        let maskRun: OSIROIMaskRun

        if _maskRunArray.count != 0 {
            maskRun = (_maskRunArray.lastObject as! NSValue).osiroiMaskRun()
            _maskRunArray.removeLastObject()
        } else if _maskRunIndex < maskRunCount {
            maskRun = _maskRunData!.bytes.assumingMemoryBound(to: OSIROIMaskRun.self)[Int(_maskRunIndex)]
            _maskRunIndex += 1
        } else {
            cprVolumeDataAssert(false)
            maskRun = OSIROIMaskRunZero
        }

        return maskRun
    }

    @objc public func count() -> UInt {
        return UInt(_maskRunArray.count) &+ (maskRunCount &- _maskRunIndex)
    }
}
