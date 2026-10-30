/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import IsiXImaging

// The mouse buttons of DCMView are implemented in Swift: an extension of
// DCMView, with the same selectors. Every method is
// `dynamic`, so the MPR and CPR views that override them, and call super, reach
// them as before. A click picks its tool with -getTool: (IsiXImaging's
// ViewInput rule), starts a drag, a ROI, the repulsor or the ROI selector, and
// -mouseDragged: carries it on. An @try is HorosObjCException.perform.

extension DCMView {

    // MARK: - Mouse buttons

    /// A ROI or measuring tool: within this application, the first click in a
    /// viewer that is not the key window places its first point, as in the key
    /// window, so two viewers side by side are measured in turn. Coming from
    /// another application, the click only brings the window forward.
    @objc(acceptsFirstMouse:)
    public override dynamic func acceptsFirstMouse(for theEvent: NSEvent?) -> Bool {
        return ViewInput.acceptsFirstMouse(tool: self.horos_currentTool.rawValue, applicationIsActive: NSApp.isActive)
    }

    // Event/window association routes local and remotely delivered input without
    // querying unsupported global cursor visibility. Keep the loupe exception;
    // reject foreign or windowless events even when the hardware cursor is visible.
    @objc(shouldIgnoreHiddenCursorEvent:)
    public dynamic func shouldIgnoreHiddenCursorEvent(_ event: NSEvent!) -> Bool {
        if self.horos_lensActive {
            return false
        }
        guard let targetWindow = self.window else { return true }
        return event?.window !== targetWindow
    }

    @objc(mouseDown:)
    public override dynamic func mouseDown(with event: NSEvent) {
        self.cancelOpeningScaleToFitForInteraction()
        if self.shouldIgnoreHiddenCursorEvent(event) { return }
        if self.event(toPlugins: event) { return }

        self.horos_currentMouseEventTool = ToolMode(rawValue: -1)!

        if !self.drawing { return }
        if self.window?.isVisible != true { return }
        if self.curDCM == nil { return }
        if self.horos_curImage < 0 { return }
        if self.is2DViewer() == true {
            if inputMessages(self.windowController())?.inputWindowWillClose() == true { return }
        }

        if self.is2DViewer() == true && event.type == .leftMouseDown {
            let flags = event.modifierFlags
            if !flags.contains(.shift) && !flags.contains(.control) && !flags.contains(.option) && !flags.contains(.command) {
                var tempPt = event.window?.contentView?.convert(event.locationInWindow, to: self) ?? .zero
                tempPt = self.convert(fromNSView2GL: tempPt)

                let dict = NSMutableDictionary()
                dict.setObject(NSNumber(value: Float(tempPt.y)), forKey: "Y" as NSString)
                dict.setObject(NSNumber(value: DrawingGeometry.cLong(Double(tempPt.x))), forKey: "X" as NSString)
                dict.setObject(NSNumber(value: false), forKey: "stopMouseDown" as NSString)
                inputPost(.OsirixMouseDown, object: self.windowController(), userInfo: dict)

                if inputMessages(dict.value(forKey: "stopMouseDown"))?.inputBoolValue() == true { return }
            }
        }

        if self.beginLengthClick(event) { return }

        if self.horos__mouseDownTimer != nil {
            self.deleteMouseDownTimer()
        }

        if event.type == .leftMouseDown {
            let timer = Timer.scheduledTimer(timeInterval: self.timeIntervalForDrag, target: self,
                                             selector: NSSelectorFromString("startDrag:"), userInfo: event, repeats: false)
            self.horos__mouseDownTimer = timer
        }

        if self.horos_dcmPixList != nil {
            // The lock is shared by every view and taken by other threads too:
            // it is given back on every way out, a double-click a hot key
            // takes and an exception included.
            DCMView.horos_static_drawLock?.lock()
            defer { DCMView.horos_static_drawLock?.unlock() }

            inputLogException(inputCatch {
                self.mouseDownWithImages(event)
            }, "-[DCMView mouseDown:]")
        }
    }

    /// The body of -mouseDown: with images, under the draw lock. A double-click
    /// a hot key takes goes no further.
    private func mouseDownWithImages(_ event: NSEvent) {
        let wc = inputMessages(self.windowController())

        self.deleteLens()

        self.erase2DPointMarker()
        self.blending?.erase2DPointMarker()

        let eventLocation = event.locationInWindow
        let size = self.frame
        var tool: ToolMode

        self.mouseMoved(with: event) // Update some variables...

        let startPoint = self.convert(eventLocation, from: nil)
        self.horos_start = startPoint
        self.horos_previous = startPoint

        var roiHit = false

        if self.roiTool(self.horos_currentTool) || self.horos_currentTool == .tRepulsor || self.horos_currentTool == .tROISelector {
            let tempPt = self.convert(fromNSView2GL: self.convert(eventLocation, from: nil))
            if self.click(inROI: tempPt) != nil { roiHit = true }
            if self.discardROIStarted(byFirstClickOf: event) { roiHit = false }
        }

        if roiHit == false {
            tool = self.getTool(event)
        } else {
            tool = self.horos_currentTool
        }

        self.horos_startImage = self.horos_curImage
        self.setStartWLWW()
        self.horos_startScaleValue = self.horos_scaleValue
        self.horos_rotationStart = self.horos_rotation
        self.horos_blendingFactorStart = self.horos_blendingFactor
        self.horos_scrollMode = 0
        self.horos_resizeTotal = 1

        self.horos_originStart = self.horos_origin

        var mesure = self.convert(eventLocation, from: nil)
        mesure.y = size.size.height - mesure.y
        self.horos_mesureA = mesure
        self.horos_mesureB = mesure

        var roiRect = self.horos_roiRect
        roiRect.origin = self.convert(eventLocation, from: nil)
        roiRect.origin.y = size.size.height - roiRect.origin.y
        self.horos_roiRect = roiRect

        var clickCount = 1
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .leftMouseUp || event.type == .rightMouseUp {
            clickCount = event.clickCount
        }

        if clickCount > 1 && self.horos__mouseDownTimer != nil {
            self.deleteMouseDownTimer()
        }

        let currentFlags = NSApplication.shared.currentEvent?.modifierFlags ?? []
        if clickCount == 2 && self.window === BrowserController.currentBrowser()?.window {
            BrowserController.currentBrowser()?.matrixDoublePressed(nil)
        } else if clickCount == 2 && roiHit == false && currentFlags.contains(.command) && self.actionForHotKey("dbl-click + cmd") {
            return
        } else if clickCount == 2 && roiHit == false && currentFlags.contains(.option) && self.actionForHotKey("dbl-click + alt") {
            return
        } else if clickCount == 2 && roiHit == false && self.stringID == nil && self.actionForHotKey("dbl-click") {
            return
        }

        self.horos_crossMove = -1
        if tool == .tCross && self.is2DViewer() {
            self.deleteMouseDownTimer()
            self.mouseDraggedCrosshair(event)
        }

        if tool == .tRotate {
            var current = self.currentPoint(inView: event)

            current.x -= self.frame.size.width / 2.0
            current.y -= self.frame.size.height / 2.0

            self.horos_rotationStart = ViewInput.rotationStart(self.horos_rotationStart, fromCenter: current,
                                                               xFlipped: self.horos_xFlipped, yFlipped: self.horos_yFlipped,
                                                               deg2rad: DCMView.horos_static_deg2rad)
        }

        if tool == .tRepulsor {
            self.deleteMouseDownTimer()

            wc?.inputAddToUndoQueue("roi")

            let tempPt = self.convert(fromNSView2GL: self.convert(eventLocation, from: nil))

            if self.anyROI(at: tempPt) {
                self.horos_currentTool = .tPencil
                tool = .tPencil
                self.horos_repulsorROIEdition = true
            } else {
                self.deleteMouseDownTimer()
                let timer = Timer.scheduledTimer(timeInterval: 0.05, target: self, selector: NSSelectorFromString("setAlphaRepulsor:"),
                                                 userInfo: event, repeats: true)
                self.horos_repulsorColorTimer = timer
                self.horos_repulsorAlpha = 0.1
                self.horos_repulsorAlphaSign = 1.0
                self.horos_repulsorRadius = 0

                let pixSpacingRatio = ViewInput.pixelRatio(spacingX: self.pixelSpacingX, spacingY: self.pixelSpacingY)

                var roiArray: NSArray = self.selectedROIs() ?? NSArray()
                if roiArray.count == 0 { roiArray = self.horos_curRoiList ?? NSArray() }

                func pushed(_ r: ROI) -> Bool {
                    return r.type != .tPlain && r.type != .tArrow && r.type != .tAngle && r.type != .tAxis && r.type != .tDynAngle && r.type != .tTAGT
                }

                var firstROI: [CGPoint]? = nil
                if roiArray.count > 0 {
                    let r = roiArray.object(at: 0) as! ROI
                    if pushed(r) {
                        // An empty ROI raises here, as -objectAtIndex: did.
                        firstROI = [(r.points.object(at: 0) as! MyPoint).point]
                    }
                }

                var pushedROIs: [[CGPoint]] = []
                for i in 0..<roiArray.count {
                    let r = roiArray.object(at: i) as! ROI
                    if pushed(r) {
                        pushedROIs.append((r.points ?? NSMutableArray()).map { ($0 as! MyPoint).point })
                    }
                }

                let distance = ViewInput.repulsorDistance(firstROI: firstROI, pushedROIs: pushedROIs, click: tempPt, pixelRatio: pixSpacingRatio)
                self.horos_repulsorRadius = ViewInput.repulsorRadius(distance: distance, imageWidth: self.curDCM.pwidth)

                if roiArray.count == 0 || distance == 0 {
                    _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Repulsor", comment: ""),
                                                message: NSLocalizedString("The Repulsor tool works only if ROIs (Length ROI, Opened and Closed Polygon ROI and Pencil ROI) are on the image.", comment: ""),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }
            }
        }

        if tool == .tROISelector {
            let selectedList = NSMutableArray()
            self.horos_ROISelectorSelectedROIList = selectedList

            // if shift key is pressed, we need to keep track of the ROIs that were selected before the click
            if event.modifierFlags.contains(.shift) {
                for case let r as ROI in (self.horos_curRoiList ?? NSMutableArray()) where r.roImode == Int(ROI_selected) {
                    selectedList.add(r)
                }
            }

            var tempPt = self.convert(eventLocation, from: nil)

            var startPoint = tempPt
            var endPoint = tempPt
            startPoint.y = self.frame.size.height - startPoint.y
            endPoint.y = self.frame.size.height - endPoint.y
            self.horos_ROISelectorStartPoint = startPoint
            self.horos_ROISelectorEndPoint = endPoint

            self.deleteMouseDownTimer()

            tempPt = self.convert(fromNSView2GL: tempPt)

            if self.anyROI(at: tempPt) {
                self.horos_currentTool = .tPencil
                tool = .tPencil
                self.horos_selectorROIEdition = true
            }
        }

        // ROI TOOLS
        if self.roiTool(tool) == true && self.horos_crossMove == -1 {
            self.horos_mouseDraggedForROIUndo = false

            if !self.horos_mouseDraggedForROIUndo {
                self.horos_mouseDraggedForROIUndo = true
                wc?.inputAddToUndoQueue("roi")
            }

            do {
                try HorosObjCException.perform {
                    self.mouseDownWithROITool(tool, event: event, clickCount: clickCount)
                }
            } catch {
                if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                    NSLog("**** mouseDown ROI : %@", e)
                }
            }
        }

        self.horos_currentMouseEventTool = tool

        self.mouseDragged(with: event)
    }

    /// Whether the point is on a ROI: on its handles first, then anywhere on it.
    private func anyROI(at tempPt: NSPoint) -> Bool {
        guard let curDCM = self.curDCM else { return false }
        let rois = self.horos_curRoiList ?? NSMutableArray()
        var clickInROI = false
        for case let r as ROI in rois {
            if r.click(inROI: tempPt, Float(Double(curDCM.pwidth) / 2.0), Float(Double(curDCM.pheight) / 2.0), self.horos_scaleValue, true) != 0 {
                clickInROI = true
            }
        }

        if !clickInROI {
            for case let r as ROI in rois {
                if r.click(inROI: tempPt, Float(Double(curDCM.pwidth) / 2.0), Float(Double(curDCM.pheight) / 2.0), self.horos_scaleValue, false) != 0 {
                    clickInROI = true
                }
            }
        }
        return clickInROI
    }

    /// A click with a ROI tool: it selects the ROI under it (the ROI window
    /// follows, a double-click opens one), Shift deselects it, and elsewhere
    /// it goes on with the ROI being drawn or starts a new one, named after
    /// its kind.
    private func mouseDownWithROITool(_ tool: ToolMode, event: NSEvent, clickCount: Int) {
        let wc = inputMessages(self.windowController())
        let curDCM = self.curDCM
        let halfWidth = Float(Double(curDCM?.pwidth ?? 0) / 2.0), halfHeight = Float(Double(curDCM?.pheight ?? 0) / 2.0)
        let curRoiList = self.horos_curRoiList ?? NSMutableArray()

        self.deleteMouseDownTimer()

        var doNothing = false
        var selected = -1
        let tempPt = self.convert(fromNSView2GL: self.convert(event.locationInWindow, from: nil))

        if AnnotationLevel.revealROIs() {
            DCMView.setDefaults()
        }

        var roiFound = false

        let flags = event.modifierFlags
        if !(flags.contains(.command) && flags.contains(.shift)) {
            for case let r as ROI in curRoiList {
                if r.click(inROI: tempPt, halfWidth, halfHeight, self.horos_scaleValue, true) != 0 {
                    selected = curRoiList.index(of: r)
                    roiFound = true
                    break
                }
            }
        }

        if roiFound == false {
            for case let r as ROI in curRoiList {
                if r.click(inROI: tempPt, halfWidth, halfHeight, self.horos_scaleValue, false) != 0 {
                    selected = curRoiList.index(of: r)
                    break
                }
            }
        }

        if flags.contains(.shift) && !flags.contains(.command) {
            if selected != -1 {
                let r = curRoiList.object(at: selected) as! ROI
                if r.roImode == Int(ROI_selected) {
                    r.roImode = Int(ROI_sleep)
                    // unselect all ROIs in the same group
                    wc?.inputSetMode(Int(ROI_sleep), toROIGroupWithID: (curRoiList.object(at: selected) as! ROI).groupID)
                    doNothing = true
                }
            }
        } else {
            if selected == -1 || ((curRoiList.object(at: selected) as! ROI).roImode != Int(ROI_selected) && (curRoiList.object(at: selected) as! ROI).roImode != Int(ROI_selectedModify)) {
                // Unselect previous ROIs
                for case let r as ROI in curRoiList { r.roImode = Int(ROI_sleep) }
            }
        }

        if doNothing == false {
            if selected >= 0 && self.horos_drawingROI == false {
                self.horos_curROI = nil

                // Bring the selected ROI to the first position in array
                let roi = curRoiList.object(at: selected) as! ROI

                wc?.inputBringToFrontROI(roi)

                var roiVal = roi.click(inROI: tempPt, halfWidth, halfHeight, self.horos_scaleValue, true)
                if roiVal == Int(ROI_sleep) {
                    roiVal = roi.click(inROI: tempPt, halfWidth, halfHeight, self.horos_scaleValue, false)
                }

                if self.is2DViewer() {
                    wc?.inputSetMode(roiVal, toROIGroupWithID: roi.groupID) // change the mode to the whole group before the selected ROI!
                }

                roi.roImode = roiVal

                let winList = NSApplication.shared.windows
                var found = false

                if self.is2DViewer() {
                    for window in winList {
                        let controller = window.windowController

                        // Not a ROI window that is closing: its -windowWillClose:
                        // autoreleased it, and it goes with a window shown again.
                        if controller?.windowNibName == "ROI" &&
                            !((controller?.responds(to: NSSelectorFromString("windowWillClose")) ?? false) && inputMessages(controller)?.inputWindowWillClose() == true) {
                            found = true

                            inputMessages(window.windowController)?.inputSetROI(roi, self.windowController() as AnyObject?)
                            if clickCount > 1 {
                                window.makeKeyAndOrderFront(self)
                            }
                        }
                    }

                    if clickCount > 1 {
                        if found == false {
                            let roiWin = ROIWindow(roi: roi, self.windowController() as? ViewerController)
                            // The ROI window releases itself when it closes.
                            _ = Unmanaged.passRetained(roiWin)
                            roiWin.showWindow(self)
                        }
                    }
                }
            } else { // Start drawing a new ROI !
                if let curROI = self.horos_curROI {
                    self.horos_drawingROI = curROI.mouseRoiDown(tempPt, self.horos_scaleValue)

                    if self.horos_drawingROI == false {
                        self.horos_curROI = nil
                    }

                    if self.horos_curROI?.roImode == Int(ROI_selected) {
                        inputPost(.OsirixROISelected, object: self.horos_curROI)
                    }
                } else {
                    // Unselect previous ROIs
                    for case let r as ROI in curRoiList { r.roImode = Int(ROI_sleep) }

                    self.horos_drawingROI = false

                    let aNewROI: ROI = ROI(type: tool, Float(curDCM?.pixelSpacingX ?? 0), Float(curDCM?.pixelSpacingY ?? 0),
                                           DCMPix.originCorrected(accordingToOrientation: curDCM))
                    self.horos_curROI = aNewROI

                    var roiName: String? = ROI.defaultName()
                    if roiName == nil && (UserDefaults.standard.bool(forKey: "EmptyNameForNewROIs") == false || tool == .t2DPoint) {
                        roiName = DCMView.newROIName(for: tool)
                    }

                    if let roiName {
                        var names: [String] = []
                        for case let slice as NSArray in (self.horos_dcmRoiList ?? NSMutableArray()) {
                            for case let existingROI as ROI in slice {
                                if let name = existingROI.name { names.append(name) }
                            }
                        }
                        aNewROI.name = ROIName.availableName(from: roiName, existingNames: names)
                    }

                    // A numbered contour may belong to an object outlined on a
                    // neighbouring image; that is decided once it is finished.
                    if ROIObjectJoin.isUnnamed(aNewROI.name) == false &&
                        aNewROI.isValidForVolume() && self.is2DViewer() && ROIObjectJoin.isEnabled {
                        self.horos_contourAwaitingJoin = aNewROI
                    }

                    // Shift is the lens of a ROI tool: a ROI drawn with it held
                    // goes on this image alone, as one drawn without it.
                    self.horos_curRoiList?.add(aNewROI)

                    aNewROI.curView = self

                    if UserDefaults.standard.bool(forKey: "markROIImageAsKeyImage") {
                        if self.is2DViewer() == true && self.isKeyImage() == false && wc?.inputIsPostprocessed() == false {
                            wc?.inputSetKeyImage(self)
                        }
                    }

                    wc?.inputBringToFrontROI(aNewROI)

                    self.horos_drawingROI = aNewROI.mouseRoiDown(tempPt, self.horos_scaleValue)

                    if self.horos_drawingROI == false {
                        self.horos_curROI = nil
                    }

                    if aNewROI.roImode == Int(ROI_selected) {
                        inputPost(.OsirixROISelected, object: aNewROI)
                    }

                    let userInfo = NSMutableDictionary()
                    userInfo.setObject(aNewROI, forKey: "ROI" as NSString)
                    userInfo.setObject(NSNumber(value: Int32(self.horos_curImage)), forKey: "sliceNumber" as NSString)

                    inputPost(.OsirixAddROI, object: self, userInfo: userInfo)
                }
            }
        }

        self.deleteInvalidROIs()
    }

    /// The name a new ROI of a tool starts from, numbered afterwards; nil for
    /// the tools whose ROIs had none.
    private static func newROIName(for tool: ToolMode) -> String? {
        switch tool {
        case .tOval: return NSLocalizedString("Oval ", comment: "keep the space at the end of the string")
        case .tDynAngle: return NSLocalizedString("Dynamic Angle ", comment: "keep the space at the end of the string")
        case .tTAGT: return NSLocalizedString("Perpendicular Distance ", comment: "keep the space at the end of the string")
        case .tAxis: return NSLocalizedString("Bone Axis ", comment: "keep the space at the end of the string")
        case .tOPolygon, .tCPolygon: return NSLocalizedString("Polygon ", comment: "keep the space at the end of the string")
        case .tAngle: return NSLocalizedString("Angle ", comment: "keep the space at the end of the string")
        case .tArrow: return NSLocalizedString("Arrow ", comment: "keep the space at the end of the string")
        case .tPlain, .tPencil: return NSLocalizedString("ROI ", comment: "ROI = Region of Interest, keep the space at the end of the string")
        case .tMesure: return NSLocalizedString("Measurement ", comment: "keep the space at the end of the string")
        case .tROI: return NSLocalizedString("Rectangle ", comment: "keep the space at the end of the string")
        case .t2DPoint: return NSLocalizedString("Point ", comment: "keep the space at the end of the string")
        default: return nil
        }
    }

    @objc(mouseUp:)
    public override dynamic func mouseUp(with event: NSEvent) {
        if self.horos_lengthClickEvent != nil { self.finishLengthClick(event); return }
        if self.shouldIgnoreHiddenCursorEvent(event) { return }
        if self.event(toPlugins: event) { return }

        self.horos_mouseDragging = false

        // get rid of timer
        self.deleteMouseDownTimer()

        let userInfo = NSMutableDictionary()
        userInfo.setObject(NSNumber(value: Int32(self.horos_curImage)), forKey: "curImage" as NSString)
        userInfo.setObject(event, forKey: "event" as NSString)

        if self.window?.isVisible != true { return }

        if self.is2DViewer() == true {
            if inputMessages(self.windowController())?.inputWindowWillClose() == true { return }
        }

        if self.horos_dcmPixList != nil {
            if DCMView.horos_static_pluginOverridesMouse && event.modifierFlags.contains(.control) {
                // Simulate Right Mouse Button action
                inputPost(.OsirixRightMouseUp, object: self, userInfo: userInfo)
                return
            }

            DCMView.horos_static_drawLock?.lock()

            inputLogException(inputCatch {
                self.mouseUpWithImages(event)
            }, "-[DCMView mouseUp:]")

            inputPost(.OsirixUpdateWLWWMenu, object: DCMView.findWLWWPreset(self.horos_curWL, self.horos_curWW, self.curDCM))

            DCMView.horos_static_drawLock?.unlock()
        }
    }

    /// The body of -mouseUp: with images, under the draw lock: the series
    /// matrix follows the image the drag reached, the window level is redrawn
    /// at full quality, the ROIs end their drag, and the repulsor and the ROI
    /// selector finish.
    private func mouseUpWithImages(_ event: NSEvent) {
        self.mouseMoved(with: event) // Update some variables...

        if self.horos_curImage != self.horos_startImage && (self.horos_matrix != nil && BrowserController.currentBrowser() != nil), let matrix = self.horos_matrix {
            var rows = 0, cols = 0
            matrix.getNumberOfRows(&rows, columns: &cols)
            if cols < 1 { cols = 1 }
            let cell = matrix.cell(atRow: Int(self.horos_curImage) / cols, column: Int(self.horos_curImage) % cols)
            cell?.performClick(nil)
            matrix.selectCell(atRow: Int(self.horos_curImage) / cols, column: Int(self.horos_curImage) % cols)
        }

        var tool = self.horos_currentMouseEventTool

        if self.horos_crossMove >= 0 { tool = .tCross }

        if tool == .tWL || tool == .tWLBlended {
            if self.is2DViewer() == true {
                inputMessages(inputMessages(self.windowController())?.inputThickSlabController())?.inputSetLowQuality(false)
                self.reapplyWindowLevel()
                self.loadTextures()
                self.needsDisplay = true
            }
        }

        if self.roiTool(tool) {
            let tempPt = self.convert(fromNSView2GL: self.convert(event.locationInWindow, from: nil))

            for case let r as ROI in (self.horos_curRoiList ?? NSMutableArray()) {
                _ = r.mouseRoiUp(tempPt, scaleValue: self.horos_scaleValue)

                if r.roImode == Int(ROI_selected) {
                    inputPost(.OsirixROISelected, object: r)
                    break
                }
            }

            self.deleteInvalidROIs()
            self.joinFinishedContourToAdjacentObject()

            self.needsDisplay = true
        }

        if self.horos_repulsorROIEdition {
            self.horos_currentTool = .tRepulsor
            tool = .tRepulsor
            self.horos_repulsorROIEdition = false
        }

        if tool == .tRepulsor {
            self.horos_repulsorRadius = 0
            if let timer = self.horos_repulsorColorTimer {
                timer.invalidate()
                self.horos_repulsorColorTimer = nil
            }
            self.needsDisplay = true
        }

        if self.horos_selectorROIEdition {
            self.horos_currentTool = .tROISelector
            tool = .tROISelector
            self.horos_selectorROIEdition = false
        }

        if tool == .tROISelector {
            self.horos_ROISelectorSelectedROIList = nil

            let s = self.horos_ROISelectorStartPoint, e = self.horos_ROISelectorEndPoint
            let rect = NSMakeRect(s.x - 1, s.y - 1, abs(e.x - s.x) + 2, abs(e.y - s.y) + 2)
            self.horos_ROISelectorStartPoint = NSMakePoint(0.0, 0.0)
            self.horos_ROISelectorEndPoint = NSMakePoint(0.0, 0.0)
            self.draw(rect)
        }
    }

    // A double-click that Hot Keys gives an action is that action, with a ROI tool
    // too: the ROI its first click started, which has no point but the ones under
    // the double-click, goes, with the undo step that click recorded. Left there,
    // it would take the second click, or keep the action from running (full screen
    // waits for no ROI to be drawn). An angle or a polygon drawn further keeps its
    // double-click, which ends it.
    @objc(discardROIStartedByFirstClickOf:)
    public dynamic func discardROIStarted(byFirstClickOf event: NSEvent!) -> Bool {
        guard let event else { return false }
        if event.clickCount != 2 || self.horos_curROI == nil || self.horos_drawingROI == false || self.is2DViewer() == false { return false }
        let flags = event.modifierFlags
        let key = flags.contains(.command) ? "dbl-click + cmd" : flags.contains(.option) ? "dbl-click + alt" : "dbl-click"
        if DCMView.horos_static__hotKeyDictionary?.object(forKey: key as NSString) == nil { return false }
        let point = self.convert(fromNSView2GL: self.convert(event.locationInWindow, from: nil))
        let tolerance = ViewInput.doubleClickTolerance(scale: self.horos_scaleValue)
        guard let started = self.horos_curROI else { return false }
        let points = (started.points ?? NSMutableArray()).map { p -> CGPoint in
            let p = p as! MyPoint
            return CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        }
        if !ViewInput.allPoints(points, within: tolerance, of: point) { return false }
        self.horos_curROI = nil
        self.horos_drawingROI = false
        inputPost(.OsirixRemoveROI, object: started)
        self.removeROI(fromSliceOrVolume: started)
        inputMessages(self.windowController())?.inputRemoveLastItemFromUndoQueue()
        return true
    }

    /// The first ROI of the image under the point, nil if none.
    @objc(clickInROI:)
    public dynamic func click(inROI tempPt: NSPoint) -> ROI! {
        for case let r as ROI in (self.horos_curRoiList ?? NSMutableArray()) {
            if r.click(inROI: tempPt, Float(Double(self.curDCM?.pwidth ?? 0) / 2.0), Float(Double(self.curDCM?.pheight ?? 0) / 2.0), self.horos_scaleValue, false) != 0 {
                return r
            }
        }

        return nil
    }

    /// The window level a drag starts from, of the image and of the blended one.
    @objc(setStartWLWW)
    public dynamic func setStartWLWW() {
        let ww = self.curDCM?.ww ?? 0, wl = self.curDCM?.wl ?? 0
        self.horos_startWW = ww
        self.horos_startWL = wl
        self.horos_startMin = wl - ww / 2
        self.horos_startMax = wl + ww / 2

        let bww = self.blending?.curDCM?.ww ?? 0, bwl = self.blending?.curDCM?.wl ?? 0
        self.horos_bdstartWW = bww
        self.horos_bdstartWL = bwl
        self.horos_bdstartMin = bwl - bww / 2
        self.horos_bdstartMax = bwl + bww / 2
    }

    // MARK: - Other buttons

    @objc(otherMouseDown:)
    public override dynamic func otherMouseDown(with event: NSEvent) {
        self.cancelOpeningScaleToFitForInteraction()
        if self.event(toPlugins: event) { return }

        if self.horos_curImage < 0 { return }

        self.window?.makeKeyAndOrderFront(self)
        self.window?.makeFirstResponder(self)
        self.sendSyncMessage(0)

        self.mouseDown(with: event)
    }

    @objc(rightMouseDown:)
    public override dynamic func rightMouseDown(with event: NSEvent) {
        self.cancelOpeningScaleToFitForInteraction()
        if self.event(toPlugins: event) { return }

        if self.horos_curImage < 0 { return }

        self.window?.makeKeyAndOrderFront(self)
        self.window?.makeFirstResponder(self)
        self.sendSyncMessage(0)

        if DCMView.horos_static_pluginOverridesMouse {
            let userInfo = NSMutableDictionary()
            userInfo.setObject(NSNumber(value: Int32(self.horos_curImage)), forKey: "curImage" as NSString)
            userInfo.setObject(event, forKey: "event" as NSString)
            inputPost(.OsirixRightMouseDown, object: self, userInfo: userInfo)
            return
        }

        self.mouseDown(with: event)
    }

    @objc(rightMouseUp:)
    public override dynamic func rightMouseUp(with event: NSEvent) {
        if self.event(toPlugins: event) { return }

        self.horos_mouseDragging = false

        let userInfo = NSMutableDictionary()
        userInfo.setObject(NSNumber(value: Int32(self.horos_curImage)), forKey: "curImage" as NSString)
        userInfo.setObject(event, forKey: "event" as NSString)

        if DCMView.horos_static_pluginOverridesMouse {
            inputPost(.OsirixRightMouseUp, object: self, userInfo: userInfo)
        } else {
            var clickCount = 0

            if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .leftMouseUp || event.type == .rightMouseUp {
                clickCount = event.clickCount
            }

            if clickCount == 1 {
                if self.is2DViewer() {
                    let roi = self.click(inROI: self.convert(fromNSView2GL: self.convert(event.locationInWindow, from: nil)))
                    if let roi {
                        inputMessages(self.windowController())?.inputComputeContextualMenu(for: roi)
                    } else {
                        inputMessages(self.windowController())?.inputComputeContextualMenu()
                    }
                }

                if let menu = self.menu(for: event) {
                    NSMenu.popUpContextMenu(menu, with: event, for: self)
                }
            }
        }

        inputPost(.OsirixUpdateWLWWMenu, object: DCMView.findWLWWPreset(self.horos_curWL, self.horos_curWW, self.curDCM))
    }

    @objc(otherMouseDragged:)
    public override dynamic func otherMouseDragged(with event: NSEvent) {
        if self.event(toPlugins: event) { return }
        self.mouseDragged(with: event)
    }

    // otherMouseDown: starts the click with mouseDown:, so mouseUp: ends it: a ROI
    // being drawn or moved, a two-click length, the window level's full quality.
    // mouseUp: hands the event to the plugins first, once.
    @objc(otherMouseUp:)
    public override dynamic func otherMouseUp(with event: NSEvent) {
        self.mouseUp(with: event)
    }

    @objc(rightMouseDragged:)
    public override dynamic func rightMouseDragged(with event: NSEvent) {
        if self.event(toPlugins: event) { return }

        if DCMView.horos_static_pluginOverridesMouse {
            self.mouseMoved(with: event) // Update some variables...
            let userInfo = NSMutableDictionary()
            userInfo.setObject(NSNumber(value: Int32(self.horos_curImage)), forKey: "curImage" as NSString)
            userInfo.setObject(event, forKey: "event" as NSString)
            inputPost(.OsirixRightMouseDragged, object: self, userInfo: userInfo)
            return
        }

        self.mouseDragged(with: event)
    }

    // MARK: - Contextual menu

    /// The view's menu, with the ROI labels when the image has ROIs; none
    /// when a plugin takes the mouse or with Control-Option, which windows
    /// the blended image.
    @objc(menuForEvent:)
    public override dynamic func menu(for theEvent: NSEvent) -> NSMenu? {
        if DCMView.horos_static_pluginOverridesMouse { return nil }
        let contextualMenuWhere = theEvent.locationInWindow // JF20070103 WindowAnchored ctrl-clickPoint registered
        self.horos_contextualMenuInWindowPosX = Float(contextualMenuWhere.x)
        self.horos_contextualMenuInWindowPosY = Float(contextualMenuWhere.y)
        if theEvent.modifierFlags.contains(.control) && theEvent.modifierFlags.contains(.option) { return nil }
        let menu = self.menu?.copy() as? NSMenu
        // A copy has no delegate: the view's menu may have one that prepares it
        // each time it opens.
        menu?.delegate = self.menu?.delegate
        if (self.horos_curRoiList?.count ?? 0) > 0, let menu {
            menu.addItem(NSMenuItem.separator())
            let labels = menu.addItem(withTitle: NSLocalizedString("ROI Labels...", comment: ""),
                                      action: #selector(DCMView.showCompleteROILabels(_:)), keyEquivalent: "")
            labels.target = self
        }
        return menu
    }
}
