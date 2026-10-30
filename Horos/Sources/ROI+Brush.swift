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
import IsiXROI

// A brush ROI's mask (ROIBrushMask in IsiXROI): its bytes, cut down to what is
// painted, merged with another brush's, widened, and resampled when the
// image's pixel spacing or origin change; and how the other ROIs follow those
// changes.
extension ROI {

    /// Forgets what was made from the mask: the outline of a selected brush.
    @objc public func textureBufferHasChanged() {
        if let outline = textureBufferSelected {
            free(outline)
            textureBufferSelected = nil
        }
    }

    /// Cuts a brush's mask down to its painted pixels. Answers whether
    /// nothing is painted; true for a ROI that is not a brush.
    @discardableResult
    @objc public func reduceTextureIfPossible() -> Bool {
        if _type != .tPlain { return true }
        let result = mask.reduceIfPossible()
        if result.replaced { textureBufferHasChanged() }
        return result.empty
    }

    /// Adds the pixels of brush `r` to this brush.
    @objc(mergeWithTexture:)
    public func merge(withTexture r: ROI!) {
        guard let r else { return }
        if _type != .tPlain { return }
        if r.type != .tPlain { return }
        if self === r { return }
        mask.merge(with: r.mask)
        textureBufferHasChanged()
    }

    /// Adds `margin` empty pixels around the mask.
    @objc(addMarginToBuffer:)
    public func addMargin(toBuffer margin: Int32) {
        mask.addMargin(margin)
        textureBufferHasChanged()
    }

    /// Takes `t`, `w` × `h` bytes allocated with malloc, as the mask.
    @objc(setTexture:width:height:)
    public func setTexture(_ t: UnsafeMutablePointer<UInt8>!, width w: Int32, height h: Int32) {
        if let old = mask.buffer { free(old) }
        mask.buffer = t
        mask.width = w
        mask.height = h
        textureBufferHasChanged()
    }

    /// A copy of `width` × `height` bytes with `margin` empty pixels around
    /// them, allocated with calloc.
    @objc(addMargin:buffer:width:height:)
    public class func addMargin(_ margin: Int32, buffer: UnsafeMutablePointer<UInt8>!, width: Int32, height: Int32) -> UnsafeMutablePointer<UInt8>! {
        ROIBrushMask.addingMargin(margin, to: buffer, width: width, height: height)
    }

    /// Paints a disc of `val` the size of the `width` × `width` buffer.
    @objc(fillCircle:::)
    public class func fillCircle(_ buf: UnsafeMutablePointer<UInt8>!, _ width: Int32, _ val: UInt8) {
        guard let buf else { return }
        ROIBrushMask.fillCircle(buf, width: width, value: val)
    }

    // MARK: Pixel spacing and origin

    @objc(setOriginAndSpacing::)
    public func setOriginAndSpacing(_ ipixelSpacing: Float, _ iimageOrigin: NSPoint) {
        setOriginAndSpacing(ipixelSpacing, ipixelSpacing, iimageOrigin)
    }

    @objc(setOriginAndSpacing:::)
    public func setOriginAndSpacing(_ ipixelSpacingx: Float, _ ipixelSpacingy: Float, _ iimageOrigin: NSPoint) {
        setOriginAndSpacing(ipixelSpacingx, ipixelSpacingy, iimageOrigin, true)
    }

    @objc(setOriginAndSpacing::::)
    public func setOriginAndSpacing(_ ipixelSpacingx: Float, _ ipixelSpacingy: Float, _ iimageOrigin: NSPoint, _ sendNotification: Bool) {
        setOriginAndSpacing(ipixelSpacingx, ipixelSpacingy, iimageOrigin, sendNotification, true)
    }

    /// Takes the pixel spacing and origin of the image the ROI is now on. A
    /// ROI that had both keeps its place in the patient: its points, rectangle
    /// or mask move and scale to the new pixels. With `inImageCheck`, a ROI
    /// that would leave the image is not moved.
    @objc(setOriginAndSpacing:::::)
    public func setOriginAndSpacing(_ ipixelSpacingx: Float, _ ipixelSpacingy: Float, _ iimageOrigin: NSPoint, _ sendNotification: Bool,
                                    _ inImageCheck: Bool) {
        if ipixelSpacingx == 0 { return }
        if ipixelSpacingy == 0 { return }

        if _pixelSpacingY != 0 && _pixelSpacingX != 0 {
            var change = false
            if _pixelSpacingX != Double(ipixelSpacingx) { change = true }
            if _pixelSpacingY != Double(ipixelSpacingy) { change = true }
            if _imageOrigin.x != iimageOrigin.x || _imageOrigin.y != iimageOrigin.y { change = true }
            if !change { return }

            let ratioX = _pixelSpacingX / Double(ipixelSpacingx), ratioY = _pixelSpacingY / Double(ipixelSpacingy)
            var offset = NSPoint.zero
            let modeSaved = mode
            mode = ROI_selected

            if _type == .tPlain {
                // The height scales by the horizontal ratio, as it always did.
                let oldWidth = mask.width, oldHeight = mask.height
                mask.width = ROIBrushMask.int32(Double(mask.width) * ratioX)
                mask.height = ROIBrushMask.int32(Double(mask.height) * ratioX)
                let newBuffer = ROIBrushMask.rescaled(mask.buffer, width: oldWidth, height: oldHeight, to: mask.width, mask.height)
                mask.upLeftX = ROIBrushMask.int32(Double(mask.upLeftX) * ratioX)
                mask.upLeftY = ROIBrushMask.int32(Double(mask.upLeftY) * ratioY)
                mask.downRightX = mask.upLeftX &+ mask.width
                mask.downRightY = mask.upLeftY &+ mask.height

                offset.x = (_imageOrigin.x - iimageOrigin.x) / CGFloat(_pixelSpacingX)
                offset.y = (_imageOrigin.y - iimageOrigin.y) / CGFloat(_pixelSpacingY)
                offset.x *= CGFloat(ratioX)
                offset.y *= CGFloat(ratioY)
                roiMove(offset, sendNotification)

                if let old = mask.buffer { free(old) }
                mask.buffer = newBuffer
                textureBufferHasChanged()
            } else {
                offset.x = (_imageOrigin.x - iimageOrigin.x) / CGFloat(_pixelSpacingX)
                offset.y = (_imageOrigin.y - iimageOrigin.y) / CGFloat(_pixelSpacingY)
                roiMove(offset, sendNotification)

                if let pix = _pix, inImageCheck {
                    let imRect = NSRect(x: 0, y: 0, width: CGFloat(pix.pwidth), height: CGFloat(pix.pheight))
                    var inImage = false
                    // The vertical position scales by the horizontal ratio here too.
                    for case let pt as MyPoint in self.points
                        where ROI.pointInRect(NSPoint(x: Double(pt.x) * ratioX, y: Double(pt.y) * ratioX), imRect) {
                        inImage = true
                        break
                    }
                    if !inImage { roiMove(NSPoint(x: -offset.x, y: -offset.y), sendNotification) }
                }

                _rect.origin.x *= CGFloat(ratioX)
                _rect.origin.y *= CGFloat(ratioY)
                _rect.size.width *= CGFloat(ratioX)
                _rect.size.height *= CGFloat(ratioY)

                for i in 0..<_points.count {
                    var aPoint = myPoint(i).point
                    aPoint.x *= CGFloat(ratioX)
                    aPoint.y *= CGFloat(ratioY)
                    myPoint(i).point = aPoint
                }
            }
            mode = modeSaved
        }

        _pixelSpacingX = Double(ipixelSpacingx)
        _pixelSpacingY = Double(ipixelSpacingy)
        _imageOrigin = iimageOrigin

        if sendNotification {
            rtotal = -1
            Brtotal = -1
            postChange(nil)
        }
    }
}
