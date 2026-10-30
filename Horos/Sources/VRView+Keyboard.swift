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

// The keyboard of VRView, the fly-to ('f' and the endoscopy's fly-through)
// and the current tool: a Swift extension of the class, with the same
// selectors.
//
// The arithmetic keeps the Objective-C's types: a float operand of a double
// expression is widened, and a product added to a sum is one fused
// multiply-add, as clang compiled `a * b + c` (addingProduct).

/// The keys that delete a measurement or a point.
private func isDeleteKey(_ c: Int) -> Bool {
    return c == NSDeleteFunctionKey || c == NSDeleteCharacter || c == NSBackspaceCharacter || c == NSDeleteCharFunctionKey
}

extension VRView {

    // MARK: - Fly to

    @objc(flyTo:::)
    func flyTo(_ x: Float, _ y: Float, _ z: Float) {
        let vtk = horos_vtk
        let flyTo = [Double(x), Double(y), Double(z)]
        var flyFrom = [Double](repeating: 0, count: 3)
        vtk.getCameraFocalPoint(&flyFrom)

        let d = (0..<3).map { flyTo[$0] - flyFrom[$0] }

        let delta = (horos_firstObject?.pixelSpacingX ?? 0) * Double(horos_factor)

        let flyToFactor = Double(Float(1) / Float(15.0))

        let focalPt = (0..<3).map { flyFrom[$0].addingProduct(d[$0] * delta, flyToFactor) }

        vtk.setCameraFocalPoint(focalPt)

        let distance = vtk.cameraDistance
        vtk.cameraDistance = 10.0 * delta
        vtk.cameraDolly(0.15 + 1.0)
        vtk.cameraDistance = distance
        vtk.cameraOrthogonalizeViewUp()

        if clipRangeActivated {
            vtk.setCameraClippingRangeNear(0.0, far: clippingRangeThickness)
        } else {
            vtk.resetCameraClippingRange()
        }
    }

    @objc(flyToVoxel:)
    func flyTo(_ voxel: OSIVoxel!) {
        var pt2D: [Float] = [voxel.x, voxel.y, voxel.z]
        var pt3D: [Float] = [0, 0, 0]
        convert2DPoint(&pt2D, to3DPoint: &pt3D)
        flyTo(pt3D[0], pt3D[1], pt3D[2])
    }

    // Fly to 2D position on a slice;
    @objc(flyToPoint:slice:)
    func flyTo(_ point: NSPoint, slice: Int32) {
        var pt2D: [Float] = [Float(point.x), Float(point.y), Float(slice)]
        var pt3D: [Float] = [0, 0, 0]
        convert2DPoint(&pt2D, to3DPoint: &pt3D)
        flyTo(pt3D[0], pt3D[1], pt3D[2])
    }

    @objc(processFlyTo)
    func processFlyTo() {
        let destination = horos_flyToDestination
        let factor = horos_factor
        flyTo(destination[0] * factor, destination[1] * factor, destination[2] * factor)

        let vtk = horos_vtk
        vtk.setVolumeMinimumImageSampleDistance(horos_LOD * lowResLODFactor)
        vtk.setBlendingMinimumImageSampleDistance(horos_LOD * lowResLODFactor)

        display()

        vtk.setVolumeMinimumImageSampleDistance(horos_LOD)
        vtk.setBlendingMinimumImageSampleDistance(horos_LOD)

        NotificationCenter.default.post(name: .OsirixVRCameraDidChange, object: self, userInfo: nil)
    }

    // MARK: - Keyboard

    public override func keyUp(with event: NSEvent) {
        if eventToPlugins(event) { return }

        guard let characters = event.characters as NSString?, characters.length > 0 else { return }

        let c = characters.character(at: 0)

        if c == unichar(UInt8(ascii: "f")) {
            horos_flyto = false
            needsDisplay = true
        }
    }

    public override func keyDown(with event: NSEvent) {
        if eventToPlugins(event) { return }

        guard let characters = event.characters as NSString?, characters.length > 0 else { return }

        let c = Int(characters.character(at: 0))
        let vtk = horos_vtk
        let currentTool = self.currentTool()

        if c == Int(UInt8(ascii: "f")) {
            if !vtk.cameraParallelProjection && !horos_flyto {
                let mousePoint = VRInteractionGeometry.backingPoint(window?.mouseLocationOutsideOfEventStream ?? .zero, in: self)
                var pix = [Int](repeating: 0, count: 3)
                var value: Float = 0

                horos_flyto = get3DPixelUnder2DPositionX(Float(mousePoint.x), y: Float(mousePoint.y), pixel: &pix,
                                                         position: horos_flyToDestination, value: &value)
            }
        } else if c == Int(UInt8(ascii: " ")) {
            if window?.windowController is VRController {
                horos_isRotating = !horos_isRotating
            }
        } else if c == Int(UInt8(ascii: "?")) {
            let now = Date()

            NSLog("360 degree rotation - 100 images - START")
            for _ in 0..<100 {
                azimuth(Float(360.0 / 100.0))
                display()
            }
            NSLog("360 degree rotation - 100 images - END")
            NSLog("360 degree rotation - Result in [s]: %f", -now.timeIntervalSinceNow)

            AppController.shared()?.notificationTitle(
                NSLocalizedString("Performance Test", comment: ""),
                description: String(format: NSLocalizedString("360 degree rotation - 100 images\rResult in [s] : %f", comment: ""),
                                    -now.timeIntervalSinceNow),
                name: "result")
        } else if c == 27 && currentTool == .t3DCut {
            let scissorsCount = vtk.scissorsPointCount

            if horos_bestRenderingWasGenerated {
                horos_bestRenderingWasGenerated = false
                display()
            }

            IsiXVTKVolumeView.volumeRenderingSuppressed = true

            if scissorsCount != 0 {
                // Delete current ROI
                vtk.setScissorsOutline(nil, count: 0)
                horos_ROIPoints?.removeAllObjects()

                display()
            }

            IsiXVTKVolumeView.volumeRenderingSuppressed = false
        } else if currentTool == .tAngle {
            if c == 27 || isDeleteKey(c) {
                clearAngleMeasurement()
                needsDisplay = true
            }
        } else if currentTool == .tMesure || currentTool == .tOval {
            if c == 27 || isDeleteKey(c) {
                if currentTool == .tMesure {
                    let lineCount = vtk.activeLinePointCount

                    if horos_bestRenderingWasGenerated {
                        horos_bestRenderingWasGenerated = false
                        display()
                    }
                    IsiXVTKVolumeView.volumeRenderingSuppressed = true

                    if lineCount != 0 && vtk.activeLineVisible {
                        // Delete current ROI
                        vtk.clearActiveLine()

                        computeLength()

                        display()
                    }

                    IsiXVTKVolumeView.volumeRenderingSuppressed = false
                } else if currentTool == .tOval {
                    if horos_bestRenderingWasGenerated {
                        horos_bestRenderingWasGenerated = false
                        display()
                    }
                    IsiXVTKVolumeView.volumeRenderingSuppressed = true

                    // Delete current ROI
                    vtk.hideOval()
                    horos_Oval2DRadius = 0

                    computeLength()
                    display()

                    IsiXVTKVolumeView.volumeRenderingSuppressed = false
                }
            }
        } else if (c == NSCarriageReturnCharacter || c == NSEnterCharacter || c == NSTabCharacter || isDeleteKey(c))
                    && currentTool == .t3DCut {
            if vtk.scissorsPointCount < 3 {
                HorosAlertPanel.run(title: NSLocalizedString("3D Cut", comment: ""),
                                    message: NSLocalizedString("Draw an ROI on the 3D image and then press Return (include) or Delete (exclude) keys.", comment: ""),
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            } else if c == NSTabCharacter && horos_controller?.viewer2D()?.postprocessed() == true {
                HorosAlertPanel.run(title: NSLocalizedString("Restore", comment: ""),
                                    message: NSLocalizedString("This dataset has been post processed (reslicing, MPR, ...). You cannot restore it.", comment: ""),
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            } else {
                let waiting = WaitRendering(NSLocalizedString("Applying Scissor...", comment: ""))
                waiting?.showWindow(self)

                if let lock = horos_deleteRegionLock, lock.try() {
                    deleteRegion(Int32(c), horos_pixList ?? NSMutableArray(), false)

                    lock.unlock()
                }

                waiting?.close()
            }
        } else if isDeleteKey(c) && currentTool == .t3Dpoint {
            if isAny3DPointSelected() {
                removeSelected3DPoint()
            }
        } else if c == 27 && horosStereoMode() == StereoMode.twoScreens.rawValue {
            horosSetStereoMode(StereoMode.off.rawValue)
        } else if c == 27 {
            horos_controller?.offFullScreen()
        } else if !actionForHotKey(event.characters) {
            horosVTKKeyDown(event)
        }
    }

    @IBAction @objc(undo:)
    func undo(_ sender: Any?) {
        horos_controller?.undo(sender)
    }

    // MARK: - The current tool

    @objc(currentTool)
    func currentTool() -> ToolMode {
        return horos_currentTool
    }

    @objc(_tool)
    func _tool() -> ToolMode {
        return horos__tool
    }

    @objc(setCurrentTool:)
    func setCurrentTool(_ i: ToolMode) {
        let vtk = horos_vtk
        // Hotkeys and programmatic actions must obey the same projection restriction
        // as the disabled toolbar cell. Keep the current tool when rejecting a request.
        if i == .tMesure && vtk.hasCamera && !vtk.cameraParallelProjection {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = NSLocalizedString("Length Measurement", comment: "")
            alert.informativeText = NSLocalizedString("Length measurements require parallel projection. Select Parallel in the Perspective controls.", comment: "")
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModal()
            return
        }
        let previousTool = horos_currentTool

        horos_currentTool = i
        let currentTool = i

        if currentTool != .t3DRotate {
            vtk.hideCropBox()
        }

        if currentTool == .tOval || previousTool == .tOval {
            if horos_bestRenderingWasGenerated {
                horos_bestRenderingWasGenerated = false
                display()
            }
            IsiXVTKVolumeView.volumeRenderingSuppressed = true
            IsiXVTKVolumeView.volumeRenderingSuppressed = false
        }

        updateLineMeasurementProjections()

        if (currentTool == .t3DCut && previousTool == .t3DCut) || currentTool != .t3DCut {
            if horos_bestRenderingWasGenerated {
                horos_bestRenderingWasGenerated = false
                display()
            }
            IsiXVTKVolumeView.volumeRenderingSuppressed = true
            if vtk.scissorsPointCount != 0 {
                // Delete current ROI
                vtk.setScissorsOutline(nil, count: 0)
                horos_ROIPoints?.removeAllObjects()

                display()
            }

            IsiXVTKVolumeView.volumeRenderingSuppressed = false
        }

        if currentTool != .t3Dpoint && previousTool == .t3Dpoint {
            unselectAllActors()
            if point3DInfoPanel?.isVisible == true { point3DInfoPanel?.performClose(self) }
            needsDisplay = true
        }

        setCursorFor(currentTool)
    }
}
