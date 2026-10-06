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

import AppKit

// NSBitmapImageRep (N2) is implemented in Swift; the selectors and
// <Horos/NSBitmapImageRep+N2.h> are those of the former category.

/// The C conversion of a sample to NSUInteger as it behaves on arm64: NaN and
/// negative values are 0 and values past the range saturate.
fileprivate func cSample(_ value: CGFloat) -> Int {
    if value.isNaN || value <= 0 { return 0 }
    if value >= CGFloat(UInt.max) { return Int(bitPattern: UInt.max) }
    return Int(bitPattern: UInt(value))
}

public extension NSBitmapImageRep {

    @available(*, deprecated, message: "buggy in Retina...")
    @objc(setColor:)
    func setColor(_ color: NSColor?) {
        let colorSpace = self.colorSpace
        let spp = samplesPerPixel
        var samples = [Int](repeating: 0, count: spp)
        // -getComponents: writes as many components as the colour has; the
        // Objective-C array had spp of them.
        var fsamples = [CGFloat](repeating: 0, count: max(spp, color?.numberOfComponents ?? 0))
        var y = pixelsHigh - 1
        while y >= 0 {
            var x = pixelsWide - 1
            while x >= 0 {
                getPixel(&samples, atX: x, y: y)
                for i in 0..<spp {
                    fsamples[i] = CGFloat(samples[i]) * 1.0 / 255
                }

                var xycolor = NSColor(colorSpace: colorSpace, components: fsamples, count: spp)

                var brightness: CGFloat = 0, alpha: CGFloat = 0
                xycolor.usingColorSpace(.genericRGB)?.getHue(nil, saturation: nil, brightness: &brightness, alpha: &alpha)
                let fixedColor = NSColor(deviceHue: color?.hueComponent ?? 0, saturation: color?.saturationComponent ?? 0,
                                         brightness: max(0.75, brightness), alpha: alpha)

                // Unused, as in the Objective-C: the samples come from `color`.
                xycolor = fixedColor.usingColorSpace(colorSpace) ?? xycolor
                _ = xycolor
                color?.getComponents(&fsamples)
                if hasAlpha {
                    fsamples[spp - 1] = alpha
                }

                for i in 0..<spp {
                    samples[i] = cSample(floor(fsamples[i] * 255))
                }

                setPixel(&samples, atX: x, y: y)
                x -= 1
            }
            y -= 1
        }
    }

    @objc func image() -> NSImage {
        let image = NSImage(size: size)
        image.addRepresentation(copy() as! NSImageRep)
        return image
    }
}
