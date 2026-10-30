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

// The life of VRView around its frames and its saved state: the 3D state the
// controller saves with the series and restores (-get3DStateDictionary,
// -set3DStateDictionary:), the camera reset, the idle auto-rotation, the
// window's closing and the controller's release, the fused series' viewer
// closing, the iChat frame and the first responder. A Swift extension of the
// class, with the same selectors; the initializer and -dealloc are in
// VRView.swift.
//
// A saved number is read as the Objective-C read it: its float, long or BOOL
// value, 0 for a missing one; a value of another class raises the same
// exception, which -[VRController load3DState] catches and logs.

/// `[x floatValue]` of a saved value, 0 when it is missing.
private func savedFloat(_ value: Any?) -> Float {
    return savedNumber(value)?.floatValue ?? 0
}

/// A saved value as the Objective-C messaged it: whatever its class, it answers
/// the number's message as its own (an NSString's floatValue), or raises as it
/// did (an object without it); nil for a missing one.
private func savedNumber(_ value: Any?) -> NSNumber? {
    guard let value else { return nil }
    return unsafeBitCast(value as AnyObject, to: NSNumber.self)
}

/// A saved array as the Objective-C messaged it: another object raises at
/// -objectAtIndex:, as it did; nil for a missing one.
private func savedArray(_ value: Any?) -> NSArray? {
    guard let value else { return nil }
    return unsafeBitCast(value as AnyObject, to: NSArray.self)
}

/// `[[array objectAtIndex: i] floatValue]`, 0 for a missing array.
private func savedFloat(_ array: NSArray?, _ i: Int) -> Float {
    guard let array else { return 0 }
    return savedFloat(array.object(at: i))
}

extension VRView {

    // MARK: - Events the view takes

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    public override var acceptsFirstResponder: Bool { true }

    public override var mouseDownCanMoveWindow: Bool { false }

    public override func becomeFirstResponder() -> Bool {
        NotificationCenter.default.post(name: .OsirixVRViewDidBecomeFirstResponder, object: self)
        connect2SpaceNavigator()
        return super.becomeFirstResponder()
    }

    /// The fused series' viewer is closing: the fusion goes.
    @objc(CloseViewerNotification:)
    func closeViewerNotification(_ note: Notification) {
        if (note.object as AnyObject?) === horos_blendingController { // our blended serie is closing itself....
            setBlendingPixSource(nil)
            needsDisplay = true
        }
    }

    // MARK: - The idle auto-rotation

    /// Three minutes without the mouse, and the volume turns by itself
    /// (autorotate3D): the countdown starts again.
    @objc(resetAutorotate:)
    func resetAutorotate(_ sender: Any?) {
        if UserDefaults.standard.bool(forKey: "autorotate3D") && window?.windowController is VRController {
            horos_startAutoRotate?.invalidate()

            horos_startAutoRotate = Timer.scheduledTimer(timeInterval: 60 * 3, target: self, selector: #selector(startAutoRotate(_:)),
                                                         userInfo: nil, repeats: false)
        }
    }

    @objc(startAutoRotate:)
    func startAutoRotate(_ sender: Any?) {
        if UserDefaults.standard.bool(forKey: "autorotate3D") {
            horos_isRotating = true
        }
    }

    /// The view's timer: a turn of the auto-rotation, a step of the fly-to.
    @objc(autoRotate:)
    func autoRotate(_ sender: Any?) {
        if horos_isRotating {
            azimuth(4.0)
            // The current event may be nil, which the Objective-C handed on.
            _ = perform(#selector(NSResponder.mouseMoved(with:)), with: NSApplication.shared.currentEvent)
            needsDisplay = true
        }

        if horos_flyto {
            processFlyTo()
        }
    }

    @objc(timerUpdate:)
    func timerUpdate(_ sender: Any?) {
        if horos_ROIUPDATE {
            display()
        }

        horos_ROIUPDATE = false
    }

    // MARK: - Closing

    @objc(windowWillClose:)
    func windowWillClose(_ notification: Notification) {
        if let window = self.window, window === (notification.object as AnyObject?) {
            if window.windowController is VRController {
                window.acceptsMouseMovedEvents = false
            }

            horos_startAutoRotate?.invalidate()
            horos_startAutoRotate = nil

            horos_autoRotate?.invalidate()
            horos_autoRotate = nil

            deleteMouseDownTimer()
            deleteRightMouseDownTimer()

            NotificationCenter.default.removeObserver(self)
        }
    }

    // Sent by -[VRController dealloc]. The timers retain the view and are otherwise
    // invalidated only by -windowWillClose:, which a window never shown never
    // posts: the endoscopy viewer's, when its initializer fails.
    @objc(prepareForRelease)
    func prepareForRelease() {
        horos_startAutoRotate?.invalidate()
        horos_startAutoRotate = nil

        horos_autoRotate?.invalidate()
        horos_autoRotate = nil

        deleteMouseDownTimer()
        deleteRightMouseDownTimer()
    }

    // MARK: - The camera reset

    // vtkRenderer::ResetCamera() puts the view angle back to 30 degrees, which is
    // how each projection mode has always ended up after its reset. An angle chosen
    // since then is kept; when the camera is fitted to the volume again, it is
    // moved to frame the volume as it would at 30 degrees.
    @objc(horosResetCameraFitting:)
    func horosResetCameraFitting(_ fit: Bool) {
        let chosenViewAngle = horos_chosenViewAngle
        horos_vtk.resetCameraKeepingViewAngle(chosenViewAngle, keep: chosenViewAngle > 0 && horos_projectionMode != 1, fit: fit)
        NotificationCenter.default.post(name: Notification.Name(ViewAngleControl.didChangeNotification), object: self)
    }

    @objc(resetImage:)
    func resetImage(_ sender: Any?) {
        let vtk = horos_vtk
        horosResetCameraFitting(true)
        saView(self)

        if horos_clipRangeActivated {
            goToCenter()
        }

        saView(self)

        vtk.setVolumeMinimumImageSampleDistance(horos_LOD)
        vtk.setBlendingMinimumImageSampleDistance(horos_LOD)

        setCurrentTool(.t3DRotate)
        horos_controller?.toolsMatrix()?.selectCell(withTag: Int(ToolMode.t3DRotate.rawValue))

        needsDisplay = true
    }

    // MARK: - The saved 3D state

    @objc(set3DStateDictionary:)
    func set3DStateDictionary(_ dict: [AnyHashable: Any]?) {
        let vtk = horos_vtk

        if let dict {
            if let tempArray = savedArray(dict["ShadingValues"]) {
                setShadingValues(savedFloat(tempArray, 0), savedFloat(tempArray, 1), savedFloat(tempArray, 2), savedFloat(tempArray, 3))
            }

            if renderingMode == 0 && vtk.hasProperty {
                vtk.shade = savedNumber(dict["ShadingFlag"])?.intValue ?? 0
            }

            let savedSupersampling = savedFloat(dict["superSampling"])
            var ratio: Float = 1

            if savedSupersampling != 0 {
                ratio = horos_superSampling / savedSupersampling
            }

            if (savedNumber(dict["SUVConverted"])?.boolValue ?? false) == (horos_firstObject?.suvConverted ?? false) {
                setWLWW(savedFloat(dict["WL"]), savedFloat(dict["WW"]))
            }

            /// The three saved floats, each times the ratio in float, then widened.
            func scaled(_ array: NSArray?) -> [Double] {
                return (0..<3).map { Double(savedFloat(array, $0) * ratio) }
            }

            var tempArray = savedArray(dict["CameraPosition"])
            if vtk.hasCamera {
                vtk.setCameraPosition(scaled(tempArray))
            }

            tempArray = savedArray(dict["CameraViewUp"])
            if vtk.hasCamera {
                vtk.setCameraViewUp(scaled(tempArray))
            }

            tempArray = savedArray(dict["CameraFocalPoint"])
            if vtk.hasCamera {
                vtk.setCameraFocalPoint(scaled(tempArray))
            }

            tempArray = savedArray(dict["CameraClipping"])
            if vtk.hasCamera {
                vtk.setCameraClippingRangeNear(Double(savedFloat(tempArray, 0)), far: Double(savedFloat(tempArray, 1)))
            }

            if let projection = dict["Projection"] {
                projectionMode = savedNumber(projection)?.int32Value ?? 0
            }

            // A state saved before the angle could be set has none: the mode's own.
            if let angle = dict["ViewAngle"] {
                viewAngle = savedNumber(angle)?.doubleValue ?? 0
            }

            dontResetImage = true
            if dict["clipRangeActivated"] != nil {
                clipRangeActivated = savedNumber(dict["clipRangeActivated"])?.boolValue ?? false
                clippingRangeThickness = Double(savedFloat(dict["clippingRangeThickness"]))
            } else {
                clipRangeActivated = false
            }
            dontResetImage = false
        } else {
            if renderingMode == 0 && vtk.hasProperty { // volume rendering
                vtk.shade = UserDefaults.standard.bool(forKey: "defaultShading") ? 1 : 0
            }
        }

        if vtk.hasVolume && !vtk.volumeHasMapper {
            engine = 2
        }
    }

    @objc(get3DStateDictionary)
    func get3DStateDictionary() -> NSMutableDictionary? {
        let vtk = horos_vtk
        var temp = [Double](repeating: 0, count: 3)
        var ambient: Float = 0, diffuse: Float = 0, specular: Float = 0, specularpower: Float = 0

        if !vtk.hasCamera { return nil }

        let dict = NSMutableDictionary()

        /// Three doubles saved as floats.
        func floats(_ count: Int) -> NSArray {
            return (0..<count).map { NSNumber(value: Float(temp[$0])) } as NSArray
        }

        dict.setObject(NSNumber(value: horos_wl), forKey: "WL" as NSString)
        dict.setObject(NSNumber(value: horos_ww), forKey: "WW" as NSString)
        dict.setObject(NSNumber(value: horos_firstObject?.suvConverted ?? false), forKey: "SUVConverted" as NSString)

        vtk.getCameraPosition(&temp)
        dict.setObject(floats(3), forKey: "CameraPosition" as NSString)
        vtk.getCameraViewUp(&temp)
        dict.setObject(floats(3), forKey: "CameraViewUp" as NSString)
        vtk.getCameraFocalPoint(&temp)
        dict.setObject(floats(3), forKey: "CameraFocalPoint" as NSString)
        vtk.getCameraClippingRange(&temp)
        dict.setObject(floats(2), forKey: "CameraClipping" as NSString)

        getShadingValues(&ambient, &diffuse, &specular, &specularpower)
        dict.setObject([NSNumber(value: ambient), NSNumber(value: diffuse), NSNumber(value: specular), NSNumber(value: specularpower)] as NSArray,
                       forKey: "ShadingValues" as NSString)
        dict.setObject(NSNumber(value: vtk.shade), forKey: "ShadingFlag" as NSString)
        dict.setObject(NSNumber(value: Int(horos_projectionMode)), forKey: "Projection" as NSString)
        if viewAngleAdjustable {
            dict.setObject(NSNumber(value: vtk.cameraViewAngle), forKey: "ViewAngle" as NSString)
        }

        dict.setObject(NSNumber(value: clipRangeActivated), forKey: "clipRangeActivated" as NSString)
        dict.setObject(NSNumber(value: Float(getClippingRangeThickness())), forKey: "clippingRangeThickness" as NSString)

        dict.setObject(NSNumber(value: horos_superSampling), forKey: "superSampling" as NSString)

        return dict
    }

    // MARK: - iChat and the flags its clients read

    // The _hasChanged flag is set to 'NO' after any check (by a client of this
    // class), and 'YES' after a frame is drawn that is not identical to the
    // previous one (in the drawInBounds: method).

    // Returns the current state of the flag, and sets it to the passed in value.
    @objc(_checkHasChanged:)
    func _checkHasChanged(_ flag: Bool) -> Bool {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        let hasChanged = horos_hasChanged
        horos_hasChanged = flag
        return hasChanged
    }

    @objc(checkHasChanged)
    func checkHasChanged() -> Bool {
        // Calling with 'NO' clears _hasChanged after the call (see above).
        return _checkHasChanged(false)
    }

    @objc(setIChatFrame:)
    dynamic func setIChatFrame(_ set: Bool) {
        if controller()?.style() == "panel" { return }

        if set {
            if horos_iChatFrameIsSet { return }
            let iChatWidth = horos_iChatWidth, iChatHeight = horos_iChatHeight
            if iChatWidth == 0 || iChatHeight == 0 { return }

            horos_iChatFrameIsSet = true

            let savedViewSizeFrame = frame
            horos_savedViewSizeFrame = savedViewSizeFrame

            var newFrame = NSRect.zero
            newFrame.size.width = CGFloat(iChatWidth)
            newFrame.size.height = CGFloat(iChatHeight)
            newFrame.origin.x = savedViewSizeFrame.origin.x + (savedViewSizeFrame.size.width - CGFloat(iChatWidth)) / 2.0
            newFrame.origin.y = savedViewSizeFrame.origin.y + (savedViewSizeFrame.size.height - CGFloat(iChatHeight)) / 2.0
            frame = newFrame
        } else {
            horos_iChatFrameIsSet = false
            let savedViewSizeFrame = horos_savedViewSizeFrame
            if savedViewSizeFrame.size.width > 0 && savedViewSizeFrame.size.height > 0 {
                frame = savedViewSizeFrame
            }
        }
    }

    @objc(recordFlyThru)
    func recordFlyThru() {
        horos_controller?.recordFlyThru()
    }

    // MARK: - 3DConnexion SpaceNavigator

    @objc(closeEvent:)
    func closeEvent(_ sender: Any?) {
        let vtk = horos_vtk
        let vV = VRView.horos_snVRView
        vtk.setVolumeMinimumImageSampleDistance(horos_LOD)

        vtk.setBlendingMinimumImageSampleDistance(horos_LOD)

        vV?.horos_vtk.invokeInteractorEvent(.leftButtonRelease)

        horos_snStopped = true

        horos_snCloseEventTimer = nil
    }

    // The 3Dconnexion SpaceNavigator drove the camera in 32-bit builds only.
    @objc(connect2SpaceNavigator)
    func connect2SpaceNavigator() {
    }
}
