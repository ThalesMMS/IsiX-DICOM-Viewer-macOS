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

/// The messages the controller sends to its viewer, an id in the former class:
/// an OrthogonalMPRViewer, an OrthogonalMPRPETCTViewer or an EndoscopyViewer.
/// The protocol names the selectors, it is not checked: a viewer that does not
/// answer one raises, as before.
@objc private protocol OrthogonalMPRControllerViewerMessages: NSObjectProtocol {
    @objc(blendingPropagateOriginal:) func blendingPropagateOriginal(_ sender: OrthogonalMPRView!)
    @objc(blendingPropagateX:) func blendingPropagateX(_ sender: OrthogonalMPRView!)
    @objc(blendingPropagateY:) func blendingPropagateY(_ sender: OrthogonalMPRView!)
    @objc(toggleDisplayResliceAxes) func toggleDisplayResliceAxes()
    /// -[OrthogonalMPRViewer fullWindowView:], the former cast of the viewer.
    @objc(fullWindowView:) func fullWindowView(_ index: Int32)
    @objc(syncOriginPosition) func syncOriginPosition() -> UnsafeMutablePointer<Float>!
}

/// The messages the controller sends to an id that is a view: -scaleToFit to
/// the destination of -scaleToFit:, -xFlipped and -yFlipped to the sender of
/// the flips. Not checked, as above.
@objc private protocol OrthogonalMPRControllerViewMessages: NSObjectProtocol {
    @objc(scaleToFit) func scaleToFit()
    @objc(xFlipped) var xFlipped: Bool { get }
    @objc(yFlipped) var yFlipped: Bool { get }
}

private func viewerMessages(_ viewer: AnyObject?) -> OrthogonalMPRControllerViewerMessages? {
    return unsafeBitCast(viewer, to: OrthogonalMPRControllerViewerMessages?.self)
}

private func viewMessages(_ object: Any?) -> OrthogonalMPRControllerViewMessages? {
    return unsafeBitCast(object as AnyObject?, to: OrthogonalMPRControllerViewMessages?.self)
}

/// [a isEqual: b], nil answering NO.
private func objIsEqual(_ a: Any?, _ b: Any?) -> Bool {
    guard let a = a as? NSObject else { return false }
    return a.isEqual(b)
}

/// [a isEqualTo: b], nil answering NO.
private func objIsEqualTo(_ a: Any?, _ b: Any?) -> Bool {
    guard let a = a as? NSObject else { return false }
    return a.isEqual(to: b)
}

/// [object floatValue] and [object longValue], messages to an id: an object
/// that does not answer raises, as before; nil answers 0.
private func floatValueOf(_ object: Any?) -> Float {
    return ((object as? NSObject)?.value(forKey: "floatValue") as? NSNumber)?.floatValue ?? 0
}

private func longValueOf(_ object: Any?) -> Int {
    return ((object as? NSObject)?.value(forKey: "longValue") as? NSNumber)?.intValue ?? 0
}

/// A float converted to long as the arm64 code of the former C did (fcvtzs):
/// toward zero, saturated, NaN to 0; a Swift conversion traps instead.
private func cLong(_ x: Double) -> Int {
    if x.isNaN { return 0 }
    if x >= 9223372036854775807.0 { return Int.max }
    if x <= -9223372036854775808.0 { return Int.min }
    return Int(x)
}

private func cLong(_ x: Float) -> Int {
    return cLong(Double(x))
}

/// A float converted to int, saturated in the same way.
private func cInt(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483647.0 { return Int32.max }
    if x <= -2147483648.0 { return Int32.min }
    return Int32(x)
}

/// -[DCMPix setTransferFunction:] sent with the NSData itself, which every
/// pixel of the three lists keeps; the Data Swift imports the property as
/// would be bridged again for each one.
private func sendSetTransferFunction(_ pix: AnyObject, _ transferFunction: NSData?) {
    typealias Send = @convention(c) (AnyObject, Selector, NSData?) -> Void
    let selector = NSSelectorFromString("setTransferFunction:")
    unsafeBitCast((pix as! NSObject).method(for: selector), to: Send.self)(pix, selector, transferFunction)
}

/// [dictionary setObject: object forKey: key], which raised with a nil key.
private func setObject(_ dictionary: NSMutableDictionary, _ object: Any, forKey key: String?) {
    guard let key else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSDictionaryM setObject:forKey:]: key cannot be nil", userInfo: nil).raise()
        return
    }
    dictionary.setObject(object, forKey: key as NSString)
}

/// [dictionary objectForKey: key], nil for a nil key.
private func object(_ dictionary: NSDictionary, forKey key: String?) -> Any? {
    guard let key else { return nil }
    return dictionary.object(forKey: key)
}

/// ToolsMenuIconSize, a macro of ViewerController.h that Swift does not import.
private let ToolsMenuIconSize = NSMakeSize(28.0, 28.0)

/// Controller for Orthogonal MPR: it keeps the pixels of the series, reslices
/// them along the cross of its three OrthogonalMPRViews and keeps their scale,
/// WL/WW, thick slab and ROIs together.
///
/// Implemented in Swift since #870: the Objective-C name, the selectors and
/// <Horos/OrthogonalMPRController.h> are those of the former class, the
/// controller object of OrthogonalMPR.xib, Endoscopy.xib and PETCT.xib. It is
/// not final: OrthogonalMPRPETCTController subclasses it, and its methods are
/// dynamic, sent through the Objective-C runtime as before.
@objc(OrthogonalMPRController)
public class OrthogonalMPRController: NSObject {
    // MARK: - The former instance variables

    /// Retained, as the former ivars.
    private var _originalDCMPixList: NSMutableArray? = nil
    private var _originalDCMFilesList: NSMutableArray? = nil
    private var _originalROIList: NSMutableArray? = nil
    private var _reslicer: OrthogonalReslice? = nil
    private var _transferFunction: NSData? = nil
    /// The reslicer's lists, which the former ivars kept without retaining them.
    private unowned(unsafe) var xReslicedDCMPixList: NSMutableArray? = nil
    private unowned(unsafe) var yReslicedDCMPixList: NSMutableArray? = nil
    private var _sign: Float = 0

    private var originalCrossPositionX: Float = 0
    private var originalCrossPositionY: Float = 0
    private var xReslicedCrossPositionX: Float = 0
    private var xReslicedCrossPositionY: Float = 0
    private var yReslicedCrossPositionX: Float = 0
    private var yReslicedCrossPositionY: Float = 0
    private var _orientationVector: Int = 0

    /// The outlets of the nib, kept without retaining them, as the former ivars:
    /// the nib set those without retaining them, and each view retains the
    /// controller through -setController:, which a retain back would make a
    /// cycle that keeps the controller, the views and the reslicer alive after
    /// the window closes. The nib sets them through the setters below.
    private unowned(unsafe) var _originalView: OrthogonalMPRView? = nil
    private unowned(unsafe) var _xReslicedView: OrthogonalMPRView? = nil
    private unowned(unsafe) var _yReslicedView: OrthogonalMPRView? = nil

    /// The viewer, an id kept without retaining it. Endoscopy.xib also sets it
    /// as an outlet, which the nib set without retaining it either.
    private unowned(unsafe) var _viewer: AnyObject? = nil
    private var originalViewFrame = NSZeroRect
    private var xReslicedViewFrame = NSZeroRect
    private var yReslicedViewFrame = NSZeroRect

    private var _thickSlabMode: Int16 = 0
    private var _thickSlab: Int16 = 0

    /// The ViewerController of the series, kept without retaining it.
    private unowned(unsafe) var viewerController: ViewerController? = nil

    @objc public dynamic var orientationVector: Int {
        get { return _orientationVector }
        set { _orientationVector = newValue }
    }

    // MARK: - The nib's outlets, set by key-value coding

    @objc(setOriginalView:)
    private dynamic func setOriginalViewOutlet(_ view: OrthogonalMPRView?) {
        _originalView = view
    }

    @objc(setXReslicedView:)
    private dynamic func setXReslicedViewOutlet(_ view: OrthogonalMPRView?) {
        _xReslicedView = view
    }

    @objc(setYReslicedView:)
    private dynamic func setYReslicedViewOutlet(_ view: OrthogonalMPRView?) {
        _yReslicedView = view
    }

    @objc(setViewer:)
    private dynamic func setViewerOutlet(_ viewer: AnyObject?) {
        _viewer = viewer
    }

    // MARK: -

    @objc(setCrossPosition:::)
    public dynamic func setCrossPosition(_ x: Float, _ y: Float, _ sender: Any!) {
        self.reslice(cLong(x), cLong(y), unsafeBitCast(sender as AnyObject?, to: OrthogonalMPRView?.self))
    }

    @objc(setBlendingFactor:)
    public dynamic func setBlendingFactor(_ f: Float) {
    }

    @objc(applyOrientation)
    private dynamic func applyOrientation() {
        switch _orientationVector {
        case Int(eSagittalPos), Int(eSagittalNeg):
            _xReslicedView?.xFlipped = true
            if (_xReslicedView?.rotation ?? 0) == 0 { _xReslicedView?.rotation = 90 }

            _yReslicedView?.xFlipped = true
            if (_yReslicedView?.rotation ?? 0) == 0 { _yReslicedView?.rotation = 90 }

        case Int(eCoronalPos), Int(eCoronalNeg):
            _xReslicedView?.yFlipped = true
            if (_yReslicedView?.rotation ?? 0) == 0 { _yReslicedView?.rotation = 90 }

        case Int(eAxialPos):
            break

        case Int(eAxialNeg):
            _xReslicedView?.yFlipped = true
            _yReslicedView?.yFlipped = true

        default:
            NSLog("Orientation Unknown: %d", Int32(truncatingIfNeeded: _orientationVector))
        }
    }

    @objc(setPixList:::)
    public dynamic func setPixList(_ pix: [Any]!, _ files: [Any]!, _ vC: ViewerController!) {
        if let originalDCMPixList = _originalDCMPixList {
            originalDCMPixList.removeAllObjects()
        } else {
            _originalDCMPixList = NSMutableArray(capacity: pix?.count ?? 0)
        }

        for p in pix ?? [] {
            _originalDCMPixList?.add((p as! NSObject).copy())
        }

        _originalDCMFilesList = NSMutableArray(array: files ?? [])

        if vC?.blending() == nil {
            _originalROIList = vC?.imageView()?.dcmRoiList
        } else {
            // The former code set the ivar to nil without releasing it.
            if let originalROIList = _originalROIList { _ = Unmanaged.passRetained(originalROIList) }
            _originalROIList = nil
        }

        _reslicer = OrthogonalReslice(originalDCMPixList: _originalDCMPixList)
    }

    /// The former initializer. The viewers send it again to the controller the
    /// nib made, once they have the pixels: it is a method, so that it keeps the
    /// outlets the nib set, which a Swift initializer would start over. It
    /// returns the controller, as -[NSObject init] did.
    @discardableResult
    @objc(initWithPixList::::::)
    public dynamic func initWithPixList(_ pix: [Any]!, _ files: [Any]!, _ vData: Data!, _ vC: ViewerController!, _ bC: ViewerController!, _ newViewer: Any!) -> Any! {
        // initialisations
        self.setPixList(pix, files, vC)

        // Set the views (OrthogonalMPRView)
        _originalView?.setController(self)
        _xReslicedView?.setController(self)
        _yReslicedView?.setController(self)

        _originalView?.currentTool = .tCross
        _xReslicedView?.currentTool = .tCross
        _yReslicedView?.currentTool = .tCross

        viewerController = vC

        _viewer = newViewer as AnyObject?
        let originalMenu = self.contextualMenu()
        _originalView?.menu = originalMenu
        let xMenu = self.contextualMenu()
        _xReslicedView?.menu = xMenu
        let yMenu = self.contextualMenu()
        _yReslicedView?.menu = yMenu

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(changeWLWW(_:)),
                                               name: NSNotification.Name.OsirixChangeWLWW,
                                               object: nil)

        _orientationVector = Int(vC?.orientationVector() ?? 0)
        self.applyOrientation()

        return self
    }

    deinit {
        NSLog("OrthogonalMPRController dealloc")

        NotificationCenter.default.removeObserver(self)
        // The lists, the transfer function and the reslicer are released with the object.
    }

    // MARK: - Orthogonal reslice methods

    @objc(reslice:::)
    public dynamic func reslice(_ x: Int, _ y: Int, _ sender: OrthogonalMPRView!) {
        let originalView = _originalView
        let xReslicedView = _xReslicedView
        let yReslicedView = _yReslicedView

        // A scale and an origin are only read back where a view with pixels set
        // them; the former locals started without a value.
        var originalScaleValue: Float = 0, xScaleValue: Float = 0, yScaleValue: Float = 0
        var originalRotation: Float, xRotation: Float, yRotation: Float

        originalRotation = 0
        xRotation = 0
        yRotation = 0

        var originalOrigin = NSZeroPoint, xOrigin = NSZeroPoint, yOrigin = NSZeroPoint

        var originalOldValues = false, xOldValues = false, yOldValues = false

        if originalView?.dcmPixList != nil {
            originalScaleValue = originalView?.scaleValue ?? 0
            originalRotation = originalView?.rotation ?? 0
            originalOrigin = originalView?.origin ?? NSZeroPoint
            originalOldValues = true
        }

        if xReslicedView?.dcmPixList != nil {
            xScaleValue = xReslicedView?.scaleValue ?? 0
            xRotation = xReslicedView?.rotation ?? 0
            xOrigin = xReslicedView?.origin ?? NSZeroPoint
            xOldValues = true
        }

        if yReslicedView?.dcmPixList != nil {
            yScaleValue = yReslicedView?.scaleValue ?? 0
            yRotation = yReslicedView?.rotation ?? 0
            yOrigin = yReslicedView?.origin ?? NSZeroPoint
            yOldValues = true
        }

        if objIsEqual(sender, originalView) {
            // orthogonal reslice on both axes
            _reslicer?.reslice(x, y)

            xReslicedDCMPixList = _reslicer?.xReslicedDCMPixList
            yReslicedDCMPixList = _reslicer?.yReslicedDCMPixList

            xReslicedView?.setPixList(xReslicedDCMPixList, _originalDCMFilesList)
            yReslicedView?.setPixList(yReslicedDCMPixList, _originalDCMFilesList)

//            // WLWW
            var wl: Float = 0, ww: Float = 0
            originalView?.getWLWW(&wl, &ww)

            if wl != 0 && ww != 0 {
                xReslicedView?.adjustWLWW(wl, ww)
                yReslicedView?.adjustWLWW(wl, ww)
            }

            // move cross on the other views
            xReslicedView?.setCrossPositionX(Float(Double(x) + 0.5))
            yReslicedView?.setCrossPositionX(Float(Double(y) + 0.5))
            // indexOfObject: is an NSUInteger, NSNotFound when the image is not
            // in the list: the sum wraps as it did.
            let curDCM = originalView?.curDCM
            let sliceIndex: Int = (originalView?.pixList()?.index(of: curDCM as Any) ?? 0) &+ Int(curDCM?.stack ?? 0) / 2
            let h: Int = (_sign > 0) ? (originalView?.dcmPixList?.count ?? 0) &- sliceIndex &- 1 : sliceIndex

            xReslicedView?.setCrossPositionY(Float(Double(h) + 0.5))
            yReslicedView?.setCrossPositionY(Float(Double(h) + 0.5))
        } else {
            let stackCount = Int32(truncatingIfNeeded: originalView?.dcmPixList?.count ?? 0)

//            stackCount /= 2;
//            stackCount *= 2;

            // slice index on axial view
            var sliceIndex: Int32 = (_sign > 0) ? Int32(truncatingIfNeeded: Int(stackCount) &- 1 &- y) : Int32(truncatingIfNeeded: y)

            sliceIndex = sliceIndex &- Int32(_thickSlab / 2)

            if sliceIndex < 0 { sliceIndex = 0 }
            if sliceIndex >= stackCount { sliceIndex = stackCount &- 1 }
            // update axial view
            originalView?.setIndex(Int16(truncatingIfNeeded: sliceIndex))

            if objIsEqual(sender, xReslicedView) {
                originalView?.setCrossPositionX(Float(Double(x) + 0.5))
                // compute 3rd view
                _reslicer?.yReslice(x)
                yReslicedDCMPixList = _reslicer?.yReslicedDCMPixList

                yReslicedView?.setCurRoiList(self.pointsROI(atX: x))

                yReslicedView?.setPixList(yReslicedDCMPixList, _originalDCMFilesList)

                // WLWW; the former locals started without a value, which only
                // a view without an image left as it was.
                var wl: Float = 0, ww: Float = 0
                xReslicedView?.getWLWW(&wl, &ww)
                originalView?.adjustWLWW(wl, ww)
                yReslicedView?.adjustWLWW(wl, ww)

                // move cross on 3rd view
                yReslicedView?.setCrossPositionY(Float(Double(y) + 0.5))
            } else if objIsEqual(sender, yReslicedView) {
                originalView?.setCrossPositionY(Float(Double(x) + 0.5))
                // compute 3rd view
                _reslicer?.xReslice(x)
                xReslicedDCMPixList = _reslicer?.xReslicedDCMPixList

                xReslicedView?.setCurRoiList(self.pointsROI(atY: y))

                xReslicedView?.setPixList(xReslicedDCMPixList, _originalDCMFilesList)

                // WLWW, as above.
                var wl: Float = 0, ww: Float = 0
                yReslicedView?.getWLWW(&wl, &ww)
                originalView?.adjustWLWW(wl, ww)
                xReslicedView?.adjustWLWW(wl, ww)

                // move cross on 3rd view
                xReslicedView?.setCrossPositionY(Float(Double(y) + 0.5))
            }
        }

        if originalOldValues {
            // scale
            originalView?.scaleValue = originalScaleValue
//            NSLog(@"originalScaleValue : %f", originalScaleValue);
            // rotation
            originalView?.rotation = originalRotation
            // origin
            originalView?.origin = originalOrigin
        }

        if xOldValues {
            // scale
            xReslicedView?.scaleValue = xScaleValue
            // rotation
            xReslicedView?.rotation = xRotation
            // origin
            xReslicedView?.origin = xOrigin
        }

        if yOldValues {
            // scale
            yReslicedView?.scaleValue = yScaleValue
            // rotation
            yReslicedView?.rotation = yRotation
            // origin
            yReslicedView?.origin = yOrigin
        }

        self.loadROIonReslicedViews(cLong(originalView?.crossPositionX() ?? 0), cLong(originalView?.crossPositionY() ?? 0))

        self.applyOrientation()

        var i = 0

        i = 0
        while i < (yReslicedDCMPixList?.count ?? 0) {
            sendSetTransferFunction(yReslicedDCMPixList!.object(at: i) as AnyObject, _transferFunction)
            i += 1
        }

        i = 0
        while i < (_originalDCMPixList?.count ?? 0) {
            sendSetTransferFunction(_originalDCMPixList!.object(at: i) as AnyObject, _transferFunction)
            i += 1
        }

        i = 0
        while i < (xReslicedDCMPixList?.count ?? 0) {
            sendSetTransferFunction(xReslicedDCMPixList!.object(at: i) as AnyObject, _transferFunction)
            i += 1
        }

        originalView?.updateImage()
        xReslicedView?.updateImage()
        yReslicedView?.updateImage()

        // needs display
        originalView?.needsDisplay = true
        xReslicedView?.needsDisplay = true
        yReslicedView?.needsDisplay = true
    }

    /// Typed Data, as Swift saw the former NSData parameter; the controller
    /// keeps it as an NSData, the one object every pixel receives.
    @objc(setTransferFunction:)
    public dynamic func setTransferFunction(_ tf: Data!) {
        _transferFunction = tf as NSData?
    }

    @objc(flipVolume)
    public dynamic func flipVolume() {
        NSLog("flipVolume")

        _sign = -_sign
        _reslicer?.flipVolume()
        self.reslice(cLong(_originalView?.crossPositionX() ?? 0), cLong(_originalView?.crossPositionY() ?? 0), _originalView)
        _xReslicedView?.needsDisplay = true
        _yReslicedView?.needsDisplay = true
    }

    // MARK: - DCMView methods

    @objc(blendingPropagateOriginal:)
    public dynamic func blendingPropagateOriginal(_ sender: OrthogonalMPRView!) {
        let originalView = _originalView
        let fValue: Double = Double(sender?.scaleValue ?? 0) / (sender?.pixelSpacing ?? 0)
        originalView?.scaleValue = Float(fValue * (originalView?.pixelSpacing ?? 0))
        originalView?.rotation = sender?.rotation ?? 0

        let pan = sender?.origin ?? NSZeroPoint
        var delta = DCMPix.originDeltaBetween(originalView?.curDCM, and: sender?.curDCM)
        delta.x *= CGFloat(sender?.scaleValue ?? 0)
        delta.y *= CGFloat(sender?.scaleValue ?? 0)
        originalView?.origin = NSMakePoint(pan.x + delta.x, pan.y - delta.y)

        var pt = NSZeroPoint

        // X - Views
        pt.y = _xReslicedView?.origin.y ?? 0
        pt.x = (sender?.origin.x ?? 0) + delta.x
        _xReslicedView?.origin = pt

        // Y - Views
        pt.y = _yReslicedView?.origin.y ?? 0
        pt.x = -(sender?.origin.y ?? 0) + delta.y
        _yReslicedView?.origin = pt
    }

    @objc(blendingPropagateX:)
    public dynamic func blendingPropagateX(_ sender: OrthogonalMPRView!) {
        let xReslicedView = _xReslicedView
        let fValue: Double = Double(sender?.scaleValue ?? 0) / (sender?.pixelSpacing ?? 0)
        xReslicedView?.scaleValue = Float(fValue * (xReslicedView?.pixelSpacing ?? 0))
        xReslicedView?.rotation = sender?.rotation ?? 0

        let pan = sender?.origin ?? NSZeroPoint
        var delta = DCMPix.originDeltaBetween(xReslicedView?.curDCM, and: sender?.curDCM)
        delta.x *= CGFloat(sender?.scaleValue ?? 0)
        delta.y *= CGFloat(sender?.scaleValue ?? 0)
        delta.y = 0
        xReslicedView?.origin = NSMakePoint(pan.x + delta.x, pan.y - delta.y)

        var pt = NSZeroPoint

        // X - Views
        pt.y = _originalView?.origin.y ?? 0
        pt.x = (sender?.origin.x ?? 0) + delta.x
        _originalView?.origin = pt

        // Y - Views
        pt.x = _yReslicedView?.origin.x ?? 0
        pt.y = (sender?.origin.y ?? 0) + delta.y
        _yReslicedView?.origin = pt
    }

    @objc(blendingPropagateY:)
    public dynamic func blendingPropagateY(_ sender: OrthogonalMPRView!) {
        let yReslicedView = _yReslicedView
        let fValue: Double = Double(sender?.scaleValue ?? 0) / (sender?.pixelSpacing ?? 0)
        yReslicedView?.scaleValue = Float(fValue * (yReslicedView?.pixelSpacing ?? 0))
        yReslicedView?.rotation = sender?.rotation ?? 0

        let pan = sender?.origin ?? NSZeroPoint
        var delta = DCMPix.originDeltaBetween(yReslicedView?.curDCM, and: sender?.curDCM)
        delta.x *= CGFloat(sender?.scaleValue ?? 0)
        delta.y *= CGFloat(sender?.scaleValue ?? 0)
        delta.y = 0
        yReslicedView?.origin = NSMakePoint(pan.x + delta.x, pan.y - delta.y)

        var pt = NSZeroPoint

        // X - Views
        pt.x = _originalView?.origin.x ?? 0
        pt.y = -((sender?.origin.x ?? 0) + delta.x)
        _originalView?.origin = pt

        // Y - Views
        pt.x = _xReslicedView?.origin.x ?? 0
        pt.y = (sender?.origin.y ?? 0) + delta.y
        _xReslicedView?.origin = pt
    }

    @objc(blendingPropagate:)
    public dynamic func blendingPropagate(_ sender: OrthogonalMPRView!) {
        if objIsEqual(sender, _originalView) {
            viewerMessages(_viewer)?.blendingPropagateOriginal(sender)
            _originalView?.needsDisplay = true
        } else if objIsEqual(sender, _xReslicedView) {
            viewerMessages(_viewer)?.blendingPropagateX(sender)
            _xReslicedView?.needsDisplay = true
        } else if objIsEqual(sender, _yReslicedView) {
            viewerMessages(_viewer)?.blendingPropagateY(sender)
            _yReslicedView?.needsDisplay = true
        }
    }

    @objc(ApplyOpacityString:)
    public dynamic func applyOpacityString(_ str: String!) {
        var aOpacity: NSDictionary?

        if str == NSLocalizedString("Linear Table", comment: "") {
            self.setTransferFunction(nil)
        } else {
            aOpacity = (UserDefaults.standard.dictionary(forKey: "OPACITY") as NSDictionary?).flatMap { object($0, forKey: str) } as? NSDictionary
            if let aOpacity {
//                array = [aOpacity objectForKey:@"Points"];

                self.setTransferFunction(OpacityTransferView.tableWith4096Entries(aOpacity.object(forKey: "Points") as? NSArray) as Data?)
            }
        }
    }

    @objc(ApplyCLUTString:)
    public dynamic func applyCLUTString(_ str: String!) {
        if str == NSLocalizedString("No CLUT", comment: "") {
            _originalView?.setCLUT(nil, nil, nil)
            _xReslicedView?.setCLUT(nil, nil, nil)
            _yReslicedView?.setCLUT(nil, nil, nil)
        } else {
            var aCLUT: NSDictionary?
            var array: NSArray?
            var i = 0
            var red = [UInt8](repeating: 0, count: 256), green = [UInt8](repeating: 0, count: 256), blue = [UInt8](repeating: 0, count: 256)

            aCLUT = (UserDefaults.standard.dictionary(forKey: "CLUT") as NSDictionary?).flatMap { object($0, forKey: str) } as? NSDictionary
            if let aCLUT {
                array = aCLUT.object(forKey: "Red") as? NSArray
                i = 0
                while i < 256 {
                    red[i] = UInt8(truncatingIfNeeded: longValueOf(array?.object(at: i)))
                    i += 1
                }

                array = aCLUT.object(forKey: "Green") as? NSArray
                i = 0
                while i < 256 {
                    green[i] = UInt8(truncatingIfNeeded: longValueOf(array?.object(at: i)))
                    i += 1
                }

                array = aCLUT.object(forKey: "Blue") as? NSArray
                i = 0
                while i < 256 {
                    blue[i] = UInt8(truncatingIfNeeded: longValueOf(array?.object(at: i)))
                    i += 1
                }

                _originalView?.setCLUT(&red, &green, &blue)
                _xReslicedView?.setCLUT(&red, &green, &blue)
                _yReslicedView?.setCLUT(&red, &green, &blue)

                _originalView?.needsDisplay = true
                _xReslicedView?.needsDisplay = true
                _yReslicedView?.needsDisplay = true
            }
        }
    }

    @objc(changeWLWW:)
    private dynamic func changeWLWW(_ note: Notification) {
        let otherPix = note.object as? DCMPix

        if let otherPix, _originalDCMPixList?.contains(otherPix) == true {
            var iwl: Float, iww: Float

            iww = otherPix.ww
            iwl = otherPix.wl

            if iww != (_originalView?.curDCM?.ww ?? 0) || iwl != (_originalView?.curDCM?.wl ?? 0) {
                self.setWLWW(iwl, iww)
            }
        }
    }

    @objc(setWLWW::)
    public dynamic func setWLWW(_ iwl: Float, _ iww: Float) {
        viewerController?.setWL(iwl, ww: iww)

        _originalView?.adjustWLWW(iwl, iww)
        _xReslicedView?.adjustWLWW(iwl, iww)
        _yReslicedView?.adjustWLWW(iwl, iww)
        self.setCurWLWWMenu(NSLocalizedString("Other", comment: ""))

        NotificationCenter.default.post(name: NSNotification.Name.OsirixChangeWLWW, object: _originalView?.curDCM, userInfo: nil)
    }

    @objc(setCurWLWWMenu:)
    public dynamic func setCurWLWWMenu(_ str: String!) {
        _originalView?.setCurWLWWMenu(str)
        _xReslicedView?.setCurWLWWMenu(str)
        _yReslicedView?.setCurWLWWMenu(str)
    }

    @objc(setScaleValue:)
    public dynamic func setScaleValue(_ x: Float) {
        _originalView?.adjustScaleValue(x)

        if (_xReslicedView?.pixelSpacingX ?? 0) != 0 && (_originalView?.pixelSpacingX ?? 0) != 0 {
            let scaleValue = _originalView?.scaleValue ?? 0

            _xReslicedView?.adjustScaleValue(Float(Double(scaleValue) * (_xReslicedView?.pixelSpacingX ?? 0) / (_originalView?.pixelSpacingX ?? 0)))
            _yReslicedView?.adjustScaleValue(Float(Double(scaleValue) * (_yReslicedView?.pixelSpacingX ?? 0) / (_originalView?.pixelSpacingX ?? 0)))
        } else {
            _xReslicedView?.adjustScaleValue(x)
            _yReslicedView?.adjustScaleValue(x)
        }
    }

    @objc(resetImage)
    public dynamic func resetImage() {
        let originalView = _originalView
        originalView?.origin = NSMakePoint(0, 0)
        originalView?.scaleToFit()
        originalView?.setWLWW(originalView?.curDCM?.savedWL ?? 0, originalView?.curDCM?.savedWW ?? 0)
        originalView?.rotation = 0
        originalView?.xFlipped = false
        originalView?.yFlipped = false

        _xReslicedView?.origin = NSMakePoint(0, 0)
        _xReslicedView?.scaleToFit()
        _xReslicedView?.setWLWW(originalView?.curDCM?.savedWL ?? 0, originalView?.curDCM?.savedWW ?? 0)
//        [xReslicedView setRotation: 0];
//        [xReslicedView setXFlipped:NO];
//        [xReslicedView setYFlipped:NO];

        _yReslicedView?.origin = NSMakePoint(0, 0)
        _yReslicedView?.scaleToFit()
        _yReslicedView?.setWLWW(originalView?.curDCM?.savedWL ?? 0, originalView?.curDCM?.savedWW ?? 0)
//        [yReslicedView setRotation: 0];
//        [yReslicedView setXFlipped:NO];
//        [yReslicedView setYFlipped:NO];

        self.applyOrientation()
    }

    @objc(scrollTool:::)
    public dynamic func scrollTool(_ from: Int, _ to: Int, _ sender: Any!) {
        var x: Int, y: Int, max: Int
        if objIsEqual(sender, _originalView) {
            max = _xReslicedView?.curDCM?.pheight ?? 0
            x = cLong(_xReslicedView?.crossPositionX() ?? 0)
            y = cLong(xReslicedCrossPositionY + Float(from &- to))
            if y < 0 { y = 0 }
            if y >= max { y = max &- 1 }
            _xReslicedView?.setCrossPosition(Float(Double(x) + 0.5), Float(Double(y) + 0.5))
        } else if objIsEqual(sender, _xReslicedView) {
            max = _originalView?.curDCM?.pheight ?? 0
            x = cLong(_originalView?.crossPositionX() ?? 0)
            y = cLong(originalCrossPositionY + Float(from &- to))
            if y < 0 { y = 0 }
            if y >= max { y = max &- 1 }
            _originalView?.setCrossPosition(Float(Double(x) + 0.5), Float(Double(y) + 0.5))
        } else if objIsEqual(sender, _yReslicedView) {
            max = _originalView?.curDCM?.pwidth ?? 0
            x = cLong(originalCrossPositionX + Float(from &- to))
            y = cLong(_originalView?.crossPositionY() ?? 0)
            if x < 0 { x = 0 }
            if x >= max { x = max &- 1 }
            _originalView?.setCrossPosition(Float(Double(x) + 0.5), Float(Double(y) + 0.5))
        }
    }

    @objc(saveCrossPositions)
    public dynamic func saveCrossPositions() {
        originalCrossPositionX = _originalView?.crossPositionX() ?? 0
        originalCrossPositionY = _originalView?.crossPositionY() ?? 0
        xReslicedCrossPositionX = _xReslicedView?.crossPositionX() ?? 0
        xReslicedCrossPositionY = _xReslicedView?.crossPositionY() ?? 0
        yReslicedCrossPositionX = _yReslicedView?.crossPositionX() ?? 0
        yReslicedCrossPositionY = _yReslicedView?.crossPositionY() ?? 0
    }

    @objc(restoreCrossPositions)
    public dynamic func restoreCrossPositions() {
        _originalView?.setCrossPosition(originalCrossPositionX, originalCrossPositionY)
        _xReslicedView?.setCrossPosition(xReslicedCrossPositionX, xReslicedCrossPositionY)
        _yReslicedView?.setCrossPosition(yReslicedCrossPositionX, yReslicedCrossPositionY)
    }

    // MARK: -

    @objc(notifyPositionChange)
    public dynamic func notifyPositionChange() {
        // Patient crosshair uses one absolute point and the shared frame guard.
        // Preserve the older relative MPR synchronization for the other tools.
        if self.currentTool() == Int32(ToolMode.tCross.rawValue), let mprViewer = _viewer as? OrthogonalMPRViewer,
           mprViewer.publishPatientCrosshair() { return }
        let originPos = viewerMessages(_viewer)?.syncOriginPosition()

        if let originPos {
            // The former array started without a value, which a viewer that
            // does not write it left as it was.
            var currentLocation: [Float] = [0, 0, 0]
            OrthogonalMPRViewer.getDICOMCoords(_viewer, &currentLocation)

            let newPosition = NSMutableArray(capacity: 3)

            for i in 0..<3 {
                newPosition.add(NSNumber(value: currentLocation[i] - originPos[i]))
            }

            OrthogonalMPRViewer.positionChange(_viewer, newPosition as? [Any])
        }
    }

    @objc(moveToRelativePosition:)
    public dynamic func move(toRelativePosition relativeDicomLocation: [Any]!) {
        let originPos = viewerMessages(_viewer)?.syncOriginPosition()

        let newLocation = NSMutableArray(capacity: 3)

        (relativeDicomLocation as NSArray?)?.enumerateObjects { obj, idx, _ in
            newLocation.insert(NSNumber(value: floatValueOf(obj) + originPos![idx]), at: idx)
        }

        self.move(toAbsolutePosition: newLocation as? [Any])
    }

    @objc(moveToAbsolutePosition:)
    public dynamic func move(toAbsolutePosition newDicomLocation: [Any]!) {
        // The former arrays started without a value, which a view without an
        // image left as it was.
        var dcmCoord: [Float] = [0, 0, 0]
        var sliceCoord: [Float] = [0, 0, 0]
        let location = newDicomLocation as NSArray?

        for i in 0..<3 {
            dcmCoord[i] = floatValueOf(location?.object(at: i))
        }

        let originalPix = _originalView?.curDCM
        originalPix?.convertDICOMCoords(&dcmCoord, toSliceCoords: &sliceCoord, pixelCenter: true)
        sliceCoord[0] = Float(Double(sliceCoord[0]) / (originalPix?.pixelSpacingX ?? 0))
        sliceCoord[1] = Float(Double(sliceCoord[1]) / (originalPix?.pixelSpacingY ?? 0))
        sliceCoord[2] = Float(Double(sliceCoord[2]) / (originalPix?.sliceInterval ?? 0))
        //    NSLog(@"moveToAbsolutePosition - sliceCoord : %f %f index : %f", sliceCoord[0], sliceCoord[1], sliceCoord[2]);

        _originalView?.setCrossPosition(sliceCoord[0], sliceCoord[1], withNotification: false)

        let xPix = _xReslicedView?.curDCM
        xPix?.convertDICOMCoords(&dcmCoord, toSliceCoords: &sliceCoord, pixelCenter: true)
        sliceCoord[0] = Float(Double(sliceCoord[0]) / (xPix?.pixelSpacingX ?? 0))
        sliceCoord[1] = Float(Double(sliceCoord[1]) / (xPix?.pixelSpacingY ?? 0))
        sliceCoord[2] = Float(Double(sliceCoord[2]) / (xPix?.sliceInterval ?? 0))
        //    NSLog(@"moveToAbsolutePosition - sliceCoord : %f %f index : %f", sliceCoord[0], sliceCoord[1], sliceCoord[2]);

        _xReslicedView?.setCrossPosition(sliceCoord[0], sliceCoord[1], withNotification: false)
    }

    // MARK: -

    @objc(toggleDisplayResliceAxes:)
    public dynamic func toggleDisplayResliceAxes(_ sender: Any!) {
        if objIsEqualTo(sender, _viewer) {
            _originalView?.toggleDisplayResliceAxes()
            _xReslicedView?.toggleDisplayResliceAxes()
            _yReslicedView?.toggleDisplayResliceAxes()
        } else {
            viewerMessages(_viewer)?.toggleDisplayResliceAxes()
        }
    }

    @objc(displayResliceAxes:)
    public dynamic func displayResliceAxes(_ boo: Int) {
        _originalView?.displayResliceAxes(boo)
        _xReslicedView?.displayResliceAxes(boo)
        _yReslicedView?.displayResliceAxes(boo)
    }

    @objc(doubleClick::)
    public dynamic func doubleClick(_ event: NSEvent!, _ sender: Any!) {
        self.fullWindowView(sender)
    }

    @objc(fullWindowView:)
    public dynamic func fullWindowView(_ sender: Any!) {
        let mprViewer = viewerMessages(_viewer)

        if objIsEqual(sender, _originalView) {
            mprViewer?.fullWindowView(0)
        } else if objIsEqual(sender, _xReslicedView) {
            mprViewer?.fullWindowView(1)
        } else if objIsEqual(sender, _yReslicedView) {
            mprViewer?.fullWindowView(2)
        }
    }

    @objc(saveViewsFrame)
    public dynamic func saveViewsFrame() {
        originalViewFrame = _originalView?.frame ?? NSZeroRect
        xReslicedViewFrame = _xReslicedView?.frame ?? NSZeroRect
        yReslicedViewFrame = _yReslicedView?.frame ?? NSZeroRect
    }

    @objc(restoreViewsFrame)
    public dynamic func restoreViewsFrame() {
        _originalView?.frame = originalViewFrame
        _xReslicedView?.frame = xReslicedViewFrame
        _yReslicedView?.frame = yReslicedViewFrame
    }

    @objc(scaleToFit)
    public dynamic func scaleToFit() {
        _originalView?.scaleToFit()
    }

    @objc(scaleToFit:)
    public dynamic func scaleToFit(_ destination: Any!) {
        viewMessages(destination)?.scaleToFit()
    }

    @objc(saveScaleValue)
    public dynamic func saveScaleValue() {
        _originalView?.saveScaleValue()
        _xReslicedView?.saveScaleValue()
        _yReslicedView?.saveScaleValue()
    }

    @objc(restoreScaleValue)
    public dynamic func restoreScaleValue() {
        _originalView?.restoreScaleValue()
        _xReslicedView?.restoreScaleValue()
        _yReslicedView?.restoreScaleValue()
    }

    @objc(refreshViews)
    public dynamic func refreshViews() {
        self.saveCrossPositions()
        self.reslice(cLong(originalCrossPositionX), cLong(originalCrossPositionY), _originalView)
    }

    // MARK: - Thick Slab

    @objc(thickSlabMode)
    public dynamic func thickSlabMode() -> Int16 {
        return _thickSlabMode
    }

    @objc(setThickSlabMode:)
    public dynamic func setThickSlabMode(_ newThickSlabMode: Int16) {
        if _thickSlabMode == newThickSlabMode {
            return
        }
        _thickSlabMode = newThickSlabMode
        self.setFusion()
    }

    @objc(thickSlab)
    public dynamic func thickSlab() -> Int16 {
        return _thickSlab
    }

    @objc(maxThickSlab)
    public dynamic func maxThickSlab() -> Int {
        return _originalDCMPixList?.count ?? 0
    }

    @objc(thickSlabDistance)
    public dynamic func thickSlabDistance() -> Float {
        return Float(fabs((_originalDCMPixList?.object(at: 0) as? DCMPix)?.sliceInterval ?? 0))
    }

    @objc(setThickSlab:)
    public dynamic func setThickSlab(_ newThickSlab: Int16) {
        _thickSlab = newThickSlab
        _reslicer?.thickSlab = newThickSlab
        self.setFusion()
    }

    @objc(setFusion)
    public dynamic func setFusion() {
        var originalThickSlab: Int, xReslicedThickSlab: Int, yReslicedThickSlab: Int
        originalThickSlab = Int(_thickSlab)

        let curDCM = _originalView?.curDCM
        xReslicedThickSlab = cLong(Double(Float(_thickSlab) * self.thickSlabDistance()) / (curDCM?.pixelSpacingY ?? 0))
        yReslicedThickSlab = cLong(Double(Float(_thickSlab) * self.thickSlabDistance()) / (curDCM?.pixelSpacingX ?? 0))

        _originalView?.setFusion(_thickSlabMode, Int16(truncatingIfNeeded: originalThickSlab))
        _originalView?.setThickSlabXY(xReslicedThickSlab, cLong(Double(yReslicedThickSlab) / (_originalView?.curDCM?.pixelRatio ?? 0)))

        _reslicer?.thickSlab = Int16(truncatingIfNeeded: xReslicedThickSlab)

        _xReslicedView?.setFusion(_thickSlabMode, Int16(truncatingIfNeeded: xReslicedThickSlab))
        _xReslicedView?.setThickSlabXY(yReslicedThickSlab, Int(_thickSlab))

        _yReslicedView?.setFusion(_thickSlabMode, Int16(truncatingIfNeeded: yReslicedThickSlab))
        _yReslicedView?.setThickSlabXY(xReslicedThickSlab, Int(_thickSlab))

        self.saveCrossPositions()
        self.reslice(cLong(originalCrossPositionX), cLong(originalCrossPositionY), _originalView)

        UserDefaults.standard.set(Int(_thickSlab), forKey: "stackThicknessOrthoMPR")
    }

    // MARK: - NSWindow related methods

    @objc(showViews:)
    public dynamic func showViews(_ sender: Any!) {
        // Set the 1st view
        _originalView?.setPixList(_originalDCMPixList, _originalDCMFilesList, _originalROIList)
        _originalView?.setIndexWithReset(Int16(truncatingIfNeeded: (_originalDCMPixList?.count ?? 0) / 2), true)

        let pix = _originalView?.pixList()?.object(at: 0) as? DCMPix

        _sign = ((pix?.sliceInterval ?? 0) >= 0) ? 1.0 : -1.0

        // orthogonal reslice
        var x: Int, y: Int // coordinate of the reslice
        let firstDCMPix = _originalDCMPixList?.object(at: 0) as? DCMPix
        x = (firstDCMPix?.pwidth ?? 0) / 2
        y = (firstDCMPix?.pheight ?? 0) / 2

        _originalView?.setCrossPositionX(Float(Double(x) + 0.5))
        _originalView?.setCrossPositionY(Float(Double(y) + 0.5))
        self.reslice(x, y, _originalView)
    }

    // MARK: - accessors

    @objc(reslicer)
    public dynamic func reslicer() -> OrthogonalReslice! {
        return _reslicer
    }

    @objc(setReslicer:)
    public dynamic func setReslicer(_ newReslicer: OrthogonalReslice!) {
        _reslicer = newReslicer
    }

    @objc(originalDCMPixList)
    public dynamic func originalDCMPixList() -> NSMutableArray! {
        return _originalDCMPixList
    }

    @objc(firtsDCMPixInOriginalDCMPixList)
    public dynamic func firtsDCMPixInOriginalDCMPixList() -> DCMPix! {
        return _originalDCMPixList?.object(at: 0) as? DCMPix
    }

    @objc(originalDCMFilesList)
    public dynamic func originalDCMFilesList() -> NSMutableArray! {
        return _originalDCMFilesList
    }

    @objc(originalView)
    public dynamic func originalView() -> OrthogonalMPRView! {
        return _originalView
    }

    @objc(xReslicedView)
    public dynamic func xReslicedView() -> OrthogonalMPRView! {
        return _xReslicedView
    }

    @objc(yReslicedView)
    public dynamic func yReslicedView() -> OrthogonalMPRView! {
        return _yReslicedView
    }

    @objc(viewer)
    public dynamic func viewer() -> Any! {
        return _viewer
    }

    @objc(sign)
    public dynamic func sign() -> Float {
        return _sign
    }

    // MARK: - Tools Selection

    @objc(setCurrentTool:)
    public dynamic func setCurrentTool(_ newTool: ToolMode) {
        _originalView?.currentTool = newTool
        _xReslicedView?.currentTool = newTool
        _yReslicedView?.currentTool = newTool
    }

    @objc(currentTool)
    public dynamic func currentTool() -> Int32 {
        return Int32(_originalView?.currentTool.rawValue ?? 0)
    }

    // MARK: - ROIs

    @objc(pointsROIAtX:)
    public dynamic func pointsROI(atX x: Int) -> NSMutableArray! {
        let plainDict = NSMutableDictionary()
        let rois = _originalView?.dcmRoiList
        let roisAtX = NSMutableArray()

        let lastPix = _yReslicedView?.pixList()?.lastObject as? DCMPix
        let imageWidth = Int32(truncatingIfNeeded: lastPix?.pwidth ?? 0)
        let imageHeight = Int32(truncatingIfNeeded: lastPix?.pheight ?? 0)
        if imageWidth <= 0 || imageHeight <= 0 ||
            UInt(imageWidth) > UInt.max / UInt(imageHeight) { return roisAtX }

        var i = 0, j = 0
        i = 0
        while i < (rois?.count ?? 0) {
            j = 0
            while j < ((rois!.object(at: i) as? NSArray)?.count ?? 0) {
                let aROI = (rois!.object(at: i) as! NSArray).object(at: j) as! ROI
                if aROI.type == .t2DPoint {
                    if cLong((aROI.points.object(at: 0) as! MyPoint).x) == x {
                        let yView = _yReslicedView
                        let new2DPointROI: ROI = ROI(type: .t2DPoint, Float(yView?.pixelSpacingX ?? 0), Float(yView?.pixelSpacingY ?? 0), NSMakePoint(yView?.origin.x ?? 0, yView?.origin.y ?? 0))
                        var irect = NSZeroRect
                        irect.origin.x = CGFloat((aROI.points.object(at: 0) as! MyPoint).y)
                        let sliceIndex: Int = (_sign > 0) ? (_originalView?.dcmPixList?.count ?? 0) &- 1 &- i : i // i is slice number
                        irect.origin.y = CGFloat(sliceIndex) // i is slice number
                        irect.size.width = 0
                        irect.size.height = 0
                        new2DPointROI.rect = irect
                        new2DPointROI.parent = aROI
                        // copy the name
                        new2DPointROI.name = aROI.name
                        // add the 2D Point ROI to the ROI list
                        roisAtX.add(new2DPointROI)
                    }
                }

                if aROI.type == .tPlain {
                    if aROI.textureBuffer != nil && aROI.textureWidth > 0 && aROI.textureHeight > 0 &&
                        x >= Int(aROI.textureUpLeftCornerX) &&
                        UInt(bitPattern: x) &- UInt(bitPattern: Int(aROI.textureUpLeftCornerX)) < UInt(bitPattern: Int(aROI.textureWidth)) {
                        if object(plainDict, forKey: aROI.name) == nil {
                            let t = calloc(Int(imageWidth) * Int(imageHeight), MemoryLayout<UInt8>.size)

                            if let t {
                                let yView = _yReslicedView
                                let newROI: ROI = ROI(type: .tPlain, Float(yView?.pixelSpacingX ?? 0), Float(yView?.pixelSpacingY ?? 0), NSMakePoint(yView?.origin.x ?? 0, yView?.origin.y ?? 0))

                                newROI.name = aROI.name
                                newROI.thickness = aROI.thickness
                                newROI.rgbcolor = aROI.rgbcolor
                                newROI.opacity = aROI.opacity

                                newROI.setTexture(t.assumingMemoryBound(to: UInt8.self), width: imageWidth, height: imageHeight)
                                setObject(plainDict, newROI, forKey: aROI.name)
                            } else {
                                NSLog("***** not enough memory : pointsROIAtX - OrthogonalMPRController")
                            }
                        }

                        let p = object(plainDict, forKey: aROI.name) as? ROI

                        if let p {
                            let sliceIndex: Int = _sign > 0 ? (_originalView?.dcmPixList?.count ?? 0) &- 1 &- i : i
                            HorosCopyMPRBrushLine(p.textureBuffer, imageWidth, imageHeight, sliceIndex,
                                                  aROI.textureBuffer, aROI.textureWidth, aROI.textureHeight,
                                                  aROI.textureUpLeftCornerX, aROI.textureUpLeftCornerY, x, true)
                        }
                    }
                }
                j += 1
            }
            i += 1
        }

        let keys = plainDict.keyEnumerator()
        while let key = keys.nextObject() {
            let r = plainDict.object(forKey: key) as? ROI

            r?.reduceTextureIfPossible()

            roisAtX.add(r as Any)
        }

        return roisAtX
    }

    @objc(pointsROIAtY:)
    public dynamic func pointsROI(atY y: Int) -> NSMutableArray! {
        let plainDict = NSMutableDictionary()
        let rois = _originalView?.dcmRoiList
        let roisAtY = NSMutableArray()

        let lastPix = _xReslicedView?.pixList()?.lastObject as? DCMPix
        let imageWidth = Int32(truncatingIfNeeded: lastPix?.pwidth ?? 0)
        let imageHeight = Int32(truncatingIfNeeded: lastPix?.pheight ?? 0)
        if imageWidth <= 0 || imageHeight <= 0 ||
            UInt(imageWidth) > UInt.max / UInt(imageHeight) { return roisAtY }

        var i = 0, j = 0
        i = 0
        while i < (rois?.count ?? 0) {
            j = 0
            while j < ((rois!.object(at: i) as? NSArray)?.count ?? 0) {
                let aROI = (rois!.object(at: i) as! NSArray).object(at: j) as! ROI
                if aROI.type == .t2DPoint {
                    if cLong((aROI.points.object(at: 0) as! MyPoint).y) == y {
                        let xView = _xReslicedView
                        let new2DPointROI: ROI = ROI(type: .t2DPoint, Float(xView?.pixelSpacingX ?? 0), Float(xView?.pixelSpacingY ?? 0), NSMakePoint(xView?.origin.x ?? 0, xView?.origin.y ?? 0))
                        var irect = NSZeroRect
                        irect.origin.x = CGFloat((aROI.points.object(at: 0) as! MyPoint).x)
                        let sliceIndex: Int = (_sign > 0) ? (_originalView?.dcmPixList?.count ?? 0) &- 1 &- i : i // i is slice number
                        irect.origin.y = CGFloat(sliceIndex)
                        irect.size.width = 0
                        irect.size.height = 0
                        new2DPointROI.rect = irect
                        new2DPointROI.parent = aROI
                        // copy the name
                        new2DPointROI.name = aROI.name
                        // add the 2D Point ROI to the ROI list
                        roisAtY.add(new2DPointROI)
                    }
                }

                if aROI.type == .tPlain {
                    if aROI.textureBuffer != nil && aROI.textureWidth > 0 && aROI.textureHeight > 0 &&
                        y >= Int(aROI.textureUpLeftCornerY) &&
                        UInt(bitPattern: y) &- UInt(bitPattern: Int(aROI.textureUpLeftCornerY)) < UInt(bitPattern: Int(aROI.textureHeight)) {
                        if object(plainDict, forKey: aROI.name) == nil {
                            let t = calloc(Int(imageWidth) * Int(imageHeight), MemoryLayout<UInt8>.size)

                            if let t {
                                let xView = _xReslicedView
                                let newROI: ROI = ROI(type: .tPlain, Float(xView?.pixelSpacingX ?? 0), Float(xView?.pixelSpacingY ?? 0), NSMakePoint(xView?.origin.x ?? 0, xView?.origin.y ?? 0))

                                newROI.name = aROI.name
                                newROI.thickness = aROI.thickness
                                newROI.rgbcolor = aROI.rgbcolor
                                newROI.opacity = aROI.opacity

                                newROI.setTexture(t.assumingMemoryBound(to: UInt8.self), width: imageWidth, height: imageHeight)
                                setObject(plainDict, newROI, forKey: aROI.name)
                            } else {
                                NSLog("***** not enough memory : pointsROIAtX - OrthogonalMPRController")
                            }
                        }

                        let p = object(plainDict, forKey: aROI.name) as? ROI

                        if let p {
                            let sliceIndex: Int = _sign > 0 ? (_originalView?.dcmPixList?.count ?? 0) &- 1 &- i : i
                            HorosCopyMPRBrushLine(p.textureBuffer, imageWidth, imageHeight, sliceIndex,
                                                  aROI.textureBuffer, aROI.textureWidth, aROI.textureHeight,
                                                  aROI.textureUpLeftCornerX, aROI.textureUpLeftCornerY, y, false)
                        }
                    }
                }
                j += 1
            }
            i += 1
        }

        let keys = plainDict.keyEnumerator()
        while let key = keys.nextObject() {
            let r = plainDict.object(forKey: key) as? ROI

            r?.reduceTextureIfPossible()

            roisAtY.add(r as Any)
        }

        return roisAtY
    }

    @objc(loadROIonXReslicedView:)
    public dynamic func loadROIonXReslicedView(_ y: Int) {
        _xReslicedView?.setCurRoiList(self.pointsROI(atY: y))
        _xReslicedView?.needsDisplay = true
    }

    @objc(loadROIonYReslicedView:)
    public dynamic func loadROIonYReslicedView(_ x: Int) {
        _yReslicedView?.setCurRoiList(self.pointsROI(atX: x))
        _yReslicedView?.needsDisplay = true
    }

    @objc(loadROIonReslicedViews::)
    public dynamic func loadROIonReslicedViews(_ x: Int, _ y: Int) {
        self.loadROIonXReslicedView(y)
        self.loadROIonYReslicedView(x)
    }

    @objc(contextualMenu)
    public dynamic func contextualMenu() -> NSMenu! {

// if contextualMenuPath says @"default", recreate the default menu once and again
// if contextualMenuPath contains a path, create the new contextual menu
// if contextualMenuPath says @"custom", don't do anything

        var contextual: NSMenu

        /******************* Tools menu ***************************/
        contextual = NSMenu(title: NSLocalizedString("Tools", comment: ""))
        var item: NSMenuItem
        //Menu titles
        let titles: NSArray = [NSLocalizedString("Contrast", comment: ""),
                               NSLocalizedString("Move", comment: ""),
                               NSLocalizedString("Magnify", comment: ""),
                               NSLocalizedString("Rotate", comment: ""),
                               NSLocalizedString("Scroll", comment: ""),
                               NSLocalizedString("Length", comment: ""),
                               NSLocalizedString("Oval", comment: ""),
                               NSLocalizedString("Angle", comment: ""),
                               NSLocalizedString("Point", comment: ""),
                               NSLocalizedString("Cross", comment: "")]
        //Image Names
        let images: NSArray = ["WLWW",
                               "Move",
                               "Zoom",
                               "Rotate",
                               "Stack",
                               "Length",
                               "Oval",
                               "Angle",
                               "Point",
                               "Cross"]	// DO NOT LOCALIZE THIS LINE ! -> filenames !

        let tagIndexes: NSArray = [NSNumber(value: 0),
                                   NSNumber(value: 1),
                                   NSNumber(value: 2),
                                   NSNumber(value: 3),
                                   NSNumber(value: 4),
                                   NSNumber(value: 5),
                                   NSNumber(value: 9),
                                   NSNumber(value: 12),
                                   NSNumber(value: 19),
                                   NSNumber(value: 8)]

        let enumerator2 = images.objectEnumerator()
        let enumerator3 = tagIndexes.objectEnumerator()
        var image: String?
        var tag: NSNumber?
        var i: Int32 = 0

        for case let title as String in titles {
            image = enumerator2.nextObject() as? String
            tag = enumerator3.nextObject() as? NSNumber
            item = NSMenuItem(title: title, action: NSSelectorFromString("changeTool:"), keyEquivalent: "")
            item.tag = Int(tag?.int32Value ?? 0)
            //[item setTarget:self];
            item.image = image.flatMap { NSImage(named: $0) }
            item.image?.size = ToolsMenuIconSize
            contextual.addItem(item)
        }

        contextual.addItem(NSMenuItem.separator())

        item = NSMenuItem(title: NSLocalizedString("Show Patient Crosshair", comment: ""),
                          action: NSSelectorFromString("togglePatientCrosshair:"), keyEquivalent: "")
        item.target = _viewer
        contextual.addItem(item)

        /******************* WW/WL menu items **********************/
        let menu = AppController.shared()?.wlwwMenu()?.copy() as? NSMenu
        item = NSMenuItem(title: NSLocalizedString("Window Width & Level", comment: ""), action: nil, keyEquivalent: "")
        item.submenu = menu
        contextual.addItem(item)

        contextual.addItem(NSMenuItem.separator())

        /************* window resize Menu ****************/


        let submenu = NSMenu(title: "Resize window")

        let resizeWindowArray: NSArray = ["25%", "50%", "100%", "200%", "300%", "iPod Video"]
        i = 0
        for case let titleMenu as String in resizeWindowArray {
            let tag = i
            i += 1
            item = NSMenuItem(title: titleMenu, action: NSSelectorFromString("resizeWindow:"), keyEquivalent: "")
            item.tag = Int(tag)
            submenu.addItem(item)
        }

        item = NSMenuItem(title: NSLocalizedString("Resize window", comment: ""), action: nil, keyEquivalent: "")
        item.submenu = submenu
        contextual.addItem(item)

        contextual.addItem(NSMenuItem.separator())

        item = NSMenuItem(title: NSLocalizedString("No Rescale Size (100%)", comment: ""), action: NSSelectorFromString("actualSize:"), keyEquivalent: "")
        contextual.addItem(item)

        item = NSMenuItem(title: NSLocalizedString("Actual size", comment: ""), action: NSSelectorFromString("realSize:"), keyEquivalent: "")
        contextual.addItem(item)

        return contextual
    }

    @objc(flipVertical:)
    @IBAction public dynamic func flipVertical(_ sender: Any!) {
        let flipped = viewMessages(sender)?.yFlipped ?? false
        _originalView?.yFlipped = flipped
        _xReslicedView?.yFlipped = flipped
        _yReslicedView?.yFlipped = flipped
    }

    @objc(flipHorizontal:)
    @IBAction public dynamic func flipHorizontal(_ sender: Any!) {
        if !objIsEqual(sender, _yReslicedView) {
            let flipped = viewMessages(sender)?.xFlipped ?? false
            _originalView?.xFlipped = flipped
            _xReslicedView?.xFlipped = flipped
        }
    }
}
