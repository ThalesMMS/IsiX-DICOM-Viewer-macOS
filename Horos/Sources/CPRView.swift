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
//
//  CPRView.m
//  OsiriX
//
//  Created by Joël Spaltenstein on 6/5/11.
//  Copyright 2011 OsiriX Team. All rights reserved.
//

import Cocoa

// The reformation types of CPRView.h, as the NSInteger CPRViewReformationType.
private let straightenedReformationType = CPRViewReformationType(CPRViewStraightenedReformationType.rawValue)
private let stretchedReformationType = CPRViewReformationType(CPRViewStretchedReformationType.rawValue)

/// assert() of the Objective-C: checked in Debug only.
@inline(__always)
private func debugAssert(_ condition: @autoclosure () -> Bool) {
    #if DEBUG
    precondition(condition())
    #endif
}

/// The messages the former class sent to [self reformationView], typed id:
/// sent as Objective-C sent them, by selector, without a class check. The
/// types are those CPRStraightenedView and CPRStretchedView implement.
@objc private protocol CPRViewReformationViewMessages {
    @objc(waitUntilPixUpdate) func waitUntilPixUpdate()
    @objc(getWLWW::) func getWLWW(_ wl: UnsafeMutablePointer<Float>!, _ ww: UnsafeMutablePointer<Float>!)
    @objc(curDCM) var curDCM: DCMPix! { get }
    @objc(curImage) var curImage: Int16 { get }
    @objc(delegate) var delegate: CPRViewDelegate? { get }
    /// Sent as -[CPRStraightenedView volumeData] in the former class (a cast
    /// to pick the return type), whatever the reformation view.
    @objc(volumeData) var volumeData: CPRVolumeData! { get }
    @objc(curvedPath) var curvedPath: CPRCurvedPath! { get }
    @objc(displayInfo) var displayInfo: CPRDisplayInfo! { get }
    @objc(clippingRangeMode) var clippingRangeMode: CPRViewClippingRangeMode { get }
    @objc(orangePlane) var orangePlane: N3Plane { get }
    @objc(purplePlane) var purplePlane: N3Plane { get }
    @objc(bluePlane) var bluePlane: N3Plane { get }
    @objc(orangeSlabThickness) var orangeSlabThickness: CGFloat { get }
    @objc(purpleSlabThickness) var purpleSlabThickness: CGFloat { get }
    @objc(blueSlabThickness) var blueSlabThickness: CGFloat { get }
    @objc(orangePlaneColor) var orangePlaneColor: NSColor! { get }
    @objc(purplePlaneColor) var purplePlaneColor: NSColor! { get }
    @objc(bluePlaneColor) var bluePlaneColor: NSColor! { get }
    @objc(curvedVolumeData) var curvedVolumeData: CPRVolumeData! { get }
    @objc(generatedHeight) var generatedHeight: CGFloat { get }
    @objc(displayCrossLines) var displayCrossLines: Bool { get }
    /// Sent as -[DCMView rotation] in the former class (a cast).
    @objc(rotation) var rotation: Float { get }
    @objc(scaleValue) var scaleValue: Float { get }
}

/// The curved MPR view of the CPR window: it hosts a CPRStraightenedView and a
/// CPRStretchedView, shows the one of its reformation type, forwards the
/// settings to both and the queries to the one shown.
///
/// Implemented in Swift since #825: the Objective-C name, the selectors and
/// <Horos/CPRView.h> are those of the former class, the customClass of the CPR
/// view of CPR.xib, which creates it with -initWithFrame:.
@objc(CPRView)
public final class CPRView: NSView {
    // MARK: - The former instance variables

    private var _reformationType: CPRViewReformationType = 0

    private var _straightenedView: CPRStraightenedView? = nil
    private var _stretchedView: CPRStretchedView? = nil

    /// [self reformationView], to which the former class sent its queries as
    /// messages to an id; nil answers 0/nil/NO as a message to nil did.
    private var reformationViewMessages: CPRViewReformationViewMessages? {
        guard let reformationView = self.reformationView() else {
            return nil
        }
        return unsafeBitCast(reformationView as AnyObject, to: CPRViewReformationViewMessages.self)
    }

    // MARK: - Initialization

    public override init(frame: NSRect) {
        super.init(frame: frame)
        _straightenedView = CPRStraightenedView(frame: self.bounds)
        _stretchedView = CPRStretchedView(frame: self.bounds)

        if let straightenedView = _straightenedView {
            self.addSubview(straightenedView)
        }
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        // _straightenedView and _stretchedView: Swift releases them.
    }

    public override dynamic var frame: NSRect {
        get { return super.frame }
        set {
            super.frame = newValue

            NSDisableScreenUpdates()
            _straightenedView?.frame = self.bounds
            _stretchedView?.frame = self.bounds

            NSEnableScreenUpdates()
        }
    }

    @objc public dynamic var reformationType: CPRViewReformationType {
        get { return _reformationType }
        set {
            let reformationType = newValue
            debugAssert(reformationType == straightenedReformationType || reformationType == stretchedReformationType)

            if reformationType != _reformationType {
                if _reformationType == straightenedReformationType { // going from straightened to stretched
                    _straightenedView?.removeFromSuperview()
                    _stretchedView?.curvedPath = _straightenedView?.curvedPath
                    _stretchedView?.displayInfo = _straightenedView?.displayInfo
                    if let stretchedView = _stretchedView {
                        self.addSubview(stretchedView)
                    }
                } else {
                    _stretchedView?.removeFromSuperview()
                    _straightenedView?.curvedPath = _stretchedView?.curvedPath
                    _straightenedView?.displayInfo = _stretchedView?.displayInfo
                    if let straightenedView = _straightenedView {
                        self.addSubview(straightenedView)
                    }
                }
                _reformationType = reformationType
            }
        }
    }

    /// Returns the actual view that does the reformation. I expect hacky calls
    /// that do and do screen grabs and such will need this.
    @objc(reformationView)
    public dynamic func reformationView() -> Any! {
        if _reformationType == straightenedReformationType {
            return _straightenedView
        } else {
            return _stretchedView
        }
    }

    @objc(_setNeedsNewRequest)
    public dynamic func _setNeedsNewRequest() {
        if _reformationType == straightenedReformationType {
            self._straightenedView?._setNeedsNewRequest()
        } else {
            self._stretchedView?._setNeedsNewRequest()
        }
    }

    /// Returns once the reformation view's DCM pix object has been updated to
    /// reflect any changes made to the view.
    @objc(waitUntilPixUpdate)
    public dynamic func waitUntilPixUpdate() {
        self.reformationViewMessages?.waitUntilPixUpdate()
    }

    @objc(cancelStraightenedGeneration)
    public dynamic func cancelStraightenedGeneration() -> Bool {
        if _reformationType == straightenedReformationType {
            return _straightenedView?.cancelStraightenedGeneration() ?? false
        }
        return false
    }

    // MARK: - DCMView-like methods

    @objc(setWLWW::)
    public dynamic func setWLWW(_ wl: Float, _ ww: Float) {
        _straightenedView?.setWLWW(wl, ww)
        _stretchedView?.setWLWW(wl, ww)
    }

    @objc(getWLWW::)
    public dynamic func getWLWW(_ wl: UnsafeMutablePointer<Float>!, _ ww: UnsafeMutablePointer<Float>!) {
        self.reformationViewMessages?.getWLWW(wl, ww)
    }

    @objc(setCLUT:::)
    public dynamic func setCLUT(_ r: UnsafeMutablePointer<UInt8>!, _ g: UnsafeMutablePointer<UInt8>!, _ b: UnsafeMutablePointer<UInt8>!) {
        _straightenedView?.setCLUT(r, g, b)
        _stretchedView?.setCLUT(r, g, b)
    }

    @objc public dynamic var curDCM: DCMPix! {
        return self.reformationViewMessages?.curDCM
    }

    @objc public dynamic var curImage: Int16 {
        return self.reformationViewMessages?.curImage ?? 0
    }

    @objc(setIndex:)
    public dynamic func setIndex(_ index: Int16) {
        _straightenedView?.setIndex(index)
        _stretchedView?.setIndex(index)
    }

    @objc(setCurrentTool:)
    public dynamic func setCurrentTool(_ i: ToolMode) {
        _straightenedView?.currentTool = i
        _stretchedView?.currentTool = i
    }

    @objc(nsimage)
    private dynamic func nsimage() -> NSImage! {
        if _reformationType == straightenedReformationType {
            return _straightenedView?.nsimage()
        } else {
            return _stretchedView?.nsimage()
        }
    }

    @objc(nsimage:)
    private dynamic func nsimage(_ bo: Bool) -> NSImage! {
        if _reformationType == straightenedReformationType {
            return _straightenedView?.nsimage(bo)
        } else {
            return _stretchedView?.nsimage(bo)
        }
    }

    @objc(nsimage:allViewers:)
    private dynamic func nsimage(_ bo: Bool, allViewers all: Bool) -> NSImage! {
        if _reformationType == straightenedReformationType {
            return _straightenedView?.nsimage(bo, allViewers: all)
        } else {
            return _stretchedView?.nsimage(bo, allViewers: all)
        }
    }

    @objc(getRawPixels::::::)
    private dynamic func getRawPixels(_ width: UnsafeMutablePointer<Int>!, _ height: UnsafeMutablePointer<Int>!, _ spp: UnsafeMutablePointer<Int>!, _ bpp: UnsafeMutablePointer<Int>!, _ screenCapture: Bool, _ force8bits: Bool) -> UnsafeMutablePointer<UInt8>! {
        if _reformationType == straightenedReformationType {
            return _straightenedView?.getRawPixels(width, height, spp, bpp, screenCapture, force8bits)
        } else {
            return _stretchedView?.getRawPixels(width, height, spp, bpp, screenCapture, force8bits)
        }
    }

    @objc(getRawPixelsWidth:height:spp:bpp:screenCapture:force8bits:removeGraphical:squarePixels:allTiles:allowSmartCropping:origin:spacing:)
    private dynamic func getRawPixelsWidth(_ width: UnsafeMutablePointer<Int>!, height: UnsafeMutablePointer<Int>!, spp: UnsafeMutablePointer<Int>!, bpp: UnsafeMutablePointer<Int>!, screenCapture: Bool, force8bits: Bool, removeGraphical: Bool, squarePixels: Bool, allTiles: Bool, allowSmartCropping: Bool, origin imOrigin: UnsafeMutablePointer<Float>!, spacing imSpacing: UnsafeMutablePointer<Float>!) -> UnsafeMutablePointer<UInt8>! {
        if _reformationType == straightenedReformationType {
            return _straightenedView?.getRawPixelsWidth(width, height: height, spp: spp, bpp: bpp, screenCapture: screenCapture, force8bits: force8bits, removeGraphical: removeGraphical, squarePixels: squarePixels, allTiles: allTiles, allowSmartCropping: allowSmartCropping, origin: imOrigin, spacing: imSpacing)
        } else {
            return _stretchedView?.getRawPixelsWidth(width, height: height, spp: spp, bpp: bpp, screenCapture: screenCapture, force8bits: force8bits, removeGraphical: removeGraphical, squarePixels: squarePixels, allTiles: allTiles, allowSmartCropping: allowSmartCropping, origin: imOrigin, spacing: imSpacing)
        }
    }

    @objc(getRawPixelsWidth:height:spp:bpp:screenCapture:force8bits:removeGraphical:squarePixels:allTiles:allowSmartCropping:origin:spacing:offset:isSigned:)
    private dynamic func getRawPixelsWidth(_ width: UnsafeMutablePointer<Int>!, height: UnsafeMutablePointer<Int>!, spp: UnsafeMutablePointer<Int>!, bpp: UnsafeMutablePointer<Int>!, screenCapture: Bool, force8bits: Bool, removeGraphical: Bool, squarePixels: Bool, allTiles: Bool, allowSmartCropping: Bool, origin imOrigin: UnsafeMutablePointer<Float>!, spacing imSpacing: UnsafeMutablePointer<Float>!, offset: UnsafeMutablePointer<Int32>!, isSigned: UnsafeMutablePointer<ObjCBool>!) -> UnsafeMutablePointer<UInt8>! {
        if _reformationType == straightenedReformationType {
            return _straightenedView?.getRawPixelsWidth(width, height: height, spp: spp, bpp: bpp, screenCapture: screenCapture, force8bits: force8bits, removeGraphical: removeGraphical, squarePixels: squarePixels, allTiles: allTiles, allowSmartCropping: allowSmartCropping, origin: imOrigin, spacing: imSpacing, offset: offset, isSigned: isSigned)
        } else {
            return _stretchedView?.getRawPixelsWidth(width, height: height, spp: spp, bpp: bpp, screenCapture: screenCapture, force8bits: force8bits, removeGraphical: removeGraphical, squarePixels: squarePixels, allTiles: allTiles, allowSmartCropping: allowSmartCropping, origin: imOrigin, spacing: imSpacing, offset: offset, isSigned: isSigned)
        }
    }

    // MARK: - Standard CPRView methods

    /// As an implementation detail, the sender that will call the delegate will
    /// actually be the reformation view.
    @objc public dynamic var delegate: CPRViewDelegate? {
        get { return self.reformationViewMessages?.delegate }
        set {
            _straightenedView?.delegate = newValue
            _stretchedView?.delegate = newValue
        }
    }

    /// The volume data of the original data.
    @objc public dynamic var volumeData: CPRVolumeData! {
        get { return self.reformationViewMessages?.volumeData }
        set {
            _straightenedView?.volumeData = newValue
            _stretchedView?.volumeData = newValue
        }
    }

    // A copy property of CPRView.h whose setter the former class wrote: it
    // passed the path on uncopied (the reformation views copy it).
    @objc public dynamic var curvedPath: CPRCurvedPath! {
        get { return self.reformationViewMessages?.curvedPath }
        set {
            _straightenedView?.curvedPath = newValue
            _stretchedView?.curvedPath = newValue
        }
    }

    // A copy property of CPRView.h whose setter the former class wrote: it
    // passed the display info on uncopied (the reformation views copy it).
    @objc public dynamic var displayInfo: CPRDisplayInfo! {
        get { return self.reformationViewMessages?.displayInfo }
        set {
            _straightenedView?.displayInfo = newValue
            _stretchedView?.displayInfo = newValue
        }
    }

    @objc public dynamic var clippingRangeMode: CPRViewClippingRangeMode {
        get { return self.reformationViewMessages?.clippingRangeMode ?? 0 }
        set {
            _straightenedView?.clippingRangeMode = newValue
            _stretchedView?.clippingRangeMode = newValue
        }
    }

    // BOGUS implementations until the stretched CPR View can handle these.
    // Set the planes to N3PlaneInvalid to keep them from appearing.
    @objc public dynamic var orangePlane: N3Plane {
        get { return self.reformationViewMessages?.orangePlane ?? N3Plane() }
        set {
            _straightenedView?.orangePlane = newValue
            _stretchedView?.orangePlane = newValue
        }
    }

    @objc public dynamic var purplePlane: N3Plane {
        get { return self.reformationViewMessages?.purplePlane ?? N3Plane() }
        set {
            _straightenedView?.purplePlane = newValue
            _stretchedView?.purplePlane = newValue
        }
    }

    @objc public dynamic var bluePlane: N3Plane {
        get { return self.reformationViewMessages?.bluePlane ?? N3Plane() }
        set {
            _straightenedView?.bluePlane = newValue
            _stretchedView?.bluePlane = newValue
        }
    }

    @objc public dynamic var orangeSlabThickness: CGFloat {
        get { return self.reformationViewMessages?.orangeSlabThickness ?? 0 }
        set {
            _straightenedView?.orangeSlabThickness = newValue
            _stretchedView?.orangeSlabThickness = newValue
        }
    }

    @objc public dynamic var purpleSlabThickness: CGFloat {
        get { return self.reformationViewMessages?.purpleSlabThickness ?? 0 }
        set {
            _straightenedView?.purpleSlabThickness = newValue
            _stretchedView?.purpleSlabThickness = newValue
        }
    }

    @objc public dynamic var blueSlabThickness: CGFloat {
        get { return self.reformationViewMessages?.blueSlabThickness ?? 0 }
        set {
            _straightenedView?.blueSlabThickness = newValue
            _stretchedView?.blueSlabThickness = newValue
        }
    }

    @objc public dynamic var orangePlaneColor: NSColor! {
        get { return self.reformationViewMessages?.orangePlaneColor }
        set {
            _straightenedView?.orangePlaneColor = newValue
            _stretchedView?.orangePlaneColor = newValue
        }
    }

    @objc public dynamic var purplePlaneColor: NSColor! {
        get { return self.reformationViewMessages?.purplePlaneColor }
        set {
            _straightenedView?.purplePlaneColor = newValue
            _stretchedView?.purplePlaneColor = newValue
        }
    }

    @objc public dynamic var bluePlaneColor: NSColor! {
        get { return self.reformationViewMessages?.bluePlaneColor }
        set {
            _straightenedView?.bluePlaneColor = newValue
            _stretchedView?.bluePlaneColor = newValue
        }
    }

    /// The volume data that was generated.
    @objc public dynamic var curvedVolumeData: CPRVolumeData! {
        return self.reformationViewMessages?.curvedVolumeData
    }

    /// Height of the image that is generated in mm. Kinda hack: sends
    /// CPRViewDidChangeGeneratedHeight to the delegate when this value changes.
    @objc public dynamic var generatedHeight: CGFloat {
        return self.reformationViewMessages?.generatedHeight ?? 0
    }

    @objc public dynamic var displayTransverseLines: Bool {
        get { return _straightenedView?.displayTransverseLines ?? false }
        set { _straightenedView?.displayTransverseLines = newValue }
    }

    @objc public dynamic var displayCrossLines: Bool {
        get { return self.reformationViewMessages?.displayCrossLines ?? false }
        set {
            _straightenedView?.displayCrossLines = newValue
            _stretchedView?.displayCrossLines = newValue
        }
    }

    @objc public dynamic var rotation: Float {
        get { return self.reformationViewMessages?.rotation ?? 0 }
        set {
            _straightenedView?.rotation = newValue
            _stretchedView?.rotation = newValue
        }
    }

    @objc public dynamic var scaleValue: Float {
        get { return self.reformationViewMessages?.scaleValue ?? 0 }
        set {
            _straightenedView?.scaleValue = newValue
            _stretchedView?.scaleValue = newValue
        }
    }
}
