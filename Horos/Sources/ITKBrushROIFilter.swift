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

import Accelerate
import Foundation
import IsiXSegmentation

/// The morphology filters of brush ROIs: erode, dilate, open and close, by a
/// disc of the radius asked (IsiXSegmentation's MorphologyKernel), with
/// vImage's Planar8 erosion and dilation on the ROI's texture.
///
/// -[ViewerController applyMorphology:...] runs one operation per ROI on a
/// concurrent queue, all with one filter. Each element is drawn once per side,
/// under the filter's lock, and published only once complete: no operation
/// sees a half-drawn element or draws a second one.
@objc(ITKBrushROIFilter)
public final class ITKBrushROIFilter: NSObject, @unchecked Sendable {

    private let lock = NSLock()
    private var erosionElements: [Int: [UInt8]] = [:]
    private var dilationElements: [Int: [UInt8]] = [:]

    /// The erosion or dilation element of side `side`.
    private func element(side: Int, erosion: Bool) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        if let element = erosion ? erosionElements[side] : dilationElements[side] {
            return element
        }
        let element = erosion ? MorphologyKernel.erosion(side: side) : MorphologyKernel.dilation(side: side)
        if erosion {
            erosionElements[side] = element
        } else {
            dilationElements[side] = element
        }
        return element
    }

    /// Runs vImage's erosion or dilation by the element of `side` over the
    /// ROI's texture, in place.
    private func filter(_ roi: ROI, side: Int, erosion: Bool) {
        let width = Int(roi.textureWidth), height = Int(roi.textureHeight)
        guard side > 0, width > 0, height > 0, let buffer = roi.textureBuffer else { return }
        let kernel = element(side: side, erosion: erosion)
        guard let filtered = malloc(height * width) else { return }
        defer { free(filtered) }

        var source = vImage_Buffer(data: buffer, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
        var destination = vImage_Buffer(data: filtered, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
        let error = kernel.withUnsafeBufferPointer { element -> vImage_Error in
            if erosion {
                return vImageErode_Planar8(&source, &destination, 0, 0, element.baseAddress!, vImagePixelCount(side), vImagePixelCount(side),
                                           vImage_Flags(kvImageDoNotTile))
            }
            return vImageDilate_Planar8(&source, &destination, 0, 0, element.baseAddress!, vImagePixelCount(side), vImagePixelCount(side),
                                        vImage_Flags(kvImageDoNotTile))
        }
        if error != 0 { NSLog("%d", Int32(truncatingIfNeeded: error)) }

        memcpy(buffer, filtered, width * height)
    }

    @objc(erode:withStructuringElementRadius:)
    public func erode(_ aROI: ROI?, withStructuringElementRadius structuringElementRadius: Int32) {
        guard let aROI else { return }
        filter(aROI, side: Int(MorphologyKernel.side(radius: structuringElementRadius)), erosion: true)
        aROI.textureBufferHasChanged()
        _ = aROI.reduceTextureIfPossible()
    }

    @objc(dilate:withStructuringElementRadius:)
    public func dilate(_ aROI: ROI?, withStructuringElementRadius structuringElementRadius: Int32) {
        guard let aROI else { return }
        // A margin, so that the region can grow past the texture's edges.
        aROI.addMargin(toBuffer: structuringElementRadius &* 2)
        filter(aROI, side: Int(MorphologyKernel.side(radius: structuringElementRadius)), erosion: false)
        _ = aROI.reduceTextureIfPossible()
    }

    @objc(close:withStructuringElementRadius:)
    public func close(_ aROI: ROI?, withStructuringElementRadius structuringElementRadius: Int32) {
        dilate(aROI, withStructuringElementRadius: structuringElementRadius)
        erode(aROI, withStructuringElementRadius: structuringElementRadius)
    }

    @objc(open:withStructuringElementRadius:)
    public func open(_ aROI: ROI?, withStructuringElementRadius structuringElementRadius: Int32) {
        erode(aROI, withStructuringElementRadius: structuringElementRadius)
        dilate(aROI, withStructuringElementRadius: structuringElementRadius)
    }
}
