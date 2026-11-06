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
import IsiXPreferences

// The mouse moving over DCMView is implemented in Swift: an extension of
// DCMView, with the same selectors. The view under
// the pointer reads the pixel there, for itself and for the image blended
// with it, shows the magnifier with Shift, sends the patient crosshair with
// Shift-Control, and tells the other views, which clear theirs.

extension DCMView {

    // MARK: - Mouse moved

    @objc(mouseMoved:)
    public override dynamic func mouseMoved(with theEvent: NSEvent) {
        if self.shouldIgnoreHiddenCursorEvent(theEvent) { return }
        if self.window?.isVisible != true {
            if self.is2DViewer() && inputMessages(self.windowController())?.inputFullScreenON() == true {

            } else {
                return
            }
        }

        if self.event(toPlugins: theEvent) { return }

        if !self.drawing { return }

        if self.is2DViewer() == true {
            if inputMessages(self.windowController())?.inputWindowWillClose() == true { return }
        }

        if self.curDCM == nil { return }

        if self.horos_dcmPixList == nil { return }

        if self.horos_avoidMouseMovedRecursive {
            return
        }

        self.horos_avoidMouseMovedRecursive = true

        let eventLocation = self.window?.mouseLocationOutsideOfEventStream ?? .zero

        if self.window?.isVisible == true {
            let view = self.window?.contentView?.hitTest(eventLocation)

            if let view = view as? DCMView {
                view.mouseMoved(inView: eventLocation)
            }

            if self.is2DViewer() == true && self.window?.isKeyWindow == true {
                inputMessages(self.windowController())?.inputAutoHideMatrix()
            }
        }

        self.horos_avoidMouseMovedRecursive = false
    }

    /// The view under the pointer, at a point of the window: the pixel values
    /// shown in the annotations, the magnifier, the patient crosshair, the
    /// ROI point under the mouse and the ROI text shown over a ROI.
    @objc(mouseMovedInView:)
    public dynamic func mouseMoved(inView eventLocationInWindow: NSPoint) {
        self.horosMoveScrollPreview(atWindowPoint: eventLocationInWindow)
        let modifierFlags = NSApplication.shared.currentEvent?.modifierFlags ?? []
        let eventLocationInView = self.convert(eventLocationInWindow, from: nil)

        inputLogException(HorosObjCException.caughtWithoutAllocation {
            self.deleteLens()

            BrowserController.updateActivity()

            let cpixelMouseValueR = Float(self.horos_pixelMouseValueR)
            let cpixelMouseValueG = Float(self.horos_pixelMouseValueG)
            let cpixelMouseValueB = Float(self.horos_pixelMouseValueB)
            let cmouseXPos = self.horos_mouseXPos
            let cmouseYPos = self.horos_mouseYPos
            let cpixelMouseValue = self.horos_pixelMouseValue

            self.horos_pixelMouseValueR = 0
            self.horos_pixelMouseValueG = 0
            self.horos_pixelMouseValueB = 0
            self.horos_mouseXPos = 0
            self.horos_mouseYPos = 0
            self.horos_pixelMouseValue = 0

            let cblendingMouseXPos = self.horos_blendingMouseXPos
            let cblendingMouseYPos = self.horos_blendingMouseYPos
            let cblendingPixelMouseValue = self.horos_blendingPixelMouseValue
            let cblendingPixelMouseValueR = Float(self.horos_blendingPixelMouseValueR)
            let cblendingPixelMouseValueG = Float(self.horos_blendingPixelMouseValueG)
            let cblendingPixelMouseValueB = Float(self.horos_blendingPixelMouseValueB)

            self.horos_blendingMouseXPos = 0
            self.horos_blendingMouseYPos = 0
            self.horos_blendingPixelMouseValue = 0
            self.horos_blendingPixelMouseValueR = 0
            self.horos_blendingPixelMouseValueG = 0
            self.horos_blendingPixelMouseValueB = 0

            var needUpdate = false

            DCMView.horos_static_drawLock?.lock()

            inputLogException(HorosObjCException.caughtWithoutAllocation {
                self.readPixelsUnderMouse(eventLocationInWindow, inView: eventLocationInView, modifierFlags: modifierFlags)
            }, "-[DCMView mouseMovedInView:]")

            DCMView.horos_static_drawLock?.unlock()

            if cpixelMouseValueR != Float(self.horos_pixelMouseValueR) { needUpdate = true }
            if cpixelMouseValueG != Float(self.horos_pixelMouseValueG) { needUpdate = true }
            if cpixelMouseValueB != Float(self.horos_pixelMouseValueB) { needUpdate = true }
            if cmouseXPos != self.horos_mouseXPos { needUpdate = true }
            if cmouseYPos != self.horos_mouseYPos { needUpdate = true }
            if cpixelMouseValue != self.horos_pixelMouseValue { needUpdate = true }
            if cblendingMouseXPos != self.horos_blendingMouseXPos { needUpdate = true }
            if cblendingMouseYPos != self.horos_blendingMouseYPos { needUpdate = true }
            if cblendingPixelMouseValue != self.horos_blendingPixelMouseValue { needUpdate = true }
            if cblendingPixelMouseValueR != Float(self.horos_blendingPixelMouseValueR) { needUpdate = true }
            if cblendingPixelMouseValueG != Float(self.horos_blendingPixelMouseValueG) { needUpdate = true }
            if cblendingPixelMouseValueB != Float(self.horos_blendingPixelMouseValueB) { needUpdate = true }

            if needUpdate {
                self.needsDisplay = true
                inputPost(NSNotification.Name("DCMViewMouseMovedUpdated"), object: self)
            }
        }, "-[DCMView mouseMovedInView:]")
    }

    /// The part of -mouseMovedInView: under the draw lock.
    private func readPixelsUnderMouse(_ eventLocationInWindow: NSPoint, inView eventLocationInView: NSPoint, modifierFlags: NSEvent.ModifierFlags) {
        let modifiers = ViewInput.Modifiers(rawValue: modifierFlags.rawValue)
        var mouseOnImage = false

        let imageLocation = self.convert(fromNSView2GL: eventLocationInView)

        self.horos_mouseXPos = Float(imageLocation.x)
        self.horos_mouseYPos = Float(imageLocation.y)

        let curDCM: DCMPix! = self.curDCM
        let probe = PixelProbe(width: curDCM?.pwidth ?? 0, height: curDCM?.pheight ?? 0)
        if let pixel = probe.pixel(at: imageLocation) { // NSPointInRect does not work in MPR Ortho
                mouseOnImage = true

                if ViewInput.syncsPatientPoint(modifiers) && self.horos_mouseDragging == false {
                    self.sync3DPosition()
                } else if ViewInput.isShiftAlone(modifiers) && self.horos_mouseDragging == false
                            && self.horosShiftHidesMeasurementMagnifier(with: modifierFlags) == false {
                    // With a ROI tool also over a ROI, on the click and while a
                    // point waits for its second click. A drag shows the ROI
                    // tool's lens itself, once the ROI has taken the point.
                    self.computeMagnifyLens(imageLocation)
                }

                if curDCM.isRGB {
                    let rgb = probe.rgb(x: pixel.x, y: pixel.y, in: UnsafeRawPointer(curDCM.fImage!).assumingMemoryBound(to: UInt8.self))
                    self.horos_pixelMouseValueR = rgb.red
                    self.horos_pixelMouseValueG = rgb.green
                    self.horos_pixelMouseValueB = rgb.blue
                } else {
                    self.horos_pixelMouseValue = curDCM.getPixelValueX(pixel.x, y: pixel.y)
                }
        }

        // Blended view
        if let blendingView = self.blending {
            let blendedLocation = blendingView.convert(fromNSView2GL: eventLocationInView)
            let blendedDCM: DCMPix! = blendingView.curDCM

            let blendedProbe = PixelProbe(width: blendedDCM?.pwidth ?? 0, height: blendedDCM?.pheight ?? 0)
            if let pixel = blendedProbe.pixel(at: blendedLocation) {
                    self.horos_blendingMouseXPos = Float(blendedLocation.x)
                    self.horos_blendingMouseYPos = Float(blendedLocation.y)

                    if blendedDCM.isRGB {
                        let rgb = blendedProbe.rgb(x: pixel.x, y: pixel.y, in: UnsafeRawPointer(blendedDCM.fImage!).assumingMemoryBound(to: UInt8.self))
                        self.horos_blendingPixelMouseValueR = rgb.red
                        self.horos_blendingPixelMouseValueG = rgb.green
                        self.horos_blendingPixelMouseValueB = rgb.blue
                    } else {
                        self.horos_blendingPixelMouseValue = blendedDCM.getPixelValueX(pixel.x, y: pixel.y)
                    }
            }
        }

        let halfWidth = Float(Double(curDCM?.pwidth ?? 0) / 2.0), halfHeight = Float(Double(curDCM?.pheight ?? 0) / 2.0)

        // Are we near a ROI point?
        if self.roiTool(self.horos_currentTool) {
            let pt = self.convert(fromNSView2GL: self.convert(eventLocationInWindow, from: nil))

            for case let r as ROI in (self.horos_curRoiList ?? NSMutableArray()) {
                r.displayPointUnderMouse(pt, halfWidth, halfHeight, self.horos_scaleValue)
            }

            if NSApplication.shared.currentEvent?.type == .mouseMoved {
                // Should we change the mouse cursor?
                if !modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                    self.flagsChanged(with: NSApplication.shared.currentEvent)
                }
            }
        }

        let preferences = PreferencesSource.process.preferences
        if preferences[ViewerPreferences.roiTextIfMouseIsOver] && preferences[ViewerPreferences.roiTextIfSelected] {
            if self.horos_mouseDragging == false {
                let pt = self.convert(fromNSView2GL: self.convert(eventLocationInWindow, from: nil))

                for case let r as ROI in (self.horos_curRoiList ?? NSMutableArray()) {
                    let c = r.clickInTextBox

                    if r.click(inROI: pt, halfWidth, halfHeight, self.horos_scaleValue, false) != 0 {
                        if !r.mouseOverROI {
                            r.mouseOverROI = true
                            self.needsDisplay = true
                        }
                    } else if r.mouseOverROI {
                        r.mouseOverROI = false
                        self.needsDisplay = true
                    }
                    r.clickInTextBox = c
                }
            }
        }

        _ = mouseOnImage
    }

    /// Another view's pointer: this one clears the pixel it showed. Each value
    /// is compared with the 0 it has just been given, as the Objective-C
    /// compared it with the ivar it had just zeroed; this runs in every other
    /// view at every mouse event, so the values are not read back.
    @objc(DCMViewMouseMovedUpdated:)
    public dynamic func dcmViewMouseMovedUpdated(_ n: NSNotification!) {
        if (n?.object as AnyObject?) !== self {
            let cpixelMouseValueR = Float(self.horos_pixelMouseValueR), cpixelMouseValueG = Float(self.horos_pixelMouseValueG), cpixelMouseValueB = Float(self.horos_pixelMouseValueB)
            let cmouseXPos = self.horos_mouseXPos, cmouseYPos = self.horos_mouseYPos
            let cpixelMouseValue = self.horos_pixelMouseValue

            self.horos_pixelMouseValueR = 0
            self.horos_pixelMouseValueG = 0
            self.horos_pixelMouseValueB = 0
            self.horos_mouseXPos = 0
            self.horos_mouseYPos = 0
            self.horos_pixelMouseValue = 0

            let cblendingMouseXPos = self.horos_blendingMouseXPos, cblendingMouseYPos = self.horos_blendingMouseYPos
            let cblendingPixelMouseValue = self.horos_blendingPixelMouseValue
            let cblendingPixelMouseValueR = Float(self.horos_blendingPixelMouseValueR), cblendingPixelMouseValueG = Float(self.horos_blendingPixelMouseValueG), cblendingPixelMouseValueB = Float(self.horos_blendingPixelMouseValueB)

            self.horos_blendingMouseXPos = 0
            self.horos_blendingMouseYPos = 0
            self.horos_blendingPixelMouseValue = 0
            self.horos_blendingPixelMouseValueR = 0
            self.horos_blendingPixelMouseValueG = 0
            self.horos_blendingPixelMouseValueB = 0

            let needUpdate = cpixelMouseValueR != 0 || cpixelMouseValueG != 0 || cpixelMouseValueB != 0
                || cmouseXPos != 0 || cmouseYPos != 0 || cpixelMouseValue != 0
                || cblendingMouseXPos != 0 || cblendingMouseYPos != 0 || cblendingPixelMouseValue != 0
                || cblendingPixelMouseValueR != 0 || cblendingPixelMouseValueG != 0 || cblendingPixelMouseValueB != 0

            if needUpdate {
                self.needsDisplay = true
            }
        }
    }

    // MARK: - Patient crosshair

    /// The point under the mouse, sent to the other viewers: the shared
    /// patient crosshair moves the native ones once, and the sync message,
    /// with the point in patient coordinates, keeps the plugins and the
    /// reference lines informed.
    @objc(sync3DPosition)
    public dynamic func sync3DPosition() {
        guard let curDCM = self.curDCM, self.horos_curImage >= 0,
              !inputBeyondLast(self.horos_curImage, self.horos_dcmPixList?.count ?? 0),
              let dcmPixList = self.horos_dcmPixList else { return }
        var location: [Float] = [0, 0, 0]

        curDCM.convertX(self.horos_mouseXPos, pixY: self.horos_mouseYPos, toDICOMCoords: &location, pixelCenter: true)

        // The shared controller moves native consumers once. Keep the established
        // OsirixSyncNotification payload below for plugins and reference lines.
        let sharedPoint = self.is2DViewer() &&
            PatientCrosshairController.shared.publish(location, viewer: self.windowController() as? ViewerController, owner: self.windowController().map { $0 as AnyObject })

        // This used to ignore flippedData, while -syncMessage: right below honoured
        // it: a reversed series sent the far end of the slab from the wrong side of
        // the current slice, and the receiver drew the band there.
        let current = Int(self.horos_curImage)
        let farEnd = ThickSlabRange.farEndIndex(currentIndex: current,
                                                stack: Int(curDCM.stack),
                                                count: dcmPixList.count,
                                                flippedData: self.horos_flippedData)
        let thickDCM = farEnd >= 0 ? dcmPixList.object(at: farEnd) as? DCMPix : nil

        let message = ViewerSyncMessage(position: ViewerSyncMessage.position(current: current, count: dcmPixList.count, flippedData: self.horos_flippedData),
                                        direction: nil,
                                        location: Float((dcmPixList.object(at: current) as? DCMPix)?.sliceLocation ?? 0),
                                        offset: self.horos_syncRelativeDiff,
                                        frameOfReferenceUID: curDCM.frameofReferenceUID,
                                        studyInstanceUID: self.horosStudyInstanceUID(at: current),
                                        patientPoint: ViewerSyncMessage.PatientPoint(x: location[0], y: location[1], z: location[2]),
                                        sharesPatientCrosshair: sharedPoint)
        self.postSyncMessage(self.syncUserInfo(message, image: curDCM, farEndImage: thickDCM))
    }

    // MARK: - Entering and leaving

    @objc(mouseEntered:)
    public override dynamic func mouseEntered(with theEvent: NSEvent) {
        _ = self.event(toPlugins: theEvent)
        self.horos_cursorSet = true
    }

    @objc(mouseExited:)
    public override dynamic func mouseExited(with theEvent: NSEvent) {
        self.horosHideScrollPreview()
        _ = self.event(toPlugins: theEvent)

        self.mouseMoved(with: theEvent)

        self.deleteLens()
        self.horosHideCursor(forMagnifier: false)
        self.horos_mouseXPos = 0
        self.horos_mouseYPos = 0

        self.horos_cursorSet = false
    }

    @objc(cursorUpdate:)
    public override dynamic func cursorUpdate(with theEvent: NSEvent) {
        self.flagsChanged(with: theEvent)
        self.horos_cursor?.set()
        self.horos_cursorSet = true
    }
}
