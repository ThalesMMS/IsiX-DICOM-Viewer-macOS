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
import IsiXImaging
import IsiXPreferences
import IsiXROI

// The "Mouse dragging methods" of DCMView are implemented in Swift:
// an extension of DCMView, with the same selectors.
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
// An @try is HorosObjCException.caughtWithoutAllocation, or
// HorosObjCException.perform. What the repulsor does to the ROIs'
// points and which ROIs the ROI selector touches are IsiXROI's ROIRepulsor
// and ROISelectorRegion.

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
    // Foundation
    @objc(objectAtIndex:) func draggingObjectAtIndex(_ index: Int) -> AnyObject?
    @objc(valueForKey:) func draggingValueForKey(_ key: NSString) -> AnyObject?
    @objc(setValue:forKey:) func draggingSetValue(_ value: AnyObject?, forKey key: NSString)
    @objc(isEqualToString:) func draggingIsEqualToString(_ s: NSString?) -> Bool
    @objc(boolValue) func draggingBoolValue() -> Bool
    @objc(boolForKey:) func draggingBoolForKey(_ key: NSString) -> Bool
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

/// An element of a fast enumeration, as the class the Objective-C typed it.
@inline(__always)
private func asROI(_ object: Any) -> ROI {
    return unsafeDowncast(object as AnyObject, to: ROI.self)
}

// Keys and values of the dragging path. NSString is not Sendable, and only
// DCMView, which AppKit isolates to the main actor, reads them: they are
// isolated there.
@MainActor private let kRoi: NSString = "roi"
@MainActor private let kModality: NSString = "modality"
@MainActor private let kPT: NSString = "PT"
@MainActor private let kNM: NSString = "NM"
@MainActor private let kMouseClickZoomCentered: NSString = "MouseClickZoomCentered"
@MainActor private let kMove: NSString = "move"

extension DCMView {

    // MARK: - Mouse dragging methods

    @objc(mouseDragged:)
    public override dynamic func mouseDragged(with event: NSEvent) {
        if IsiXPluginHost.shared.takesViewerInput(event, in: self) { return }
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

            if let e = HorosObjCException.caughtWithoutAllocation({
                    var tool = self.horos_currentMouseEventTool

                    self.mouseMoved(with: event)    // Update some variables...

                    if self.horos_crossMove >= 0 { tool = .tCross }

                    let rois = (self.horos_curRoiList?.copy() as? [AnyObject]) ?? []
                    let precise = self.roiTool(tool) && rois.contains { self.preciseDragApplies(to: asROI($0)) }
                    let eventLocation = PreciseDrag.location(of: event, in: self.window,
                                                             anchor: self.convert(self.horos_start, to: nil), precise: precise)
                    let current = self.convert(eventLocation, from: nil)

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
            }) {
                _N2LogExceptionImpl(e, true, "-[DCMView mouseDragged:]")
            }

            DCMView.horos_static_drawLock?.unlock()
        }
    }

    // get current Point for Event in the local view Coordinates
    @objc(currentPointInView:)
    public dynamic func currentPoint(inView event: NSEvent!) -> NSPoint {
        // A precise drag moves its point, and the cursor with it, slower than the mouse.
        let eventLocation = PreciseDrag.trackedLocation(of: event, in: self.window)
        return self.convert(eventLocation, from: nil)
    }

    // A precise drag slows the handle, the measurement being drawn or the 2D
    // point being moved. Freehand painting, click-by-click polygons and manual
    // label movement keep the mouse's speed.
    func preciseDragApplies(to r: ROI) -> Bool {
        guard !r.locked else { return false }
        let handle = r.roImode == Int(ROI_selectedModify) && r.type != .tPlain && r.type != .tText
        let measurement = r.roImode == Int(ROI_drawing) &&
            (r.type == .tMesure || r.type == .tArrow || r.type == .tROI || r.type == .tOval || r.type == .tAngle)
        let pointMove = r.roImode == Int(ROI_selected) && r.type == .t2DPoint && !r.clickInTextBox
        return handle || measurement || pointMove
    }

    // Check to see if an roi is selected at the Open GL point
    @objc(checkROIsForHitAtPoint:forEvent:)
    public dynamic func checkROIsForHit(at point: NSPoint, for event: NSEvent!) -> Bool {
        var haveHit = false

        // [NSArray arrayWithArray: curRoiList]
        let rois = (self.horos_curRoiList?.copy() as? [AnyObject]) ?? []
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

                    for object in self.horos_curRoiList ?? [] {
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

                    for object in self.horos_curRoiList ?? [] {
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
                    for object in self.horos_curRoiList ?? [] {
                        let r = asROI(object)
                        if r.roImode == Int(ROI_selected) {
                            if r.clickInTextBox { textBoxMove = true }
                        }
                    }
                    // Move text Box
                    if textBoxMove {
                        for object in self.horos_curRoiList ?? [] {
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
                        for object in self.horos_curRoiList ?? [] {
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
        if !SliceSyncSettings.listensToMessages || !self.is2DViewer() || self.horos_matrix != nil || !self.horosFollowsSync ||
            self.horos_curImage < 0 || (windowControllerOf(self)?.draggingWindowWillClose() ?? false) { return }
        // Retire the transient legacy marker; the canonical point is projected at draw time.
        self.horos_slicePoint3D[0] = Float.infinity
        let point = PatientCrosshairController.shared.point(forViewer: unsafeBitCast(msg(self)?.draggingWindowController(), to: ViewerController?.self))
        if let point,
           msg(msg(msg(notification)?.draggingUserInfo())?.draggingObjectForKey(kMove))?.draggingBoolValue() ?? false,
           PatientCrosshairController.shared.sourceOwner !== msg(self)?.draggingWindowController() {
            var patient: (Float, Float, Float) = (Float(point.x), Float(point.y), Float(point.z))
            let index = withUnsafeMutablePointer(to: &patient) {
                $0.withMemoryRebound(to: Float.self, capacity: 3) { self.findPlaneAndPoint($0, nil) }
            }
            if index >= 0 && index != Int32(self.horos_curImage) {
                if self.horos_listType == CChar(UInt8(ascii: "i")) {
                    self.setIndex(Int(truncatingIfNeeded: index))
                } else {
                    self.setIndexWithReset(Int(truncatingIfNeeded: index), true)
                }
                windowControllerOf(self)?.draggingAdjustSlider()
            }
        }
        self.needsDisplay = true
    }

    @objc(getPatientCrosshairSliceCoordinates:)
    public dynamic func getPatientCrosshairSliceCoordinates(_ coordinates: UnsafeMutablePointer<Float>!) -> Bool {
        if !self.is2DViewer() || !PatientCrosshairController.shared.isVisible || self.curDCM == nil { return false }
        let point = PatientCrosshairController.shared.point(forViewer: unsafeBitCast(msg(self)?.draggingWindowController(), to: ViewerController?.self))
        guard let point, (self.curDCM?.pixelSpacingX ?? 0) > 0, (self.curDCM?.pixelSpacingY ?? 0) > 0 else { return false }
        var patient: (Float, Float, Float) = (Float(point.x), Float(point.y), Float(point.z))
        withUnsafeMutablePointer(to: &patient) {
            $0.withMemoryRebound(to: Float.self, capacity: 3) {
                self.curDCM?.convertDICOMCoords($0, toSliceCoords: coordinates, pixelCenter: true)
            }
        }
        let pix = self.curDCM
        return SliceSynchronizer.crosshairIsOnSlice(SIMD3(coordinates[0], coordinates[1], coordinates[2]),
                                                    sliceInterval: pix?.sliceInterval ?? 0, sliceThickness: pix?.sliceThickness ?? 0,
                                                    width: pix?.pwidth ?? 0, height: pix?.pheight ?? 0,
                                                    pixelSpacingX: pix?.pixelSpacingX ?? 0, pixelSpacingY: pix?.pixelSpacingY ?? 0)
    }

    // Methods for Zooming with mouse Drag: the scale and the pan from the
    // drag's start (ViewportState).
    @objc(mouseDraggedZoom:)
    public dynamic func mouseDraggedZoom(_ event: NSEvent!) {
        let current = self.currentPoint(inView: event)

        self.scaleValue = self.viewport.zoomDragScale(delta: PreciseMouse.appliedDelta(Double(current.y - self.horos_start.y)),
                                                      imageWidth: self.curDCM?.pwidth ?? 0)

        let centred = standardDefaults()?.draggingBoolForKey(kMouseClickZoomCentered) ?? false
        let origin = self.viewport.zoomDragOrigin(click: centred ? self.convertToBacking(self.horos_start) : nil,
                                                  drawingSize: self.horos_drawingFrameRect.size, deg2rad: DCMView.horos_static_deg2rad)
        self.setOriginX(origin.x, y: origin.y)
    }

    // Method for translating the image while dragging
    @objc(mouseDraggedTranslate:)
    public dynamic func mouseDraggedTranslate(_ event: NSEvent!) {
        let current = self.currentPoint(inView: event)
        let origin = self.viewport.translateDragOrigin(from: self.horos_start, to: current, backingScale: Double(self.window?.backingScaleFactor ?? 0),
                                                       deg2rad: DCMView.horos_static_deg2rad)
        self.setOriginX(origin.x, y: origin.y)

        //set value for Series Object Presentation State
        if self.is2DViewer() == true && (windowControllerOf(self)?.draggingIsPostprocessed() ?? false) == false {
            HorosObjCException.logged("-[DCMView mouseDraggedTranslate:]") {
                ImagePresentationStore(series: self.seriesObj(), image: nil)
                    .storeSeriesOffset(x: Float(self.horos_origin.x), y: Float(self.horos_origin.y))
            }
        }
    }

    //Method for rotating
    @objc(mouseDraggedRotate:)
    public dynamic func mouseDraggedRotate(_ event: NSEvent!) {
        var current = self.currentPoint(inView: event)

        current.x -= self.frame.size.width / 2.0
        current.y -= self.frame.size.height / 2.0

        self.rotation = self.viewport.rotateDragRotation(fromCentre: current, deg2rad: DCMView.horos_static_deg2rad)
    }

    //Scrolling through images with Mouse
    // could be cleaned up by subclassing DCMView
    @objc(mouseDraggedImageScroll:)
    public dynamic func mouseDraggedImageScroll(_ event: NSEvent!) {
        let current = self.currentPoint(inView: event)
        let start = self.horos_start
        self.horos_scrollMode = StackNavigation.dragAxis(self.horos_scrollMode, from: start, to: current)

        let previmage = self.horos_curImage

        // The wheel obeyed the reversal preference and the flipped series order
        // while the drag ignored both, so the two gestures walked the series in
        // opposite directions as soon as either was in play.
        guard self.stackNavigation.drag(from: start, to: current, axis: self.horos_scrollMode, size: self.frame.size,
                                        count: self.horos_dcmPixList?.count ?? 0,
                                        sign: ScrollDirection.dragSign(flippedData: self.horos_flippedData)) else { return }

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
            self.sendSyncMessage(self.horos_curImage - previmage)
            self.horosShowScrollPreview(atWindowPoint: event?.locationInWindow ?? .zero)
        }
    }

    @objc(mouseDraggedBlending:)
    public dynamic func mouseDraggedBlending(_ event: NSEvent!) {
        let current = self.currentPoint(inView: event)
        let start = self.horos_start

        if self.is2DViewer() == true {
            msg(windowControllerOf(self)?.draggingThickSlabController())?.draggingSetLowQuality(true)
        }

        let blendingView = self.horos_blending
        let file = msg(msg(blendingView)?.draggingDcmFilesList())?.draggingObjectAtIndex(0)
        let window = self.windowLevelDragged(self.fusedWindowLevelDrag, file: file, delta: CGVector(dx: current.x - start.x, dy: current.y - start.y))
        blendingView?.curDCM?.changeWLWW(window.level, window.width)

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

        if self.is2DViewer() == true {
            msg(windowControllerOf(self)?.draggingThickSlabController())?.draggingSetLowQuality(true)
        }

        let file = msg(msg(self)?.draggingDcmFilesListIvar())?.draggingObjectAtIndex(Int(self.horos_curImage))
        let window = self.windowLevelDragged(self.windowLevelDrag, file: file, delta: CGVector(dx: current.x - start.x, dy: current.y - start.y))
        self.curDCM?.changeWLWW(window.level, window.width)

        self.windowLevelState.level = self.curDCM?.wl ?? 0
        self.windowLevelState.width = self.curDCM?.ww ?? 0

        if self.is2DViewer() == true {
            let preset = msg(DCMView.self as AnyObject)?.draggingFindWLWWPreset(self.windowLevelState.level, self.windowLevelState.width, self.curDCM)
            windowControllerOf(self)?.draggingSetCurWLWWMenu(preset)
        }

        self.setWLWW(self.windowLevelState.level, self.windowLevelState.width)
    }

    /// The window `drag` gives after the mouse moved by `delta`, for an image
    /// of `file`: the PET windowing preferences are read at each move, so a
    /// change takes effect during the drag. The step is floored with the slope
    /// of the view's own image.
    private func windowLevelDragged(_ drag: WindowLevelDrag, file: AnyObject?, delta: CGVector) -> (level: Float, width: Float) {
        let preferences = PreferencesSource.process.preferences
        let petLike = hasModality(file, kPT) || (preferences[VolumeRenderingPreferences.mouseWindowingNM] && hasModality(file, kNM))
        let settings = petLike ? WindowLevelSettings(preferences: preferences) : WindowLevelSettings()
        return drag.window(delta: delta, mode: petLike ? settings.petWindowingMode : nil,
                           petMinimum: settings.petMinimumValue, slope: self.curDCM?.slope ?? 0)
    }

    @objc(selectedROIs)
    public dynamic func selectedROIs() -> NSMutableArray! {
        // Selected, being modified or being drawn.
        return NSMutableArray(array: ViewROIEditing.rois(self.horos_curRoiList).filter { ROISelection.isSelected($0.roImode) })
    }

    @objc(mouseDraggedRepulsor:)
    public dynamic func mouseDraggedRepulsor(_ event: NSEvent!) {
        let eventLocation = event?.locationInWindow ?? .zero
        var tempPt = self.convert(eventLocation, from: nil)

        self.horos_repulsorPosition = tempPt
        tempPt = self.convert(fromNSView2GL: tempPt)

        let repulsor = ROIRepulsor(center: tempPt, radius: self.horos_repulsorRadius,
                                   pixelRatio: ViewInput.pixelRatio(spacingX: self.pixelSpacingX, spacingY: self.pixelSpacingY),
                                   scale: self.horos_scaleValue)

        let selected = ViewROIEditing.rois(self.selectedROIs())
        for r in selected.isEmpty ? ViewROIEditing.rois(self.horos_curRoiList) : selected
            where ROIRepulsor.pushes(type: r.type.rawValue, locked: r.locked) {
            ViewROIEditing.repulse(r, with: repulsor)
        }
    }

    @objc(mouseDraggedROISelector:)
    public dynamic func mouseDraggedROISelector(_ event: NSEvent!) {
        // deselect all ROIs
        for object in self.horos_curRoiList ?? [] {
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

        // The dragged rectangle in the image: a rectangle over an image that is
        // not rotated, its four corners taken into the image otherwise.
        let startPoint = self.convertToBacking(self.horos_ROISelectorStartPoint)
        let endPoint = self.convertToBacking(self.horos_ROISelectorEndPoint)
        let region: ROISelectorRegion
        if self.horos_rotation == 0 {
            region = ROISelectorRegion(area: .rect(ROISelectorRegion.rect(from: self.convert(fromUpLeftView2GL: startPoint),
                                                                          to: self.convert(fromUpLeftView2GL: endPoint))))
        } else {
            region = ROISelectorRegion(area: .quad(ROISelectorRegion.corners(from: startPoint, to: endPoint).map {
                self.convert(fromUpLeftView2GL: $0)
            }))
        }

        // select ROIs in the selection rectangle
        // [NSArray arrayWithArray: curRoiList]
        let geometry = ViewROIEditing.SelectorGeometry()
        for roi in ViewROIEditing.rois(self.horos_curRoiList?.copy()) {
            let shape = ViewROIEditing.selectorShape(of: roi, in: region, scale: self.horos_scaleValue)
            if region.touches(shape, geometry: geometry) {
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
