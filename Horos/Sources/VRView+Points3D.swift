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
import IsiXImaging
import IsiXVolumeRendering

// The 3D points of VRView: spheres the VTK adapter draws for the 2D viewer's
// point ROIs, their selection, colour and radius, and the voxel under a
// position of the view. A Swift extension of VRView, with the same
// selectors. The lists are the view's NSMutableArrays: each point is its
// actor (an NSValue of the pointer), its position (an NSValue of float[3]),
// its radius and its colour, at the same index.
//
// The arithmetic keeps the Objective-C's types: a float operand of a double
// expression is widened, and a product added to a sum is one fused
// multiply-add, as clang compiled `a * b + c` (addingProduct).

extension VRView {

    // MARK: - Adding

    @objc(add3DPoint:::::::)
    func add3DPoint(_ x: Double, _ y: Double, _ z: Double, _ radius: Float, _ r: Float, _ g: Float, _ b: Float) {
        let x = x * Double(horos_factor)
        let y = y * Double(horos_factor)
        let z = z * Double(horos_factor)

        // Sphere
        let sphereActor = horos_vtk.makePointSphereX(x, y: y, z: z, radius: Double(radius * horos_superSampling),
                                                     red: Double(r), green: Double(g), blue: Double(b))

        var center: [Float] = [Float(x), Float(y), Float(z)]
        horos_point3DPositionsArray.add(NSValue(bytes: &center, objCType: "[3f]"))
        horos_point3DRadiusArray.add(NSNumber(value: radius * horos_superSampling))
        horos_point3DColorsArray.add(NSColor(calibratedRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1.0))

        add3DPointActor(sphereActor)
    }

    @objc(add3DPoint:::)
    func add3DPoint(_ x: Double, _ y: Double, _ z: Double) {
        add3DPoint(x, y, z, horos_point3DDefaultRadius, horos_point3DDefaultColorRed,
                   horos_point3DDefaultColorGreen, horos_point3DDefaultColorBlue)
    }

    /// `actor`, a vtkActor *, shown as a 3D point.
    @objc(add3DPointActor:)
    func add3DPointActor(_ actor: UnsafeMutableRawPointer?) {
        horos_point3DActorArray.add(NSValue(pointer: actor))
        if let actor { horos_vtk.addPointActor(actor) }
    }

    @objc(addRandomPoints::)
    func addRandomPoints(_ n: Int32, _ r: Int32) {
        var origin = [Double](repeating: 0, count: 3)
        horos_vtk.getVolumePosition(&origin, fused: false)

        // add some random points: random()'s range, 0 to 2^31 - 1, from
        // arc4random, as Swift has no random().
        func random() -> Double { Double(arc4random() & 0x7FFF_FFFF) }
        for _ in 0..<max(Int(n), 0) {
            let x = (random() / (pow(2.0, 31.0) - 1) * 2.0 - 1.0) * Double(r) + origin[0] / 2.0
            let y = (random() / (pow(2.0, 31.0) - 1) * 2.0 - 1.0) * Double(r) + origin[1] / 2.0
            let z = (random() / (pow(2.0, 31.0) - 1) * 2.0 - 1.0) * Double(r) + origin[2]
            add3DPoint(x, y, z, 2.0, 1.0, 0.0, 0.0)
        }
    }

    // MARK: - The voxel under a position

    @objc(get3DPixelUnder2DPositionX:Y:pixel:position:value:)
    func get3DPixelUnder2DPositionX(_ x: Float, y: Float, pixel pix: UnsafeMutablePointer<Int>!,
                                    position: UnsafeMutablePointer<Float>!, value val: UnsafeMutablePointer<Float>!) -> Bool {
        return get3DPixelUnder2DPositionX(x, y: y, pixel: pix, position: position, value: val, maxOpacity: 1.1, minValue: 0)
    }

    /// The first voxel along the ray under (x, y), in the view's pixels, whose
    /// opacities add up to `maxOpacity` (the brightest one in a MIP), and at
    /// least `minValue` when it is not 0: its indices, its position in
    /// millimetres and its value.
    @objc(get3DPixelUnder2DPositionX:Y:pixel:position:value:maxOpacity:minValue:)
    func get3DPixelUnder2DPositionX(_ x: Float, y: Float, pixel pix: UnsafeMutablePointer<Int>!,
                                    position: UnsafeMutablePointer<Float>!, value val: UnsafeMutablePointer<Float>!,
                                    maxOpacity: Float, minValue: Float) -> Bool {
        let vtk = horos_vtk
        let factor = Double(horos_factor)
        guard let curPixList = horos_controller?.curPixList(), let firstObject = horos_firstObject else { return false }

        // world point
        var worldPointClicked = [Double](repeating: 0, count: 4)
        vtk.worldPoint(ofDisplayX: Double(x), y: Double(y), z: 0, into: &worldPointClicked)
        worldPointClicked[0] /= factor
        worldPointClicked[1] /= factor
        worldPointClicked[2] /= factor

        // transform matrix
        let transform = vtk.userTransformFused(false)

        // camera view plane normal
        var cameraViewPlaneNormal = [Double](repeating: 0, count: 3)
        vtk.getCameraViewPlaneNormal(&cameraViewPlaneNormal)

        // camera position
        var cameraPosition = [Double](repeating: 0, count: 3)
        vtk.getCameraPosition(&cameraPosition)
        cameraPosition[0] /= factor
        cameraPosition[1] /= factor
        cameraPosition[2] /= factor

        var o = [Float](repeating: 0, count: 9)
        firstObject.orientation(&o)

        let normal = cameraViewPlaneNormal
        func projected(_ a: Int) -> Double {
            (normal[1] * Double(o[a + 1])).addingProduct(normal[0], Double(o[a])).addingProduct(normal[2], Double(o[a + 2]))
        }
        let cameraProjObj = [projected(0), projected(3), projected(6)]

        let stackOrientation: Int, stackMax: Int
        if abs(cameraProjObj[0]) > abs(cameraProjObj[1]) && abs(cameraProjObj[0]) > abs(cameraProjObj[2]) {
            stackOrientation = 0
            stackMax = Int(firstObject.pwidth)
        } else if abs(cameraProjObj[1]) > abs(cameraProjObj[0]) && abs(cameraProjObj[1]) > abs(cameraProjObj[2]) {
            stackOrientation = 1
            stackMax = Int(firstObject.pheight)
        } else {
            stackOrientation = 2
            stackMax = curPixList.count
        }

        if vtk.cameraParallelProjection {
            cameraPosition[0] = worldPointClicked[0] + cameraViewPlaneNormal[0]
            cameraPosition[1] = worldPointClicked[1] + cameraViewPlaneNormal[1]
            cameraPosition[2] = worldPointClicked[2] + cameraViewPlaneNormal[2]
        }

        // the two points defining the line going through the volume
        let point1: [Float] = [Float(cameraPosition[0]), Float(cameraPosition[1]), Float(cameraPosition[2])]
        // Go beyond the object...
        let point2: [Float] = (0..<3).map {
            Float(cameraPosition[$0].addingProduct(worldPointClicked[$0] - cameraPosition[$0], 5000.0))
        }

        // volume position
        var volumePosition = [Double](repeating: 0, count: 3)
        vtk.getVolumePosition(&volumePosition, fused: false)
        volumePosition[0] /= factor
        volumePosition[1] /= factor
        volumePosition[2] /= factor

        let direction = point1[stackOrientation] - point2[stackOrientation] < 0

        var pointFound = false
        var opacitySum: Float = 0.0
        var maxValue = -Float.greatestFiniteMagnitude
        let maximumIntensity = vtk.volumeBlendModeIsMaximumIntensity
        let pixelSpacingX = firstObject.pixelSpacingX, pixelSpacingY = firstObject.pixelSpacingY
        let sliceInterval = firstObject.sliceInterval
        let width = Int(firstObject.pwidth), height = Int(firstObject.pheight)
        let superSampling = Double(horos_superSampling), offset = horos_OFFSET16, valueFactor = horos_valueFactor

        var p = 0
        while p < stackMax {
            defer { p += 1 }
            let n = direction ? p : (stackMax - 1) - p

            var currentPoint: [Float] = [0, 0, 0]
            let planeVector: [Float]
            switch stackOrientation {
            case 0:
                currentPoint[0] = Float(Double(n) * pixelSpacingX)
                planeVector = [o[0], o[1], o[2]]
            case 1:
                currentPoint[1] = Float(Double(n) * pixelSpacingY)
                planeVector = [o[3], o[4], o[5]]
            default:
                currentPoint[2] = Float(Double(n) * sliceInterval)
                planeVector = [o[6], o[7], o[8]]
            }

            currentPoint[0] = Float(Double(currentPoint[0]) + volumePosition[0])
            currentPoint[1] = Float(Double(currentPoint[1]) + volumePosition[1])
            currentPoint[2] = Float(Double(currentPoint[2]) + volumePosition[2])

            let untransformed = currentPoint
            transform?.transformFloatPoint(untransformed, into: &currentPoint)

            var resultPt: [Float] = [0, 0, 0]
            guard PlaneGeometry.segmentPlane(point2, point1, normal: planeVector, point: currentPoint, result: &resultPt) != 0 else {
                continue
            }

            // Convert this 3D point to 2D point projected in the plane
            var tempPoint3D: [Float] = [0, 0, 0]
            transform?.inverseTransformFloatPoint(resultPt, into: &tempPoint3D)

            tempPoint3D[0] = Float(Double(tempPoint3D[0]) - volumePosition[0])
            tempPoint3D[1] = Float(Double(tempPoint3D[1]) - volumePosition[1])
            tempPoint3D[2] = Float(Double(tempPoint3D[2]) - volumePosition[2])

            tempPoint3D[0] = Float(Double(tempPoint3D[0]) / pixelSpacingX)
            tempPoint3D[1] = Float(Double(tempPoint3D[1]) / pixelSpacingY)
            tempPoint3D[2] = Float(Double(tempPoint3D[2]) / sliceInterval)

            // convert to long
            var ptInt = [CConversion.long(Double(tempPoint3D[0]) + 0.5),
                         CConversion.long(Double(tempPoint3D[1]) + 0.5),
                         CConversion.long(Double(tempPoint3D[2]) + 0.5)]

            if horos_needToFlip {
                ptInt[2] = curPixList.count - ptInt[2] - 1
            }

            guard ptInt[0] >= 0 && ptInt[0] < width && ptInt[1] >= 0 && ptInt[1] < height
                    && ptInt[2] >= 0 && ptInt[2] < curPixList.count,
                  let currentDCMPix = curPixList[ptInt[2]] as? DCMPix,
                  let imageBuffer = currentDCMPix.fImage else { continue }
            let currentPointValue = imageBuffer[ptInt[0] + ptInt[1] * Int(currentDCMPix.pwidth)]

            if !maximumIntensity {
                // Volume Rendering Mode
                let opacity = vtk.opacity(at: Double((currentPointValue + offset) * valueFactor))
                opacitySum = Float(Double(opacitySum).addingProduct(opacity, superSampling))

                if minValue != 0 {
                    pointFound = currentPointValue >= minValue
                    pointFound = pointFound && opacitySum >= maxOpacity
                } else {
                    pointFound = opacitySum >= maxOpacity
                }

                if pointFound {
                    val.pointee = currentPointValue
                    pix[0] = ptInt[0]; pix[1] = ptInt[1]; pix[2] = ptInt[2]
                    position[0] = resultPt[0]; position[1] = resultPt[1]; position[2] = resultPt[2]
                    p = stackMax    // stop the loop
                }
            } else if currentPointValue > maxValue {
                pointFound = minValue != 0 ? currentPointValue >= minValue : true

                maxValue = currentPointValue
                val.pointee = currentPointValue
                pix[0] = ptInt[0]; pix[1] = ptInt[1]; pix[2] = ptInt[2]
                position[0] = resultPt[0]; position[1] = resultPt[1]; position[2] = resultPt[2]
            }
        }

        return pointFound
    }

    @objc(throw3DPointOnSurface::)
    func throw3DPointOnSurface(_ x: Double, _ y: Double) {
        var pix = [Int](repeating: 0, count: 3)
        var pos = [Float](repeating: 0, count: 3)
        var value: Float = 0

        if get3DPixelUnder2DPositionX(Float(x), y: Float(y), pixel: &pix, position: &pos, value: &value) {
            add3DPoint(Double(pos[0]), Double(pos[1]), Double(pos[2]))

            var rgb = RGBColor()
            rgb.red = UInt16(truncatingIfNeeded: CConversion.int(Double(horos_point3DDefaultColorRed) * 65535.0))
            rgb.green = UInt16(truncatingIfNeeded: CConversion.int(Double(horos_point3DDefaultColorGreen) * 65535.0))
            rgb.blue = UInt16(truncatingIfNeeded: CConversion.int(Double(horos_point3DDefaultColorBlue) * 65535.0))

            horos_controller?.add2DPoint(Float(pix[0]), Float(pix[1]), Float(pix[2]), &pos, rgb)
        }
    }

    // MARK: - Display

    @objc(setDisplay3DPoints:)
    func setDisplay3DPoints(_ on: Bool) {
        horos_display3DPoints = on

        for object in horos_point3DActorArray {
            guard let actor = (object as? NSValue)?.pointerValue else { continue }
            if on {
                horos_vtk.addPointActor(actor)
            } else {
                horos_vtk.removePointActor(actor)
            }
        }
        unselectAllActors()
        needsDisplay = true
    }

    @objc(toggleDisplay3DPoints)
    func toggleDisplay3DPoints() {
        setDisplay3DPoints(!horos_display3DPoints)
    }

    // MARK: - Selection

    @objc(isAny3DPointSelected)
    func isAny3DPointSelected() -> Bool {
        return horos_picked3DPoint != nil && Int(selected3DPointIndex()) < horos_point3DActorArray.count
    }

    /// The index of the picked point, or the number of points when none is.
    @objc(selected3DPointIndex)
    func selected3DPointIndex() -> UInt32 {
        let pickedPropPointer = horos_picked3DPoint
        var i: UInt32 = 0
        for object in horos_point3DActorArray {
            if pickedPropPointer == (object as? NSValue)?.pointerValue {
                return i
            }
            i += 1
        }
        return i // if no point is selected, returns [point3DActorArray count], i.e. out of bounds...
    }

    @objc(unselectAllActors)
    func unselectAllActors() {
        horos_picked3DPoint = nil
        needsDisplay = true
    }

    // MARK: - Removing

    @objc(remove3DPointAtIndex:)
    func remove3DPoint(at index: UInt32) {
        let index = Int(index)
        // point to remove
        let actor = (horos_point3DActorArray[index] as? NSValue)?.pointerValue
        // remove from Renderer
        if let actor { horos_vtk.removePointActor(actor) }
        // remove the highlight bounding box
        unselectAllActors()
        // kill the actor himself
        if let actor { horos_vtk.deletePointActor(actor) }
        // remove from list
        horos_point3DActorArray.removeObject(at: index)
        horos_point3DPositionsArray.removeObject(at: index)
        horos_point3DRadiusArray.removeObject(at: index)
        horos_point3DColorsArray.removeObject(at: index)
        // refresh display
        needsDisplay = true
    }

    @objc(removeSelected3DPoint)
    func removeSelected3DPoint() {
        guard isAny3DPointSelected() else { return }
        // remove 2D Point
        var position: [Float] = [0, 0, 0]
        (horos_point3DPositionsArray[Int(selected3DPointIndex())] as? NSValue)?.getValue(&position)

        // The 3D point goes through the notification [controller remove2DPoint…] sends.
        horos_controller?.remove2DPoint(position[0], position[1], position[2])
    }

    // MARK: - Appearance

    @objc(IBSetSelected3DPointColor:)
    func IBSetSelected3DPointColor(_ sender: Any?) {
        guard let color = (sender as? NSColorWell)?.color else { return }
        if point3DPropagateToAll?.state.rawValue ?? 0 != 0 {
            setAll3DPointsColor(color)
            setAll3DPointsRadius(point3DRadiusSlider?.floatValue ?? 0)
        } else {
            setSelected3DPointColor(color)
        }
        needsDisplay = true
    }

    @objc(IBSetSelected3DPointRadius:)
    func IBSetSelected3DPointRadius(_ sender: Any?) {
        let radius = (sender as? NSControl)?.floatValue ?? 0
        if point3DPropagateToAll?.state.rawValue ?? 0 != 0 {
            setAll3DPointsRadius(radius)
            if let color = point3DColorWell?.color.usingColorSpace(.genericRGB) {
                setAll3DPointsColor(color)
            }
        } else {
            setSelected3DPointRadius(radius)
        }
        needsDisplay = true
    }

    @objc(IBPropagate3DPointsSettings:)
    func IBPropagate3DPointsSettings(_ sender: Any?) {
        guard (sender as? NSButton)?.state == .on else { return }
        setAll3DPointsRadius(point3DRadiusSlider?.floatValue ?? 0)
        if let color = point3DColorWell?.color.usingColorSpace(.genericRGB) {
            setAll3DPointsColor(color)
        }
        needsDisplay = true
    }

    @objc(setSelected3DPointColor:)
    func setSelected3DPointColor(_ color: NSColor) {
        if isAny3DPointSelected() { set3DPointAt(selected3DPointIndex(), color: color) }
    }

    @objc(setAll3DPointsColor:)
    func setAll3DPointsColor(_ color: NSColor) {
        var i: UInt32 = 0
        while Int(i) < horos_point3DColorsArray.count {
            set3DPointAt(i, color: color)
            i += 1
        }
    }

    @objc(set3DPointAtIndex:Color:)
    func set3DPointAt(_ index: UInt32, color: NSColor) {
        let index = Int(index)
        if let actor = (horos_point3DActorArray[index] as? NSValue)?.pointerValue {
            horos_vtk.setPointActor(actor, red: Double(color.redComponent), green: Double(color.greenComponent),
                                    blue: Double(color.blueComponent))
        }
        horos_point3DColorsArray.removeObject(at: index)
        horos_point3DColorsArray.insert(color, at: index)
    }

    @objc(setSelected3DPointRadius:)
    func setSelected3DPointRadius(_ radius: Float) {
        if isAny3DPointSelected() { set3DPointAt(selected3DPointIndex(), radius: radius) }
    }

    @objc(setAll3DPointsRadius:)
    func setAll3DPointsRadius(_ radius: Float) {
        var i: UInt32 = 0
        while Int(i) < horos_point3DRadiusArray.count {
            set3DPointAt(i, radius: radius)
            i += 1
        }
    }

    @objc(set3DPointAtIndex:Radius:)
    func set3DPointAt(_ index: UInt32, radius: Float) {
        let index = Int(index)
        var center: [Float] = [0, 0, 0]
        (horos_point3DPositionsArray[index] as? NSValue)?.getValue(&center)
        if let actor = (horos_point3DActorArray[index] as? NSValue)?.pointerValue {
            horos_vtk.setPointActor(actor, centerX: Double(center[0]), y: Double(center[1]), z: Double(center[2]),
                                    radius: Double(radius * horos_superSampling))
        }
        horos_point3DRadiusArray.removeObject(at: index)
        horos_point3DRadiusArray.insert(NSNumber(value: radius), at: index)
    }

    // MARK: - Defaults

    @objc(save3DPointsDefaultProperties:)
    func save3DPointsDefaultProperties(_ sender: Any?) {
        let defaults = UserDefaults.standard
        // A message to nil answered 0.
        let color = point3DColorWell?.color.usingColorSpace(.genericRGB)
        horos_point3DDefaultColorRed = Float(color?.redComponent ?? 0)
        horos_point3DDefaultColorGreen = Float(color?.greenComponent ?? 0)
        horos_point3DDefaultColorBlue = Float(color?.blueComponent ?? 0)
        horos_point3DDefaultColorAlpha = Float(color?.alphaComponent ?? 0)
        defaults.set(horos_point3DDefaultColorRed, forKey: "points3DcolorRed")
        defaults.set(horos_point3DDefaultColorGreen, forKey: "points3DcolorGreen")
        defaults.set(horos_point3DDefaultColorBlue, forKey: "points3DcolorBlue")
        defaults.set(horos_point3DDefaultColorAlpha, forKey: "points3DcolorAlpha")

        // radius
        horos_point3DDefaultRadius = point3DRadiusSlider?.floatValue ?? 0
        defaults.set(point3DRadiusSlider?.floatValue ?? 0, forKey: "points3Dradius")
    }

    @objc(load3DPointsDefaultProperties)
    func load3DPointsDefaultProperties() {
        let defaults = UserDefaults.standard
        horos_point3DDefaultColorRed = defaults.float(forKey: "points3DcolorRed")
        horos_point3DDefaultColorGreen = defaults.float(forKey: "points3DcolorGreen")
        horos_point3DDefaultColorBlue = defaults.float(forKey: "points3DcolorBlue")
        horos_point3DDefaultColorAlpha = defaults.float(forKey: "points3DcolorAlpha")

        if horos_point3DDefaultColorAlpha == 0.0 {
            horos_point3DDefaultColorRed = 0.0
            horos_point3DDefaultColorGreen = 1.0
            horos_point3DDefaultColorBlue = 0.0
            horos_point3DDefaultColorAlpha = 1.0
        }

        // radius
        horos_point3DDefaultRadius = defaults.float(forKey: "points3Dradius")
        if horos_point3DDefaultRadius == 0 { horos_point3DDefaultRadius = 5.0 }
    }

    @objc(factor)
    func factor() -> Float {
        return horos_factor
    }
}
