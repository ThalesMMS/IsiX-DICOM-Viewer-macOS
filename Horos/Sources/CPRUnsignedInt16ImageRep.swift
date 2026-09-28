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

/// 16-bit pixels of a CPR slice, with the window and the geometry of the slice.
///
/// Implemented in Swift since #719: the Objective-C name, the selectors and
/// <Horos/CPRUnsignedInt16ImageRep.h> are those of the former class.
@objc(CPRUnsignedInt16ImageRep)
public final class CPRUnsignedInt16ImageRep: NSImageRep {
    private var _unsignedInt16Data: UnsafeMutablePointer<UInt16>?

    // Zero, as the ivars of an instance made by -init or -initWithCoder: were.
    @objc public var windowWidth: CGFloat = 0 // these will affect how this rep will draw when part of an NSImage
    @objc public var windowLevel: CGFloat = 0

    @objc public var offset: CGFloat = 0
    @objc public var slope: CGFloat = 0
    @objc public var pixelSpacingX: CGFloat = 0
    @objc public var pixelSpacingY: CGFloat = 0
    @objc public var sliceThickness: CGFloat = 0

    @objc public var imageToDicomTransform = N3AffineTransform()

    private var freeWhenDone = false

    /// With a NULL data, the receiver mallocs the pixels and frees them.
    @objc(initWithData:pixelsWide:pixelsHigh:)
    public init?(data: UnsafeMutablePointer<UInt16>?, pixelsWide: UInt, pixelsHigh: UInt) {
        if data == nil {
            let size = Int(bitPattern: UInt(MemoryLayout<UInt16>.size) &* pixelsWide &* pixelsHigh)
            guard let allocated = malloc(size) else {
                return nil
            }
            _unsignedInt16Data = allocated.assumingMemoryBound(to: UInt16.self)
            freeWhenDone = true
        } else {
            _unsignedInt16Data = data
        }
        super.init()

        self.pixelsWide = Int(bitPattern: pixelsWide)
        self.pixelsHigh = Int(bitPattern: pixelsHigh)
        self.size = NSMakeSize(CGFloat(pixelsWide), CGFloat(pixelsHigh))
        offset = 0
        slope = 1
        imageToDicomTransform = N3AffineTransformIdentity
    }

    /// -init of NSImageRep: no pixels.
    @objc public override init() {
        super.init()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        if freeWhenDone {
            free(_unsignedInt16Data)
        }
    }

    public override func draw() -> Bool {
        // assert(false) of the former code, checked in Debug only.
        #if DEBUG
        preconditionFailure("one day it would be cool if this could actually be used as an image rep in an NSImage")
        #else
        return false
        #endif
    }

    @objc public func unsignedInt16Data() -> UnsafeMutablePointer<UInt16>? {
        return _unsignedInt16Data
    }

    // MARK: (DCMPixAndVolume)

    @objc(getOrientation:)
    public func getOrientation(_ orientation: UnsafeMutablePointer<Float>) {
        var doubleOrientation = [Double](repeating: 0, count: 6)

        getOrientationDouble(&doubleOrientation)

        for i in 0..<6 {
            orientation[i] = Float(doubleOrientation[i])
        }
    }

    @objc(getOrientationDouble:)
    public func getOrientationDouble(_ orientation: UnsafeMutablePointer<Double>) {
        let xBasis = N3VectorNormalize(N3VectorMake(imageToDicomTransform.m11, imageToDicomTransform.m12, imageToDicomTransform.m13))
        let yBasis = N3VectorNormalize(N3VectorMake(imageToDicomTransform.m21, imageToDicomTransform.m22, imageToDicomTransform.m23))

        orientation[0] = xBasis.x; orientation[1] = xBasis.y; orientation[2] = xBasis.z
        orientation[3] = yBasis.x; orientation[4] = yBasis.y; orientation[5] = yBasis.z
    }

    @objc public var originX: Float {
        return Float(imageToDicomTransform.m41)
    }

    @objc public var originY: Float {
        return Float(imageToDicomTransform.m42)
    }

    @objc public var originZ: Float {
        return Float(imageToDicomTransform.m43)
    }
}
