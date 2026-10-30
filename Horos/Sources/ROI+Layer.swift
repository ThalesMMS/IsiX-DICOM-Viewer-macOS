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

// A layer ROI: an image laid over the view (a scale, a ruler, a picture),
// drawn from its ARGB pixels (ROILayerPixels in IsiXROI) on the four corners
// it is dragged, rotated and resized by, and archived as PNG.
extension ROI {

    /// Forgets the layer's pixels: they are made again when it is drawn.
    @objc public func forgetLayerPixels() {
        ctxArray?.removeAllObjects()
        textArray?.removeAllObjects()
    }

    /// Takes `image` as the layer, at its size in the image's pixels.
    func setLayerImageValue(_ image: NSImage?) {
        _layerImage = image
        _isLayerOpacityConstant = true
        _canColorizeLayer = false

        let imageSize = image?.size ?? .zero
        let imageWidth = Float(imageSize.width), imageHeight = Float(imageSize.height)
        var scaleFactorX: Float = 1.0, scaleFactorY: Float = 1.0
        if _pixelSpacingX != 0 && _pixelSpacingY != 0 {
            scaleFactorX = Float(Double(_layerPixelSpacingX) / _pixelSpacingX)
            scaleFactorY = Float(Double(_layerPixelSpacingY) / _pixelSpacingY)
        }
        let corners = [NSPoint(x: 0, y: 0),
                       NSPoint(x: CGFloat(imageWidth * scaleFactorX), y: 0),
                       NSPoint(x: CGFloat(imageWidth * scaleFactorX), y: CGFloat(imageHeight * scaleFactorY)),
                       NSPoint(x: 0, y: CGFloat(imageHeight * scaleFactorY))]
        _points.setArray(corners.map { MyPoint(point: $0) as Any })

        generateEncodedLayerImage()
        computeLayerPixels()
    }

    /// The layer's ARGB pixels, kept in the texture buffer, from its image.
    @objc public func computeLayerPixels() {
        guard let tiff = _layerImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
            // No image: no pixels, as an empty bitmap gave none.
            if let old = mask.buffer { free(old) }
            mask.buffer = nil
            textureBufferHasChanged()
            setLayerPixelsMarker(width: 0, height: 0, bytesPerRow: 0)
            return
        }
        let height = bitmap.pixelsHigh, width = bitmap.pixelsWide

        if let old = mask.buffer { free(old) }
        mask.buffer = nil
        textureBufferHasChanged()

        var bytesPerRow = Int(Int32(truncatingIfNeeded: bitmap.bytesPerRow))
        if let samples = bitmap.bitmapData {
            let pixels = ROILayerPixels.argb(from: samples, height: height, bytesPerRow: bitmap.bytesPerRow, samplesPerPixel: bitmap.samplesPerPixel,
                                             opacity: _opacity, constantOpacity: _isLayerOpacityConstant)
            mask.buffer = pixels.bytes
            bytesPerRow = pixels.bytesPerRow
        }

        if _canColorizeLayer, let layerColor, let bytes = mask.buffer {
            ROILayerPixels.colorize(bytes, width: width, height: height, bytesPerRow: bytesPerRow,
                                    red: Double(layerColor.redComponent), green: Double(layerColor.greenComponent), blue: Double(layerColor.blueComponent),
                                    opacity: _opacity)
        }
        setLayerPixelsMarker(width: Int32(truncatingIfNeeded: width), height: Int32(truncatingIfNeeded: height),
                             bytesPerRow: Int32(truncatingIfNeeded: bytesPerRow))
    }

    /// The canvas draws the pixels; nothing is uploaded. The marker keeps
    /// them until something invalidates the layer.
    private func setLayerPixelsMarker(width: Int32, height: Int32, bytesPerRow: Int32) {
        layerPixelsWidth = width
        layerPixelsHeight = height
        layerPixelsRowBytes = bytesPerRow
        ctxArray?.removeAllObjects()
        textArray?.removeAllObjects()
        ctxArray?.add(NSNull())
        textArray?.add(NSNumber(value: 0))
    }

    /// The layer's image as PNG, as it is archived: compressed when large.
    @objc public func generateEncodedLayerImage() {
        guard let layerImage = _layerImage, let tiff = layerImage.tiffRepresentation, let imageRep = NSBitmapImageRep(data: tiff) else {
            layerImageJPEG = nil
            return
        }
        let size = layerImage.size
        let factor: Float = size.height > 512 && size.width > 512 ? 0.3 : 1.0
        layerImageJPEG = imageRep.representation(using: .png, properties: [.compressionFactor: NSNumber(value: factor)]) as NSData?
    }

    /// Whether `point` is inside the quadrilateral of the four points.
    @objc(isPoint:inRectDefinedByPointA:pointB:pointC:pointD:)
    @discardableResult
    public func isPoint(_ point: NSPoint, inRectDefinedByPointA pointA: NSPoint, pointB: NSPoint, pointC: NSPoint, pointD: NSPoint) -> Bool {
        let path = NSBezierPath()
        path.move(to: pointA)
        path.line(to: pointB)
        path.line(to: pointC)
        path.line(to: pointD)
        path.close()
        return path.contains(point)
    }

    /// `point` turned by `alpha` degrees around `center`.
    @objc(rotatePoint:withAngle:aroundCenter:)
    @discardableResult
    public func rotatePoint(_ point: NSPoint, withAngle alpha: Float, aroundCenter center: NSPoint) -> NSPoint {
        let alphaRad = Double(alpha * ROI.deg2rad)
        let dx = Double(point.x - center.x), dy = Double(point.y - center.y)
        let x = Float((-(sin(alphaRad) * dy)).addingProduct(cos(alphaRad), dx))
        let y = Float((cos(alphaRad) * dy).addingProduct(sin(alphaRad), dx))
        return NSPoint(x: CGFloat(x) + center.x, y: CGFloat(y) + center.y)
    }
}
