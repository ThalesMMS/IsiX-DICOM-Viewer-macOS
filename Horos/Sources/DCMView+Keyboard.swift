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

// The keyboard and the first responder of DCMView are implemented in Swift: an
// extension of DCMView, with the same selectors. The
// arrows and the page keys move through the stack (the other way in a series
// shown in reverse order), Delete removes the selected ROIs, Tab steps the
// annotations, the modifiers show the labels, the large description and the
// magnifier; the view that becomes first responder becomes the key view its
// viewer synchronizes the others from.

extension DCMView {

    // MARK: - Keys

    @objc(keyDown:)
    public override dynamic func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && (self.horos_lengthFirstEndpoint != nil || self.horos_lengthClickEvent != nil) {
            self.cancelLengthPlacement(); return
        }
        self.cancelOpeningScaleToFitForInteraction()
        if self.event(toPlugins: event) { return }
        guard let characters = event.characters as NSString?, characters.length > 0 else { return }

        var c = characters.character(at: 0)

        if (self.windowController() as AnyObject?) === BrowserController.currentBrowser() {
            super.keyDown(with: event)
            return
        }

        guard let dcmPixList = self.horos_dcmPixList else { return }
        let wc = inputMessages(self.windowController())

        // The increment sent to the synchronized viewers; Home and End, and the
        // keys that move no image, send none.
        var inc = 0
        let previmage = self.horos_curImage

        // The magnifier's keys, for the lens and, while the mouse holds a point,
        // for the measurement's: + and the right arrow zoom in, - and the left
        // arrow out, up and down resize. A drag stays on its image, so the
        // arrows are free there.
        if self.horos_lensActive || self.horosMeasurementMagnifierHoldsKeys() {
            let zoom = Int(c) == NSLeftArrowFunctionKey || Int(c) == NSRightArrowFunctionKey || c == 43 || c == 45 || c == 95
            let size = Int(c) == NSUpArrowFunctionKey || Int(c) == NSDownArrowFunctionKey
            // The factors are shared by every view and kept between launches:
            // step from what another view may have set since.
            // The lens reads them back as it is recomputed, so the step is
            // stored first.
            if zoom || size {
                self.horosLoadMagnifierFactors()
                if zoom {
                    self.horos_lensZoomFactor = MagnifierPresentation.zoomFactor(self.horos_lensZoomFactor, steppedIn: Int(c) == NSRightArrowFunctionKey || c == 43)
                } else {
                    self.horos_lensSizeFactor = MagnifierPresentation.sizeFactor(self.horos_lensSizeFactor, steppedUp: Int(c) == NSUpArrowFunctionKey)
                }
                MagnifierPresentation.store(zoomFactor: self.horos_lensZoomFactor, sizeFactor: self.horos_lensSizeFactor, in: UserDefaults.standard)
                if size && self.horos_lensActive {
                    self.computeMagnifyLens(NSMakePoint(CGFloat(self.horos_mouseXPos), CGFloat(self.horos_mouseYPos)))
                }
                self.needsDisplay = true
                return
            }
        }

        c = ViewInput.key(c, flippedData: self.horos_flippedData)

        let flags = event.modifierFlags
        let page = self.horos_imageRows * self.horos_imageColumns

        if Int(c) == NSDeleteFunctionKey || Int(c) == NSDeleteCharacter || Int(c) == NSBackspaceCharacter || Int(c) == NSDeleteCharFunctionKey {
            self.deleteSelectedROIs()
        } else if (c == 13 || c == 3 || c == 32) && self.is2DViewer() == true { // Return - Enter - Space
            wc?.inputPlayStop(wc?.inputFindPlayStopButton())
        } else if c == 27 { // Escape
            // Full screen is left first; otherwise Escape removes the patient crosshair.
            if self.is2DViewer() == true {
                if wc?.inputFullScreenON() == true {
                    wc?.inputOffFullScreen()
                } else {
                    PatientCrosshairController.shared.clearPoint()
                }
            }
        } else if Int(c) == NSLeftArrowFunctionKey {
            if flags.contains(.command) {
                super.keyDown(with: event)
            } else {
                if flags.contains(.control) {
                    inc = -Int(self.curDCM?.stack ?? 0)
                    self.horos_curImage += inc

                    _ = self.scrollThroughSeriesIfNecessary(Int32(self.horos_curImage))

                    if self.horos_curImage < 0 { self.horos_curImage = 0 }
                } else {
                    if flags.contains(.option) { wc?.inputSetKeyImage(self) }
                    inc = -page
                    self.horos_curImage -= page

                    _ = self.scrollThroughSeriesIfNecessary(Int32(self.horos_curImage))

                    if self.horos_curImage < 0 { self.horos_curImage = 0 }
                }
            }
        } else if Int(c) == NSRightArrowFunctionKey {
            if flags.contains(.command) {
                super.keyDown(with: event)
            } else {
                if flags.contains(.control) {
                    inc = Int(self.curDCM?.stack ?? 0)
                    self.horos_curImage += inc

                    _ = self.scrollThroughSeriesIfNecessary(Int32(self.horos_curImage))

                    if inputBeyondLast(self.horos_curImage, dcmPixList.count) { self.horos_curImage = dcmPixList.count - 1 }
                } else {
                    if flags.contains(.option) { wc?.inputSetKeyImage(self) }
                    inc = page
                    self.horos_curImage += page

                    _ = self.scrollThroughSeriesIfNecessary(Int32(self.horos_curImage))

                    if inputBeyondLast(self.horos_curImage, dcmPixList.count) { self.horos_curImage = dcmPixList.count - 1 }
                }
            }
        } else if Int(c) == NSUpArrowFunctionKey {
            if self.is2DViewer() == true && (wc?.inputMaxMovieIndex() ?? 0) > 1 {
                super.keyDown(with: event)
            } else {
                self.scaleValue = Float(Double(self.horos_scaleValue) + 1.0 / 50.0)

                self.needsDisplay = true
            }
        } else if Int(c) == NSDownArrowFunctionKey {
            if (wc?.inputMaxMovieIndex() ?? 0) > 1 && (wc?.inputMaxMovieIndex() ?? 0) > 1 {
                super.keyDown(with: event)
            } else {
                self.scaleValue = self.horos_scaleValue - 1.0 / 50.0

                self.needsDisplay = true
            }
        } else if Int(c) == NSPageUpFunctionKey {
            inc = -page
            self.horos_curImage -= page
            if self.horos_curImage < 0 { self.horos_curImage = 0 }
        } else if Int(c) == NSPageDownFunctionKey {
            inc = page
            self.horos_curImage += page
            if inputBeyondLast(self.horos_curImage, dcmPixList.count) { self.horos_curImage = dcmPixList.count - 1 }
        } else if Int(c) == NSHomeFunctionKey {
            self.horos_curImage = 0
        } else if Int(c) == NSEndFunctionKey {
            self.horos_curImage = dcmPixList.count - 1
        } else if c == 9 { // Tab key
            let a = Int32(truncatingIfNeeded: AnnotationLevel.level(after: Int(self.horos_annotationType)))

            UserDefaults.standard.set(Int(a), forKey: "ANNOTATIONS")
            DCMView.setDefaults()
            self.horos_annotationType = a

            inputPost(.OsirixUpdateView, object: self)

            for case let v as ViewerController in (ViewerController.getDisplayed2DViewers() ?? NSMutableArray()) {
                v.setWindowTitle(self)
            }
        } else {
            NSLog("Keydown: %d", Int32(c))

            if self.actionForHotKey(event.characters as NSString?) == false { super.keyDown(with: event) }
        }

        if previmage != self.horos_curImage {
            self.inputShowCurrentImage()

            if self.is2DViewer() == true {
                wc?.inputAdjustSlider()
            }

            // SYNCRO
            self.sendSyncMessage(inc)

            self.needsDisplay = true
        }

        if self.is2DViewer() == true {
            wc?.inputPropagateSettings()
        }
    }

    /// Delete: the points selected in the ROIs being edited, or those ROIs,
    /// then the selected ones; a ROI's group goes with it.
    private func deleteSelectedROIs() {
        inputMessages(self.windowController())?.inputAddToUndoQueue("roi")

        // NE PAS OUBLIER DE CHANGER EGALEMENT LE CUT !
        var removed = false

        DCMView.horos_static_drawLock?.lock()

        let rArray = self.horos_curRoiList

        do {
            try HorosObjCException.perform {
                var i = 0
                while i < (rArray?.count ?? 0) {
                    let r = rArray!.object(at: i) as! ROI

                    if r.roImode == Int(ROI_selectedModify) || r.roImode == Int(ROI_drawing) {
                        if r.deleteSelectedPoint() == false && r.locked == false {
                            if self.horos_curROI === r {
                                self.horos_curROI = nil
                                self.horos_drawingROI = false
                            }
                            let groupID = r.groupID
                            // The notification can release it: a mirrored 2D
                            // point's owner removes it. `r` holds it here.
                            inputPost(.OsirixRemoveROI, object: r)
                            self.removeROI(fromSliceOrVolume: r)
                            i -= 1
                            removed = true
                            if groupID != 0.0 {
                                self.deleteROIGroupID(groupID)
                            }
                        }
                    }
                    i += 1
                }

                i = 0
                while i < (rArray?.count ?? 0) {
                    let r = rArray!.object(at: i) as! ROI

                    if r.roImode == Int(ROI_selected) && r.locked == false && r.hidden == false {
                        let groupID = r.groupID
                        inputPost(.OsirixRemoveROI, object: r)
                        self.removeROI(fromSliceOrVolume: r)
                        i -= 1
                        removed = true
                        if groupID != 0.0 {
                            self.deleteROIGroupID(groupID)
                        }
                    }
                    i += 1
                }

                inputPost(.OsirixROIRemovedFromArray, object: nil)

                if removed {
                    self.selectSuccessorOfDeletedROIs()
                }
            }
        } catch {
            inputLogException(error, "-[DCMView keyDown:]")
        }

        DCMView.horos_static_drawLock?.unlock()

        self.needsDisplay = true
    }

    @objc(keyUp:)
    public override dynamic func keyUp(with theEvent: NSEvent) {
        if self.event(toPlugins: theEvent) { return }
        super.keyUp(with: theEvent)
    }

    // MARK: - Modifiers

    /// -flagsChanged: without an event.
    @objc(flagsChanged)
    public dynamic func flagsChanged() {
        self.flagsChanged(with: nil)
    }

    /// The modifiers held: Command-Shift hides the labels, Control alone
    /// shows the description in large, Shift shows the magnifier, and the
    /// cursor becomes the tool's they choose. It is also sent without an
    /// event, which counts as no modifier.
    @objc(flagsChanged:)
    public override dynamic func flagsChanged(with event: NSEvent?) {
        self.deleteLens()

        if self.is2DViewer() == true {
            let modifiers = inputModifiers(event)
            var update = false

            if ViewInput.suppressesLabels(modifiers) {
                if self.horos_suppress_labels == false { update = true }
                self.horos_suppress_labels = true
            } else {
                if self.horos_suppress_labels == true { update = true }
                self.horos_suppress_labels = false
            }

            if update == true { self.needsDisplay = true }

            let cLarge = self.horos_showDescriptionInLarge
            self.horos_showDescriptionInLarge = ViewInput.showsDescriptionInLarge(modifiers)

            if self.horos_showDescriptionInLarge != cLarge {
                self.switchShowDescriptionInLarge()
                inputMessages(self.windowController())?.inputShowCurrentThumbnail(self)
            }
        }

        var roiHit = false

        if self.roiTool(self.horos_currentTool) {
            let tempPt = self.convert(fromNSView2GL: self.convert(event?.locationInWindow ?? .zero, from: nil))
            if self.click(inROI: tempPt) != nil {
                roiHit = true
            }
            // Pressing Shift shows the lens and releasing it, above, removes it,
            // also in the middle of a drag, which goes on.
            if self.horosShiftLensWanted(with: event?.modifierFlags ?? []) {
                self.computeMagnifyLens(NSMakePoint(CGFloat(self.horos_mouseXPos), CGFloat(self.horos_mouseYPos)))
            }
            // The measurement magnifier is drawn with the frame: Shift hides it,
            // and brings it back when released, without waiting for the mouse.
            else if UserDefaults.standard.bool(forKey: MagnifierPresentation.measurementDefaultsKey) {
                self.needsDisplay = true
            }
        } else if ViewInput.isShiftAlone(inputModifiers(event)) && self.horos_mouseDragging == false {
            if event?.type != .leftMouseDragged && event?.type != .leftMouseDown {
                self.computeMagnifyLens(NSMakePoint(CGFloat(self.horos_mouseXPos), CGFloat(self.horos_mouseYPos)))
            }
        }

        if roiHit == false {
            self.setCursorForView(self.getTool(event))
        } else {
            self.setCursorForView(self.horos_currentTool)
        }

        if self.horos_cursorSet { self.horos_cursor?.set() }

        if let event {
            super.flagsChanged(with: event)
        } else {
            // [super flagsChanged: nil], which the Swift spelling cannot send.
            let selector = #selector(NSResponder.flagsChanged(with:))
            let imp = class_getMethodImplementation(DCMView.superclass(), selector)
            unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector, NSEvent?) -> Void).self)(self, selector, nil)
        }
    }

    // MARK: - First responder

    @objc(acceptsFirstResponder)
    public override dynamic var acceptsFirstResponder: Bool {
        if self.curDCM == nil { return false }

        return true
    }

    @objc(becomeFirstResponder)
    public override dynamic func becomeFirstResponder() -> Bool {
        self.horos_isKeyView = true

        self.updateTilingViews()

        if self.horos_curImage < 0 {
            let last = (self.horos_dcmPixList?.count ?? 0) - 1
            if self.horos_flippedData {
                if self.horos_listType == CChar(UInt8(ascii: "i")) { self.setIndex(last) }
                else { self.setIndexWithReset(last, true) }
            } else {
                if self.horos_listType == CChar(UInt8(ascii: "i")) { self.setIndex(0) }
                else { self.setIndexWithReset(0, true) }
            }

            self.updateTilingViews()
        }

        self.becomeKeyWindow()
        self.needsDisplay = true

        if self.is2DViewer() {
            inputMessages(self.windowController())?.inputAdjustSlider()
            inputMessages(self.windowController())?.inputPropagateSettings()
        }

        inputPost(.OsirixDCMViewDidBecomeFirstResponder, object: self)

        self.flagsChanged(with: NSApplication.shared.currentEvent)

        return true
    }

    @objc(resignFirstResponder)
    public override dynamic func resignFirstResponder() -> Bool {
        self.horos_isKeyView = false
        self.needsDisplay = true
        self.sendSyncMessage(0)

        return super.resignFirstResponder()
    }

    /// Another view became the key view of the window: this one no longer is.
    @objc(newImageViewisKey:)
    public dynamic func newImageViewisKey(_ note: NSNotification!) {
        if (note?.object as AnyObject?) !== self {
            self.horos_isKeyView = false
        }
    }

    /// The viewer's window became main: the reference lines are recomputed
    /// from this view, which tells the others where it is.
    @objc(becomeMainWindow)
    public dynamic func becomeMainWindow() {
        self.updateTilingViews()

        self.invalidateReferenceLines()
        self.horos_slicePoint3D[0] = Float.infinity

        self.sendSyncMessage(0)
        self.computeColor()
        self.needsDisplay = true
    }

    /// The viewer's window became key: as becoming main, and the 2D point
    /// markers go.
    @objc(becomeKeyWindow)
    public dynamic func becomeKeyWindow() {
        self.invalidateReferenceLines()
        self.horos_slicePoint3D[0] = Float.infinity

        self.erase2DPointMarker()
        self.blending?.erase2DPointMarker()

        self.sendSyncMessage(0)

        self.flagsChanged(with: NSApplication.shared.currentEvent)

        self.needsDisplay = true
    }
}
