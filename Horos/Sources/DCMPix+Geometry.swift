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
import AppKit
import Foundation
import IsiXImaging

/// Where an image lies and how it is drawn turned: its orientation, the
/// conversions between its pixels, the patient and its slice, the origins of
/// two images compared, and the images it renders rotated, scaled, flipped,
/// merged and copied. The arithmetic is IsiXImaging's
/// (ImagePlaneCoordinates, ImageRendering); this reads and writes the image.
extension DCMPix {
    private var orientationPointer: UnsafePointer<Double> { UnsafePointer(horos_orientation) }

    // MARK: - Orientation

    /// The nine values of the orientation: rows, columns, normal.
    @objc(orientationDouble:)
    public dynamic func orientationDouble(_ c: UnsafeMutablePointer<Double>!) {
        checkLoad()
        for i in 0..<9 { c[i] = horos_orientation[i] }
    }

    /// The nine values of the orientation, in single precision.
    @objc(orientation:)
    public dynamic func orientation(_ c: UnsafeMutablePointer<Float>!) {
        checkLoad()
        for i in 0..<9 { c[i] = Float(horos_orientation[i]) }
    }

    /// Takes the row and column cosines (six values), made unit, and their unit normal.
    @objc(setOrientationDouble:)
    public dynamic func setOrientationDouble(_ c: UnsafeMutablePointer<Double>!) {
        ImagePlaneGeometryFunctions.setOrientation(horos_orientation, fromCosines: c)
    }

    /// Takes the row and column cosines (six values) in single precision.
    @objc(setOrientation:)
    public dynamic func setOrientation(_ c: UnsafeMutablePointer<Float>!) {
        var d = [Double](repeating: 0, count: 6)
        for i in 0..<6 { d[i] = Double(c[i]) }
        setOrientationDouble(&d)
    }

    /// Whether `c` has this image's orientation, within 0.001 for each value.
    @objc(identicalOrientationTo:)
    public dynamic func identicalOrientation(to c: DCMPix!) -> Bool {
        var o = [Double](repeating: 0, count: 9)
        c?.orientationDouble(&o)
        for i in 0..<9 where abs(o[i] - horos_orientation[i]) > 0.001 {
            return false
        }
        return true
    }

    /// Whether the orientation has a normal: a plane placed by its cosines.
    @objc(is3DPlane)
    public dynamic func is3DPlane() -> Bool {
        horos_orientation[6] != 0 || horos_orientation[7] != 0 || horos_orientation[8] != 0
    }

    /// The orientation of this image flipped and turned by `rotation` degrees
    /// in a view, into nine floats.
    @objc(orientationCorrected:rotation:xFlipped:yFlipped:)
    public dynamic func orientationCorrected(_ correctedOrientation: UnsafeMutablePointer<Float>!, rotation: Float,
                                             xFlipped: Bool, yFlipped: Bool) {
        var o = [Float](repeating: 0, count: 9)
        orientation(&o)
        let corrected = ImagePlaneCoordinates.correctedOrientation(o, rotation: rotation, xFlipped: xFlipped, yFlipped: yFlipped)
        for i in 0..<9 { correctedOrientation[i] = corrected[i] }
    }

    // MARK: - Pixel, patient and slice coordinates

    /// The patient coordinates (mm) of pixel (x, y); with `pixelCenter`, of its centre.
    @objc(convertPixX:pixY:toDICOMCoords:pixelCenter:)
    public dynamic func convertX(_ x: Float, pixY y: Float, toDICOMCoords d: UnsafeMutablePointer<Float>!, pixelCenter: Bool) {
        let p = ImagePlaneCoordinates.patientPoint(x: x, y: y, pixelCenter: pixelCenter,
                                                   originX: horos_originX, originY: horos_originY, originZ: horos_originZ,
                                                   orientation: orientationPointer, spacingX: horos_pixelSpacingX, spacingY: horos_pixelSpacingY)
        d[0] = p.x; d[1] = p.y; d[2] = p.z
    }

    @objc(convertPixX:pixY:toDICOMCoords:)
    public dynamic func convertX(_ x: Float, pixY y: Float, toDICOMCoords d: UnsafeMutablePointer<Float>!) {
        convertX(x, pixY: y, toDICOMCoords: d, pixelCenter: true)
    }

    @objc(convertPixDoubleX:pixY:toDICOMCoords:pixelCenter:)
    public dynamic func convertDoubleX(_ x: Double, pixY y: Double, toDICOMCoords d: UnsafeMutablePointer<Double>!, pixelCenter: Bool) {
        let p = ImagePlaneCoordinates.patientPoint(x: x, y: y, pixelCenter: pixelCenter,
                                                   originX: horos_originX, originY: horos_originY, originZ: horos_originZ,
                                                   orientation: orientationPointer, spacingX: horos_pixelSpacingX, spacingY: horos_pixelSpacingY)
        d[0] = p.x; d[1] = p.y; d[2] = p.z
    }

    @objc(convertPixDoubleX:pixY:toDICOMCoords:)
    public dynamic func convertDoubleX(_ x: Double, pixY y: Double, toDICOMCoords d: UnsafeMutablePointer<Double>!) {
        convertDoubleX(x, pixY: y, toDICOMCoords: d, pixelCenter: true)
    }

    /// A patient point (mm) in this slice's axes; with `pixelCenter`, from the
    /// first pixel's corner.
    @objc(convertDICOMCoords:toSliceCoords:pixelCenter:)
    public dynamic func convertDICOMCoords(_ dc: UnsafeMutablePointer<Float>!, toSliceCoords sc: UnsafeMutablePointer<Float>!, pixelCenter: Bool) {
        let s = ImagePlaneCoordinates.slicePoint(SIMD3(dc[0], dc[1], dc[2]), pixelCenter: pixelCenter,
                                                 originX: horos_originX, originY: horos_originY, originZ: horos_originZ,
                                                 orientation: orientationPointer, spacingX: horos_pixelSpacingX, spacingY: horos_pixelSpacingY)
        sc[0] = s.x; sc[1] = s.y; sc[2] = s.z
    }

    @objc(convertDICOMCoords:toSliceCoords:)
    public dynamic func convertDICOMCoords(_ dc: UnsafeMutablePointer<Float>!, toSliceCoords sc: UnsafeMutablePointer<Float>!) {
        convertDICOMCoords(dc, toSliceCoords: sc, pixelCenter: true)
    }

    @objc(convertDICOMCoordsDouble:toSliceCoords:pixelCenter:)
    public dynamic func convertDICOMCoordsDouble(_ dc: UnsafeMutablePointer<Double>!, toSliceCoords sc: UnsafeMutablePointer<Double>!,
                                                 pixelCenter: Bool) {
        let s = ImagePlaneCoordinates.slicePoint(SIMD3(dc[0], dc[1], dc[2]), pixelCenter: pixelCenter,
                                                 originX: horos_originX, originY: horos_originY, originZ: horos_originZ,
                                                 orientation: orientationPointer, spacingX: horos_pixelSpacingX, spacingY: horos_pixelSpacingY)
        sc[0] = s.x; sc[1] = s.y; sc[2] = s.z
    }

    @objc(convertDICOMCoordsDouble:toSliceCoords:)
    public dynamic func convertDICOMCoordsDouble(_ dc: UnsafeMutablePointer<Double>!, toSliceCoords sc: UnsafeMutablePointer<Double>!) {
        convertDICOMCoordsDouble(dc, toSliceCoords: sc, pixelCenter: true)
    }

    /// The patient coordinates of the image's centre pixel.
    @objc(getSliceCenter3DCoords:)
    public dynamic func getSliceCenter3DCoords(_ center: UnsafeMutablePointer<Float>!) {
        guard let center else { return }
        convertX(Float(pwidth / 2), pixY: Float(pheight / 2), toDICOMCoords: center)
    }

    /// The index of the image of `pixList` whose plane is nearest to a patient
    /// point, and that point in its slice coordinates.
    @objc(nearestSliceInPixelList:withDICOMCoords:sliceCoords:)
    public static dynamic func nearestSlice(inPixelList pixList: [Any]!, withDICOMCoords dicomCoords: UnsafeMutablePointer<Float>!,
                                            sliceCoords nearestSliceCoords: UnsafeMutablePointer<Float>!) -> Int32 {
        let list = (pixList ?? []) as NSArray
        var nearest: UInt32 = 0
        var minDist = Float.greatestFiniteMagnitude
        for i in 0..<UInt32(truncatingIfNeeded: list.count) {
            var sliceCoords = [Float](repeating: 0, count: 3)
            guard let pix = list.object(at: Int(i)) as? DCMPix else { continue }
            pix.convertDICOMCoords(dicomCoords, toSliceCoords: &sliceCoords)
            if abs(sliceCoords[2]) < minDist {
                minDist = abs(sliceCoords[2])
                for k in 0..<3 { nearestSliceCoords[k] = sliceCoords[k] }
                nearest = i
            }
        }
        return Int32(bitPattern: nearest)
    }

    // MARK: - Origins

    /// The shift, in pixels of `pix2`, from the centre of `pix2` to the centre of `pix1`.
    @objc(originDeltaBetween:And:)
    public static dynamic func originDeltaBetween(_ pix1: DCMPix!, and pix2: DCMPix!) -> NSPoint {
        guard let pix1, let pix2 else { return .zero }
        let destSpacingX = pix1.pixelSpacingX, destSpacingY = pix1.pixelSpacingY
        let senderSpacingX = pix2.pixelSpacingX, senderSpacingY = pix2.pixelSpacingY
        let destOrigin = (pix1.originX, pix1.originY, pix1.originZ)
        let senderOrigin = (pix2.originX, pix2.originY, pix2.originZ)
        if destSpacingX == 0 || destSpacingY == 0 || senderSpacingX == 0 || senderSpacingY == 0 {
            return .zero
        }
        let destWidth = pix1.pwidth, destHeight = pix1.pheight
        var destOrientation = [Double](repeating: 0, count: 9), senderOrientation = [Double](repeating: 0, count: 9)
        pix1.orientationDouble(&destOrientation)
        pix2.orientationDouble(&senderOrientation)
        return destOrientation.withUnsafeBufferPointer { d in
            senderOrientation.withUnsafeBufferPointer { s in
                let destination = ImagePlaneCoordinates.Plane(originX: destOrigin.0, originY: destOrigin.1, originZ: destOrigin.2,
                                                              spacingX: destSpacingX, spacingY: destSpacingY,
                                                              width: destWidth, height: destHeight, orientation: d.baseAddress!)
                let sender = ImagePlaneCoordinates.Plane(originX: senderOrigin.0, originY: senderOrigin.1, originZ: senderOrigin.2,
                                                         spacingX: senderSpacingX, spacingY: senderSpacingY,
                                                         width: pix2.pwidth, height: pix2.pheight, orientation: s.baseAddress!)
                return ImagePlaneCoordinates.originDelta(destination: destination, sender: sender, senderRatio: pix2.pixelRatio)
            }
        }
    }

    /// The image's origin projected on its own row and column cosines.
    @objc(originCorrectedAccordingToOrientation:)
    public static dynamic func originCorrected(accordingToOrientation pix1: DCMPix!) -> NSPoint {
        guard let pix1 else { return .zero }
        var o = [Double](repeating: 0, count: 9)
        pix1.orientationDouble(&o)
        let origin = (pix1.originX, pix1.originY, pix1.originZ)
        return o.withUnsafeBufferPointer {
            ImagePlaneCoordinates.correctedOrigin(originX: origin.0, originY: origin.1, originZ: origin.2, orientation: $0.baseAddress!)
        }
    }

    /// The image's extent in its own plane: its origin and its size in mm
    /// (in pixels when it has no pixel size).
    @objc(rectCoordinates)
    public dynamic func rectCoordinates() -> NSRect {
        if pixelSpacingX != 0 && pixelSpacingY != 0 {
            return NSRect(x: originX, y: originY, width: pixelSpacingX * Double(pwidth), height: pixelSpacingY * Double(pheight))
        }
        return NSRect(x: originX, y: originY, width: Double(pwidth), height: Double(pheight))
    }

    /// `pt` turned by `a` radians around `c`.
    @objc(rotatePoint:aroundPoint:angle:)
    public static dynamic func rotatePoint(_ pt: NSPoint, aroundPoint c: NSPoint, angle a: Float) -> NSPoint {
        ImagePlaneCoordinates.rotate(pt, around: c, angle: a)
    }

    // MARK: - Rendering

    /// The bounds of this image scaled and turned by `r` degrees.
    @objc(usefulRectWithRotation:scale:xFlipped:yFlipped:)
    public dynamic func usefulRect(withRotation r: Float, scale: Float, xFlipped xF: Bool, yFlipped yF: Bool) -> NSRect {
        ImagePlaneCoordinates.usefulRect(width: pwidth, height: pheight, scale: scale, pixelRatio: horos_pixelRatio, rotation: r)
    }

    @objc(renderWithRotation:scale:xFlipped:yFlipped:)
    public dynamic func render(withRotation r: Float, scale: Float, xFlipped xF: Bool, yFlipped yF: Bool) -> DCMPix! {
        render(withRotation: r, scale: scale, xFlipped: xF, yFlipped: yF, backgroundOffset: -1024)
    }

    /// A new image of this one flipped, scaled and turned by `r` degrees, with
    /// its pixel size, orientation and origin; the corners a turn uncovers get
    /// the series' minimum plus `bgO`. Nil for a colour image.
    @objc(renderWithRotation:scale:xFlipped:yFlipped:backgroundOffset:)
    public dynamic func render(withRotation r: Float, scale: Float, xFlipped xF: Bool, yFlipped yF: Bool, backgroundOffset bgO: Float) -> DCMPix! {
        if isRGB { return nil }
        let dstRect = usefulRect(withRotation: r, scale: scale, xFlipped: xF, yFlipped: yF)
        var rot = r * ImagePlaneCoordinates.degreesToRadians
        let scaled = ImagePlaneCoordinates.scaledSize(width: pwidth, height: pheight, scale: scale, pixelRatio: horos_pixelRatio)
        let centerPt = NSPoint(x: Double(scaled.width) / 2, y: Double(scaled.height) / 2)
        let newW = ImagePlaneCoordinates.cInt(Double(dstRect.size.width))
        let newH = ImagePlaneCoordinates.cInt(Double(dstRect.size.height))

        var source = UnsafeMutableRawPointer(computefImage())
        var owned = source != nil && source != UnsafeMutableRawPointer(fImage)
        if shutterEnabled && shutterRect.size.width > 0 && shutterRect.size.height > 0 {
            shutterRect = ImageRendering.shutterRect(shutterRect, width: pwidth, height: pheight)
            if let image = source,
               let masked = ImageRendering.shuttered(image.assumingMemoryBound(to: Float.self), width: pwidth, height: pheight,
                                                     rect: shutterRect, fill: minValueOfSeries - 1024) {
                if owned { free(image) }
                source = UnsafeMutableRawPointer(masked)
                owned = true
            }
        }
        let height = Double(Float(pheight) * scale) * horos_pixelRatio
        guard let data = ImageRendering.rotatedImage(source, ownsSource: owned, width: pwidth, height: pheight,
                                                     xFlipped: xF, yFlipped: yF,
                                                     scaledWidth: ImagePlaneCoordinates.cUnsignedLong(Double(Float(pwidth) * scale)),
                                                     scaledHeight: ImagePlaneCoordinates.cUnsignedLong(height),
                                                     rotation: r, outputWidth: newW, outputHeight: newH,
                                                     background: minValueOfSeries, backgroundOffset: bgO) else { return nil }
        if xF { rot = Float(Double(rot) * -1.0) }
        if yF { rot = Float(Double(rot) * -1.0) }

        guard let newPix = copy() as? DCMPix else { free(data); return nil }
        newPix.freefImage(whenDone: false)
        newPix.fImage = data.assumingMemoryBound(to: Float.self)
        newPix.freefImage(whenDone: true)
        newPix.pheight = Int(newH)
        newPix.pwidth = Int(newW)
        newPix.pixelSpacingX = horos_pixelSpacingX / Double(scale)
        newPix.pixelSpacingY = horos_pixelSpacingX / Double(scale)

        // New orientation
        var v = [Float](repeating: 0, count: 9)
        newPix.orientationCorrected(&v, rotation: r, xFlipped: xF, yFlipped: yF)
        newPix.setOrientation(&v)

        // New origin
        var a = DCMPix.rotatePoint(dstRect.origin, aroundPoint: centerPt, angle: -rot)
        if xF { a.x = Double(scaled.width) - a.x - 1 }
        if yF { a.y = Double(scaled.height) - a.y - 1 }
        var o = [Float](repeating: 0, count: 3)
        convertX(Float(a.x / Double(scale)), pixY: Float(a.y / Double(scale)), toDICOMCoords: &o, pixelCenter: false)
        newPix.setOrigin(&o)
        return newPix
    }

    @objc(renderInRectSize:atPosition:rotation:scale:xFlipped:yFlipped:)
    public dynamic func render(inRectSize rectSize: NSSize, atPosition oo: NSPoint, rotation r: Float, scale: Float,
                               xFlipped xF: Bool, yFlipped yF: Bool) -> DCMPix! {
        render(inRectSize: rectSize, atPosition: oo, rotation: r, scale: scale, xFlipped: xF, yFlipped: yF, smartCrop: true)
    }

    /// This image rendered turned and scaled into a view of `rectSize` with its
    /// centre at `oo` from the view's centre; with `smartCrop`, cut to what of
    /// it the view shows.
    @objc(renderInRectSize:atPosition:rotation:scale:xFlipped:yFlipped:smartCrop:)
    public dynamic func render(inRectSize rectSize: NSSize, atPosition oo: NSPoint, rotation r: Float, scale: Float,
                               xFlipped xF: Bool, yFlipped yF: Bool, smartCrop: Bool) -> DCMPix! {
        if isRGB { return nil }
        guard let newPix = render(withRotation: r, scale: scale, xFlipped: xF, yFlipped: yF, backgroundOffset: 0) else { return nil }
        let src = vImage_Buffer(data: UnsafeMutableRawPointer(newPix.fImage), height: vImagePixelCount(bitPattern: newPix.pheight),
                                width: vImagePixelCount(bitPattern: newPix.pwidth), rowBytes: newPix.pwidth * 4)
        var position = oo
        var size = rectSize
        if xF { position.x = -position.x }
        if yF { position.y = -position.y }
        position = DCMPix.rotatePoint(position, aroundPoint: .zero, angle: -r * ImagePlaneCoordinates.degreesToRadians)

        // zero coordinate is in the center of the view
        var cov = NSPoint(x: size.width / 2 + position.x - Double(newPix.pwidth / 2),
                          y: size.height / 2 - position.y - Double(newPix.pheight / 2))
        if smartCrop {    // remove the black part of the image
            let usefulRect = NSRect(origin: cov, size: NSSize(width: Double(newPix.pwidth), height: Double(newPix.pheight)))
            let smartRect = NSIntersectionRect(NSRect(origin: .zero, size: size), usefulRect)
            size.height = smartRect.size.height
            size.width = smartRect.size.width
            cov.x -= smartRect.origin.x
            cov.y -= smartRect.origin.y
        }
        cov.x = Double(ImagePlaneCoordinates.cInt(Double(cov.x)))
        cov.y = Double(ImagePlaneCoordinates.cInt(Double(cov.y)))

        var dst = vImage_Buffer()
        dst.height = ImagePlaneCoordinates.cUnsignedLong(Double(size.height).rounded(.toNearestOrAwayFromZero))
        dst.width = ImagePlaneCoordinates.cUnsignedLong(Double(size.width).rounded(.toNearestOrAwayFromZero))
        dst.rowBytes = Int(dst.width) * 4
        dst.data = malloc(Int(dst.height) * dst.rowBytes)
        guard dst.data != nil else { return nil }
        var source = src
        drawImage(&source, inImage: &dst, offset: cov, background: minValueOfSeries - 1024)

        guard let rPix = newPix.copy() as? DCMPix else { free(dst.data); return nil }
        rPix.freefImage(whenDone: false)
        rPix.fImage = dst.data.assumingMemoryBound(to: Float.self)
        rPix.freefImage(whenDone: true)
        rPix.pheight = Int(bitPattern: dst.height)
        rPix.pwidth = Int(bitPattern: dst.width)

        // New origin
        var o = [Float](repeating: 0, count: 3)
        rPix.convertX(Float(-cov.x), pixY: Float(-cov.y), toDICOMCoords: &o, pixelCenter: false)
        rPix.setOrigin(&o)
        return rPix
    }

    /// renderInRectSize:... as an image, in the rendered image's own window.
    @objc(renderNSImageInRectSize:atPosition:rotation:scale:xFlipped:yFlipped:)
    public dynamic func renderNSImage(inRectSize rectSize: NSSize, atPosition oo: NSPoint, rotation r: Float, scale: Float,
                                      xFlipped xF: Bool, yFlipped yF: Bool) -> NSImage! {
        if isRGB { return nil }
        let newPix = render(inRectSize: rectSize, atPosition: oo, rotation: r, scale: scale, xFlipped: xF, yFlipped: yF)
        newPix?.changeWLWW(newPix?.wl ?? 0, newPix?.ww ?? 0)
        return newPix?.image()
    }

    /// This image and `o` in one, `o` centred on this one and moved by `oo`
    /// pixels, drawn over it where it is more than 900 above the background,
    /// in this image's window. Nil when either is colour or `o` is nil.
    @objc(mergeWithDCMPix:offset:)
    public dynamic func merge(with o: DCMPix!, offset oo: NSPoint) -> DCMPix! {
        guard let o else { return nil }
        if o.isRGB { return nil }
        if isRGB { return nil }
        var newPix: DCMPix?
        if let exception = HorosObjCException.caught({ newPix = merged(with: o, offset: oo) }) {
            _N2LogExceptionImpl(exception, true, "-[DCMPix mergeWithDCMPix:offset:]")
        }
        return newPix
    }

    private func merged(with o: DCMPix, offset oo: NSPoint) -> DCMPix? {
        let ox = Double(ImagePlaneCoordinates.cInt(Double(oo.x)))
        let oy = Double(ImagePlaneCoordinates.cInt(Double(oo.y)))
        let dstRect = NSRect(x: 0, y: 0, width: Double(pwidth), height: Double(pheight))
        let center = NSPoint(x: Double(pwidth / 2 - o.pwidth / 2), y: Double(pheight / 2 - o.pheight / 2))
        let srcRect = NSRect(x: ox + center.x, y: oy + center.y, width: Double(o.pwidth), height: Double(o.pheight))
        let unionRect = NSUnionRect(dstRect, srcRect)

        var dst = vImage_Buffer()
        dst.height = ImagePlaneCoordinates.cUnsignedLong(Double(unionRect.size.height))
        dst.width = ImagePlaneCoordinates.cUnsignedLong(Double(unionRect.size.width))
        dst.rowBytes = Int(dst.width) * 4
        dst.data = malloc(Int(dst.height) * dst.rowBytes)
        guard dst.data != nil else { return nil }

        // Draw first image
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(fImage), height: vImagePixelCount(bitPattern: pheight),
                                width: vImagePixelCount(bitPattern: pwidth), rowBytes: pwidth * 4)
        drawImage(&src, inImage: &dst, offset: NSPoint(x: -unionRect.origin.x, y: -unionRect.origin.y),
                  background: minValueOfSeries - 1024, transparency: false)

        // Adapt the window level
        if wl != o.wl {
            let diffww = o.ww / ww
            let diffwl = (o.wl - wl) * diffww
            ImageRendering.adaptWindow(dst.data.assumingMemoryBound(to: Float.self), count: Int(bitPattern: dst.height * dst.width),
                                       levelShift: diffwl, widthScale: diffww)
        }

        src = vImage_Buffer(data: UnsafeMutableRawPointer(o.fImage), height: vImagePixelCount(bitPattern: o.pheight),
                            width: vImagePixelCount(bitPattern: o.pwidth), rowBytes: o.pwidth * 4)
        drawImage(&src, inImage: &dst, offset: NSPoint(x: ox + center.x - unionRect.origin.x, y: oy + center.y - unionRect.origin.y),
                  background: minValueOfSeries - 1024, transparency: true)

        // Create final DCMPix
        guard let newPix = copy() as? DCMPix else { free(dst.data); return nil }
        newPix.freefImage(whenDone: false)
        newPix.fImage = dst.data.assumingMemoryBound(to: Float.self)
        newPix.freefImage(whenDone: true)
        newPix.pheight = Int(bitPattern: dst.height)
        newPix.pwidth = Int(bitPattern: dst.width)

        // New origin
        var origin = [Float](repeating: 0, count: 3)
        newPix.convertX(Float(unionRect.origin.x), pixY: Float(unionRect.origin.y), toDICOMCoords: &origin, pixelCenter: false)
        newPix.setOrigin(&origin)
        return newPix
    }

    /// Copies `src` into `dst` at `oo`, over `b` (opaque) or over what is there
    /// where `src` is more than 900 above `b` (transparent).
    @objc(drawImage:inImage:offset:background:transparency:)
    public dynamic func drawImage(_ src: UnsafeMutablePointer<vImage_Buffer>!, inImage dst: UnsafeMutablePointer<vImage_Buffer>!,
                                  offset oo: NSPoint, background b: Float, transparency t: Bool) {
        ImageRendering.draw(src.pointee, into: dst.pointee, offset: oo, background: b, transparency: t)
    }

    @objc(drawImage:inImage:offset:background:)
    public dynamic func drawImage(_ src: UnsafeMutablePointer<vImage_Buffer>!, inImage dst: UnsafeMutablePointer<vImage_Buffer>!,
                                  offset oo: NSPoint, background b: Float) {
        drawImage(src, inImage: dst, offset: oo, background: b, transparency: false)
    }
}
