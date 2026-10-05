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

import Cocoa

// The "Mouse dragging methods" of DCMView are implemented in Swift since #834:
// an extension of DCMView, which stays Objective-C, with the same selectors.
// Every method is `dynamic`, so the Objective-C and Swift subclasses that
// override them (OrthogonalMPRView, the MPR and CPR views, plugins) are reached
// as before, and DCMView's own sends go through objc_msgSend.
//
// These methods run once per mouse event while a button is down (the window
// level drag among them): they make no allocation the Objective-C code did not
// make, and no Array, Dictionary or String crosses the bridge. The messages
// whose Swift spelling would bridge a value (an id receiver, an NSString key,
// an NSArray result) go through DCMViewDraggingMessages, an @objc protocol that
// only names the selectors: the message goes to the object as it did, and a
// message to nil answers nil, NO or 0. Keys and texts are NSString constants.
// An @try is HorosObjCException.perform.

/// The messages of the former Objective-C that go to an id or would bridge a
/// value in their Swift spelling. The protocol is not checked: an object that
/// does not answer raises as the runtime raised.
@objc private protocol DCMViewDraggingMessages {
    // DCMView
    @objc(windowController) func draggingWindowController() -> AnyObject?
    @objc(dcmFilesList) func draggingDcmFilesList() -> NSArray?
    @objc(horos_dcmFilesList) func draggingDcmFilesListIvar() -> NSArray?
    // The DCMView class
    @objc(findWLWWPreset:::) func draggingFindWLWWPreset(_ wl: Float, _ ww: Float, _ pix: DCMPix?) -> NSString?
    // The window controller, an id
    @objc(windowWillClose) func draggingWindowWillClose() -> Bool
    @objc(addToUndoQueue:) func draggingAddToUndoQueue(_ what: NSString?)
    @objc(propagateSettings) func draggingPropagateSettings()
    @objc(adjustSlider) func draggingAdjustSlider()
    @objc(isPostprocessed) func draggingIsPostprocessed() -> Bool
    @objc(thickSlabController) func draggingThickSlabController() -> AnyObject?
    @objc(setCurWLWWMenu:) func draggingSetCurWLWWMenu(_ s: NSString?)
    @objc(setMode:toROIGroupWithID:) func draggingSetMode(_ mode: Int, toROIGroupWithID groupID: TimeInterval)
    @objc(selectROI:deselectingOther:) func draggingSelectROI(_ roi: ROI?, deselectingOther: Bool)
    // ThickSlabController
    @objc(setLowQuality:) func draggingSetLowQuality(_ q: Bool)
    // ROI
    @objc(comments) func draggingComments() -> NSString?
    @objc(setComments:) func draggingSetComments(_ s: NSString?)
    // Foundation
    @objc(objectAtIndex:) func draggingObjectAtIndex(_ index: Int) -> AnyObject?
    @objc(valueForKey:) func draggingValueForKey(_ key: NSString) -> AnyObject?
    @objc(setValue:forKey:) func draggingSetValue(_ value: AnyObject?, forKey key: NSString)
    @objc(isEqualToString:) func draggingIsEqualToString(_ s: NSString?) -> Bool
    @objc(boolValue) func draggingBoolValue() -> Bool
    @objc(boolForKey:) func draggingBoolForKey(_ key: NSString) -> Bool
    @objc(integerForKey:) func draggingIntegerForKey(_ key: NSString) -> Int
    @objc(userInfo) func draggingUserInfo() -> NSDictionary?
    @objc(objectForKey:) func draggingObjectForKey(_ key: AnyObject) -> AnyObject?
}

/// The object, as the messages it is sent; nil stays nil.
@inline(__always)
private func msg(_ object: AnyObject?) -> DCMViewDraggingMessages? {
    return unsafeBitCast(object, to: DCMViewDraggingMessages?.self)
}

/// [view windowController], an id.
@inline(__always)
private func windowControllerOf(_ view: DCMView) -> DCMViewDraggingMessages? {
    return msg(msg(view)?.draggingWindowController())
}

/// [NSUserDefaults standardUserDefaults].
@inline(__always)
private func standardDefaults() -> DCMViewDraggingMessages? {
    return msg(UserDefaults.standard)
}

/// [[file valueForKey:@"modality"] isEqualToString: modality].
@inline(__always) @MainActor
private func hasModality(_ file: AnyObject?, _ modality: NSString) -> Bool {
    return msg(msg(file)?.draggingValueForKey(kModality))?.draggingIsEqualToString(modality) ?? false
}

/// [(NSMutableArray*) array objectAtIndex: i] as the element it holds.
@inline(__always)
private func element<T: AnyObject>(_ array: NSArray, _ index: Int, _ type: T.Type) -> T {
    return unsafeDowncast(array.object(at: index) as AnyObject, to: type)
}

/// An element of a fast enumeration, as the class the Objective-C typed it.
@inline(__always)
private func asROI(_ object: Any) -> ROI {
    return unsafeDowncast(object as AnyObject, to: ROI.self)
}

/// float min(float a, float b) of DCMView.m: the arguments are converted to
/// float, and so is the result.
@inline(__always)
private func cMin(_ a: CGFloat, _ b: CGFloat) -> Float {
    let a = Float(a), b = Float(b)
    if a < b { return a } else { return b }
}

// Keys and values of the dragging path. NSString is not Sendable, and only
// DCMView, which AppKit isolates to the main actor, reads them: they are
// isolated there.
@MainActor private let kRoi: NSString = "roi"
@MainActor private let kModality: NSString = "modality"
@MainActor private let kPT: NSString = "PT"
@MainActor private let kNM: NSString = "NM"
@MainActor private let kMouseWindowingNM: NSString = "mouseWindowingNM"
@MainActor private let kPETWindowingMode: NSString = "PETWindowingMode"
@MainActor private let kPETMinimumValue: NSString = "PETMinimumValue"
@MainActor private let kMouseClickZoomCentered: NSString = "MouseClickZoomCentered"
@MainActor private let kXOffset: NSString = "xOffset"
@MainActor private let kYOffset: NSString = "yOffset"
@MainActor private let kMove: NSString = "move"
@MainActor private let kMorphingGenerated: NSString = "morphing generated"
@MainActor private let kEmpty: NSString = ""

extension DCMView {

    // MARK: - Mouse dragging methods

    @objc(mouseDragged:)
    public override dynamic func mouseDragged(with event: NSEvent) {
        if let lengthClickEvent = self.horos_lengthClickEvent {
            let down = self.convert(lengthClickEvent.locationInWindow, from: nil)
            let now = self.convert(event.locationInWindow, from: nil)
            // The synthetic mouseDragged from mouseDown is not a drag. AppKit view
            // points make this threshold independent of Retina backing and zoom.
            if hypot(now.x - down.x, now.y - down.y) < 3.0 { return }
            let downEvent = lengthClickEvent
            _ = Unmanaged.passRetained(downEvent)
            self.cancelLengthPlacement()
            self.horos_replayingLengthDrag = true
            self.mouseDown(with: downEvent)
            self.horos_replayingLengthDrag = false
            Unmanaged.passUnretained(downEvent).release()
        }
        if self.horos_curImage < 0 {
            return
        }

        if self.shouldIgnoreHiddenCursorEvent(event) { return }

        if self.event(toPlugins: event) { return }

        self.deleteLens()

        self.horos_mouseDragging = true

        // if window is not visible do nothing
        if (self.window?.isVisible ?? false) == false { return }

        // if window will close do nothing
        if self.is2DViewer() == true {
            if windowControllerOf(self)?.draggingWindowWillClose() ?? false { return }
        }

        // Movement before the still-press timer is WW/WL, scroll or ROI — not export.
        if self.horos__dragInProgress == false &&
            ViewerImageDrag.shouldCancelWait(deltaX: event.deltaX, deltaY: event.deltaY) {
            self.deleteMouseDownTimer()
        }

        // The file-promise session owns the pointer until it ends.
        if self.horos__dragInProgress == true { return }

        // if we have images do drag
        if self.horos_dcmPixList != nil {
            DCMView.horos_static_drawLock?.lock()

            do {
                try HorosObjCException.perform {
                    let eventLocation = event.locationInWindow
                    let current = self.convert(eventLocation, from: nil)
                    var tool = self.horos_currentMouseEventTool

                    self.mouseMoved(with: event)    // Update some variables...

                    if self.horos_crossMove >= 0 { tool = .tCross }

                    // if ROI tool is valid continue with drag
                    /**************** ROI actions *********************************/
                    if self.roiTool(tool) {
                        var action = false

                        var tempPt = self.convert(eventLocation, from: nil)

                        // get point in Open GL
                        tempPt = self.convert(fromNSView2GL: tempPt)

                        // check rois for hit Test.
                        action = self.checkROIsForHit(at: tempPt, for: event)

                        // if we have action the ROI is being drawn. Don't move and rotate ROI
                        if action == false { // Is there a selected ROI -> rotate or move it
                            action = self.mouseDragged(forROIs: event)
                        }
                        _ = action

                        // Shift keeps the lens through the drag, over the point
                        // the ROI has just taken.
                        if self.horosShiftLensWanted(with: event.modifierFlags) {
                            self.computeMagnifyLens(tempPt)
                        }
                    }

                    /********** Actions for Various Tools *********************/
                    else {
                        switch tool {
                        case .t3DRotate: self.mouseDragged3DRotate(event)
                        case .tCross: self.mouseDraggedCrosshair(event)
                        case .tZoom: self.mouseDraggedZoom(event)
                        case .tTranslate: self.mouseDraggedTranslate(event)
                        case .tRotate: self.mouseDraggedRotate(event)
                        case .tNext: self.mouseDraggedImageScroll(event)
                        case .tWLBlended: self.mouseDraggedBlending(event)
                        case .tWL: self.mouseDraggedWindowLevel(event)
                        case .tRepulsor: self.mouseDraggedRepulsor(event)
                        case .tROISelector: self.mouseDraggedROISelector(event)
                        default: break
                        }
                    }

                    /****************** Update Display ***********************/

                    self.horos_previous = current

                    self.needsDisplay = true

                    if self.is2DViewer() == true {
                        windowControllerOf(self)?.draggingPropagateSettings()
                    }
                }
            } catch {
                if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                    _N2LogExceptionImpl(e, true, "-[DCMView mouseDragged:]")
                }
            }

            DCMView.horos_static_drawLock?.unlock()
        }
    }

    // get current Point for Event in the local view Coordinates
    @objc(currentPointInView:)
    public dynamic func currentPoint(inView event: NSEvent!) -> NSPoint {
        let eventLocation = event?.locationInWindow ?? .zero
        return self.convert(eventLocation, from: nil)
    }

    // Check to see if an roi is selected at the Open GL point
    @objc(checkROIsForHitAtPoint:forEvent:)
    public dynamic func checkROIsForHit(at point: NSPoint, for event: NSEvent!) -> Bool {
        var haveHit = false

        // [NSArray arrayWithArray: curRoiList]
        let rois = (self.horos_curRoiList?.copy() as! NSArray?) ?? NSArray()
        for object in rois {
            let r = asROI(object)
            if r.locked == false {
                if !self.horos_mouseDraggedForROIUndo {
                    self.horos_mouseDraggedForROIUndo = true
                    windowControllerOf(self)?.draggingAddToUndoQueue(kRoi)
                }

                let modifierFlags = UInt32(truncatingIfNeeded: event?.modifierFlags.rawValue ?? 0)
                if r.mouseRoiDragged(point, modifierFlags, self.horos_scaleValue) != false {
                    haveHit = true
                }
            }
        }
        return haveHit
    }

    // Modifies the Selected ROIs for the drag. Can rotate, scalem move the ROI or the Text Box.
    @objc(mouseDraggedForROIs:)
    public dynamic func mouseDragged(forROIs event: NSEvent!) -> Bool {
        var action = false

        do {
            try HorosObjCException.perform {
                let current = self.currentPoint(inView: event)
                let modifierFlags = event?.modifierFlags ?? []

                // Command and Alternate rotate ROI
                if modifierFlags.contains(.command) && modifierFlags.contains(.option) {
                    if !self.horos_mouseDraggedForROIUndo {
                        self.horos_mouseDraggedForROIUndo = true
                        windowControllerOf(self)?.draggingAddToUndoQueue(kRoi)
                    }

                    let rotatePoint = self.convert(fromNSView2GL: self.horos_start)

                    var offset = NSPoint()

                    offset.x = -(self.horos_previous.x - current.x) / CGFloat(self.horos_scaleValue)
                    offset.y = (self.horos_previous.y - current.y) / CGFloat(self.horos_scaleValue)

                    for object in self.horos_curRoiList ?? NSMutableArray() {
                        let r = asROI(object)
                        if r.roImode == Int(ROI_selected) {
                            action = true
                            r.rotate(Float(offset.x), rotatePoint)
                        }
                    }
                }
                // Command and Shift scale
                else if modifierFlags.contains(.command) && !modifierFlags.contains(.shift) {
                    if !self.horos_mouseDraggedForROIUndo {
                        self.horos_mouseDraggedForROIUndo = true
                        windowControllerOf(self)?.draggingAddToUndoQueue(kRoi)
                    }

                    let rotatePoint = self.convert(fromNSView2GL: self.horos_start)

                    var ss: Double = 1.0 - Double(self.horos_previous.x - current.x) / 200.0

                    if self.horos_resizeTotal * ss < 0.2 { ss = 0.2 / self.horos_resizeTotal }
                    if self.horos_resizeTotal * ss > 5.0 { ss = 5.0 / self.horos_resizeTotal }

                    self.horos_resizeTotal *= ss

                    for object in self.horos_curRoiList ?? NSMutableArray() {
                        let r = asROI(object)
                        if r.roImode == Int(ROI_selected) {
                            action = true
                            r.resize(Float(ss), rotatePoint)
                        }
                    }
                }
                // Move ROI
                else {
                    var textBoxMove = false
                    var offset = NSPoint()
                    var xx: Float, yy: Float

                    offset.x = -(self.horos_previous.x - current.x) / CGFloat(self.horos_scaleValue)
                    offset.y = (self.horos_previous.y - current.y) / CGFloat(self.horos_scaleValue)

                    offset.x *= self.window?.backingScaleFactor ?? 0
                    offset.y *= self.window?.backingScaleFactor ?? 0

                    if self.horos_xFlipped { offset.x = -offset.x }
                    if self.horos_yFlipped { offset.y = -offset.y }

                    xx = Float(offset.x); yy = Float(offset.y)

                    let angle = Double(self.horos_rotation) * DCMView.horos_static_deg2rad
                    offset.x = Double(xx) * cos(angle) + Double(yy) * sin(angle)
                    offset.y = -Double(xx) * sin(angle) + Double(yy) * cos(angle)

                    offset.y /= self.curDCM?.pixelRatio ?? 0
                    // hit test for text box
                    for object in self.horos_curRoiList ?? NSMutableArray() {
                        let r = asROI(object)
                        if r.roImode == Int(ROI_selected) {
                            if r.clickInTextBox { textBoxMove = true }
                        }
                    }
                    // Move text Box
                    if textBoxMove {
                        for object in self.horos_curRoiList ?? NSMutableArray() {
                            let r = asROI(object)
                            if r.roImode == Int(ROI_selected) {
                                if !self.horos_mouseDraggedForROIUndo {
                                    self.horos_mouseDraggedForROIUndo = true
                                    windowControllerOf(self)?.draggingAddToUndoQueue(kRoi)
                                }

                                action = true
                                r.setTextBoxOffset(offset)
                            }
                        }
                    }
                    // move ROI
                    else {
                        for object in self.horos_curRoiList ?? NSMutableArray() {
                            let r = asROI(object)
                            if r.roImode == Int(ROI_selected) && r.locked == false && r.type != .tPlain {
                                if !self.horos_mouseDraggedForROIUndo {
                                    self.horos_mouseDraggedForROIUndo = true
                                    windowControllerOf(self)?.draggingAddToUndoQueue(kRoi)
                                }

                                action = true
                                r.roiMove(offset)
                            }
                        }
                    }
                }
            }
        } catch {
            if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                NSLog("****** mouseDraggedForROIs: %@", e)
            }
        }
        return action
    }

    // Method for mouse dragging while 3D rotate. Does nothing
    @objc(mouseDragged3DRotate:)
    public dynamic func mouseDragged3DRotate(_ event: NSEvent!) {
    }

    @objc(mouseDraggedCrosshair:)
    public dynamic func mouseDraggedCrosshair(_ event: NSEvent!) {
        if !self.is2DViewer() || self.curDCM == nil || (windowControllerOf(self)?.draggingWindowWillClose() ?? false) { return }
        let pixel = self.convert(fromNSView2GL: self.convert(event?.locationInWindow ?? .zero, from: nil))
        if !pixel.x.isFinite || !pixel.y.isFinite || pixel.x < 0 || pixel.y < 0 ||
            pixel.x >= CGFloat(self.curDCM?.pwidth ?? 0) || pixel.y >= CGFloat(self.curDCM?.pheight ?? 0) { return }
        // Read the event's point, including its pixel value. The global cursor may
        // already have moved by the time a queued click/drag is handled.
        self.mouseMoved(inView: event?.locationInWindow ?? .zero)
        let flags = NSApp.currentEvent?.modifierFlags.rawValue ?? 0
        let shiftControl = NSEvent.ModifierFlags.shift.rawValue | NSEvent.ModifierFlags.control.rawValue
        if self.horos_mouseDragging || (flags & shiftControl) != shiftControl {
            self.sync3DPosition()
        }
    }

    @objc(patientCrosshairChanged:)
    dynamic func patientCrosshairChanged(_ notification: NSNotification!) {
        if DCMView.horos_static_gDontListenToSyncMessage || !self.is2DViewer() || self.horos_matrix != nil || !self.horos_isKeyView ||
            self.horos_curImage < 0 || (windowControllerOf(self)?.draggingWindowWillClose() ?? false) { return }
        // Retire the transient legacy marker; the canonical point is projected at draw time.
        self.horos_slicePoint3D[0] = Float.infinity
        let point = HorosPatientCrosshairForViewer(unsafeBitCast(msg(self)?.draggingWindowController(), to: ViewerController?.self))
        if let point,
           msg(msg(msg(notification)?.draggingUserInfo())?.draggingObjectForKey(kMove))?.draggingBoolValue() ?? false,
           PatientCrosshairController.shared.sourceOwner !== msg(self)?.draggingWindowController() {
            var patient: (Float, Float, Float) = (Float(point.x), Float(point.y), Float(point.z))
            let index = withUnsafeMutablePointer(to: &patient) {
                $0.withMemoryRebound(to: Float.self, capacity: 3) { self.findPlaneAndPoint($0, nil) }
            }
            if index >= 0 && index != Int32(self.horos_curImage) {
                if self.horos_listType == CChar(UInt8(ascii: "i")) {
                    self.setIndex(Int16(truncatingIfNeeded: index))
                } else {
                    self.setIndexWithReset(Int16(truncatingIfNeeded: index), true)
                }
                windowControllerOf(self)?.draggingAdjustSlider()
            }
        }
        self.needsDisplay = true
    }

    @objc(getPatientCrosshairSliceCoordinates:)
    public dynamic func getPatientCrosshairSliceCoordinates(_ coordinates: UnsafeMutablePointer<Float>!) -> Bool {
        if !self.is2DViewer() || !PatientCrosshairController.shared.isVisible || self.curDCM == nil { return false }
        let point = HorosPatientCrosshairForViewer(unsafeBitCast(msg(self)?.draggingWindowController(), to: ViewerController?.self))
        guard let point, (self.curDCM?.pixelSpacingX ?? 0) > 0, (self.curDCM?.pixelSpacingY ?? 0) > 0 else { return false }
        var patient: (Float, Float, Float) = (Float(point.x), Float(point.y), Float(point.z))
        withUnsafeMutablePointer(to: &patient) {
            $0.withMemoryRebound(to: Float.self, capacity: 3) {
                self.curDCM?.convertDICOMCoords($0, toSliceCoords: coordinates, pixelCenter: true)
            }
        }
        // MAX(fabs(sliceInterval), fabs(sliceThickness)) * 0.5
        let interval = fabs(self.curDCM?.sliceInterval ?? 0), thickness = fabs(self.curDCM?.sliceThickness ?? 0)
        let halfSlice: Double = (interval > thickness ? interval : thickness) * 0.5
        return coordinates[0].isFinite && coordinates[1].isFinite && coordinates[2].isFinite &&
            fabs(Double(coordinates[2])) <= halfSlice + 0.001 &&
            coordinates[0] >= 0 && Double(coordinates[0]) < Double(self.curDCM?.pwidth ?? 0) * (self.curDCM?.pixelSpacingX ?? 0) &&
            coordinates[1] >= 0 && Double(coordinates[1]) < Double(self.curDCM?.pheight ?? 0) * (self.curDCM?.pixelSpacingY ?? 0)
    }

    // Methods for Zooming with mouse Drag
    @objc(mouseDraggedZoom:)
    public dynamic func mouseDraggedZoom(_ event: NSEvent!) {
        let current = self.currentPoint(inView: event)

        self.scaleValue = Float(Double(self.horos_startScaleValue) + Double(current.y - self.horos_start.y) / (80.0 * Double(self.curDCM?.pwidth ?? 0) / 512.0))

        var o = NSMakePoint(0, 0)

        if standardDefaults()?.draggingBoolForKey(kMouseClickZoomCentered) ?? false {
            var oo = self.convertToBacking(self.horos_start)

            let drawingFrameRect = self.horos_drawingFrameRect
            let scaleValue = CGFloat(self.horos_scaleValue), startScaleValue = CGFloat(self.horos_startScaleValue)
            oo.x = (oo.x - drawingFrameRect.size.width / 2.0) - (((oo.x - drawingFrameRect.size.width / 2.0) * scaleValue) / startScaleValue)
            oo.y = (oo.y - drawingFrameRect.size.height / 2.0) - (((oo.y - drawingFrameRect.size.height / 2.0) * scaleValue) / startScaleValue)

            oo.y = -oo.y

            if self.horos_xFlipped { oo.x = -oo.x }
            if self.horos_yFlipped { oo.y = -oo.y }

            let angle = Double(self.horos_rotation) * DCMView.horos_static_deg2rad
            o.x = oo.x * cos(angle) + oo.y * sin(angle)
            o.y = oo.x * sin(angle) - oo.y * cos(angle)
        }

        let scaleValue = CGFloat(self.horos_scaleValue), startScaleValue = CGFloat(self.horos_startScaleValue)
        let originStart = self.horos_originStart
        self.setOriginX(Float(((originStart.x * scaleValue) / startScaleValue) + o.x),
                        y: Float(((originStart.y * scaleValue) / startScaleValue) + o.y))
    }

    // Method for translating the image while dragging
    @objc(mouseDraggedTranslate:)
    public dynamic func mouseDraggedTranslate(_ event: NSEvent!) {
        let current = self.currentPoint(inView: event)
        var xmove: Float, ymove: Float, xx: Float, yy: Float

        xmove = Float(current.x - self.horos_start.x)
        ymove = Float(-(current.y - self.horos_start.y))

        xmove = Float(Double(xmove) * (self.window?.backingScaleFactor ?? 0))
        ymove = Float(Double(ymove) * (self.window?.backingScaleFactor ?? 0))

        if self.horos_xFlipped { xmove = -xmove }
        if self.horos_yFlipped { ymove = -ymove }

        let angle = Double(self.horos_rotation) * DCMView.horos_static_deg2rad
        xx = Float(Double(xmove) * cos(angle) + Double(ymove) * sin(angle))
        yy = Float(Double(xmove) * sin(angle) - Double(ymove) * cos(angle))

        let originStart = self.horos_originStart
        self.setOriginX(Float(originStart.x + CGFloat(xx)), y: Float(originStart.y + CGFloat(yy)))

        //set value for Series Object Presentation State
        if self.is2DViewer() == true && (windowControllerOf(self)?.draggingIsPostprocessed() ?? false) == false {
            do {
                try HorosObjCException.perform {
                    msg(self.seriesObj())?.draggingSetValue(NSNumber(value: Float(self.horos_origin.x)), forKey: kXOffset)
                    msg(self.seriesObj())?.draggingSetValue(NSNumber(value: Float(self.horos_origin.y)), forKey: kYOffset)
                }
            } catch {
                if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                    _N2LogExceptionImpl(e, false, "-[DCMView mouseDraggedTranslate:]")
                }
            }
        }
    }

    //Method for rotating
    @objc(mouseDraggedRotate:)
    public dynamic func mouseDraggedRotate(_ event: NSEvent!) {
        var current = self.currentPoint(inView: event)

        current.x -= self.frame.size.width / 2.0
        current.y -= self.frame.size.height / 2.0

        var sign: Float = 1

        if self.horos_xFlipped { sign = -sign }
        if self.horos_yFlipped { sign = -sign }

        var rot = Float(Double(self.horos_rotationStart) + Double(sign) * atan2(current.x, current.y) / DCMView.horos_static_deg2rad)

        while rot < 0 { rot += 360 }
        while rot > 360 { rot -= 360 }

        self.rotation = rot
    }

    //Scrolling through images with Mouse
    // could be cleaned up by subclassing DCMView
    @objc(mouseDraggedImageScroll:)
    public dynamic func mouseDraggedImageScroll(_ event: NSEvent!) {
        var previmage: Int16
        let movie4Dmove = false
        let current = self.currentPoint(inView: event)
        let start = self.horos_start
        if self.horos_scrollMode == 0 {
            if abs(start.x - current.x) < abs(start.y - current.y) {
                if abs(start.y - current.y) > 3 { self.horos_scrollMode = 1 }
            } else if abs(start.x - current.x) >= abs(start.y - current.y) {
                if abs(start.x - current.x) > 3 { self.horos_scrollMode = 2 }
            }
        }

        if movie4Dmove == false {
            previmage = self.horos_curImage

            let count = self.horos_dcmPixList?.count ?? 0
            if count == 0 || !current.x.isFinite || !current.y.isFinite { return }
            let scrollMode = self.horos_scrollMode
            let extent: CGFloat = scrollMode == 2 ? NSWidth(self.frame) : NSHeight(self.frame)
            if (scrollMode != 1 && scrollMode != 2) || !extent.isFinite || extent <= 0 { return }
            var movement: Double = scrollMode == 2 ? current.x - start.x : start.y - current.y
            // The wheel obeyed the reversal preference and the flipped series order
            // while the drag ignored both, so the two gestures walked the series in
            // opposite directions as soon as either was in play.
            movement *= ScrollDirection.dragSign(flippedData: self.horos_flippedData)
            let proposedIndex = Double(self.horos_startImage) + movement * Double(count) / (extent / 2.0)
            if !proposedIndex.isFinite { return }
            // Clamp in floating point before narrowing to the legacy short index.
            let lastIndex = min(Double(count) - 1, Double(Int16.max))
            self.horos_curImage = Int16(fmax(0, fmin(proposedIndex, lastIndex)))

            if previmage != self.horos_curImage {
                if self.horos_listType == CChar(UInt8(ascii: "i")) {
                    self.setIndex(self.horos_curImage)
                } else {
                    self.setIndexWithReset(self.horos_curImage, true)
                }

                if let matrix = self.horos_matrix {
                    var rows = 0, cols = 0; matrix.getNumberOfRows(&rows, columns: &cols); if cols < 1 { cols = 1 }
                    matrix.selectCell(atRow: Int(self.horos_curImage) / cols, column: Int(self.horos_curImage) % cols)
                }

                if self.is2DViewer() == true {
                    windowControllerOf(self)?.draggingAdjustSlider()
                }

                if self.horos_stringID != nil { windowControllerOf(self)?.draggingAdjustSlider() }

                // SYNCRO
                self.sendSyncMessage(Int16(truncatingIfNeeded: Int(self.horos_curImage) - Int(previmage)))
                self.horosShowScrollPreview(atWindowPoint: event?.locationInWindow ?? .zero)
            }
        }
    }

    @objc(mouseDraggedBlending:)
    public dynamic func mouseDraggedBlending(_ event: NSEvent!) {
        var WWAdapter = Float(Double(self.horos_bdstartWW) / 100.0)
        let current = self.currentPoint(inView: event)
        let start = self.horos_start

        if Double(WWAdapter) < 0.001 * Double(self.curDCM?.slope ?? 0) { WWAdapter = Float(0.001 * Double(self.curDCM?.slope ?? 0)) }

        if self.is2DViewer() == true {
            msg(windowControllerOf(self)?.draggingThickSlabController())?.draggingSetLowQuality(true)
        }

        let blendingView = self.horos_blending
        if hasModality(msg(msg(blendingView)?.draggingDcmFilesList())?.draggingObjectAtIndex(0), kPT) ||
            ((standardDefaults()?.draggingBoolForKey(kMouseWindowingNM) ?? false) == true &&
             hasModality(msg(msg(blendingView)?.draggingDcmFilesList())?.draggingObjectAtIndex(0), kNM)) {
            var startlevel: Float
            var endlevel: Float

            // Uninitialized in the Objective-C when PETWindowingMode is not 0, 1 or 2.
            var eWW: Float = 0, eWL: Float = 0

            switch standardDefaults()?.draggingIntegerForKey(kPETWindowingMode) ?? 0 {
            case 0:
                eWL = Float(Double(self.horos_bdstartWL) + (current.y - start.y) * Double(WWAdapter))
                eWW = Float(Double(self.horos_bdstartWW) + (current.x - start.x) * Double(WWAdapter))

                if Double(eWW) < 0.1 { eWW = Float(0.1) }

            case 1:
                endlevel = Float(Double(self.horos_bdstartMax) + (current.y - start.y) * Double(WWAdapter))

                eWL = (endlevel - self.horos_bdstartMin) / 2 + Float(standardDefaults()?.draggingIntegerForKey(kPETMinimumValue) ?? 0)
                eWW = endlevel - self.horos_bdstartMin

                if Double(eWW) < 0.1 { eWW = Float(0.1) }
                if eWL - eWW / 2 < 0 { eWL = eWW / 2 }

            case 2:
                endlevel = Float(Double(self.horos_bdstartMax) + (current.y - start.y) * Double(WWAdapter))
                startlevel = Float(Double(self.horos_bdstartMin) + (current.x - start.x) * Double(WWAdapter))

                if startlevel < 0 { startlevel = 0 }

                eWL = startlevel + (endlevel - startlevel) / 2
                eWW = endlevel - startlevel

                if Double(eWW) < 0.1 { eWW = Float(0.1) }
                if eWL - eWW / 2 < 0 { eWL = eWW / 2 }

            default:
                break
            }

            blendingView?.curDCM?.changeWLWW(eWL, eWW)
        } else {
            blendingView?.curDCM?.changeWLWW(Float(Double(self.horos_bdstartWL) + (current.y - start.y) * Double(WWAdapter)),
                                             Float(Double(self.horos_bdstartWW) + (current.x - start.x) * Double(WWAdapter)))
        }

        if self.is2DViewer() == true {
            let preset = msg(DCMView.self as AnyObject)?.draggingFindWLWWPreset(blendingView?.curDCM?.wl ?? 0, blendingView?.curDCM?.ww ?? 0, self.curDCM)
            msg(msg(blendingView)?.draggingWindowController())?.draggingSetCurWLWWMenu(preset)
        }

        blendingView?.loadTextures()
        self.loadTextures()

        NotificationCenter.default.post(name: .OsirixChangeWLWW, object: blendingView, userInfo: nil)
    }

    @objc(mouseDraggedWindowLevel:)
    public dynamic func mouseDraggedWindowLevel(_ event: NSEvent!) {
        let current = self.currentPoint(inView: event)
        let start = self.horos_start
        // Not blending
        //if( !(blendingView != nil))
        do {
            var WWAdapter = Float(Double(self.horos_startWW) / 80.00)

            if Double(WWAdapter) < 0.001 * Double(self.curDCM?.slope ?? 0) { WWAdapter = Float(0.001 * Double(self.curDCM?.slope ?? 0)) }

            if self.is2DViewer() == true {
                msg(windowControllerOf(self)?.draggingThickSlabController())?.draggingSetLowQuality(true)
            }

            let dcmFilesList = msg(self)?.draggingDcmFilesListIvar()
            if hasModality(msg(dcmFilesList)?.draggingObjectAtIndex(Int(self.horos_curImage)), kPT) ||
                ((standardDefaults()?.draggingBoolForKey(kMouseWindowingNM) ?? false) == true &&
                 hasModality(msg(dcmFilesList)?.draggingObjectAtIndex(Int(self.horos_curImage)), kNM)) {
                var startlevel: Float
                var endlevel: Float

                // Uninitialized in the Objective-C when PETWindowingMode is not 0, 1 or 2.
                var eWW: Float = 0, eWL: Float = 0

                switch standardDefaults()?.draggingIntegerForKey(kPETWindowingMode) ?? 0 {
                case 0:
                    eWL = Float(Double(self.horos_startWL) + (current.y - start.y) * Double(WWAdapter))
                    eWW = Float(Double(self.horos_startWW) + (current.x - start.x) * Double(WWAdapter))

                    if Double(eWW) < 0.1 { eWW = Float(0.1) }

                case 1:
                    endlevel = Float(Double(self.horos_startMax) + (current.y - start.y) * Double(WWAdapter))

                    eWL = (endlevel - self.horos_startMin) / 2 + Float(standardDefaults()?.draggingIntegerForKey(kPETMinimumValue) ?? 0)
                    eWW = endlevel - self.horos_startMin

                    if Double(eWW) < 0.1 { eWW = Float(0.1) }
                    if eWL - eWW / 2 < 0 { eWL = eWW / 2 }

                case 2:
                    endlevel = Float(Double(self.horos_startMax) + (current.y - start.y) * Double(WWAdapter))
                    startlevel = Float(Double(self.horos_startMin) + (current.x - start.x) * Double(WWAdapter))

                    if startlevel < 0 { startlevel = 0 }

                    eWL = startlevel + (endlevel - startlevel) / 2
                    eWW = endlevel - startlevel

                    if Double(eWW) < 0.1 { eWW = Float(0.1) }
                    if eWL - eWW / 2 < 0 { eWL = eWW / 2 }

                default:
                    break
                }

                self.curDCM?.changeWLWW(eWL, eWW)
            } else {
                self.curDCM?.changeWLWW(Float(Double(self.horos_startWL) + (current.y - start.y) * Double(WWAdapter)),
                                        Float(Double(self.horos_startWW) + (current.x - start.x) * Double(WWAdapter)))
            }

            self.horos_curWW = self.curDCM?.ww ?? 0
            self.horos_curWL = self.curDCM?.wl ?? 0

            if self.is2DViewer() == true {
                let preset = msg(DCMView.self as AnyObject)?.draggingFindWLWWPreset(self.horos_curWL, self.horos_curWW, self.curDCM)
                windowControllerOf(self)?.draggingSetCurWLWWMenu(preset)
            }

            self.setWLWW(self.horos_curWL, self.horos_curWW)
        }
    }

    @objc(selectedROIs)
    public dynamic func selectedROIs() -> NSMutableArray! {
        let selectedRois = NSMutableArray()
        for object in self.horos_curRoiList ?? NSMutableArray() {
            let r = asROI(object)
            let mode = r.roImode

            if mode == Int(ROI_selected) || mode == Int(ROI_selectedModify) || mode == Int(ROI_drawing) {
                selectedRois.add(r)
            }
        }

        return selectedRois
    }

    @objc(mouseDraggedRepulsor:)
    public dynamic func mouseDraggedRepulsor(_ event: NSEvent!) {
        let eventLocation = event?.locationInWindow ?? .zero
        var tempPt = self.convert(eventLocation, from: nil)

        self.horos_repulsorPosition = tempPt
        tempPt = self.convert(fromNSView2GL: tempPt)

        var pixSpacingRatio: Float = 1.0
        if self.pixelSpacingY != 0 && self.pixelSpacingX != 0 {
            pixSpacingRatio = Float(self.pixelSpacingY / self.pixelSpacingX)
        }

        let minD = Float(10.0 / Double(self.horos_scaleValue))
        let maxD = Float(50.0 / Double(self.horos_scaleValue))
        let maxN = Float(10.0 * Double(self.horos_scaleValue))

        var points: NSMutableArray

        let repulsorRadius = self.horos_repulsorRadius
        let repulsorRect = NSMakeRect(tempPt.x - CGFloat(repulsorRadius), tempPt.y - CGFloat(repulsorRadius),
                                      CGFloat(Double(repulsorRadius) * 2.0), CGFloat(Double(repulsorRadius) * 2.0))

        var roiArray: NSArray = self.selectedROIs() ?? NSMutableArray()
        if roiArray.count == 0 { roiArray = self.horos_curRoiList ?? NSMutableArray() }

        var i: Int32 = 0
        while Int(i) < roiArray.count {
            let r = element(roiArray, Int(i), ROI.self)

            if r.type != .tAxis && r.type != .tAngle && r.type != .tArrow && r.type != .tDynAngle && r.type != .tTAGT && r.type != .tPlain && r.locked == false {
                points = r.points ?? NSMutableArray()
                var n: Int32 = 0
                var j: Int32 = 0
                while Int(j) < points.count {
                    var pt = element(points, Int(j), MyPoint.self).point
                    if NSPointInRect(pt, repulsorRect) {
                        let dx = Float(pt.x - tempPt.x)
                        let dx2 = dx * dx
                        let dy = Float((pt.y - tempPt.y) * CGFloat(pixSpacingRatio))
                        let dy2 = dy * dy
                        let d = Float(sqrt(Double(dx2 + dy2)))

                        if d < Float(repulsorRadius) {
                            let moveX = dx / d * Float(repulsorRadius) - dx
                            let moveY = dy / d * Float(repulsorRadius) - dy
                            if r.type == .t2DPoint {
                                r.rect = NSOffsetRect(r.rect, CGFloat(moveX), CGFloat(moveY))
                            } else {
                                element(points, Int(j), MyPoint.self).move(moveX, moveY)
                            }

                            pt.x += CGFloat(dx / d * Float(repulsorRadius) - dx)
                            pt.y += CGFloat(dy / d * Float(repulsorRadius) - dy)

                            for delta: Int32 in -1...1 {
                                var k = j + delta
                                if r.type == .tCPolygon || r.type == .tPencil {
                                    if k == -1 {
                                        k = Int32(truncatingIfNeeded: points.count - 1)
                                    } else if Int(k) == points.count {
                                        k = 0
                                    }
                                }

                                if k != j && k >= 0 && Int(k) < points.count {
                                    let pt2 = element(points, Int(k), MyPoint.self).point
                                    let dx = Float(pt2.x - pt.x)
                                    let dx2 = dx * dx
                                    let dy = Float((pt2.y - pt.y) * CGFloat(pixSpacingRatio))
                                    let dy2 = dy * dy
                                    let d = Float(sqrt(Double(dx2 + dy2)))

                                    if d <= minD && d < Float(repulsorRadius) {
                                        points.removeObject(at: Int(k))
                                        if delta == -1 { j -= 1 }
                                    } else if (d >= maxD || d >= Float(repulsorRadius)) && Float(n) < maxN {
                                        var pt3 = NSPoint()
                                        pt3.x = (pt2.x + pt.x) / 2.0
                                        pt3.y = (pt2.y + pt.y) / 2.0
                                        let p = MyPoint(point: pt3)
                                        let index = (delta == -1) ? j : j + 1
                                        if delta == -1 { j += 1 }
                                        points.insert(p as Any, at: Int(index))
                                        n += 1
                                    }
                                }
                            }

                            if r.type == .tMesure {
                                r.type = .tOPolygon
                            }

                            r.recompute()

                            if msg(msg(r)?.draggingComments())?.draggingIsEqualToString(kMorphingGenerated) ?? false {
                                msg(r)?.draggingSetComments(kEmpty)
                            }

                            NotificationCenter.default.post(name: .OsirixROIChange, object: r, userInfo: nil)
                        }
                    }
                    j += 1
                }
            }
            i += 1
        }
    }

    @objc(mouseDraggedROISelector:)
    public dynamic func mouseDraggedROISelector(_ event: NSEvent!) {
        // deselect all ROIs
        for object in self.horos_curRoiList ?? NSMutableArray() {
            let r = asROI(object)
            // ROISelectorSelectedROIList contains ROIs that were selected _before_ the click
            if self.horos_ROISelectorSelectedROIList?.contains(r) ?? false { // this will be possible only if shift key is pressed
                r.roImode = Int(ROI_selected)
            } else {
                r.roImode = Int(ROI_sleep)
            }
        }

        let frame = self.frame
        let eventLocation = event?.locationInWindow ?? .zero
        var tempPt = self.convert(eventLocation, from: nil)
        tempPt.y = frame.size.height - tempPt.y
        self.horos_ROISelectorEndPoint = tempPt

        // NSPoint polyRect[4]: set, and read, only when the image is rotated.
        var polyRectStorage: (NSPoint, NSPoint, NSPoint, NSPoint) = (.zero, .zero, .zero, .zero)

        // Set, and read, only when the image is not rotated.
        var rect = NSRect.zero

        withUnsafeMutablePointer(to: &polyRectStorage) { polyTuple in
            polyTuple.withMemoryRebound(to: NSPoint.self, capacity: 4) { polyRect in
                if self.horos_rotation == 0 {
                    let tempStartPoint = self.convert(fromUpLeftView2GL: self.convertToBacking(self.horos_ROISelectorStartPoint))
                    let tempEndPoint = self.convert(fromUpLeftView2GL: self.convertToBacking(self.horos_ROISelectorEndPoint))

                    rect = NSMakeRect(CGFloat(cMin(tempStartPoint.x, tempEndPoint.x)), CGFloat(cMin(tempStartPoint.y, tempEndPoint.y)),
                                      abs(tempStartPoint.x - tempEndPoint.x), abs(tempStartPoint.y - tempEndPoint.y))

                    if rect.size.width < 1 { rect.size.width = 1 }
                    if rect.size.height < 1 { rect.size.height = 1 }
                } else {
                    let tempStartPoint = self.convertToBacking(self.horos_ROISelectorStartPoint)
                    let tempEndPoint = self.convertToBacking(self.horos_ROISelectorEndPoint)

                    polyRect[0] = self.convert(fromUpLeftView2GL: tempStartPoint)
                    polyRect[1] = self.convert(fromUpLeftView2GL: NSMakePoint(tempStartPoint.x, tempStartPoint.y - (tempStartPoint.y - tempEndPoint.y)))
                    polyRect[2] = self.convert(fromUpLeftView2GL: tempEndPoint)
                    polyRect[3] = self.convert(fromUpLeftView2GL: NSMakePoint(tempStartPoint.x - (tempStartPoint.x - tempEndPoint.x), tempStartPoint.y))
                }

                // select ROIs in the selection rectangle
                // [NSArray arrayWithArray: curRoiList]
                let rois = (self.horos_curRoiList?.copy() as! NSArray?) ?? NSArray()
                for object in rois {
                    var points: NSMutableArray
                    let roi = asROI(object)
                    var intersected = false
                    let roiType = roi.type

                    if self.horos_rotation == 0 {
                        if roiType == .tText {
                            let w = Float(roi.rect.size.width / CGFloat(self.horos_scaleValue))
                            let h = Float(roi.rect.size.height / CGFloat(self.horos_scaleValue))
                            let o = roi.rect.origin
                            let curROIRect = NSMakeRect(o.x - CGFloat(w) / 2.0, o.y - CGFloat(h) / 2.0, CGFloat(w), CGFloat(h))
                            intersected = NSIntersectsRect(rect, curROIRect)
                        } else if roiType == .tROI {
                            intersected = NSIntersectsRect(rect, roi.rect)
                        } else if roiType == .t2DPoint {
                            intersected = NSPointInRect(element(roi.points, 0, MyPoint.self).point, rect)
                        } else {
                            points = roi.splinePoints() ?? NSMutableArray()

                            if points.count != 0 {
                                var p1: NSPoint, p2: NSPoint
                                var j: Int32 = 0
                                while Int(j) < points.count - 1 && !intersected {
                                    p1 = element(points, Int(j), MyPoint.self).point
                                    p2 = element(points, Int(j) + 1, MyPoint.self).point
                                    intersected = lineIntersectsRect(p1, p2, rect)
                                    j += 1
                                }
                                // last segment: between last point and first one
                                if !intersected && roiType != .tMesure && roiType != .tAngle && roiType != .t2DPoint && roiType != .tOPolygon && roiType != .tArrow {
                                    p1 = unsafeDowncast(points.lastObject! as AnyObject, to: MyPoint.self).point
                                    p2 = element(points, 0, MyPoint.self).point
                                    intersected = lineIntersectsRect(p1, p2, rect)
                                }
                            }
                        }
                    } else {
                        if roiType == .tText {
                            let w = Float(roi.rect.size.width / CGFloat(self.horos_scaleValue))
                            let h = Float(roi.rect.size.height / CGFloat(self.horos_scaleValue))
                            let o = roi.rect.origin
                            let curROIRect = NSMakeRect(o.x - CGFloat(w) / 2.0, o.y - CGFloat(h) / 2.0, CGFloat(w), CGFloat(h))

                            if !intersected { intersected = DCMPix.isPoint(NSMakePoint(NSMinX(curROIRect), NSMinY(curROIRect)), inPolygon: polyRect, size: 4) }
                            if !intersected { intersected = DCMPix.isPoint(NSMakePoint(NSMinX(curROIRect), NSMaxY(curROIRect)), inPolygon: polyRect, size: 4) }
                            if !intersected { intersected = DCMPix.isPoint(NSMakePoint(NSMaxX(curROIRect), NSMaxY(curROIRect)), inPolygon: polyRect, size: 4) }
                            if !intersected { intersected = DCMPix.isPoint(NSMakePoint(NSMaxX(curROIRect), NSMinY(curROIRect)), inPolygon: polyRect, size: 4) }
                        } else if roiType == .t2DPoint {
                            intersected = DCMPix.isPoint(element(roi.points, 0, MyPoint.self).point, inPolygon: polyRect, size: 4)
                        } else {
                            points = roi.splinePoints() ?? NSMutableArray()
                            var j: Int32 = 0
                            while Int(j) < points.count && !intersected {
                                intersected = DCMPix.isPoint(element(points, Int(j), MyPoint.self).point, inPolygon: polyRect, size: 4)
                                j += 1
                            }

                            if !intersected {
                                let p = UnsafeMutablePointer<NSPoint>.allocate(capacity: points.count)
                                var j: Int32 = 0
                                while Int(j) < points.count { p[Int(j)] = element(points, Int(j), MyPoint.self).point; j += 1 }
                                j = 0
                                while j < 4 && !intersected {
                                    intersected = DCMPix.isPoint(polyRect[Int(j)], inPolygon: p, size: Int32(truncatingIfNeeded: points.count))
                                    j += 1
                                }
                                p.deallocate()
                            }

                            if !intersected {
                                points = roi.splinePoints() ?? NSMutableArray()
                                if points.count != 0 {
                                    var p1: NSPoint, p2: NSPoint
                                    var j: Int32 = 0
                                    while Int(j) < points.count - 1 && !intersected {
                                        p1 = element(points, Int(j), MyPoint.self).point
                                        p2 = element(points, Int(j) + 1, MyPoint.self).point
                                        if !intersected { intersected = DCMView.intersectionBetweenTwoLinesA1(p1, a2: p2, b1: polyRect[0], b2: polyRect[1], result: nil) }
                                        if !intersected { intersected = DCMView.intersectionBetweenTwoLinesA1(p1, a2: p2, b1: polyRect[1], b2: polyRect[2], result: nil) }
                                        if !intersected { intersected = DCMView.intersectionBetweenTwoLinesA1(p1, a2: p2, b1: polyRect[2], b2: polyRect[3], result: nil) }
                                        if !intersected { intersected = DCMView.intersectionBetweenTwoLinesA1(p1, a2: p2, b1: polyRect[3], b2: polyRect[0], result: nil) }
                                        j += 1
                                    }

                                    // last segment: between last point and first one
                                    if !intersected && roiType != .tMesure && roiType != .tAngle && roiType != .t2DPoint && roiType != .tOPolygon && roiType != .tArrow {
                                        p1 = unsafeDowncast(points.lastObject! as AnyObject, to: MyPoint.self).point
                                        p2 = element(points, 0, MyPoint.self).point
                                        if !intersected { intersected = DCMView.intersectionBetweenTwoLinesA1(p1, a2: p2, b1: polyRect[0], b2: polyRect[1], result: nil) }
                                        if !intersected { intersected = DCMView.intersectionBetweenTwoLinesA1(p1, a2: p2, b1: polyRect[1], b2: polyRect[2], result: nil) }
                                        if !intersected { intersected = DCMView.intersectionBetweenTwoLinesA1(p1, a2: p2, b1: polyRect[2], b2: polyRect[3], result: nil) }
                                        if !intersected { intersected = DCMView.intersectionBetweenTwoLinesA1(p1, a2: p2, b1: polyRect[3], b2: polyRect[0], result: nil) }
                                    }
                                }
                            }
                        }
                    }

                    if intersected {
                        if (event?.modifierFlags ?? []).contains(.shift) { // invert the mode: selected->sleep, sleep->selected
                            var mode = roi.roImode
                            if mode == Int(ROI_sleep) { mode = Int(ROI_selected) }
                            else if mode == Int(ROI_selected) { mode = Int(ROI_sleep) }

                            // set the mode for the ROI and its group (if any)
                            roi.roImode = mode
                            windowControllerOf(self)?.draggingSetMode(mode, toROIGroupWithID: roi.groupID)
                        } else {
                            windowControllerOf(self)?.draggingSelectROI(roi, deselectingOther: false)
                        }
                    }
                }
            }
        }
    }
}
