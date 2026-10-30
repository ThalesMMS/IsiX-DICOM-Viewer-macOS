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

// The scissors of VRView: the 3D cut of the volume (or of the fused series) by
// the outline drawn on the view, and the saved scissors state of the series
// (save, load, delete, and the menu items and buttons that offer them). A
// Swift extension of the class, with the same selectors; the planes are cut
// by VRViewOperation, as before, one operation a plane.
//
// The arithmetic keeps the Objective-C's types; where clang fused a product
// into a sum (a*b + c), the Swift says so with addingProduct.

/// The cut of one plane by the scissors (-[VRController applyScissor:]), an
/// operation of the cut's queue. The controller and the plane's description
/// are retained until the operation goes.
final class VRViewOperation: Operation, @unchecked Sendable {
    private let controller: VRController
    private let objects: NSArray

    init(controller: VRController, objects: [Any]) {
        self.controller = controller
        self.objects = objects as NSArray
        super.init()
    }

    override func main() {
        autoreleasepool {
            controller.applyScissor(objects)
        }
    }
}

/// The intersection of a segment and a plane, in single precision.
enum VRSegmentPlane {
    /// The point where the segment from `p0` to `p1` crosses the plane through
    /// `planePoint` normal to `normal`, or nil when they are parallel (or the
    /// segment lies in the plane) or do not meet.
    static func intersection(_ p0: [Float], _ p1: [Float], normal: [Float], planePoint: [Float]) -> [Float]? {
        let u = [p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]]
        let w = [p0[0] - planePoint[0], p0[1] - planePoint[1], p0[2] - planePoint[2]]

        /// v1·v2 as clang computed it: the last two products fused into the sum.
        func dot(_ v1: [Float], _ v2: [Float]) -> Float {
            (v1[1] * v2[1]).addingProduct(v1[0], v2[0]).addingProduct(v1[2], v2[2])
        }

        let d = dot(normal, u)
        let n = -dot(normal, w)

        if Double(abs(d)) < 0.00000001 { // segment is parallel to plane
            return nil
        }

        // they are not parallel: the intersect parameter
        let sI = n / d
        if sI < 0 || sI > 1 {
            return nil // no intersection
        }

        return [p0[0].addingProduct(sI, u[0]), p0[1].addingProduct(sI, u[1]), p0[2].addingProduct(sI, u[2])]
    }
}

extension VRView {

    // MARK: - The cut

    /// The 3D cut of the volume (or the fused series') by the scissors' outline:
    /// `c` is the key (Return keeps the inside, Delete the outside, Tab restores).
    @objc(deleteRegion:::)
    func deleteRegion(_ c: Int32, _ pxList: NSArray, _ blendedSeries: Bool) {
        let vtk = horos_vtk
        let factor = horos_factor, blendingFactor = horos_blendingFactor
        let stackMax: Int, stackOrientation: Int
        // The scissors' outline, in display pixels, two doubles a point.
        let roiCount = vtk.scissorsPointCount
        let roiPoints = calloc(2 * (roiCount > 0 ? roiCount : 1), MemoryLayout<Double>.size)!.assumingMemoryBound(to: Double.self)
        vtk.getScissorsPoints(roiPoints)
        let roiList = NSMutableArray()
        var xyz = [Double](repeating: 0, count: 3), cameraProj = [Double](repeating: 0, count: 3)
        var vector = [Float](repeating: 0, count: 9)
        let fObject = unsafeBitCast(pxList.object(at: 0) as AnyObject, to: DCMPix.self)

        NSLog("Scissor Start")
        horos_controller?.prepareUndo()

        let transform = vtk.userTransformFused(blendedSeries)

        vtk.getCameraViewPlaneNormal(&cameraProj)
        vtk.getCameraPosition(&xyz)

        let scale = Double(blendedSeries ? blendingFactor : factor)
        xyz[0] /= scale
        xyz[1] /= scale
        xyz[2] /= scale
        fObject.orientation(&vector)

        let cameraProjObj = [
            (cameraProj[1] * Double(vector[1])).addingProduct(cameraProj[0], Double(vector[0])).addingProduct(cameraProj[2], Double(vector[2])),
            (cameraProj[1] * Double(vector[4])).addingProduct(cameraProj[0], Double(vector[3])).addingProduct(cameraProj[2], Double(vector[5])),
            (cameraProj[1] * Double(vector[7])).addingProduct(cameraProj[0], Double(vector[6])).addingProduct(cameraProj[2], Double(vector[8])),
        ]

        if abs(cameraProjObj[0]) > abs(cameraProjObj[1]) && abs(cameraProjObj[0]) > abs(cameraProjObj[2]) {
            NSLog("X Stack")
            stackOrientation = 0
        } else if abs(cameraProjObj[1]) > abs(cameraProjObj[0]) && abs(cameraProjObj[1]) > abs(cameraProjObj[2]) {
            NSLog("Y Stack")
            stackOrientation = 1
        } else {
            NSLog("Z Stack")
            stackOrientation = 2
        }

        switch stackOrientation {
        case 0: stackMax = Int(fObject.pwidth)
        case 1: stackMax = Int(fObject.pheight)
        default: stackMax = pxList.count
        }

        for _ in 0..<max(stackMax, 0) {
            roiList.add(ROI(type: .tCPolygon, Float(fObject.pixelSpacingX * Double(factor)), Float(fObject.pixelSpacingY * Double(factor)),
                               DCMPix.originCorrected(accordingToOrientation: fObject))!)
        }

        // Clip the polygons to the crop box?
        var minClip = NSValue(point: NSPoint(x: 0, y: 0))
        var maxClip = NSValue(point: NSPoint(x: 0, y: 0))
        var zClip = NSPoint(x: 0, y: CGFloat(stackMax))
        var a = [Double](repeating: 0, count: 6)

        if vtk.getCroppingBox(&a), let firstObject = horos_firstObject {
            let width = Double(Int32(truncatingIfNeeded: firstObject.pwidth)), height = Double(Int32(truncatingIfNeeded: firstObject.pheight))
            let depth = Double(Int32(truncatingIfNeeded: horos_pixList?.count ?? 0))

            for x in 0..<6 {
                a[x] /= Double(horos_superSampling)
            }

            var sliceThickness = Float(firstObject.sliceInterval)

            if sliceThickness == 0 {
                sliceThickness = Float(firstObject.sliceThickness)
            }

            a[4] *= firstObject.pixelSpacingX
            a[4] /= Double(sliceThickness)
            a[5] *= firstObject.pixelSpacingX
            a[5] /= Double(sliceThickness)

            a[2] *= firstObject.pixelSpacingX / firstObject.pixelSpacingY
            a[3] *= firstObject.pixelSpacingX / firstObject.pixelSpacingY

            a[0] -= 1; a[1] += 1
            a[2] -= 1; a[3] += 1
            a[4] -= 1; a[5] += 1

            a[0] = a[0] >= width ? width : a[0];   a[1] = a[1] >= width ? width : a[1]
            a[2] = a[2] >= height ? height : a[2]; a[3] = a[3] >= height ? height : a[3]
            a[4] = a[4] >= depth ? depth : a[4];   a[5] = a[5] >= depth ? depth : a[5]

            for x in 0..<6 {
                a[x] = a[x] < 0 ? 0 : a[x]
            }

            switch stackOrientation {
            case 0:
                minClip = NSValue(point: NSPoint(x: floor(a[2]), y: floor(a[4])))
                maxClip = NSValue(point: NSPoint(x: ceil(a[3]), y: ceil(a[5])))
                zClip = NSPoint(x: floor(a[0]), y: ceil(a[1]))
            case 1:
                minClip = NSValue(point: NSPoint(x: floor(a[0]), y: floor(a[4])))
                maxClip = NSValue(point: NSPoint(x: ceil(a[1]), y: ceil(a[5])))
                zClip = NSPoint(x: floor(a[2]), y: ceil(a[3]))
            default:
                minClip = NSValue(point: NSPoint(x: floor(a[0]), y: floor(a[2])))
                maxClip = NSValue(point: NSPoint(x: ceil(a[1]), y: ceil(a[3])))
                zClip = NSPoint(x: floor(a[4]), y: ceil(a[5]))
            }
        }

        for tt in 0..<max(roiCount, 0) {
            var point1 = [Float](repeating: 0, count: 3), point2 = [Float](repeating: 0, count: 3)
            var pp = [Double](repeating: 0, count: 4)

            vtk.worldPoint(ofDisplayX: roiPoints[2 * tt], y: roiPoints[2 * tt + 1], z: 0, into: &pp)

            pp[0] /= scale
            pp[1] /= scale
            pp[2] /= scale

            if vtk.cameraParallelProjection {
                vtk.getCameraPosition(&xyz)

                xyz[0] = pp[0] + cameraProj[0]
                xyz[1] = pp[1] + cameraProj[1]
                xyz[2] = pp[2] + cameraProj[2]

                // Go beyond the object...

                pp[0] = xyz[0].addingProduct(pp[0] - xyz[0], 5000.0)
                pp[1] = xyz[1].addingProduct(pp[1] - xyz[1], 5000.0)
                pp[2] = xyz[2].addingProduct(pp[2] - xyz[2], 5000.0)

                point1 = [Float(xyz[0]), Float(xyz[1]), Float(xyz[2])]
                point2 = [Float(pp[0]), Float(pp[1]), Float(pp[2])]
            } else {
                // Go beyond the object...

                point1 = [Float(xyz[0]), Float(xyz[1]), Float(xyz[2])]

                point2[0] = Float(xyz[0].addingProduct(pp[0] - xyz[0], 5000.0))
                point2[1] = Float(xyz[1].addingProduct(pp[1] - xyz[1], 5000.0))
                point2[2] = Float(xyz[2].addingProduct(pp[2] - xyz[2], 5000.0))
            }

            // Intersection between this line and planes in Z direction
            for x in 0..<max(stackMax, 0) {
                var planeVector = [Float](repeating: 0, count: 3)
                var point = [Float](repeating: 0, count: 3)
                var vPos = [Double](repeating: 0, count: 3)

                vtk.getVolumePosition(&vPos, fused: blendedSeries)

                // factor
                vPos[0] /= scale
                vPos[1] /= scale
                vPos[2] /= scale

                switch stackOrientation {
                case 0:
                    point = [Float(Double(x) * fObject.pixelSpacingX), 0, 0]
                    planeVector = [vector[0], vector[1], vector[2]]
                case 1:
                    point = [0, Float(Double(x) * fObject.pixelSpacingY), 0]
                    planeVector = [vector[3], vector[4], vector[5]]
                default:
                    point = [0, 0, Float(Double(x) * fObject.sliceInterval)]
                    planeVector = [vector[6], vector[7], vector[8]]
                }

                point[0] = Float(Double(point[0]) + vPos[0])
                point[1] = Float(Double(point[1]) + vPos[1])
                point[2] = Float(Double(point[2]) + vPos[2])

                let untransformed = point
                transform?.transformFloatPoint(untransformed, into: &point)

                if let resultPt = VRSegmentPlane.intersection(point2, point1, normal: planeVector, planePoint: point) {
                    // Convert this 3D point to 2D point projected in the plane
                    var tempPoint3D = [Float](repeating: 0, count: 3)
                    transform?.inverseTransformFloatPoint(resultPt, into: &tempPoint3D)

                    tempPoint3D[0] = Float(Double(tempPoint3D[0]) - vPos[0])
                    tempPoint3D[1] = Float(Double(tempPoint3D[1]) - vPos[1])
                    tempPoint3D[2] = Float(Double(tempPoint3D[2]) - vPos[2])

                    tempPoint3D[0] = Float(Double(tempPoint3D[0]) / fObject.pixelSpacingX)
                    tempPoint3D[1] = Float(Double(tempPoint3D[1]) / fObject.pixelSpacingY)
                    tempPoint3D[2] = Float(Double(tempPoint3D[2]) / fObject.sliceInterval)

                    var ptInt = [CConversion.long(Double(tempPoint3D[0]) + 0.5),
                                 CConversion.long(Double(tempPoint3D[1]) + 0.5),
                                 CConversion.long(Double(tempPoint3D[2]) + 0.5)]

                    if horos_needToFlip {
                        ptInt[2] = pxList.count - ptInt[2] - 1
                    }

                    let roiID: Int, planePoint: NSPoint
                    switch stackOrientation {
                    case 0: roiID = ptInt[0]; planePoint = NSPoint(x: ptInt[1], y: ptInt[2])
                    case 1: roiID = ptInt[1]; planePoint = NSPoint(x: ptInt[0], y: ptInt[2])
                    default: roiID = ptInt[2]; planePoint = NSPoint(x: ptInt[0], y: ptInt[1])
                    }

                    if Double(roiID) >= Double(zClip.x) && Double(roiID) < Double(zClip.y) {
                        // -objectAtIndex: as before: a plane out of the list raises.
                        unsafeBitCast(roiList.object(at: roiID) as AnyObject, to: ROI.self).points.add(MyPoint.point(planePoint))
                    }
                }
            }
        }

        free(roiPoints)

        var addition = false
        var newVal: Float = 0

        let key = Int(c)
        if key == NSDeleteFunctionKey || key == NSDeleteCharacter || key == NSBackspaceCharacter || key == NSDeleteCharFunctionKey {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) {
                addition = true
                horos_gDataValuesChanged = true

                newVal = 1024
            }

            if flags.contains(.option) {
                addition = true
                horos_gDataValuesChanged = true

                newVal = -1024
            }
        }

        if key == NSTabCharacter {
            horos_gDataValuesChanged = true
        }

        guard let controller = horos_controller else { return }
        let savedMovieFrame = Int(controller.curMovieIndex())

        display()

        IsiXVTKVolumeView.volumeRenderingSuppressed = true
        vtk.setRendererDraws(false)

        var m = 0
        while m < Int(controller.viewer2D()?.maxMovieIndex() ?? 0) {
            controller.setMovieFrame(m)

            if let first = controller.curPixList()?.object(at: 0) { _ = unsafeDowncast(first as AnyObject, to: DCMPix.self).prepareRestore() }

            let queue = OperationQueue()

            for i in 0..<max(stackMax, 0) {
                let op = VRViewOperation(controller: controller,
                                         objects: [NSNumber(value: Int32(truncatingIfNeeded: i)),
                                                   NSNumber(value: Int32(truncatingIfNeeded: stackOrientation)),
                                                   NSNumber(value: c), roiList.object(at: i),
                                                   NSNumber(value: Int32(blendedSeries ? 1 : 0)),
                                                   NSNumber(value: addition), NSNumber(value: newVal), minClip, maxClip])

                queue.addOperation(op)
            }

            queue.waitUntilAllOperationsAreFinished()

            if let first = controller.curPixList()?.object(at: 0) { unsafeDowncast(first as AnyObject, to: DCMPix.self).freeRestore() }
            m += 1
        }

        // Update everything..
        controller.horosVolumeMetalRelease()
        horos_ROIUPDATE = false
        NotificationCenter.default.post(name: .OsirixUpdateVolumeData, object: horos_pixList, userInfo: ["sender": self])

        vtk.executeCropCallback()

        if horos_gDataValuesChanged {
            computeValueFactor()
            // Force min/max recomputing
            movieChangeSource(horos_data)

            horos_gDataValuesChanged = false
        } else {
            if !horos_isRGB {
                BrowserController.multiThreadedImageConvert("FTo16U", horos_srcf, horos_dst8, -horos_OFFSET16, Float(1.0 / Double(horos_valueFactor)))
            }
            applyMovieRangeGuardTo16BitVolume()
        }

        if let clutOpacityView {
            clutOpacityView.callComputeHistogram()
            clutOpacityView.updateView()
        }

        IsiXVTKVolumeView.volumeRenderingSuppressed = false
        vtk.setRendererDraws(true)

        controller.setMovieFrame(savedMovieFrame)

        // Delete current ROI
        vtk.setScissorsOutline(nil, count: 0)
        horos_ROIPoints?.removeAllObjects()

        // Drawn now, not asked for with -setNeedsDisplay:. The frame drawn at the
        // start of the cut is presented with this event's Core Animation
        // transaction (the picture layer presents with the transaction), and a
        // frame drawn later in that transaction's display pass never reached the
        // screen: the outline went away with the overlay, but the volume stayed
        // uncut until the camera moved. Of two frames drawn in the same
        // transaction, the last one is shown.
        display()

        NSLog("Scissor End")
    }

    // MARK: - Saved state

    /// Whether the series has a saved scissors state.
    private func hasScissorState() -> Bool {
        let str = VRController.getUniqueFilenameScissorState(for: horos_firstObject?.imageObj())
        return FileManager.default.fileExists(atPath: str ?? "")
    }

    @objc(updateScissorStateButtons)
    func updateScissorStateButtons() {
        let exists = hasScissorState()
        scissorStateMatrix?.cell(withTag: 1)?.isEnabled = exists
        scissorStateMatrix?.cell(withTag: 2)?.isEnabled = exists
    }

    @objc(validateMenuItem:)
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(scissorStateButtons(_:)) {
            if menuItem.tag == 2 { // Delete
                return hasScissorState()
            } else if menuItem.tag == 1 { // Load
                return hasScissorState()
            }
        }

        return true
    }

    @objc(scissorStateButtons:)
    func scissorStateButtons(_ sender: Any?) {
        let str = VRController.getUniqueFilenameScissorState(for: horos_firstObject?.imageObj()) ?? ""
        let firstObject = horos_firstObject
        let volumeSize = Int(firstObject?.pheight ?? 0) * (horos_pixList?.count ?? 0) * Int(firstObject?.pwidth ?? 0) * MemoryLayout<Float>.size
        var waiting: WaitRendering? = nil

        let tag: Int
        if let matrix = sender as? NSMatrix {
            tag = matrix.selectedCell()?.tag ?? 0
        } else {
            tag = (sender as AnyObject?)?.tag ?? 0
        }

        let noData = {
            _ = HorosAlertPanel.run(title: NSLocalizedString("3D Scissor State", comment: ""),
                                    message: NSLocalizedString("No saved data are available.", comment: ""),
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }

        switch tag {
        case 2:
            if HorosAlertPanel.run(title: NSLocalizedString("3D Scissor State", comment: ""),
                                   message: NSLocalizedString("Are you sure you want to delete this 3D state? You cannot undo this operation.", comment: ""),
                                   defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""),
                                   otherButton: nil) == HorosAlertDefaultResponse {
                try? FileManager.default.removeItem(atPath: str)
            }

        case 1: // Load
            waiting = WaitRendering(NSLocalizedString("Loading 3D object...", comment: ""))
            waiting?.showWindow(self)

            if FileManager.default.fileExists(atPath: str) {
                if let volumeData = NSData(contentsOfFile: str) {
                    if volumeData.length == volumeSize {
                        if let data = horos_data { memcpy(data, volumeData.bytes, volumeSize) }
                        NotificationCenter.default.post(name: .OsirixUpdateVolumeData, object: horos_pixList, userInfo: nil)

                        horos_vtk.executeCropCallback()
                    } else {
                        noData()
                    }
                } else {
                    noData()
                }
            } else {
                noData()
            }

        case 0: // Save
            let exists = FileManager.default.fileExists(atPath: str)
            if (exists && HorosAlertPanel.run(title: NSLocalizedString("3D Scissor State", comment: ""),
                                              message: NSLocalizedString("A 3D Scissor State already exists. Do you want to replace it with curent state?", comment: ""),
                                              defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""),
                                              otherButton: nil) == HorosAlertDefaultResponse) || !FileManager.default.fileExists(atPath: str) {
                waiting = WaitRendering(NSLocalizedString("Saving 3D object...", comment: ""))
                waiting?.showWindow(self)
                if let data = horos_data {
                    NSData(bytesNoCopy: data, length: volumeSize, freeWhenDone: false).write(toFile: str, atomically: false)
                }
            }

        default:
            break
        }

        waiting?.close()

        updateScissorStateButtons()
    }
}
