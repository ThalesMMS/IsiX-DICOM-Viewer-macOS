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

// NSArray (N2) and NSMutableArray (N2) are implemented in Swift.
// The selectors and <Horos/NSArray+N2.h> are those of the former
// categories.

public extension NSArray {

    @objc(splitArrayIntoArraysOfMinSize:maxArrays:)
    func splitArrayIntoArrays(ofMinSize minSize: UInt, maxArrays: UInt) -> NSArray {
        let chunks = NSMutableArray()

        for rangeValue in splitArrayIntoChunks(ofMinSize: minSize, maxChunks: maxArrays) {
            chunks.add(subarray(with: (rangeValue as! NSValue).rangeValue))
        }

        return chunks
    }

    @objc(splitArrayIntoChunksOfMinSize:maxChunks:)
    func splitArrayIntoChunks(ofMinSize minSize: UInt, maxChunks: UInt) -> NSArray {
        let count = UInt(self.count)
        // MAX(minSize, round(float(count)/maxChunks)) is a float, truncated
        // back to NSUInteger.
        var size = minSize
        if maxChunks != 0 {
            let rounded = (Float(count) / Float(maxChunks)).rounded()
            let floatMinSize = Float(minSize)
            let larger = floatMinSize < rounded ? rounded : floatMinSize
            size = larger >= Float(UInt.max) ? UInt.max : UInt(larger)
        }

        let chunks = NSMutableArray()

        var location = 0 as UInt, length = size
        var i: UInt = 0
        repeat {
            i &+= 1
            if i == maxChunks {
                length = count &- location
            } else if location &+ length > count {
                length = count &- location
            }
            chunks.add(NSValue(range: NSRange(location: Int(bitPattern: location), length: Int(bitPattern: length))))
            location &+= length
        } while location < count

        return chunks
    }
}

public extension NSMutableArray {

    @objc(addUniqueObjectsFromArray:)
    func addUniqueObjects(from array: NSArray?) {
        guard let array else { return }
        for obj in array {
            if !contains(obj) {
                add(obj)
            }
        }
    }
}
