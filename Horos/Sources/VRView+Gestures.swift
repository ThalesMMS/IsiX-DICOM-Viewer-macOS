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

// The gestures of VRView other than a click and its drag: the plugins' first
// look at an event, the tool of an event and its modifier keys, the wheel,
// the middle button, the pointer's hover field, the trackpad's pinch and
// rotation, and the keys VTK's interactor answered. A Swift extension of the
// class, with the same selectors.
//
// -mouseMoved: is also sent with no event (after a measurement or a camera
// change, with the application's current event, which can be nil): it reads
// the event as the Objective-C did, as zeros.

/// The plugins' event handler for the 3D viewer, a selector some plugins answer.
@objc private protocol VRInputPluginMessages {
    @objc(handleEvent:forVRViewer:) func handleEvent(_ event: NSEvent?, forVRViewer viewer: AnyObject?) -> Bool
}

extension VRView {

    // MARK: - Plugins and tools

    /// The plugins' chance to take an event first (-handleEvent:forVRViewer: of
    /// the plugins' filters): YES when one did.
    @objc(eventToPlugins:)
    func eventToPlugins(_ event: NSEvent?) -> Bool {
        var used = false

        guard let plugins = PluginManager.plugins() else { return false }
        let keys = plugins.keyEnumerator()
        while let key = keys.nextObject() {
            let plugin = plugins.object(forKey: key) as AnyObject?
            if plugin?.responds(to: #selector(VRInputPluginMessages.handleEvent(_:forVRViewer:))) == true {
                if unsafeBitCast(plugin, to: VRInputPluginMessages.self).handleEvent(event, forVRViewer: window?.windowController) {
                    used = true
                }
            }
        }

        return used
    }

    /// The tool of an event: the right button zooms (unless the contextual menu
    /// is up), the middle one pans, and the modifier keys choose over the
    /// current tool.
    @objc(getTool:)
    func getTool(_ event: NSEvent?) -> ToolMode {
        var tool: ToolMode
        let type = event?.type
        if (type == .rightMouseDown || type == .rightMouseDragged || type == .rightMouseUp) && !horos_contextualMenuActive {
            tool = .tZoom
        } else if type == .otherMouseDown || type == .otherMouseDragged || type == .otherMouseUp {
            tool = .tTranslate
        } else {
            tool = horos_currentTool
        }

        let flags = event?.modifierFlags ?? []
        if flags.contains(.control) { tool = .tRotate }
        if flags.contains(.shift) { tool = .tZoom }
        if flags.contains(.command) { tool = .tTranslate }
        if flags.contains(.option) { tool = .tWL }
        if flags.contains(.command) && flags.contains(.option) { tool = .tRotate }
        if flags.contains(.command) && flags.contains(.control) { tool = .tCamera3D }

        return tool
    }

    public override func flagsChanged(with event: NSEvent) {
        setCursorFor(getTool(event))
        if horos_cursorSet { horos_cursor?.set() }
        super.flagsChanged(with: event)
    }

    // MARK: - Wheel

    /// A wheel step: the camera turns about the volume, or, through the
    /// endoscope and in the slab, moves along its view.
    @objc(scrollInStack:)
    func scrollInStack(_ delta: Float) {
        var delta = delta
        let vtk = horos_vtk
        horos_hasChanged = true
        if !vtk.prepareInteractor() { return }

        horos_isRotating = false
        resetAutorotate(self)

        if projectionMode != 2 && !clipRangeActivated {
            azimuth(delta * 2)
            sendMouseMovedWithCurrentEvent()
            needsDisplay = true
        } else {
            if let firstObject = horos_firstObject, firstObject.pixelSpacingX > 0 {
                delta = Float(Double(delta) * (firstObject.pixelSpacingX * 2.0))
            }

            var position = [Double](repeating: 0, count: 3), focal = [Double](repeating: 0, count: 3)
            var cos = [Float](repeating: 0, count: 9)
            let distance = vtk.cameraDistance

            _ = getCosMatrix(&cos)

            vtk.getCameraPosition(&position)
            vtk.getCameraFocalPoint(&focal)

            let factor = horos_factor
            for i in 0..<3 {
                position[i] = position[i] + Double(cos[6 + i] * delta * factor)
            }
            for i in 0..<3 {
                focal[i] = focal[i] + Double(cos[6 + i] * delta * factor)
            }

            if clipRangeActivated {
                if checkPointInVolume(&position) {
                    vtk.setCameraPosition(position)
                    vtk.setCameraFocalPoint(focal)
                }
            } else {
                vtk.setCameraPosition(position)
                vtk.setCameraFocalPoint(focal)
            }

            vtk.cameraDistance = distance
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
    }

    public override func scrollWheel(with theEvent: NSEvent) {
        if eventToPlugins(theEvent) { return }

        scrollInStack(Float(theEvent.deltaY))
    }

    // MARK: - Middle button

    public override func otherMouseDown(with theEvent: NSEvent) {
        if eventToPlugins(theEvent) { return }

        horos_hasChanged = true
        let tool = getTool(theEvent)
        setCursorFor(tool)

        horosForwardMouseEvent(.middleButtonPress, event: theEvent)
    }

    public override func otherMouseDragged(with theEvent: NSEvent) {
        horosForwardMouseEvent(.move, event: theEvent)
    }

    public override func otherMouseUp(with theEvent: NSEvent) {
        horosForwardMouseEvent(.middleButtonRelease, event: theEvent)
    }

    /// Hands a mouse event to the view's interactor as vtkCocoaGLView handed it to
    /// VTK's: backing pixels from the bottom left, command counting as control.
    @objc(horosForwardMouseEvent:event:)
    func horosForwardMouseEvent(_ eventId: IsiXVTKMouseEvent, event theEvent: NSEvent) {
        let backing = convertToBacking(convert(theEvent.locationInWindow, from: nil))
        let flags = theEvent.modifierFlags
        let shiftDown: Int32 = flags.contains(.shift) ? 1 : 0
        let controlDown: Int32 = !flags.intersection([.control, .command]).isEmpty ? 1 : 0
        let clickCount = eventId == .move ? 0 : Int32(truncatingIfNeeded: theEvent.clickCount)
        horos_vtk.setInteractorEventX(CConversion.int(Double(backing.x)), y: CConversion.int(Double(backing.y)),
                                      control: controlDown, shift: shiftDown,
                                      repeat: clickCount > 1 ? clickCount - 1 : 0, alt: flags.contains(.option))
        horos_vtk.invokeInteractorEvent(eventId)
    }

    @objc(setRotate:)
    func setRotate(_ r: Bool) {
        horos_isRotating = r
    }

    // MARK: - Hover

    /// -mouseMoved: as the Objective-C sent it, with the current event or nil,
    /// so that a subclass's override still has it.
    func sendMouseMovedWithCurrentEvent() {
        perform(#selector(NSResponder.mouseMoved(with:)), with: NSApplication.shared.currentEvent)
    }

    public override func mouseMoved(with theEvent: NSEvent) {
        horosMouseMoved(theEvent)
    }

    /// The hover field: the view's size, the voxel under the pointer, the
    /// measurements and the scale.
    private func horosMouseMoved(_ theEvent: NSEvent?) {
        if eventToPlugins(theEvent) { return }

        if window?.isVisible != true {
            return
        }

        if horos_controller?.windowWillClose() == true {
            return
        }

        let drawLock = VRView.horos_drawLock
        drawLock?.lock()

        var pix = [Int](repeating: 0, count: 3)
        var pos = [Float](repeating: 0, count: 3)
        var value: Float = 0

        let mouseLocStart = VRInteractionGeometry.backingPoint(theEvent?.locationInWindow ?? .zero, in: self)

        if isViewportResizable() {
            let resizeThreshold = VTKRetinaGeometry.resizeHandleDisplayThreshold(pointThreshold: 20, scale: VTKRetinaGeometry.displayScale(of: self))
            if VTKRetinaGeometry.isViewportResizeHandle(x: mouseLocStart.x, y: mouseLocStart.y, threshold: resizeThreshold) && isViewportResizable() {
                setCursorFor(.tTranslate)
            } else {
                setCursorFor(getTool(theEvent))
            }

            if horos_cursorSet { horos_cursor?.set() }
        }

        let s = NSMutableString(string: String(format: NSLocalizedString("View Size: %d x %d", comment: ""),
                                               CConversion.int(Double(frame.size.width)), CConversion.int(Double(frame.size.height))))

        if get3DPixelUnder2DPositionX(Float(mouseLocStart.x), y: Float(mouseLocStart.y), pixel: &pix, position: &pos, value: &value) {
            let sliceNo: Int32
            if horos_controller?.viewer2D()?.imageView()?.flippedData == true {
                sliceNo = Int32(truncatingIfNeeded: pix[2])
            } else {
                sliceNo = Int32(truncatingIfNeeded: (horos_pixList?.count ?? 0) - 1 - pix[2])
            }

            let pixLoc = (String(format: "X:%d Y:%d Z:%d (px)", Int32(truncatingIfNeeded: pix[0]), Int32(truncatingIfNeeded: pix[1]), sliceNo) as NSString)
                .padding(toLength: 23, withPad: " ", startingAt: 0)
            let mmLoc = (String(format: "X:%.2f Y:%.2f Z:%.2f (mm)", Double(pos[0]), Double(pos[1]), Double(pos[2])) as NSString)
                .padding(toLength: 38, withPad: " ", startingAt: 0)
            let val = (String(format: "%.2f", Double(value)) as NSString).padding(toLength: 9, withPad: " ", startingAt: 0)

            s.append(String(format: NSLocalizedString("   Pixel: %@    %@ %@", comment: ""), val, pixLoc, mmLoc))
        }

        if horos_measureLength != 0 {
            s.append(String(format: NSLocalizedString("   Measurement: %@ ", comment: ""),
                            LengthPresentation.string(centimetres: Double(horos_measureLength))))
        }
        if horos_angleMeasurementCount == 3 && horos_measureAngle.isFinite && horos_measureAngle > 0 {
            s.append(String(format: NSLocalizedString("   Angle: %2.1f degrees ", comment: ""), Double(horos_measureAngle)))
        }

        if horos_vtk.cameraParallelProjection {
            s.append(String(format: NSLocalizedString("   Scale: %2.3f %% ", comment: ""), Double(scaleFactor())))
        }

        pixelInformation?.stringValue = s as String

        drawLock?.unlock()
    }

    // MARK: - Trackpad

    /// A trackpad gesture renders at the interactive level of detail while it
    /// lasts and at the selected one when it ends, as a drag with a tool does.
    @objc(horosTrackpadGesture:changedCamera:)
    func horosTrackpadGesture(_ event: NSEvent, changedCamera changed: Bool) {
        let vtk = horos_vtk
        let phase = event.phase
        let finished = !phase.intersection([.ended, .cancelled]).isEmpty

        if changed {
            horos_hasChanged = true
            horos_bestRenderingWasGenerated = false

            if clipRangeActivated {
                vtk.setCameraClippingRangeNear(0.0, far: Double(clippingRangeThickness))
            } else {
                vtk.resetCameraClippingRange()
            }

            if !finished {
                setLODLow(true)
            }

            NotificationCenter.default.post(name: .OsirixVRCameraDidChange, object: self, userInfo: nil)
        }

        if finished {
            setLODLow(false)
        } else if changed {
            needsDisplay = true
        }
    }

    /// Pinch: the camera's zoom. In endoscopy the camera moves along its view instead.
    public override func magnify(with event: NSEvent) {
        if eventToPlugins(event) { return }

        let vtk = horos_vtk
        if !vtk.hasCamera || !vtk.hasRenderer || horos_controller?.windowWillClose() == true { return }

        let drawLock = VRView.horos_drawLock
        drawLock?.lock()

        let factor = VRInteractionGeometry.zoomFactor(forMagnification: event.magnification)
        if factor > 0 {
            if projectionMode != 2 {
                vtk.cameraZoom(factor)
                computeLength()
            } else {
                let distance = vtk.cameraDistance
                vtk.cameraDolly(factor)
                vtk.cameraDistance = distance
                vtk.cameraComputeViewPlaneNormal()
                vtk.cameraOrthogonalizeViewUp()
            }
        }
        horosTrackpadGesture(event, changedCamera: factor > 0)

        drawLock?.unlock()
    }

    /// Two-finger rotation: the camera rolls about its direction of projection.
    public override func rotate(with event: NSEvent) {
        if eventToPlugins(event) { return }

        let vtk = horos_vtk
        if !vtk.hasCamera || !vtk.hasRenderer || horos_controller?.windowWillClose() == true { return }

        let drawLock = VRView.horos_drawLock
        drawLock?.lock()

        let degrees = VRInteractionGeometry.rollDegrees(forRotation: event.rotation)
        if degrees != 0 {
            vtk.cameraRoll(degrees)
            vtk.cameraOrthogonalizeViewUp()
            computeOrientationText()
        }
        horosTrackpadGesture(event, changedCamera: degrees != 0)

        drawLock?.unlock()
    }

    // MARK: - VTK's keys

    /// The keys vtkInteractorStyle answered that the view does not: 'p' picks the
    /// 3D point under the mouse, 'r' resets the camera. The others changed
    /// nothing the view shows.
    @objc(horosVTKKeyDown:)
    func horosVTKKeyDown(_ event: NSEvent) {
        guard let characters = event.characters as NSString?, characters.length > 0 else { return }
        let c = characters.character(at: 0)
        if c == UInt16(UInt8(ascii: "p")) || c == UInt16(UInt8(ascii: "P")) {
            let location = VRInteractionGeometry.backingPoint(event.locationInWindow, in: self)
            horosPick3DPointAt(x: Double(location.x), y: Double(location.y))
        } else if c == UInt16(UInt8(ascii: "r")) || c == UInt16(UInt8(ascii: "R")) {
            horosResetCameraFitting(true)
            needsDisplay = true
        }
    }

    /// What vtkPropPicker gave the 'p' key among the 3D points: the one nearest
    /// the viewer along the ray under the mouse, spheres being what they are.
    @objc(horosPick3DPointAtX:y:)
    func horosPick3DPointAt(x: Double, y: Double) {
        let actors = horos_display3DPoints ? ((horos_point3DActorArray as NSArray?) as? [NSValue] ?? []) : []
        horos_picked3DPoint = horos_vtk.pickPointAmong(actors, x: x, y: y)
        needsDisplay = true
    }
}
