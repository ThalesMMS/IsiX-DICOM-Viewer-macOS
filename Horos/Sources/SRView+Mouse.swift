/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:  OsiriX
 Copyright (c) OsiriX Team
 All rights reserved.
 Distributed under GNU - LGPL
 
 See http://www.osirix-viewer.com/copyright.html for details.
   This software is distributed WITHOUT ANY WARRANTY; without even
   the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
   PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import IsiXVolumeRendering

/// The surface view's mouse, keys and cursors: the tool of a button and its
/// modifiers, handed to the scene's interactor or moving the camera itself.
/// The interactor takes the view's points, as the surface view always gave
/// them.
extension SRView {
    /// The point of `event` in the view.
    private func location(_ event: NSEvent) -> NSPoint { convert(event.locationInWindow, from: nil) }

    /// Sends `vtkEvent` to the interactor at `point`, with control and shift.
    private func interact(_ vtkEvent: IsiXVTKMouseEvent, at point: NSPoint, control: Bool, shift: Bool) {
        scene.setEvent(x: SRView.cInt(point.x), y: SRView.cInt(point.y), control: control, shift: shift, repeat: 0)
        scene.invokeEvent(vtkEvent)
    }

    /// A coordinate as C converted it to int; 0 for one C could not.
    static func cInt(_ value: CGFloat) -> Int32 {
        let truncated = value.rounded(.towardZero)
        return truncated.isFinite && truncated >= CGFloat(Int32.min) && truncated <= CGFloat(Int32.max) ? Int32(truncated) : 0
    }

    /// The tool of `event`: the right button zooms, the other one translates,
    /// the left one is the current tool; the modifiers choose another.
    func getTool(_ event: NSEvent) -> ToolMode {
        var tool: ToolMode
        switch event.type {
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp: tool = .tZoom
        case .otherMouseDown, .otherMouseDragged, .otherMouseUp: tool = .tTranslate
        default: tool = currentTool
        }
        let flags = event.modifierFlags
        if flags.contains(.control) { tool = .tRotate }
        if flags.contains(.shift) { tool = .tZoom }
        if flags.contains(.command) { tool = .tTranslate }
        if flags.contains(.option) { tool = .tWL }
        if flags.contains(.command) && flags.contains(.option) { tool = .tRotate }
        if flags.contains(.command) && flags.contains(.control) { tool = .tCamera3D }
        return tool
    }

    override func flagsChanged(with event: NSEvent) {
        if !event.modifierFlags.isEmpty {
            setCursorForView(getTool(event))
            if cursorSet { cursor?.set() }
        }
        super.flagsChanged(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        setCursorForView(getTool(event))
        super.otherMouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if !dragInProgress && (event.deltaX != 0 || event.deltaY != 0) { deleteMouseDownTimer() }
        if dragInProgress { return }

        if resizeFrame {
            let before = frame
            let content = window?.contentView?.frame.size ?? .zero
            let resized = SurfaceViewFrame.dragResize(mouse: event.locationInWindow, content: content, frame: frame,
                                                      square: event.modifierFlags.contains(.shift))
            frame = resized
            scene.camera.zoom(Double(before.size.height / resized.size.height))
            window?.display()
            needsDisplay = true
            return
        }

        let point = location(event)
        switch mouseTool {
        case .tRotate:
            scene.setEvent(x: SRView.cInt(point.x), y: SRView.cInt(point.y), control: true, shift: false, repeat: 0)
            computeOrientationText()
            scene.invokeEvent(.move)
        case .t3DRotate:
            scene.setEvent(x: SRView.cInt(point.x), y: SRView.cInt(point.y), control: false, shift: false, repeat: 0)
            computeOrientationText()
            scene.invokeEvent(.move)
        case .tTranslate:
            interact(.move, at: point, control: false, shift: true)
        case .tZoom:
            rightMouseDragged(with: event)
        case .tCamera3D:
            let camera = scene.camera
            camera.yaw(Double(-(point.x - mouseLocStart.x) / 5.0))
            camera.pitch(Double((point.y - mouseLocStart.y) / 5.0))
            camera.computeViewPlaneNormal()
            camera.orthogonalizeViewUp()
            scene.resetCameraClippingRange()
            computeOrientationText()
            mouseLocStart = point
            needsDisplay = true
        default:
            break
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        let point = location(event)
        guard mouseTool == .tZoom else { return }
        if projectionMode != 2 {
            interact(.move, at: point, control: true, shift: false)
        } else {
            let camera = scene.camera
            let distance = Double(Float(camera.distance))
            camera.dolly(Double(1.0 + (point.y - mouseLocStart.y) / 1200.0))
            camera.distance = distance
            camera.computeViewPlaneNormal()
            camera.orthogonalizeViewUp()
            scene.resetCameraClippingRange()
            mouseLocStart = point
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        deleteMouseDownTimer()
        switch mouseTool {
        case .tRotate, .t3DRotate, .tTranslate: scene.invokeEvent(.leftButtonRelease)
        case .tZoom: rightMouseUp(with: event)
        default: break
        }
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        noWaitDialog = true
        mouseDown(with: event)
        noWaitDialog = false
    }

    override func rightMouseUp(with event: NSEvent) {
        if mouseTool == .tZoom && projectionMode != 2 {
            interact(.leftButtonRelease, at: location(event), control: true, shift: false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        noWaitDialog = true
        var tool = currentTool

        if event.type == .leftMouseDown {
            if mouseDownTimer != nil { deleteMouseDownTimer() }
            mouseDownTimer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(startDrag(_:)),
                                                  userInfo: event, repeats: false)
        }

        let start = location(event)
        mouseLocStart = start

        if start.x < 10 && start.y < 10 {
            resizeFrame = true
            return
        }

        if event.clickCount > 1 && tool != .t3Dpoint {
            // A double click shows the surface's point in the 2D viewers.
            let pick = VRInteractionGeometry.backingPoint(event.locationInWindow, in: self)
            var world = IsiXVTKPoint(x: 0, y: 0, z: 0)
            guard pickSurface(atDisplayX: pick.x, y: pick.y, world: &world) else { return }
            var dc = [world.x, world.y, world.z], sc = [0.0, 0.0, 0.0]
            convert3Dto2Dpoint(&dc, &sc)
            let spacingX = firstObject?.pixelSpacingX ?? 0, spacingY = firstObject?.pixelSpacingY ?? 0
            NotificationCenter.default.post(name: .OsirixDisplay3dPoint, object: pixList,
                                            userInfo: ["x": NSNumber(value: SRView.cInt(CGFloat(sc[0] * spacingX))),
                                                       "y": NSNumber(value: SRView.cInt(CGFloat(sc[1] * spacingY))),
                                                       "z": NSNumber(value: SRView.cInt(CGFloat(sc[2])))])
            return
        }

        resizeFrame = false
        tool = getTool(event)
        mouseTool = tool
        setCursorForView(tool)

        let point = location(event)
        switch tool {
        case .tRotate:
            interact(.leftButtonPress, at: point, control: true, shift: false)
        case .t3DRotate:
            interact(.leftButtonPress, at: point, control: false, shift: false)
        case .tTranslate:
            interact(.leftButtonPress, at: point, control: false, shift: true)
        case .tZoom:
            if projectionMode != 2 {
                interact(.rightButtonPress, at: point, control: true, shift: false)
            } else {
                needsDisplay = true
            }
        case .tCamera3D:
            needsDisplay = true
        case .t3Dpoint:
            // A 'p' at the mouse picks a 3D point, as VTK's style did.
            if let press = NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow, modifierFlags: [],
                                            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                            characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 112) {
                keyDown(with: press)
            }
            if !isAny3DPointSelected() {
                let pick = VRInteractionGeometry.backingPoint(event.locationInWindow, in: self)
                throw3DPointOnSurface(pick.x, pick.y)
                needsDisplay = true
            } else {
                showSelected3DPointInfo(event)
            }
        default:
            if mouseTool == .tWL {
                NSLog("WL do nothing")
            } else {
                super.mouseDown(with: event)
            }
        }
        noWaitDialog = false
    }

    override func keyDown(with event: NSEvent) {
        guard let character = event.characters?.utf16.first else { return }
        if character == UInt16(UInt8(ascii: " ")) {
            if let outline {
                if scene.contains(outline) { scene.removeActor(outline) } else { scene.addActor(outline) }
            }
            needsDisplay = true
        } else if character == 27 {
            (window?.windowController as? Window3DController)?.offFullScreen()
        } else if Int(character) == NSDeleteFunctionKey || Int(character) == NSDeleteCharacter
                    || Int(character) == NSBackspaceCharacter || Int(character) == NSDeleteCharFunctionKey {
            if isAny3DPointSelected() { removeSelected3DPoint() } else { yaw(-90.0) }
        } else {
            super.keyDown(with: event)
        }
    }

    @objc(setCurrentTool:)
    func setCurrentTool(_ i: ToolMode) {
        if currentTool == .t3Dpoint && currentTool != i {
            unselectAllActors()
            if point3DInfoPanel?.isVisible == true { point3DInfoPanel?.performClose(self) }
            needsDisplay = true
        }
        currentTool = i
        setCursorForView(currentTool)
    }

    // MARK: Cursors

    override func mouseEntered(with event: NSEvent) { cursorSet = true }
    override func mouseExited(with event: NSEvent) { cursorSet = false }

    override func cursorUpdate(with event: NSEvent) {
        cursorSet = true
        cursor?.set()
    }

    @objc func checkCursor() {
        if cursorSet { cursor?.set() }
    }

    @objc(setCursorForView:)
    func setCursorForView(_ tool: ToolMode) {
        let c: NSCursor?
        switch tool {
        case .tMesure, .t3Dpoint, .t3DCut, .tCross: c = NSCursor.crosshair
        case .t3DRotate: c = NSCursor.rotate3DCursor()
        case .tCamera3D: c = NSCursor.rotate3DCameraCursor()
        case .tTranslate: c = NSCursor.openHand
        case .tRotate: c = NSCursor.rotateCursor()
        case .tZoom: c = NSCursor.zoomCursor()
        case .tWL: c = NSCursor.contrastCursor()
        case .tNext: c = NSCursor.stackCursor()
        case .tText: c = NSCursor.iBeam
        default: c = NSCursor.arrow
        }
        if c !== cursor { cursor = c }
    }
}
