/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Accelerate
import Foundation
import IsiXImaging

/// The image arithmetic between two series dropped on each other, and the
/// subtraction of a mask (DSA) with its sliders, over IsiXImaging's
/// ImageArithmetic and MaskSubtractionImage. Each image is read with this
/// image's width and height: the other image, or the mask, must have them.
extension DCMPix {

    /// The product with `sub`, in place; an image of another size, from a series
    /// of mixed sizes or a plugin, was read past its end, and is left out.
    final func multiply(by sub: DCMPix?) {
        guard let sub, sub.pwidth == horos_width, sub.pheight == horos_height, let other = sub.fImage, let image = horos_fImage else { return }
        guard let product = multiplyImages(image, other) else { return }
        memcpy(image, product, horos_height * horos_width * MemoryLayout<Float>.size)
        free(product)
    }

    /// The difference with `sub`, in place, under the same condition.
    final func subtract(_ sub: DCMPix?, absolute: Bool) {
        guard let sub, sub.pwidth == horos_width, sub.pheight == horos_height, let other = sub.fImage, let image = horos_fImage else { return }
        guard let difference = arithmeticSubtractImages(image, other, absolute: absolute) else { return }
        memcpy(image, difference, horos_height * horos_width * MemoryLayout<Float>.size)
        free(difference)
    }

    final func product(of input: UnsafeMutablePointer<Float>?, and other: UnsafeMutablePointer<Float>?) -> UnsafeMutablePointer<Float>? {
        guard let input, let other else { return nil }
        return ImageArithmetic.product(input, other, width: horos_width, height: horos_height, offset: horos_subPixOffset)
    }

    final func difference(of input: UnsafeMutablePointer<Float>?, and other: UnsafeMutablePointer<Float>?,
                          absolute: Bool) -> UnsafeMutablePointer<Float>? {
        guard let input, let other else { return nil }
        return ImageArithmetic.difference(input, other, width: horos_width, height: horos_height, offset: horos_subPixOffset,
                                          absolute: absolute)
    }

    /// The sliders of the subtraction, copied to every image of the series.
    final func setSliders(percent p: Float, gamma g: Float, zero z: Float) {
        horos_subtractedfPercent = p
        horos_subtractedfZ = z
        horos_subtractedfZero = MaskSubtractionBridge.zero(percent: p, z: z)
        horos_subtractedfGamma = g
        if let gamma = horos_subGammaFunction { vImageDestroyGammaFunction(gamma) }
        horos_subGammaFunction = vImageCreateGammaFunction(horos_subtractedfGamma, Int32(kvImageGamma_UseGammaValue_half_precision), 0)
        horos_updateToBeApplied = true
    }

    /// The minimum and maximum of the frame less the mask, kept for the display.
    final func maskRange(of input: UnsafeMutablePointer<Float>?, mask: UnsafeMutablePointer<Float>?) -> NSPoint {
        guard let input, let mask else { return horos_subMinMax }
        horos_subMinMax = MaskSubtractionImage.range(frame: input, mask: mask, count: horos_height * horos_width)
        return horos_subMinMax
    }

    /// The frame less the mask, through the sliders: a new buffer, and `input`
    /// freed unless it is the image's own; `input` itself when nothing was made.
    final func subtractMask(_ mask: UnsafeMutablePointer<Float>?, from input: UnsafeMutablePointer<Float>?) -> UnsafeMutablePointer<Float>? {
        guard let input, let mask else { return input }
        guard let result = MaskSubtractionBridge.subtract(frame: input, mask: mask, width: horos_width, height: horos_height,
                                                          offset: horos_subPixOffset, percent: horos_subtractedfPercent,
                                                          zero: horos_subtractedfZero, range: horos_subMinMax) else { return input }
        if input != horos_fImage { free(input) }
        return result
    }
}
