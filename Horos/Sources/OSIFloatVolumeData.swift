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

/// A volume in the three natural dimensions. Objects of this class strictly
/// represent float intensity data.
///
/// Implemented in Swift since #719: the Objective-C name, the selectors and
/// <Horos/OSIFloatVolumeData.h> are those of the former class. The former header
/// redeclared the geometry and accessors of CPRVolumeData; the overrides below
/// only call super, so that the generated interface declares them again.
@objc(OSIFloatVolumeData)
public final class OSIFloatVolumeData: CPRVolumeData {
    @objc public override var pixelsWide: UInt { super.pixelsWide }
    @objc public override var pixelsHigh: UInt { super.pixelsHigh }
    @objc public override var pixelsDeep: UInt { super.pixelsDeep }

    // the smallet pixel spacing in any direction;
    @objc public override var minPixelSpacing: CGFloat { super.minPixelSpacing }
    @objc public override var pixelSpacingX: CGFloat { super.pixelSpacingX }
    @objc public override var pixelSpacingY: CGFloat { super.pixelSpacingY }
    @objc public override var pixelSpacingZ: CGFloat { super.pixelSpacingZ }

    // volumeTransform is the transform from Dicom (patient) space to pixel data coordinates.
    @objc public override var volumeTransform: N3AffineTransform { super.volumeTransform }

    @discardableResult
    @objc(getFloatRun:atPixelCoordinateX:y:z:length:)
    public override func getFloatRun(_ buffer: UnsafeMutablePointer<Float>!, atPixelCoordinateX x: UInt, y: UInt, z: UInt, length: UInt) -> Bool {
        return super.getFloatRun(buffer, atPixelCoordinateX: x, y: y, z: z, length: length)
    }

    // returns YES if the float was sucessfully gotten
    @discardableResult
    @objc(getFloat:atPixelCoordinateX:y:z:)
    public override func getFloat(_ floatPtr: UnsafeMutablePointer<Float>!, atPixelCoordinateX x: UInt, y: UInt, z: UInt) -> Bool {
        return super.getFloat(floatPtr, atPixelCoordinateX: x, y: y, z: z)
    }

    // these are slower, use the inline buffer if you care about speed
    @discardableResult
    @objc(getLinearInterpolatedFloat:atDicomVector:)
    public override func getLinearInterpolatedFloat(_ floatPtr: UnsafeMutablePointer<Float>!, atDicomVector vector: N3Vector) -> Bool {
        return super.getLinearInterpolatedFloat(floatPtr, atDicomVector: vector)
    }

    // returns true if the ROI mask is entirely with the float volume;
    @objc(checkDebugROIMask:)
    public func checkDebugROIMask(_ roiMask: OSIROIMask?) -> Bool {
        let pixelsWide = self.pixelsWide
        let pixelsHigh = self.pixelsHigh
        let pixelsDeep = self.pixelsDeep

        for case let maskRunValue as NSValue in roiMask?.maskRuns() ?? NSArray() {
            let maskRun = maskRunValue.osiroiMaskRun()

            if maskRun.depthIndex >= pixelsDeep || maskRun.heightIndex >= pixelsHigh ||
                maskRun.widthRange.location &+ maskRun.widthRange.length >= pixelsWide {
                return false
            }
        }
        return true
    }
}
