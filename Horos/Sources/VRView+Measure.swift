/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXVolumeRendering

// The measurements of VRView: the length lines (the active one and the stored
// ones, their texts and their projections as the camera moves), the angle of
// three patient points, the oval and its statistics on the full-depth image,
// and the scissors' outline. A Swift extension of the class, with the same
// selectors.
//
// The arithmetic keeps the Objective-C's types; where clang fused a product
// into a sum (a*b + c), the Swift says so with addingProduct.

/// The text of a length line: "Length: " and the length in the preferred unit,
/// in ASCII characters, as VTK draws it.
@MainActor func vrLengthText(_ centimetres: Double) -> String {
    String(format: NSLocalizedString("Length: %@ ", comment: "ONLY ASCII CHARACTERS ! NO ACCENTS OR HIEROGLYPHS"),
           LengthPresentation.asciiString(centimetres: centimetres))
}

extension VRView {

    // MARK: - Oval

    /// The oval's statistics hold for the camera they were taken with: a moved
    /// camera takes the oval away.
    @objc(checkForMovedVolume:)
    func checkForMovedVolume(_ notification: Notification?) {
        var cos = [Float](repeating: 0, count: 9)
        let valid = getCosMatrix(&cos)

        if valid {
            if horos_Oval2DRadius > 0.001 {
                var position = [Float](repeating: 0, count: 3)
                getOrigin(&position)

                var moved = false

                let ovalCos = horos_Oval2DCos
                for i in 0..<9 where ovalCos[i] != cos[i] {
                    moved = true
                }

                let ovalPosition = horos_Oval2DPosition
                for i in 0..<3 where ovalPosition[i] != position[i] {
                    moved = true
                }

                if moved {
                    horos_Oval2DPix = nil

                    horos_vtk.hideOval()
                    horos_Oval2DRadius = 0
                    needsDisplay = true
                }
            }
        }
    }

    // MARK: - Lines

    @objc(captureCurrentLineProjection)
    func captureCurrentLineProjection() {
        horos_vtk.captureLineProjection()
    }

    @objc(updateLineMeasurementProjections)
    func updateLineMeasurementProjections() {
        var wasVisible: ObjCBool = false, visible: ObjCBool = false
        var length: Double = 0
        if !horos_vtk.updateLineProjectionsWasVisible(&wasVisible, visible: &visible, length: &length) { return }
        if wasVisible.boolValue != visible.boolValue && Thread.isMainThread {
            // The hover field otherwise retains the last visible measurement until
            // the mouse moves again, including after a menu-driven camera change.
            pixelInformation?.stringValue = String(format: NSLocalizedString("View Size: %d x %d", comment: ""),
                                                         CConversion.int(Double(frame.size.width)),
                                                         CConversion.int(Double(frame.size.height)))
        }
        if visible.boolValue {
            horos_measureLength = Float(length / (10.0 * Double(horos_factor)))
        } else {
            horos_measureLength = 0
        }
        updateAngleMeasurementProjection()
    }

    // MARK: - Angle

    @objc(updateAngleMeasurementProjection)
    func updateAngleMeasurementProjection() {
        let vtk = horos_vtk
        if !vtk.hasAngleActors { return }
        var visible = false
        var display = [Double](repeating: 0, count: 9)
        var text: String? = nil
        let count = horos_angleMeasurementCount
        let patient = horos_angleMeasurementPatient
        if count > 0 {
            if vtk.projectPatientPoints(patient, count: count, factor: Double(horos_factor), into: &display) {
                visible = true
                if count == 3 {
                    horos_measureAngle = Float(VRMeasurementGeometry.angleDegrees(atX: patient[3], y: patient[4], z: patient[5],
                                                                                  armAX: patient[0], armAY: patient[1], armAZ: patient[2],
                                                                                  armBX: patient[6], armBY: patient[7], armBZ: patient[8]))
                    if horos_measureAngle.isFinite {
                        text = String(format: NSLocalizedString("Angle: %2.1f degrees ", comment: "ONLY ASCII CHARACTERS ! NO ACCENTS OR HIEROGLYPHS"),
                                      Double(horos_measureAngle))
                    } else {
                        horos_measureAngle = 0
                    }
                } else {
                    horos_measureAngle = 0
                }
            }
        }
        if !visible {
            horos_measureAngle = 0
        }
        if let text {
            text.withCString { vtk.showAngleDisplayPoints(display, count: count, text: $0, visible: visible) }
        } else {
            vtk.showAngleDisplayPoints(display, count: count, text: nil, visible: visible)
        }
    }

    @objc(clearAngleMeasurement)
    func clearAngleMeasurement() {
        horos_angleMeasurementCount = 0
        horos_measureAngle = 0
        updateAngleMeasurementProjection()
    }

    /// The patient point (in millimetres) of the volume's surface under a
    /// display point, when there is one.
    @objc(patientPointAtDisplayX:Y:into:)
    func patientPointAtDisplayX(_ x: Float, y: Float, into point: UnsafeMutablePointer<Double>) -> Bool {
        var pix = [Int](repeating: 0, count: 3)
        var pos = [Float](repeating: 0, count: 3)
        var value: Float = 0
        if !get3DPixelUnder2DPositionX(x, y: y, pixel: &pix, position: &pos, value: &value) {
            return false
        }
        if !pos[0].isFinite || !pos[1].isFinite || !pos[2].isFinite {
            return false
        }
        point[0] = Double(pos[0])
        point[1] = Double(pos[1])
        point[2] = Double(pos[2])
        return true
    }

    // MARK: - Stored lines

    /// The stored lines keep a copy of their text: a change of the length
    /// preferences rewrites it from their endpoints, as the active line's is.
    @objc(lengthPresentationDidChange:)
    func lengthPresentationDidChange(_ note: Notification?) {
        let vtk = horos_vtk
        if !vtk.hasRenderer { return }
        var index = 0
        while index < vtk.storedLineCount {
            let centimetres = vtk.storedLineLength(at: index) / (10.0 * Double(horos_factor))
            vrLengthText(centimetres).withCString { vtk.setStoredLineText($0, at: index) }
            index += 1
        }
        if vtk.activeLinePointCount == 2 && vtk.activeLineVisible {
            computeLength()
        }
        needsDisplay = true
    }

    @objc(storeCurrentLineMeasurement)
    func storeCurrentLineMeasurement() {
        horos_vtk.storeActiveLine()
    }

    @objc(clearStoredLineMeasurements)
    func clearStoredLineMeasurements() {
        horos_vtk.clearStoredLines()
    }

    /// The endpoint of a line of two points, `first` and `second`, that a click at
    /// `point` grabs, or -1.
    @objc(editableEndpointAt:first:second:)
    func editableEndpoint(at point: NSPoint, first: UnsafePointer<Double>, second: UnsafePointer<Double>) -> Int {
        VRMeasurementGeometry.editableEndpoint(at: point,
                                               first: NSPoint(x: first[0], y: first[1]), second: NSPoint(x: second[0], y: second[1]),
                                               tolerance: convertToBacking(NSSize(width: 8, height: 8)).width)
    }

    @objc(selectStoredLineMeasurementAt:)
    func selectStoredLineMeasurement(at point: NSPoint) {
        let vtk = horos_vtk
        var first = [Double](repeating: 0, count: 3), second = [Double](repeating: 0, count: 3)
        // The active handle wins at overlaps; otherwise prefer the latest overlay.
        if vtk.activeLineVisible && vtk.activeLinePointCount == 2 {
            vtk.getActiveLinePoint(0, into: &first)
            vtk.getActiveLinePoint(1, into: &second)
            if editableEndpoint(at: point, first: first, second: second) >= 0 { return }
        }
        var index = vtk.storedLineCount - 1
        while index >= 0 {
            defer { index -= 1 }
            if !vtk.storedLineVisible(at: index) || !vtk.getStoredLine(at: index, first: &first, second: &second) { continue }
            if editableEndpoint(at: point, first: first, second: second) < 0 { continue }
            vtk.reactivateStoredLine(at: index)
            computeLength()
            return
        }
    }

    @objc(adaptLine2DToResize:before:cameraZoom:)
    func adaptLine2D(toResize newFrame: NSRect, before beforeFrame: NSRect, cameraZoom: Double) {
        // Line points are VTK display pixels. Preserve their projected world
        // positions as the parallel camera's viewport changes, also for export.
        let oldSize = convertToBacking(beforeFrame.size)
        let newSize = convertToBacking(newFrame.size)
        horos_vtk.remapLinePoints { point in
            VRMeasurementGeometry.resizedPoint(point, from: oldSize, to: newSize, cameraZoom: cameraZoom)
        }
    }

    // MARK: - Texts

    /// The line's length, the oval's statistics and the hover field, after a
    /// change of a measurement or of the camera.
    @objc(computeLength)
    func computeLength() {
        let vtk = horos_vtk
        updateLineMeasurementProjections()

        if vtk.activeLinePointCount == 2 && vtk.activeLineVisible {
            var point1 = [Double](repeating: 0, count: 4), point2 = [Double](repeating: 0, count: 4)

            vtk.getActiveLinePoint(0, into: &point1)
            vtk.getActiveLinePoint(1, into: &point2)

            vtk.worldPoint(ofDisplayX: point1[0], y: point1[1], z: point1[2], into: &point1)

            vtk.worldPoint(ofDisplayX: point2[0], y: point2[1], z: point2[2], into: &point2)

            let xd = point2[0] - point1[0]
            let yd = point2[1] - point1[1]
            let zd = point2[2] - point1[2]
            let length = (yd * yd).addingProduct(xd, xd).addingProduct(zd, zd).squareRoot()

            vtk.getActiveLinePoint(0, into: &point1)
            vtk.getActiveLinePoint(1, into: &point2)

            let localizedText = vrLengthText(length / (10.0 * Double(horos_factor)))

            if point1[0] > point2[0] {
                localizedText.withCString { vtk.placeActiveLineText($0, x: point1[0] + 3, y: point1[1]) }
            } else {
                localizedText.withCString { vtk.placeActiveLineText($0, x: point2[0], y: point2[1]) }
            }

            horos_measureLength = Float(length / (10.0 * Double(horos_factor)))
        } else {
            vtk.removeActiveLineText()
            horos_measureLength = 0
        }

        if horos_Oval2DRadius > 0.001 {
            if horos_Oval2DPix == nil {
                if renderingMode == 1 || renderingMode == 3 || renderingMode == 2 { // MIP modes - full depth
                    IsiXVTKVolumeView.volumeRenderingSuppressed = true

                    vtk.setRendererDraws(false)

                    prepareFullDepthCapture()

                    renderImage(withBestQuality: false, waitDialog: false, display: true)

                    var width = 0, height = 0
                    var rgb: ObjCBool = false

                    let pixels = imageInFullDepthWidth(&width, height: &height, isRGB: &rgb)

                    let origin = horos_Oval2DPixZBufferOrigin
                    origin[0] = 0
                    origin[1] = 0
                    let rayCastImage = vtk.rayCastImageInfoFused(false)
                    origin[0] = rayCastImage.origin.0
                    origin[1] = rayCastImage.origin.1
                    horos_Oval2DSampleDistance = rayCastImage.sampleDistance
                    origin[0] = CConversion.int(Double(origin[0]) * horos_Oval2DSampleDistance)
                    origin[1] = CConversion.int(Double(origin[1]) * horos_Oval2DSampleDistance)

                    if !rgb.boolValue {
                        horos_Oval2DPix = DCMPix(data: pixels, 32, width, height, 1, 1, 0, 0, 0, false)
                    }

                    endRenderImageWithBestQuality()

                    restoreFullDepthCapture()

                    vtk.setRendererDraws(true)

                    IsiXVTKVolumeView.volumeRenderingSuppressed = false

                    free(pixels)
                }
            }

            if let ovalPix = horos_Oval2DPix {
                let circle = ROI(type: .tOval, 1, 1, NSPoint(x: 0, y: 0))

                let sampleDistance = horos_Oval2DSampleDistance
                let origin = horos_Oval2DPixZBufferOrigin
                var center = horos_Oval2DCenter
                var radius = Float(horos_Oval2DRadius)

                center.x -= CGFloat(origin[0]); center.y -= CGFloat(origin[1])
                center.x /= sampleDistance; center.y /= sampleDistance

                radius = Float(Double(radius) / sampleDistance)

                circle?.rect = NSRect(x: center.x, y: CGFloat(ovalPix.pheight) - center.y,
                                     width: CGFloat(radius), height: CGFloat(radius))

                var rmean: Float = 0, rtotal: Float = 0, rdev: Float = 0, rmin: Float = 0, rmax: Float = 0

                ovalPix.computeROI(circle, &rmean, &rtotal, &rdev, &rmin, &rmax)

                let ovalTextHeight: CGFloat = 35

                let localizedText = String(format: NSLocalizedString("Mean: %2.2f SDev: %2.2f\nMin: %2.2f Max: %2.2f",
                                                                     comment: "ONLY ASCII CHARACTERS ! NO ACCENTS OR HIEROGLYPHS"),
                                           Double(rmean), Double(rdev), Double(rmin), Double(rmax))

                let ovalCenter = horos_Oval2DCenter, ovalRadius = horos_Oval2DRadius
                if Double(ovalCenter.y) / sampleDistance > Double(ovalPix.pheight / 2) {
                    localizedText.withCString {
                        vtk.placeOvalText($0, x: Double(ovalCenter.x) - ovalRadius, y: Double(ovalCenter.y) - ovalRadius - Double(ovalTextHeight))
                    }
                } else {
                    localizedText.withCString {
                        vtk.placeOvalText($0, x: Double(ovalCenter.x) - ovalRadius, y: Double(ovalCenter.y) + ovalRadius + 5)
                    }
                }
            } else {
                vtk.removeOvalText()
            }
        }

        sendMouseMovedWithCurrentEvent()
    }

    @objc(scaleFactor)
    func scaleFactor() -> Float {
        Float(100.0 / (Double(horos_firstObject?.pixelSpacingX ?? 0) * horos_vtk.cameraParallelScale))
    }

    // MARK: - Scissors' outline

    /// The scissors' outline from the clicked points, a spline through them
    /// when the preference asks for it.
    @objc(generateROI)
    func generateROI() {
        let outline = NSMutableData()
        let roiPoints = horos_ROIPoints

        // The points are NSValues, messaged as the Objective-C messaged them.
        func pointValue(_ value: Any) -> NSPoint { unsafeBitCast(value as AnyObject, to: NSValue.self).pointValue }

        func append(_ x: Double, _ y: Double) {
            var point = (x, y)
            withUnsafeBytes(of: &point) { outline.append($0.baseAddress!, length: $0.count) }
        }

        let count = roiPoints?.count ?? 0
        if UserDefaults.standard.bool(forKey: "SplineForScissors") && count >= 3 { // Spline
            let nb = Int32(truncatingIfNeeded: count + 1)

            let nspts = calloc(Int(nb), MemoryLayout<NSPoint>.size)!.assumingMemoryBound(to: NSPoint.self)

            for i in 0..<count {
                nspts[i] = pointValue(roiPoints!.object(at: i))
            }

            nspts[count] = pointValue(roiPoints!.object(at: 0)) // we add the first point as the last one to smooth the spline

            var splinePts: UnsafeMutablePointer<NSPoint>? = nil

            let newNb = Int(spline(nspts, nb, &splinePts, nil, 0.1))

            for i in 0..<max(newNb, 0) {
                append(Double(splinePts![i].x), Double(splinePts![i].y))
            }

            if newNb != 0 { free(splinePts) }
            free(nspts)
        } else if let roiPoints {
            for pt in roiPoints {
                let point = pointValue(pt)
                append(Double(point.x), Double(point.y))
            }
        }

        // The outline closed, as a polyline back to its first point.
        horos_vtk.setScissorsOutline(outline.bytes.assumingMemoryBound(to: Double.self),
                                     count: outline.length / (2 * MemoryLayout<Double>.size))
    }
}
