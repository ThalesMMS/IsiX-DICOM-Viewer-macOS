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

// The clicks and drags of VRView: the press of each tool (measurements, the
// scissors, window and level, the camera's turns, pans and zooms, the 3D
// points, the bone removal), its drag and its release, with the right button
// and the viewport's resize handle. A Swift extension of the class, with the
// same selectors.
//
// The @try of -mouseDown: (around the click count) is HorosObjCException.
// The arithmetic keeps the Objective-C's types; where clang fused a product
// into a sum (a*b + c, a - b*c), the Swift says so with addingProduct.

extension VRView {

    // MARK: - Press

    public override func mouseDown(with theEvent: NSEvent) {
        if eventToPlugins(theEvent) { return }

        VRView.horos_snVRView = self
        IsiXVTKVolumeView.volumeRenderingSuppressed = false

        horos_hasChanged = true
        let drawLock = VRView.horos_drawLock
        drawLock?.lock()

        let vtk = horos_vtk
        let LOD = horos_LOD, lowResLODFactor = self.lowResLODFactor

        horos_snCloseEventTimer?.fire()

        horos_snStopped = true

        var mouseLoc: NSPoint, mouseLocPre: NSPoint
        var tool: ToolMode

        horos_cursor?.set()

        horos_noWaitDialog = true
        tool = horos_currentTool

        if theEvent.type == .leftMouseDown {
            if horos_mouseDownTimer != nil {
                deleteMouseDownTimer()
            }

            if horos_controller?.style() != "noNib" {
                horos_mouseDownTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(startDrag(_:)),
                                                            userInfo: theEvent, repeats: false)
            }
        }

        horos_mouseLocStart = VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)
        mouseLocPre = horos_mouseLocStart

        var clickCount = 1

        if HorosObjCException.caught({
            let type = theEvent.type
            if type == .leftMouseDown || type == .rightMouseDown || type == .leftMouseUp || type == .rightMouseUp {
                clickCount = theEvent.clickCount
            }
        }) != nil {
            clickCount = 1
        }

        if clickCount > 1 && tool != .t3Dpoint {
            var pix = [Int](repeating: 0, count: 3)
            var pos = [Float](repeating: 0, count: 3), value: Float = 0
            let mouseLocStart = horos_mouseLocStart

            if clipRangeActivated {
                var position = [Float](repeating: 0, count: 3), sc = [Float](repeating: 0, count: 3), cos = [Float](repeating: 0, count: 9)
                let r = Double(Float(getResolution()))

                getOrigin(&position)
                _ = getCosMatrix(&cos)

                let display = VTKRetinaGeometry.displaySize(of: self)
                let up = Double(display.height - mouseLocStart.y), across = Double(mouseLocStart.x)
                for i in 0..<3 {
                    let alongColumns = (across * Double(cos[i])) * r
                    position[i] = Float(alongColumns.addingProduct(up * Double(cos[3 + i]), r) + Double(position[i]))
                }

                horos_firstObject?.convertDICOMCoords(&position, toSliceCoords: &sc, pixelCenter: true)

                if let firstObject = horos_firstObject {
                    sc[0] = Float(Double(sc[0]) / firstObject.pixelSpacingX)
                    sc[1] = Float(Double(sc[1]) / firstObject.pixelSpacingY)
                    sc[2] = Float(Double(sc[2]) / firstObject.sliceInterval)
                } else {
                    sc = [Float](repeating: .nan, count: 3)
                }

                let dict: [String: Any] = ["x": NSNumber(value: CConversion.int(sc[0])), "y": NSNumber(value: CConversion.int(sc[1])),
                                           "z": NSNumber(value: CConversion.int(sc[2]))]
                NotificationCenter.default.post(name: .OsirixDisplay3dPoint, object: horos_pixList, userInfo: dict)
            } else {
                if get3DPixelUnder2DPositionX(Float(mouseLocStart.x), y: Float(mouseLocStart.y), pixel: &pix, position: &pos, value: &value) {
                    let dict: [String: Any] = ["x": NSNumber(value: Int32(truncatingIfNeeded: pix[0])),
                                               "y": NSNumber(value: Int32(truncatingIfNeeded: pix[1])),
                                               "z": NSNumber(value: Int32(truncatingIfNeeded: pix[2]))]
                    NotificationCenter.default.post(name: .OsirixDisplay3dPoint, object: horos_pixList, userInfo: dict)
                }
            }
            drawLock?.unlock()
            return
        }

        let resizeThreshold = VTKRetinaGeometry.resizeHandleDisplayThreshold(pointThreshold: 20, scale: VTKRetinaGeometry.displayScale(of: self))
        if VTKRetinaGeometry.isViewportResizeHandle(x: horos_mouseLocStart.x, y: horos_mouseLocStart.y, threshold: resizeThreshold)
            && isViewportResizable() {
            horos_resizeFrame = true
        } else {
            horos_resizeFrame = false
            tool = getTool(theEvent)
            horos__tool = tool
            setCursorFor(tool)

            if tool != .tWL && tool != .tZoom {
                horos_isRotating = false

                resetAutorotate(self)
            }

            if tool == .tMesure {
                deleteMouseDownTimer()

                if horos_bestRenderingWasGenerated {
                    horos_bestRenderingWasGenerated = false
                    display()
                }
                IsiXVTKVolumeView.volumeRenderingSuppressed = true

                var pp = [Double](repeating: 0, count: 4)

                updateLineMeasurementProjections()
                selectStoredLineMeasurement(at: horos_mouseLocStart)

                var first = [Double](repeating: 0, count: 3), second = [Double](repeating: 0, count: 3)
                var editableEndpoint = -1
                if vtk.activeLinePointCount == 2 && vtk.activeLineVisible {
                    vtk.getActiveLinePoint(0, into: &first)
                    vtk.getActiveLinePoint(1, into: &second)
                    let tolerance = convertToBacking(NSSize(width: 8, height: 8)).width
                    editableEndpoint = VRMeasurementGeometry.editableEndpoint(at: horos_mouseLocStart,
                                                                              first: NSPoint(x: first[0], y: first[1]),
                                                                              second: NSPoint(x: second[0], y: second[1]), tolerance: tolerance)
                }
                if editableEndpoint >= 0 {
                    // The drag path updates the last endpoint. Reverse only the point
                    // order when editing the first handle, preserving the segment.
                    if editableEndpoint == 0 {
                        vtk.swapActiveLineEndpoints()
                    }
                } else {
                    if vtk.activeLinePointCount >= 2 {
                        storeCurrentLineMeasurement()
                        // Delete current ROI
                        vtk.clearActiveLine()
                    }

                    // Click point 3D to 2D

                    horos_mouseLocStart = VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)

                    vtk.worldPoint(ofDisplayX: Double(horos_mouseLocStart.x), y: Double(horos_mouseLocStart.y), z: 0, into: &pp)

                    // Create the 2D Actor

                    var tempPoint = [Double](repeating: 0, count: 3)
                    vtk.displayPoint(ofWorldX: pp[0], y: pp[1], z: pp[2], w: 1.0, into: &tempPoint)

                    NSLog("New pt: %2.2f %2.2f", tempPoint[0], tempPoint[1])

                    // Both ends at the click, the second one moved by the drag.
                    vtk.appendActiveLinePointX(tempPoint[0], y: tempPoint[1])
                    vtk.appendActiveLinePointX(tempPoint[0], y: tempPoint[1])
                    vtk.commitActiveLinePoints()
                }

                captureCurrentLineProjection()
                computeLength()

                needsDisplay = true
            } else if tool == .tAngle {
                deleteMouseDownTimer()

                if horos_bestRenderingWasGenerated {
                    horos_bestRenderingWasGenerated = false
                    display()
                }
                IsiXVTKVolumeView.volumeRenderingSuppressed = true

                horos_mouseLocStart = VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)
                var patient = [Double](repeating: 0, count: 3)
                if patientPointAtDisplayX(Float(horos_mouseLocStart.x), y: Float(horos_mouseLocStart.y), into: &patient) {
                    if horos_angleMeasurementCount >= 3 {
                        horos_angleMeasurementCount = 0
                    }
                    let stored = horos_angleMeasurementPatient + 3 * Int(horos_angleMeasurementCount)
                    stored[0] = patient[0]; stored[1] = patient[1]; stored[2] = patient[2]
                    horos_angleMeasurementCount += 1
                    updateAngleMeasurementProjection()
                }
                needsDisplay = true
            } else if tool == .tOval {
                deleteMouseDownTimer()

                vtk.hideOval()
                horos_Oval2DRadius = 0

                if horos_bestRenderingWasGenerated {
                    horos_bestRenderingWasGenerated = false
                    display()
                }
                IsiXVTKVolumeView.volumeRenderingSuppressed = true

                // Click point 3D to 2D
                horos_mouseLocStart = VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)

                var pp = [Double](repeating: 0, count: 4)
                vtk.worldPoint(ofDisplayX: Double(horos_mouseLocStart.x), y: Double(horos_mouseLocStart.y), z: 0, into: &pp)

                horos_WorldOval2DCenter = NSPoint(x: pp[0], y: pp[1])

                // Create the 2D Actor
                var tempPoint = [Double](repeating: 0, count: 3)
                vtk.displayPoint(ofWorldX: pp[0], y: pp[1], z: pp[2], w: 1.0, into: &tempPoint)

                horos_Oval2DCenter = NSPoint(x: tempPoint[0], y: tempPoint[1])

                computeLength()

                needsDisplay = true
            } else if tool == .t3DCut {
                var pp = [Double](repeating: 0, count: 4)

                if horos_bestRenderingWasGenerated {
                    horos_bestRenderingWasGenerated = false
                    display()
                }

                IsiXVTKVolumeView.volumeRenderingSuppressed = true

                // Click point 3D to 2D

                horos_mouseLocStart = VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)

                vtk.worldPoint(ofDisplayX: Double(horos_mouseLocStart.x), y: Double(horos_mouseLocStart.y), z: 0, into: &pp)

                // Create the 2D Actor

                var tempPoint = [Double](repeating: 0, count: 3)
                vtk.displayPoint(ofWorldX: pp[0], y: pp[1], z: pp[2], w: 1.0, into: &tempPoint)

                NSLog("New pt: %2.2f %2.2f", tempPoint[0], tempPoint[1])

                horos_ROIPoints?.add(NSValue(point: NSPoint(x: tempPoint[0], y: tempPoint[1])))
                generateROI()

                needsDisplay = true
            } else if tool == .tWL {
                let wl = horos_wl, ww = horos_ww
                horos_startWW = ww
                horos_startWL = wl
                horos_startMin = wl - ww / 2
                horos_startMax = wl + ww / 2

                horos_mouseLocStart = VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)

                vtk.setVolumeMinimumImageSampleDistance(LOD * lowResLODFactor)

                vtk.setBlendingMinimumImageSampleDistance(LOD * lowResLODFactor)
            } else if tool == .tWLBlended {
                let wl = horos_blendingWl, ww = horos_blendingWw
                horos_startWW = ww
                horos_startWL = wl
                horos_startMin = wl - ww / 2
                horos_startMax = wl + ww / 2

                horos_mouseLocStart = VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)

                vtk.setVolumeMinimumImageSampleDistance(LOD * lowResLODFactor)

                vtk.setBlendingMinimumImageSampleDistance(LOD * lowResLODFactor)
            } else if tool == .tRotate {
                vtk.setVolumeMinimumImageSampleDistance(LOD * lowResLODFactor)

                vtk.setBlendingMinimumImageSampleDistance(LOD * lowResLODFactor)

                horos_mouseLocStart = VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)
                mouseLoc = horos_mouseLocStart
                vtk.setInteractorEventX(CConversion.int(Double(mouseLoc.x)), y: CConversion.int(Double(mouseLoc.y)), control: 1, shift: 0)
                vtk.invokeInteractorEvent(.leftButtonPress)
            } else if tool == .t3DRotate || tool == .tCamera3D {
                if horos__tool == .tCamera3D || clipRangeActivated {
                    horos_mouseLocStart = VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)
                    mouseLocPre = horos_mouseLocStart

                    vtk.setVolumeMinimumImageSampleDistance(LOD * lowResLODFactor)
                    vtk.setBlendingMinimumImageSampleDistance(LOD * lowResLODFactor)

                    horos_hasSlabRotationPivot = false
                    if clipRangeActivated && !keep3DRotateCentered {
                        // The camera's eye sits on the slab's front face, at the
                        // start of the clipping range: the pivot is half the
                        // thickness further along the view, under the click.
                        var eye = [Double](repeating: 0, count: 3), direction = [Double](repeating: 0, count: 3)
                        var middle = [Double](repeating: 0, count: 3), display = [Double](repeating: 0, count: 3)
                        var pivot = [Double](repeating: 0, count: 4)
                        vtk.getCameraPosition(&eye)
                        vtk.getCameraDirection(ofProjection: &direction)
                        let thickness = Double(clippingRangeThickness)
                        for i in 0..<3 {
                            middle[i] = eye[i] + direction[i] * thickness / 2.0
                        }

                        vtk.interactorWorld(toDisplayX: middle[0], y: middle[1], z: middle[2], display: &display)
                        vtk.interactorDisplay(toWorldX: Double(mouseLocPre.x), y: Double(mouseLocPre.y), z: display[2], world: &pivot)

                        if pivot[3] != 0 && pivot[0].isFinite && pivot[1].isFinite && pivot[2].isFinite {
                            let slabPivot = horos_slabRotationPivot
                            for i in 0..<3 {
                                slabPivot[i] = pivot[i]
                            }
                            horos_hasSlabRotationPivot = true
                        }
                    }
                } else {
                    vtk.setVolumeMinimumImageSampleDistance(LOD * lowResLODFactor)

                    vtk.setBlendingMinimumImageSampleDistance(LOD * lowResLODFactor)

                    mouseLoc = VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)

                    vtk.setInteractorEventX(CConversion.int(Double(mouseLoc.x)), y: CConversion.int(Double(mouseLoc.y)), control: 0, shift: 0)
                    vtk.invokeInteractorEvent(.leftButtonPress)

                    // By default the drag turns about the focal point, the centre
                    // of the view. With "rotate3DAroundPointUnderMouse" it turns
                    // about the visible surface under the pointer where it starts,
                    // which helps when a wide view angle leaves the focal point far
                    // to the side of what the user looks at; off the volume it
                    // still turns about the focal point.
                    var pix = [Int](repeating: 0, count: 3)
                    var surface = [Float](repeating: 0, count: 3), value: Float = 0
                    if !keep3DRotateCentered && UserDefaults.standard.bool(forKey: "rotate3DAroundPointUnderMouse")
                        && get3DPixelUnder2DPositionX(Float(mouseLoc.x), y: Float(mouseLoc.y), pixel: &pix, position: &surface, value: &value) {
                        let factor = horos_factor
                        let pivot = [Double(surface[0] * factor), Double(surface[1] * factor), Double(surface[2] * factor)]
                        vtk.setInteractorRotationPivot(pivot)
                    } else {
                        vtk.clearInteractorRotationPivot()
                    }

                    if clipRangeActivated {
                        vtk.setCameraClippingRangeNear(0.0, far: Double(clippingRangeThickness))
                    } else {
                        vtk.resetCameraClippingRange()
                    }
                }
            } else if tool == .tTranslate {
                vtk.setVolumeMinimumImageSampleDistance(LOD * lowResLODFactor)

                vtk.setBlendingMinimumImageSampleDistance(LOD * lowResLODFactor)

                mouseLoc = VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)
                vtk.setInteractorEventX(CConversion.int(Double(mouseLoc.x)), y: CConversion.int(Double(mouseLoc.y)), control: 0, shift: 1)
                vtk.invokeInteractorEvent(.leftButtonPress)
            } else if tool == .tZoom {
                vtk.setVolumeMinimumImageSampleDistance(LOD * lowResLODFactor)

                vtk.setBlendingMinimumImageSampleDistance(LOD * lowResLODFactor)

                if projectionMode != 2 {
                    mouseLoc = VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)
                    vtk.setInteractorEventX(CConversion.int(Double(mouseLoc.x)), y: CConversion.int(Double(mouseLoc.y)), control: 1, shift: 0)
                    vtk.invokeInteractorEvent(.rightButtonPress)
                } else {
                    // vtkCamera
                    horos_mouseLocStart = VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)
                    mouseLocPre = horos_mouseLocStart

                    vtk.setVolumeMinimumImageSampleDistance(LOD * lowResLODFactor)
                    vtk.setBlendingMinimumImageSampleDistance(LOD * lowResLODFactor)
                }
            } else if tool == .t3Dpoint {
                deleteMouseDownTimer()

                let artificialPKeyDown = NSEvent.keyEvent(with: .keyDown, location: theEvent.locationInWindow, modifierFlags: [],
                                                          timestamp: theEvent.timestamp, windowNumber: theEvent.windowNumber,
                                                          context: nil, characters: "p", charactersIgnoringModifiers: "p",
                                                          isARepeat: false, keyCode: 112)
                vtk.setBlendingPickable(false)

                if let artificialPKeyDown { horosVTKKeyDown(artificialPKeyDown) }

                if !isAny3DPointSelected() {
                    // add a point on the surface under the mouse click
                    throw3DPointOnSurface(Double(horos_mouseLocStart.x), Double(horos_mouseLocStart.y))
                    needsDisplay = true
                } else {
                    let selected = Int(selected3DPointIndex())
                    point3DRadiusSlider?.floatValue = unsafeBitCast(horos_point3DRadiusArray.object(at: selected) as AnyObject,
                                                                          to: NSNumber.self).floatValue
                    point3DColorWell?.color = unsafeBitCast(horos_point3DColorsArray.object(at: selected) as AnyObject, to: NSColor.self)

                    if clickCount == 2, let panel = point3DInfoPanel {
                        let r = NSRect(origin: theEvent.locationInWindow, size: .zero)
                        let mouseLocationOnScreen = window?.convertToScreen(r).origin ?? .zero
                        panel.alphaValue = 0.8
                        panel.setFrame(NSRect(x: mouseLocationOnScreen.x - panel.frame.size.width / 2.0,
                                              y: mouseLocationOnScreen.y - panel.frame.size.height - 20.0,
                                              width: panel.frame.size.width,
                                              height: panel.frame.size.height),
                                       display: true, animate: false)
                        panel.orderFront(self)

                        var pos = [Float](repeating: 0, count: 3)
                        unsafeBitCast(horos_point3DPositionsArray.object(at: selected) as AnyObject, to: NSValue.self).getValue(&pos)

                        let controller = horos_controller
                        let roi = unsafeBitCast(controller?.roi2DPointsArray?.object(at: selected) as AnyObject, to: ROI.self)
                        let point = unsafeBitCast(roi.points.object(at: 0) as AnyObject, to: MyPoint.self)
                        let pix = [CConversion.int(Double(point.x)),
                                   CConversion.int(Double(point.y)),
                                   unsafeBitCast(controller?.sliceNumber2DPointsArray?.object(at: selected) as AnyObject,
                                                 to: NSNumber.self).int32Value]

                        let dict: [String: Any] = ["x": NSNumber(value: pix[0]), "y": NSNumber(value: pix[1]), "z": NSNumber(value: pix[2])]
                        NotificationCenter.default.post(name: .OsirixDisplay3dPoint, object: horos_pixList, userInfo: dict)
                    }
                }
            } else if tool == .tBonesRemoval {
                deleteMouseDownTimer()
                removeBones(at: theEvent)
            } else {
                horosForwardMouseEvent(.leftButtonPress, event: theEvent)
            }

            vtk.setCropBoxHandleSize(0.005)
        }

        horos_bestRenderingWasGenerated = false
        horos_noWaitDialog = false
        drawLock?.unlock()
    }

    /// The bone removal of a click: a region grown from the dense voxel under
    /// the click, dilated and eroded, set to -1000 in every frame of the series.
    private func removeBones(at theEvent: NSEvent) {
        NSLog("**** Bone Removal Start")
        // enable Undo
        let controller = horos_controller
        controller?.prepareUndo()
        NSLog("**** Undo")

        // clicked point (2D coordinate)
        horos_mouseLocStart = VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)

        var pix = [Int](repeating: 0, count: 3)
        var pos = [Float](repeating: 0, count: 3), value: Float = 0
        let defaults = UserDefaults.standard
        let minValue = Float(Double(defaults.float(forKey: "VRGrowingRegionValue")) - Double(defaults.float(forKey: "VRGrowingRegionInterval")) / 3.0)

        if get3DPixelUnder2DPositionX(Float(horos_mouseLocStart.x), y: Float(horos_mouseLocStart.y), pixel: &pix, position: &pos,
                                      value: &value, maxOpacity: 1.1, minValue: minValue) {
            let waiting = WaitRendering(NSLocalizedString("Applying Bone Removal...", comment: ""))
            waiting?.showWindow(self)

            var roiList: [[String: Any]] = []

            NSLog("ITKSegmentation3D")

            let viewer = controller?.viewer2D()
            let savedMovieIndex = Int(viewer?.curMovieIndex() ?? 0)

            var m = 0
            while m < Int(viewer?.maxMovieIndex() ?? 0) {
                viewer?.setMovieIndex(Int16(truncatingIfNeeded: m))
                viewer?.imageView()?.setIndex(pix[2]) // set the DCMview on the good slice

                let seedPoint = NSPoint(x: pix[0], y: pix[1])

                let itkSegmentation = ITKSegmentation3D(viewer?.pixList(), viewer?.volumePtr(), -1)

                let interval = Double(defaults.float(forKey: "VRGrowingRegionInterval"))
                let regionValue = Double(defaults.float(forKey: "VRGrowingRegionValue"))
                itkSegmentation?.regionGrowing3D(viewer, // source viewer
                                                 nil, // destination viewer = nil means we don't want a new serie
                                                 -1, // slice = -1 means 3D region growing
                                                 seedPoint, // startingPoint
                                                 1, // algorithmNumber, 1 = threshold connected with low & up threshold
                                                 [NSNumber(value: Float(regionValue - interval / 2.0)),
                                                  NSNumber(value: Float(regionValue + interval / 2.0))], // algo parameters
                                                 false, // setIn
                                                 0.0, // inValue
                                                 false, // setOut
                                                 0.0, // outValue
                                                 ToolMode(rawValue: 0)!, // roiType
                                                 0, // roiResolution
                                                 "BoneRemovalAlgorithmROIUniqueName", // newname (I tried to make it unique ;o)
                                                 false) // merge with existing ROIs?

                // find all ROIs with name = BoneRemoval
                let rois = viewer?.rois(withName: "BoneRemovalAlgorithmROIUniqueName") ?? []

                // As +dictionaryWithObjectsAndKeys: built them: a nil value ends the list.
                var d: [[String: Any]] = []
                for r in rois {
                    let roi = unsafeBitCast(r as AnyObject, to: ROI.self)
                    var entry: [String: Any] = ["roi": roi]
                    if let curPix = roi.pix { entry["curPix"] = curPix }
                    d.append(entry)
                }

                roiList = d

                // Dilatation
                let roiObjects = roiList.compactMap { $0["roi"] }
                viewer?.applyMorphology(roiObjects, action: "dilate", radius: 10, sendNotification: false)
                viewer?.applyMorphology(roiObjects, action: "erode", radius: 6, sendNotification: false)

                let addition = false

                // Bone Removal
                let nsnewValue = NSNumber(value: Float(-1000))
                let nsminValue = NSNumber(value: -Float.greatestFiniteMagnitude)
                let nsmaxValue = NSNumber(value: Float.greatestFiniteMagnitude)
                let nsoutside = NSNumber(value: false)
                let nsaddition = NSNumber(value: addition)
                var roiToProceed: [[String: Any]] = []

                for rr in roiList {
                    var entry: [String: Any] = ["roi": rr["roi"] as Any]
                    if let curPix = rr["curPix"] {
                        entry.merge(["curPix": curPix, "action": "setPixelRoi", "newValue": nsnewValue, "minValue": nsminValue,
                                     "maxValue": nsmaxValue, "outside": nsoutside, "addition": nsaddition]) { $1 }
                    }
                    roiToProceed.append(entry)
                }

                viewer?.roiSetStartScheduler(NSMutableArray(array: roiToProceed))
                controller?.horosVolumeMetalRelease()

                NSLog("**** Set Pixels")

                // Update 3D image
                if !horos_isRGB {
                    BrowserController.multiThreadedImageConvert("FTo16U", horos_srcf, horos_dst8, -horos_OFFSET16, Float(1.0 / Double(horos_valueFactor)))
                }
                applyMovieRangeGuardTo16BitVolume()

                m += 1
            }

            viewer?.setMovieIndex(Int16(truncatingIfNeeded: savedMovieIndex))

            needsDisplay = true

            waiting?.close()

            viewer?.roiIntDeleteAllROIs(withSameName: "BoneRemovalAlgorithmROIUniqueName")

            viewer?.needsDisplayUpdate()
        } else {
            _ = HorosAlertPanel.run(title: NSLocalizedString("Bone Removing", comment: ""),
                                    message: NSLocalizedString("Failed to detect a high density voxel to start growing region.", comment: ""),
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }

        NSLog("**** Bone Removal End")
    }

    // MARK: - Drag

    public override func mouseDragged(with theEvent: NSEvent) {
        if eventToPlugins(theEvent) { return }

        horos_hasChanged = true

        if !horos_dragInProgress && (theEvent.deltaX != 0 || theEvent.deltaY != 0) {
            deleteMouseDownTimer()
        }

        if horos_dragInProgress { return }

        let drawLock = VRView.horos_drawLock
        drawLock?.lock()

        let vtk = horos_vtk

        if horos_resizeFrame {
            var newFrame = frame
            let beforeFrame: NSRect
            var mouseLoc = theEvent.locationInWindow
            let content = window?.contentView?.frame ?? .zero

            vtk.setVolumeMinimumImageSampleDistance(horos_LOD * lowResLODFactor)
            vtk.setBlendingMinimumImageSampleDistance(horos_LOD * lowResLODFactor)

            beforeFrame = frame

            if theEvent.modifierFlags.contains(.shift) {
                newFrame.size.width = content.size.width - mouseLoc.x * 2
                newFrame.size.height = newFrame.size.width

                mouseLoc.x = (content.size.width - newFrame.size.width) / 2
                mouseLoc.y = (content.size.height - newFrame.size.height) / 2
                mouseLoc.y -= 5
            }

            if content.size.width - mouseLoc.x * 2 < 100 {
                mouseLoc.x = (content.size.width - 100) / 2
            }

            if content.size.height - mouseLoc.y * 2 < 100 {
                mouseLoc.y = (content.size.height - 100) / 2
            }

            if mouseLoc.x < 10 {
                mouseLoc.x = 10
            }

            if mouseLoc.y < 10 {
                mouseLoc.y = 10
            }

            newFrame.origin.x = mouseLoc.x
            newFrame.origin.y = mouseLoc.y

            newFrame.size.width = content.size.width - mouseLoc.x * 2
            newFrame.size.height = content.size.height - 10 - mouseLoc.y * 2

            // Internal viewport resizing compensates the camera zoom to keep the
            // pixel scale fixed, unlike ordinary window resizing and matrix export.
            let cameraZoom = Double(beforeFrame.size.height / newFrame.size.height)
            adaptLine2D(toResize: newFrame, before: beforeFrame, cameraZoom: cameraZoom)
            super.frame = newFrame

            mouseMoved(with: theEvent)

            vtk.cameraZoom(cameraZoom)

            window?.display()
        } else {
            let mouseLoc = VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)
            switch horos__tool {
            case .tOval:
                deleteMouseDownTimer()

                if horos_bestRenderingWasGenerated {
                    horos_bestRenderingWasGenerated = false
                    display()
                }
                IsiXVTKVolumeView.volumeRenderingSuppressed = true

                var pp = [Double](repeating: 0, count: 4)

                // Click point 3D to 2D

                vtk.worldPoint(ofDisplayX: Double(mouseLoc.x), y: Double(mouseLoc.y), z: 0, into: &pp)

                // Create the 2D Actor

                var tempPoint = [Double](repeating: 0, count: 3)
                vtk.displayPoint(ofWorldX: pp[0], y: pp[1], z: pp[2], w: 1.0, into: &tempPoint)

                let center = horos_Oval2DCenter
                let dx = Float(Double(center.x) - tempPoint[0])
                let dy = Float(Double(center.y) - tempPoint[1])
                horos_Oval2DRadius = Double((dy * dy).addingProduct(dx, dx)).squareRoot()

                vtk.showOval(withCenterX: Double(center.x), y: Double(center.y), radius: horos_Oval2DRadius)

                computeLength()

                _ = getCosMatrix(horos_Oval2DCos)
                getOrigin(horos_Oval2DPosition)

                needsDisplay = true

            case .tMesure:
                deleteMouseDownTimer()

                if horos_bestRenderingWasGenerated {
                    horos_bestRenderingWasGenerated = false
                    display()
                }
                IsiXVTKVolumeView.volumeRenderingSuppressed = true

                var pp = [Double](repeating: 0, count: 4)

                if vtk.activeLinePointCount > 0 {
                    // Click point 3D to 2D

                    vtk.worldPoint(ofDisplayX: Double(mouseLoc.x), y: Double(mouseLoc.y), z: 0, into: &pp)

                    // Create the 2D Actor

                    var tempPoint = [Double](repeating: 0, count: 3)
                    vtk.displayPoint(ofWorldX: pp[0], y: pp[1], z: pp[2], w: 1.0, into: &tempPoint)

                    vtk.moveLastActiveLinePointX(tempPoint[0], y: tempPoint[1])

                    captureCurrentLineProjection()
                    computeLength()

                    needsDisplay = true
                }

            case .tAngle:
                deleteMouseDownTimer()
                if horos_angleMeasurementCount > 0 {
                    let loc = VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)
                    var patient = [Double](repeating: 0, count: 3)
                    if patientPointAtDisplayX(Float(loc.x), y: Float(loc.y), into: &patient) {
                        let stored = horos_angleMeasurementPatient + 3 * Int(horos_angleMeasurementCount - 1)
                        stored[0] = patient[0]; stored[1] = patient[1]; stored[2] = patient[2]
                        updateAngleMeasurementProjection()
                        needsDisplay = true
                    }
                }

            case .tWLBlended:
                let (wl, ww) = draggedWindow(theEvent, wl: horos_blendingWl, ww: horos_blendingWw,
                                             modality: horos_controller?.blendingController()?.modality())
                horos_blendingWl = wl
                horos_blendingWw = ww < 0.1 ? 0.1 : ww

                setBlendingWLWW(horos_blendingWl, horos_blendingWw)

                needsDisplay = true

            case .tWL:
                let modality = horos_controller?.viewer2D()?.modality()
                var (wl, ww) = draggedWindow(theEvent, wl: horos_wl, ww: horos_ww, modality: modality)

                if ww < 0.1 { ww = 0.1 }
                horos_wl = wl
                horos_ww = ww

                setOpacity(horos_currentOpacityArray)

                if horos_isRGB {
                    vtk.buildColour(fromTable: horos_table, start: Double(wl - ww / 2), end: Double(wl + ww / 2))
                } else if horos_advancedCLUT {
                    clutOpacityView?.setWL(wl, ww: ww)
                    clutOpacityView?.setCLUTtoVRView(true)
                    drawLock?.unlock()
                    return
                } else {
                    let valueFactor = horos_valueFactor, offset = horos_OFFSET16
                    vtk.buildColour(fromTable: horos_table, start: Double(valueFactor * (offset + wl - ww / 2)),
                                    end: Double(valueFactor * (offset + wl + ww / 2)))
                }

                let text: String
                if modality == "PT" || (UserDefaults.standard.bool(forKey: "mouseWindowingNM") && modality == "NM") {
                    if ww < 50 {
                        text = String(format: "From: %0.4f   To: %0.4f ", Double(wl - ww / 2), Double(wl + ww / 2))
                    } else {
                        text = String(format: "From: %0.f   To: %0.f ", Double(wl - ww / 2), Double(wl + ww / 2))
                    }
                } else {
                    if ww < 50 {
                        text = String(format: "WL: %0.4f WW: %0.4f ", Double(wl), Double(ww))
                    } else {
                        text = String(format: "WL: %0.f WW: %0.f ", Double(wl), Double(ww))
                    }
                }
                let windowText = horos_WLWWString
                _ = strlcpy(windowText, text, 200)

                vtk.setWindowText(windowText)
                needsDisplay = true

            case .t3DCut:
                let scissorsThreshold = VTKRetinaGeometry.scissorsDragThreshold(pointThreshold: 5, scale: VTKRetinaGeometry.displayScale(of: self))
                let previousLoc = horos_previousLoc
                if abs(mouseLoc.x - previousLoc.x) > scissorsThreshold || abs(mouseLoc.y - previousLoc.y) > scissorsThreshold {
                    var pp = [Double](repeating: 0, count: 4)

                    vtk.worldPoint(ofDisplayX: Double(mouseLoc.x), y: Double(mouseLoc.y), z: 0, into: &pp)

                    // Create the 2D Actor

                    var tempPoint = [Double](repeating: 0, count: 3)
                    vtk.displayPoint(ofWorldX: pp[0], y: pp[1], z: pp[2], w: 1.0, into: &tempPoint)

                    horos_ROIPoints?.add(NSValue(point: NSPoint(x: tempPoint[0], y: tempPoint[1])))

                    generateROI()

                    needsDisplay = true

                    horos_previousLoc = mouseLoc
                }

            case .tRotate:
                VRInteractionBenchmark.beginSample("rotate")
                vtk.setInteractorEventX(CConversion.int(Double(mouseLoc.x)), y: CConversion.int(Double(mouseLoc.y)), control: 1, shift: 0)
                computeOrientationText()
                vtk.invokeInteractorEvent(.move)
                NotificationCenter.default.post(name: .OsirixVRCameraDidChange, object: self, userInfo: nil)
                VRInteractionBenchmark.endSample()

            case .t3DRotate, .tCamera3D:
                VRInteractionBenchmark.beginSample(clipRangeActivated ? "clip" : "rotate")
                if horos__tool == .tCamera3D || clipRangeActivated {
                    // Yaw and Pitch turn the camera about its eye, on the
                    // slab's front face. With a pivot, the camera then moves
                    // back so the pivot keeps its place in the camera's own
                    // frame: same pixel, same depth in the slab.
                    var pivotInCamera: [Double] = [0, 0, 0, 1]
                    let aroundPivot = horos_hasSlabRotationPivot && clipRangeActivated && !keep3DRotateCentered
                    let slabPivot = horos_slabRotationPivot
                    if aroundPivot {
                        let pivot = [slabPivot[0], slabPivot[1], slabPivot[2], 1]
                        vtk.cameraViewTransformPoint(pivot, into: &pivotInCamera)
                    }

                    vtk.cameraYaw(-Double(theEvent.deltaX) / 5.0)
                    vtk.cameraPitch(-Double(theEvent.deltaY) / 5.0)
                    vtk.cameraComputeViewPlaneNormal()
                    vtk.cameraOrthogonalizeViewUp()

                    if aroundPivot {
                        var moved = [Double](repeating: 0, count: 4)
                        vtk.cameraInverseViewTransformPoint(pivotInCamera, into: &moved)

                        vtk.cameraTranslateX(slabPivot[0] - moved[0], y: slabPivot[1] - moved[1], z: slabPivot[2] - moved[2])
                    }

                    if clipRangeActivated {
                        vtk.setCameraClippingRangeNear(0.0, far: Double(clippingRangeThickness))
                    } else {
                        vtk.resetCameraClippingRange()
                    }

                    computeOrientationText()
                    needsDisplay = true
                    NotificationCenter.default.post(name: .OsirixVRCameraDidChange, object: self, userInfo: nil)
                } else {
                    vtk.setInteractorEventX(CConversion.int(Double(mouseLoc.x)), y: CConversion.int(Double(mouseLoc.y)), control: 0, shift: 0)
                    computeOrientationText()
                    vtk.invokeInteractorEvent(.move)
                    NotificationCenter.default.post(name: .OsirixVRCameraDidChange, object: self, userInfo: nil)
                }
                VRInteractionBenchmark.endSample()

            case .tTranslate:
                VRInteractionBenchmark.beginSample("pan")
                vtk.setInteractorEventX(CConversion.int(Double(mouseLoc.x)), y: CConversion.int(Double(mouseLoc.y)), control: 0, shift: 1)
                vtk.invokeInteractorEvent(.move)
                NotificationCenter.default.post(name: .OsirixVRCameraDidChange, object: self, userInfo: nil)
                VRInteractionBenchmark.endSample()

            case .tZoom:
                rightMouseDragged(with: theEvent)

            default:
                break
            }
        }

        vtk.setCropBoxHandleSize(0.005)

        drawLock?.unlock()

        horos_bestRenderingWasGenerated = false
    }

    /// The window and level after a drag from the press's (_startWL, _startWW):
    /// PET (and NM, when the preference says so) as the PET windowing mode
    /// says, the others by the drag's deltas.
    private func draggedWindow(_ theEvent: NSEvent, wl: Float, ww: Float, modality: String?) -> (Float, Float) {
        var wl = wl, ww = ww
        horos_startWW = ww
        horos_startWL = wl
        horos_startMin = wl - ww / 2
        horos_startMax = wl + ww / 2
        let startWW = horos_startWW, startWL = horos_startWL, startMin = horos_startMin, startMax = horos_startMax
        let wwAdapter = Float(Double(startWW) / 100.0)
        let dx = Double(theEvent.deltaX), dy = Double(theEvent.deltaY)
        let defaults = UserDefaults.standard

        if modality == "PT" || (defaults.bool(forKey: "mouseWindowingNM") && modality == "NM") {
            switch defaults.integer(forKey: "PETWindowingMode") {
            case 0:
                wl = startWL.addingProduct(-Float(CConversion.long(dy)), wwAdapter)
                ww = startWW.addingProduct(Float(CConversion.long(dx)), wwAdapter)

                if ww < 0.1 { ww = 0.1 }

            case 1:
                let endlevel = Float(Double(startMax).addingProduct(-dy, Double(wwAdapter)))

                wl = (endlevel - startMin) / 2 + Float(defaults.integer(forKey: "PETMinimumValue"))
                ww = endlevel - startMin

                if ww < 0.1 { ww = 0.1 }
                if wl - ww / 2 < 0 { wl = ww / 2 }

            case 2:
                let endlevel = Float(Double(startMax).addingProduct(-dy, Double(wwAdapter)))
                var startlevel = Float(Double(startMin).addingProduct(dx, Double(wwAdapter)))

                if startlevel < 0 { startlevel = 0 }

                wl = startlevel + (endlevel - startlevel) / 2
                ww = endlevel - startlevel

                if ww < 0.1 { ww = 0.1 }
                if wl - ww / 2 < 0 { wl = ww / 2 }

            default:
                break
            }
        } else {
            wl = startWL.addingProduct(-Float(CConversion.long(dy)), wwAdapter)
            ww = startWW.addingProduct(Float(CConversion.long(dx)), wwAdapter)
        }

        return (wl, ww)
    }

    public override func rightMouseDragged(with theEvent: NSEvent) {
        if eventToPlugins(theEvent) { return }

        horos_hasChanged = true
        let drawLock = VRView.horos_drawLock
        drawLock?.lock()
        let vtk = horos_vtk
        let mouseLoc = VRInteractionGeometry.backingPoint(theEvent.locationInWindow, in: self)

        if theEvent.deltaX != 0 || theEvent.deltaY != 0 {
            deleteRightMouseDownTimer()
        }

        if projectionMode != 2 {
            vtk.setInteractorEventX(CConversion.int(Double(mouseLoc.x)), y: CConversion.int(Double(mouseLoc.y)), control: 1, shift: 0)
            computeLength()
            vtk.invokeInteractorEvent(.move)
            NotificationCenter.default.post(name: .OsirixVRCameraDidChange, object: self, userInfo: nil)
        } else {
            // A float, as the Objective-C kept it.
            let distance = Float(vtk.cameraDistance)
            vtk.cameraDolly(1.0 + PreciseMouse.appliedDelta(-Double(theEvent.deltaY)) / 1200.0)
            vtk.cameraDistance = Double(distance)
            vtk.cameraComputeViewPlaneNormal()
            vtk.cameraOrthogonalizeViewUp()

            if clipRangeActivated {
                vtk.setCameraClippingRangeNear(0.0, far: Double(clippingRangeThickness))
            } else {
                vtk.resetCameraClippingRange()
            }

            needsDisplay = true
            NotificationCenter.default.post(name: .OsirixVRCameraDidChange, object: self, userInfo: nil)
        }

        vtk.setCropBoxHandleSize(0.005)

        drawLock?.unlock()
    }

    // MARK: - Release

    public override func mouseUp(with theEvent: NSEvent) {
        if eventToPlugins(theEvent) { return }

        horos_hasChanged = true
        deleteMouseDownTimer()
        if horos_contextualMenuActive {
            rightMouseUp(with: theEvent)
            return
        }

        let drawLock = VRView.horos_drawLock
        drawLock?.lock()

        let vtk = horos_vtk
        let LOD = horos_LOD
        vtk.setVolumeMinimumImageSampleDistance(LOD)
        vtk.setBlendingMinimumImageSampleDistance(LOD)

        if horos_resizeFrame {
            needsDisplay = true
        } else {
            switch horos__tool {
            case .t3DRotate, .tCamera3D:
                if horos__tool == .tCamera3D || clipRangeActivated {
                    horos_hasSlabRotationPivot = false
                    if !keep3DRotateCentered {
                        // Reset window center
                        let xx: Double = 0
                        let yy: Double = 0

                        var pWC = [Double](repeating: 0, count: 2)
                        vtk.getCameraWindowCenter(&pWC)
                        let display = VTKRetinaGeometry.displaySize(of: self)
                        pWC[0] *= Double(display.width / 2.0)
                        pWC[1] *= Double(display.height / 2.0)

                        if pWC[0] != xx || pWC[1] != yy {
                            vtk.setCameraWindowCenterX(0, y: 0)
                            panX(Double(display.width / 2.0).addingProduct(-(pWC[0] - xx), 10000.0),
                                 y: Double(display.height / 2.0).addingProduct(-(pWC[1] - yy), 10000.0))
                        }
                    }
                    needsDisplay = true
                } else {
                    vtk.setVolumeMinimumImageSampleDistance(LOD)

                    vtk.setBlendingMinimumImageSampleDistance(LOD)

                    vtk.invokeInteractorEvent(.leftButtonRelease)
                    NotificationCenter.default.post(name: .OsirixVRCameraDidChange, object: self, userInfo: nil)
                }

            case .tWL, .tWLBlended:
                needsDisplay = true
            case .tRotate, .tTranslate:
                vtk.setVolumeMinimumImageSampleDistance(LOD)

                vtk.setBlendingMinimumImageSampleDistance(LOD)

                vtk.invokeInteractorEvent(.leftButtonRelease)
                NotificationCenter.default.post(name: .OsirixVRCameraDidChange, object: self, userInfo: nil)
            case .tZoom:
                zoomMouseUp(theEvent)
            case .tMesure, .tAngle, .tOval, .t3DCut:
                displayIfNeeded()
                IsiXVTKVolumeView.volumeRenderingSuppressed = false
            case .tBonesRemoval: // <- DO NOTHING !
                break
            default:
                needsDisplay = true
            }
        }

        horos_bestRenderingWasGenerated = false

        drawLock?.unlock()
    }

    @objc(zoomMouseUp:)
    func zoomMouseUp(_ theEvent: NSEvent) {
        if eventToPlugins(theEvent) { return }

        horos_hasChanged = true
        if horos__tool == .tZoom {
            let vtk = horos_vtk
            vtk.setVolumeMinimumImageSampleDistance(horos_LOD)

            vtk.setBlendingMinimumImageSampleDistance(horos_LOD)

            if projectionMode != 2 {
                computeLength()
                vtk.invokeInteractorEvent(.leftButtonRelease)
            } else {
                needsDisplay = true
            }

            NotificationCenter.default.post(name: .OsirixVRCameraDidChange, object: self, userInfo: nil)
        }
    }

    public override func rightMouseDown(with theEvent: NSEvent) {
        if eventToPlugins(theEvent) { return }

        horos_hasChanged = true
        let drawLock = VRView.horos_drawLock
        drawLock?.lock()
        horos_contextualMenuActive = false
        if horos_rightMouseDownTimer != nil {
            deleteRightMouseDownTimer()
        }

        mouseDown(with: theEvent)

        drawLock?.unlock()
    }

    public override func rightMouseUp(with theEvent: NSEvent) {
        if eventToPlugins(theEvent) { return }

        horos_hasChanged = true
        let drawLock = VRView.horos_drawLock
        drawLock?.lock()

        deleteRightMouseDownTimer()
        if horos_contextualMenuActive {
            // Never set: no contextual menu raises it. The lock stays taken, as
            // it did in the Objective-C.
            horos_contextualMenuActive = false
            horos_vtk.invokeInteractorEvent(.leftButtonRelease)
            return
        }

        if horos__tool == .tZoom {
            zoomMouseUp(theEvent)
        }

        drawLock?.unlock()
    }
}
