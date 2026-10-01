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
import Accelerate

/// Given a volume, generates its projection through the Z (depth) direction.
///
/// Implemented in Swift since #719: the Objective-C name, the selectors and
/// <Horos/CPRProjectionOperation.h>, which keeps the CPRProjectionMode enum,
/// are those of the former class.
///
/// @unchecked Sendable, restated from Operation: the generator sets
/// `volumeData` and `projectionMode` before it queues the operation and not
/// after; `generatedVolume` is written by `main()` and read by the generator's
/// observer when the operation reports it has finished, on the thread that
/// finished it.
@objc(CPRProjectionOperation)
public final class CPRProjectionOperation: Operation, @unchecked Sendable {
    @objc public var volumeData: CPRVolumeData?
    @objc public private(set) var generatedVolume: CPRVolumeData?
    @objc public var projectionMode: CPRProjectionMode

    @objc public override init() {
        projectionMode = CPRProjectionMode(CPRProjectionModeNone.rawValue)
        super.init()
    }

    public override func main() {
        autoreleasepool {
            // The former @try/@catch (...) ended the operation quietly.
            try? HorosObjCException.perform { self.project() }
        }
    }

    private func project() {
        if isCancelled {
            return
        }

        if projectionMode == CPRProjectionMode(CPRProjectionModeNone.rawValue) {
            generatedVolume = volumeData
            return
        }

        // A nil volume behaves as a message to nil did: zero sizes, no data.
        let pixelsWide = volumeData?.pixelsWide ?? 0
        let pixelsHigh = volumeData?.pixelsHigh ?? 0
        let pixelsDeep = volumeData?.pixelsDeep ?? 0
        let pixelsPerPlane = Int(pixelsWide) &* Int(pixelsHigh)
        let floatBytes = malloc(MemoryLayout<Float>.size &* pixelsPerPlane)!.assumingMemoryBound(to: Float.self)

        var inlineBuffer = CPRVolumeDataInlineBuffer()
        if volumeData?.aquireInlineBuffer(&inlineBuffer) ?? false {
            let planes = CPRVolumeDataFloatBytes(&inlineBuffer)
            memcpy(floatBytes, planes, MemoryLayout<Float>.size &* pixelsPerPlane)
            let count = vDSP_Length(pixelsPerPlane)
            switch projectionMode {
            case CPRProjectionMode(CPRProjectionModeMIP.rawValue):
                var i = 1
                while UInt(i) < UInt(pixelsDeep) {
                    if isCancelled {
                        break
                    }
                    vDSP_vmax(floatBytes, 1, planes! + i &* pixelsPerPlane, 1, floatBytes, 1, count)
                    i += 1
                }
            case CPRProjectionMode(CPRProjectionModeMinIP.rawValue):
                var i = 1
                while UInt(i) < UInt(pixelsDeep) {
                    if isCancelled {
                        break
                    }
                    vDSP_vmin(floatBytes, 1, planes! + i &* pixelsPerPlane, 1, floatBytes, 1, count)
                    i += 1
                }
            case CPRProjectionMode(CPRProjectionModeMean.rawValue):
                var i = 1
                while UInt(i) < UInt(pixelsDeep) {
                    if isCancelled {
                        break
                    }
                    var floati = Float(i)
                    vDSP_vavlin(planes! + i &* pixelsPerPlane, 1, &floati, floatBytes, 1, count)
                    i += 1
                }
            default:
                break
            }
        } else {
            // A volume whose data is gone projects to zeros, as a failed fill
            // does: the output was returned with the malloc'd bytes as they
            // were (#773).
            memset(floatBytes, 0, MemoryLayout<Float>.size &* pixelsPerPlane)
        }
        volumeData?.releaseInlineBuffer(&inlineBuffer)

        let volumeTransform = N3AffineTransformConcat(volumeData?.volumeTransform ?? N3AffineTransform(),
                                                      N3AffineTransformMakeScale(1.0, 1.0, 1.0 / CGFloat(pixelsDeep)))
        generatedVolume = CPRVolumeData(floatBytesNoCopy: floatBytes, pixelsWide: numericCast(pixelsWide), pixelsHigh: numericCast(pixelsHigh), pixelsDeep: 1,
                                        volumeTransform: volumeTransform, outOfBoundsValue: volumeData?.outOfBoundsValue ?? 0, freeWhenDone: true)
    }
}
