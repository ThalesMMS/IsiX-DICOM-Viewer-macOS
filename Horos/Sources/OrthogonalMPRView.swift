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

// The OpenGL enumerants ROICanvasGL.h names, which Swift cannot import: that
// header imports Horos-Swift.h.
private let GL_LINES: UInt32 = 0x0001
private let GL_LINE_LOOP: UInt32 = 0x0002
private let GL_POINT_SMOOTH: UInt32 = 0x0B10
private let GL_LINE_SMOOTH: UInt32 = 0x0B20
private let GL_POLYGON_SMOOTH: UInt32 = 0x0B41
private let GL_BLEND: UInt32 = 0x0BE2
private let GL_SRC_ALPHA: UInt32 = 0x0302
private let GL_ONE_MINUS_SRC_ALPHA: UInt32 = 0x0303

// The static inline functions of ROICanvasGL.h, with the same parameter types:
// a CGFloat or double argument goes through a float, as it did.
private func roiLoadIdentity() { ROICanvas.current?.loadIdentity() }
private func roiScalef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.scale(x: Double(x), y: Double(y), z: Double(z)) }
private func roiBlendFunc(_ source: UInt32, _ destination: UInt32) { ROICanvas.current?.blend(source: source, destination: destination) }
private func roiEnable(_ cap: UInt32) { ROICanvas.current?.enable(cap) }
private func roiDisable(_ cap: UInt32) { ROICanvas.current?.disable(cap) }
private func roiColor3f(_ r: Float, _ g: Float, _ b: Float) {
    ROICanvas.current?.color(r: CGFloat(r), g: CGFloat(g), b: CGFloat(b), a: 1)
}
private func roiColor4f(_ r: Float, _ g: Float, _ b: Float, _ a: Float) {
    ROICanvas.current?.color(r: CGFloat(r), g: CGFloat(g), b: CGFloat(b), a: CGFloat(a))
}
private func roiLineWidth(_ w: Float) { ROICanvas.current?.lineWidth(CGFloat(w)) }
private func roiBegin(_ mode: UInt32) { ROICanvas.current?.begin(mode) }
private func roiEnd() { ROICanvas.current?.end() }
private func roiVertex2f(_ x: Float, _ y: Float) { ROICanvas.current?.vertex(x: CGFloat(x), y: CGFloat(y)) }

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

/// The messages the view sends to its window controller, an id: the
/// OrthogonalMPRViewer, OrthogonalMPRPETCTViewer or EndoscopyViewer of the
/// window, which the former code also typed by a cast that did not check the
/// class. The protocol names the selectors, it is not checked: a window
/// controller that does not answer one raises, as before; nil answers 0.
@objc private protocol OrthogonalMPRViewWindowControllerMessages: NSObjectProtocol {
    @objc(windowWillClose) func windowWillClose() -> Bool
    @objc(curMovieIndex) func curMovieIndex() -> Int16
    @objc(maxMovieIndex) func maxMovieIndex() -> Int16
    @objc(setMovieIndex:) func setMovieIndex(_ i: Int16)
    @objc(FullScreenON) func fullScreenON() -> Bool
    @objc(thickSlabController) func thickSlabController() -> AnyObject?
    @objc(setCurWLWWMenu:) func setCurWLWWMenu(_ str: NSString?)
    @objc(factorPET2SUV) func factorPET2SUV() -> Float
    @objc(applyWLWWForString:) func applyWLWW(forString str: NSString?)
    @objc(ApplyOpacityString:) func applyOpacityString(_ str: NSString?)
    @objc(setCurrentTool:) func setCurrentTool(_ tool: ToolMode)
    /// -[ThickSlabController setLowQuality:].
    @objc(setLowQuality:) func setLowQuality(_ q: Bool)
}

private func messages(_ object: Any?) -> OrthogonalMPRViewWindowControllerMessages? {
    return unsafeBitCast(object as AnyObject?, to: OrthogonalMPRViewWindowControllerMessages?.self)
}

/// -[DCMPix setArrayPix::] sent with the array itself: DCMPix keeps the array
/// it gets without retaining it, so it must be the list the view keeps, not the
/// copy that bridging to [Any] would pass.
private func sendSetArrayPix(_ pix: AnyObject, _ array: NSArray?, _ i: Int16) {
    typealias Send = @convention(c) (AnyObject, Selector, NSArray?, Int16) -> Void
    let selector = NSSelectorFromString("setArrayPix::")
    unsafeBitCast((pix as! NSObject).method(for: selector), to: Send.self)(pix, selector, array, i)
}

/// [view setPixels: pixels files: files rois: rois firstImage: … level: … reset: …]
/// with the files list itself, which the [Any] Swift imports the parameter as
/// would have copied.
private func sendSetPixels(_ view: DCMView, _ pixels: NSMutableArray?, files: NSArray?, rois: NSMutableArray?,
                           firstImage: Int16, level: CChar, reset: Bool) {
    typealias Send = @convention(c) (AnyObject, Selector, NSMutableArray?, NSArray?, NSMutableArray?, Int16, CChar, Bool) -> Void
    let selector = NSSelectorFromString("setPixels:files:rois:firstImage:level:reset:")
    unsafeBitCast(view.method(for: selector), to: Send.self)(view, selector, pixels, files, rois, firstImage, level, reset)
}

/// [view mouseMoved: event] with the application's current event, which may
/// be nil: the NSEvent Swift imports the parameter as is not optional.
private func sendMouseMoved(_ view: NSView, _ event: NSEvent?) {
    typealias Send = @convention(c) (AnyObject, Selector, NSEvent?) -> Void
    let selector = NSSelectorFromString("mouseMoved:")
    unsafeBitCast(view.method(for: selector), to: Send.self)(view, selector, event)
}

/// [a isEqualTo: b], nil answering NO.
private func objIsEqualTo(_ a: Any?, _ b: Any?) -> Bool {
    guard let a = a as? NSObject else { return false }
    return a.isEqual(to: b)
}

/// [[file valueForKey:@"modality"] isEqualToString: modality], nil answering NO.
private func hasModality(_ file: Any?, _ modality: String) -> Bool {
    return ((file as? NSObject)?.value(forKey: "modality") as? String) == modality
}

/// [object intValue], a message to an id; nil answers 0.
private func intValueOf(_ object: Any?) -> Int32 {
    return ((object as? NSObject)?.value(forKey: "intValue") as? NSNumber)?.int32Value ?? 0
}

/// View for MPRs
///
/// This view displays a cross to show where the 2 orthogonal plane are crossing
///
/// Implemented in Swift since #870: the Objective-C name, the selectors and
/// <Horos/OrthogonalMPRView.h> are those of the former class, the customClass
/// of the three views of OrthogonalMPR.xib. It is not final:
/// OrthogonalMPRPETCTView and EndoscopyMPRView subclass it, and its methods
/// are dynamic, sent through the Objective-C runtime as before. The DCMView
/// ivars are read and written through DCMView+SwiftIvars.h.
@objc(OrthogonalMPRView)
public class OrthogonalMPRView: DCMView {
    // MARK: - The former instance variables

    private var _crossPositionX: Float = 0 // coordinate x and Y of the cross
    private var _crossPositionY: Float = 0
    /// Retained, as the former ivar.
    private var _controller: OrthogonalMPRController? = nil
    private var _displayResliceAxes: Int = 0
    private var savedScaleValue: Float = 0

    private var thickSlabX: Int = 0
    private var thickSlabY: Int = 0
    private var _curWLWWMenu: String? = nil
    private var _curCLUTMenu: String? = nil
    private var _curOpacityMenu: String? = nil

    // MARK: -

    @IBAction public override dynamic func scaleToFit(_ sender: Any!) {
        super.scaleToFit(sender)
        self.blendingPropagate()
    }

    @IBAction public override dynamic func actualSize(_ sender: Any!) {
        super.actualSize(sender)
        self.blendingPropagate()
    }

    public override dynamic func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        self.blendingPropagate()
    }

    public override dynamic func setIndexWithReset(_ index: Int16, _ sizeToFit: Bool) {
        super.setIndexWithReset(index, sizeToFit)
        self.blendingPropagate()
    }

    public override dynamic func scrollWheel(with theEvent: NSEvent) {
        var reverseScrollWheel: Float

        if self.horos_curImage < 0 { return }
        if !self.drawing { return }
        if (self.window?.isVisible ?? false) == false { return }
        if self.is2DViewer() == true {
            if messages(self.windowController())?.windowWillClose() ?? false { return }
        }

        var SelectWindowScrollWheel = UserDefaults.standard.bool(forKey: "SelectWindowScrollWheel")

        if theEvent.modifierFlags.contains(.capsLock) { // Caps Lock
            SelectWindowScrollWheel = !SelectWindowScrollWheel
        }

        if SelectWindowScrollWheel {
            if (self.window?.isMainWindow ?? false) == false {
                self.window?.makeKeyAndOrderFront(self)
            }
        }

        var deltaX = Float(theEvent.deltaX)

        if UserDefaults.standard.bool(forKey: "ZoomWithHorizonScroll") == false { deltaX = 0 }

        if UserDefaults.standard.bool(forKey: "Scroll Wheel Reversed") {
            reverseScrollWheel = -1.0
        } else {
            reverseScrollWheel = 1.0
        }

        if self.horos_flippedData { reverseScrollWheel *= -1.0 }

        if self.horos_dcmPixList != nil {
            self.controller()?.saveCrossPositions()
            var change: Float

            if abs(theEvent.deltaY) > Double(abs(deltaX)) && theEvent.deltaY != 0 {
                if theEvent.modifierFlags.contains(.command) {
                    if self.horos_blending != nil {
                        let change = Float(Double(theEvent.deltaY) / -0.2)
                        self.horos_blendingFactor += change

                        self.setBlendingFactor(self.horos_blendingFactor)
                    }
                } else if theEvent.modifierFlags.contains(.option) {
                    // 4D Direction scroll - Cardiac CT eg
                    var change = Float(Double(theEvent.deltaY) / -2.5)
                    let windowController = messages(self.windowController())

                    if change > 0 {
                        change = ceil(change)
                        if change < 1 { change = 1 }

                        change += Float(windowController?.curMovieIndex() ?? 0)
                        while change >= Float(windowController?.maxMovieIndex() ?? 0) { change -= Float(windowController?.maxMovieIndex() ?? 0) }
                    } else {
                        change = floor(change)
                        if change > -1 { change = -1 }

                        change += Float(windowController?.curMovieIndex() ?? 0)
                        while change < 0 { change += Float(windowController?.maxMovieIndex() ?? 0) }
                    }

                    windowController?.setMovieIndex(Int16(truncatingIfNeeded: cInt(Double(change))))
                } else {
                    change = reverseScrollWheel * Float(theEvent.deltaY)
                    if change > 0 {
                        change = ceil(change)
                        if change < 1 { change = 1 }
                    } else {
                        change = floor(change)
                        if change > -1 { change = -1 }
                    }

                    // [self isKindOfClass: [OrthogonalMPRView class]], which self is.
                    self.scrollTool(0, cLong(change))
                }
            } else if deltaX != 0 {
                change = reverseScrollWheel * deltaX
                if change >= 0 {
                    change = ceil(change)
                    if change < 1 { change = 1 }
                } else {
                    change = floor(change)
                    if change > -1 { change = -1 }
                }

                // [self isKindOfClass: [OrthogonalMPRView class]], which self is.
                self.scrollTool(0, cLong(change))
            }

            sendMouseMoved(self, NSApplication.shared.currentEvent)
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        _displayResliceAxes = 1
        _controller = nil

        // thick slab axes distance
        thickSlabX = 0
        thickSlabY = 0

        _crossPositionX = 0
        _crossPositionY = 0

        _curWLWWMenu = NSLocalizedString("Other", comment: "")
        _curCLUTMenu = NSLocalizedString("No CLUT", comment: "")
        _curOpacityMenu = NSLocalizedString("Linear Table", comment: "")

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(addROI(_:)),
                                               name: NSNotification.Name.OsirixAddROI,
                                               object: nil)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(removeROI(_:)),
                                               name: NSNotification.Name.OsirixRemoveROI,
                                               object: nil)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(roiRemovedFromArray(_:)),
                                               name: NSNotification.Name.OsirixROIRemovedFromArray,
                                               object: nil)
    }

    /// DCMView's -initWithFrame: sends this one to self: overridden, unchanged,
    /// so that it stays inherited beside the initializer above.
    public override init!(frame: NSRect, imageRows rows: Int32, imageColumns columns: Int32) {
        super.init(frame: frame, imageRows: rows, imageColumns: columns)
    }

    /// Overridden, unchanged, so that it stays inherited beside the initializer above.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // The controller and the three menu names are released with the view.

    /// The files list is typed NSArray, as the view hands it to DCMView as it is.
    @objc(setPixList:::)
    public dynamic func setPixList(_ pix: NSMutableArray!, _ files: NSArray!, _ rois: NSMutableArray!) {
        var i = 0

        sendSetPixels(self, pix, files: files, rois: rois, firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: false)

        //if( [[[[self window] windowController] windowNibName] isEqualToString:@"OrthogonalMPR"])
        if self.window?.windowController?.windowNibName != "PETCT" {
            // Prepare pixList for image thick slab - DO IT ONLY FOR NON - PET-CT VIEWER !!!!!!! ROI CRASH - Antoine
            i = 0
            while i < (pix?.count ?? 0) {
                sendSetArrayPix(pix.object(at: i) as AnyObject, pix, Int16(truncatingIfNeeded: i))
                i += 1
            }
        }

        self.setIndex(0)
    }

    @objc(setPixList::)
    public dynamic func setPixList(_ pix: NSMutableArray!, _ files: NSArray!) {
        self.setPixList(pix, files, nil)
    }

    @objc(pixList)
    public dynamic func pixList() -> NSMutableArray! {
        return self.horos_dcmPixList
    }

    public override var curRoiList: NSMutableArray! {
        return self.horos_curRoiList
    }

    // overwrite method in DCMView
    public override dynamic func becomeMainWindow() {
    }

    @objc(setCurRoiList:)
    public dynamic func setCurRoiList(_ rois: NSMutableArray!) {
        if rois !== self.horos_curRoiList {
            // The ivar retains its list, as the former [curRoiList release]
            // and [rois retain] did.
            if let old = self.horos_curRoiList { Unmanaged.passUnretained(old).release() }
            if let rois { _ = Unmanaged.passUnretained(rois).retain() }
            self.horos_curRoiList = rois
        }

        for r in self.horos_curRoiList ?? NSMutableArray() {
            self.roiSet(r as? ROI)
        }
    }

    public override var dcmRoiList: NSMutableArray! {
        return self.horos_dcmRoiList
    }

    @objc(setController:)
    public dynamic func setController(_ newController: OrthogonalMPRController!) {
        if _controller !== newController {
            _controller = newController
        }
    }

    public override dynamic func controller() -> OrthogonalMPRController! {
        return _controller
    }

    @objc(convertPixX:pixY:toDICOMCoords:)
    public dynamic func convertPixX(_ x: Float, pixY y: Float, toDICOMCoords location: UnsafeMutablePointer<Float>!) {
        let curDCM = self.curDCM
        if Int(curDCM?.stack ?? 0) > 1 {
            var stackImageIndex: Int
            let stack = Int(curDCM?.stack ?? 0)

            if self.horos_flippedData {
                stackImageIndex = Int(self.horos_curImage) - (stack - 1) / 2
            } else {
                stackImageIndex = Int(self.horos_curImage) + (stack - 1) / 2
            }

            let dcmPixList = self.horos_dcmPixList
            if stackImageIndex < 0 { stackImageIndex = 0 }
            if stackImageIndex >= (dcmPixList?.count ?? 0) { stackImageIndex = (dcmPixList?.count ?? 0) - 1 }

            (dcmPixList?.object(at: stackImageIndex) as? DCMPix)?.convertX(x, pixY: y, toDICOMCoords: location, pixelCenter: true)
        } else {
            curDCM?.convertX(x, pixY: y, toDICOMCoords: location, pixelCenter: true)
        }
    }

    @objc(getCrossPositionDICOMCoords:)
    public dynamic func getCrossPositionDICOMCoords(_ location: UnsafeMutablePointer<Float>!) {
        self.convertPixX(_crossPositionX, pixY: _crossPositionY, toDICOMCoords: location)
    }

    @objc(setCrossPosition::)
    public dynamic func setCrossPosition(_ x: Float, _ y: Float) {
        self.setCrossPosition(x, y, withNotification: true)
    }

    @objc(setCrossPosition::withNotification:)
    public dynamic func setCrossPosition(_ x: Float, _ y: Float, withNotification doNotifychange: Bool) {
        if _crossPositionX == x && _crossPositionY == y {
            return
        }

        self.setCrossPositionX(x)
        self.setCrossPositionY(y)
        _controller?.setCrossPosition(x, y, self)

        if doNotifychange {
            _controller?.notifyPositionChange()
        }
    }

    @objc(setCrossPositionX:)
    public dynamic func setCrossPositionX(_ x: Float) {
        var x = x
        if _crossPositionX == x {
            return
        }
        let pwidth = self.curDCM?.pwidth ?? 0
        x = (x < 0) ? 0 : x
        x = (x >= Float(pwidth)) ? Float(pwidth - 1) : x
        _crossPositionX = x
    }

    @objc(setCrossPositionY:)
    public dynamic func setCrossPositionY(_ y: Float) {
        var y = y
        if _crossPositionY == y {
            return
        }
        let pheight = self.curDCM?.pheight ?? 0
        y = (y < 0) ? 0 : y
        y = (y >= Float(pheight)) ? Float(pheight - 1) : y
        _crossPositionY = y
    }

    public override dynamic func setCLUT(_ r: UnsafeMutablePointer<UInt8>!, _ g: UnsafeMutablePointer<UInt8>!, _ b: UnsafeMutablePointer<UInt8>!) {
        super.setCLUT(r, g, b)
        self.setIndex(self.curImage)
    }

    public override dynamic func setWLWW(_ wl: Float, _ ww: Float) {
        self.controller()?.setWLWW(wl, ww)
    }

    @objc(adjustWLWW::)
    public dynamic func adjustWLWW(_ wl: Float, _ ww: Float) {
        self.curDCM?.changeWLWW(wl, ww)

        self.horos_curWW = self.curDCM?.ww ?? 0
        self.horos_curWL = self.curDCM?.wl ?? 0

        self.loadTextures()
        self.needsDisplay = true
    }

    public override dynamic func getWLWW(_ wl: UnsafeMutablePointer<Float>!, _ ww: UnsafeMutablePointer<Float>!) {
        if self.curDCM == nil {
            NSLog("OrthogonalMPRView getWLWW : curDCM nil")
        } else {
            if let wl { wl.pointee = self.curDCM?.wl ?? 0 }
            if let ww { ww.pointee = self.curDCM?.ww ?? 0 }
        }
    }

    /// -setScaleValue: of the former class, which only overrode the setter.
    public override var scaleValue: Float {
        get { return super.scaleValue }
        set {
            let x = newValue
            let originalView = _controller?.originalView()
            if self.pixelSpacingX != 0 && (originalView?.pixelSpacingX ?? 0) != 0 {
                if _controller?.originalView() === self {
                    self.controller()?.setScaleValue(x)
                } else if _controller?.yReslicedView() === self {
                    self.controller()?.setScaleValue(Float(Double(x) * (_controller?.originalView()?.pixelSpacingX ?? 0) / self.pixelSpacingX))
                } else if _controller?.xReslicedView() === self {
                    self.controller()?.setScaleValue(Float(Double(x) * (_controller?.originalView()?.pixelSpacingX ?? 0) / self.pixelSpacingX))
                }
            } else {
                self.controller()?.setScaleValue(x)
            }
        }
    }

    @objc(adjustScaleValue:)
    public dynamic func adjustScaleValue(_ x: Float) {
        super.setScaleValueCentered(x)
    }

    @objc(crossPositionX)
    public dynamic func crossPositionX() -> Float {
        return _crossPositionX
    }

    @objc(crossPositionY)
    public dynamic func crossPositionY() -> Float {
        return _crossPositionY
    }

    public override dynamic func drawTextualData(_ size: NSRect, annotationsLevel annotations: Int, fullText: Bool, onlyOrientation: Bool) {
        if self.horos_isKeyView == false {
            super.drawTextualData(size, annotationsLevel: annotations, fullText: false, onlyOrientation: true)
        } else {
            super.drawTextualData(size, annotationsLevel: annotations, fullText: false, onlyOrientation: false)
        }
    }

    public override dynamic func subDraw(_ aRect: NSRect) {

        if _displayResliceAxes != 0 && PatientCrosshairController.shared.isVisible {
            roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
            roiEnable(GL_BLEND)
            roiEnable(GL_POINT_SMOOTH)
            roiEnable(GL_LINE_SMOOTH)
            roiEnable(GL_POLYGON_SMOOTH)

            let scaleValue = self.horos_scaleValue
            let pixelRatio = self.curDCM?.pixelRatio ?? 0
            var xCrossCenter: Float, yCrossCenter: Float
            xCrossCenter = (_crossPositionX - Float((self.curDCM?.pwidth ?? 0) / 2)) * scaleValue
            yCrossCenter = (_crossPositionY - Float((self.curDCM?.pheight ?? 0) / 2)) * scaleValue

            //NSLog(@"subdraw thickslab:%f pixelSpacingY:%f", [controller thickSlabDistance], [self.curDCM pixelSpacingY]);
            //yCrossCenter = yCrossCenter - ([controller thickSlabDistance]*(float)[controller thickSlab]   / 2.0);

        //	NSRect size = [self frame];
        //	float viewportSizeX, viewportSizeY;
        //	viewportSizeX = size.size.width;
        //	viewportSizeY = size.size.height / [self.curDCM pixelRatio];

        //	float xAxeLength, yAxeLength;
        //	xAxeLength = viewportSizeX;
        //	yAxeLength = viewportSizeY;

            roiColor3f(0.0, 1.0, 0.0)
            roiLineWidth(Float(1.0 * (self.window?.backingScaleFactor ?? 0)))
            roiBegin(GL_LINES)
            // vertical axis
            roiVertex2f(xCrossCenter, -4000)
            roiVertex2f(xCrossCenter, Float(Double(yCrossCenter) - 50.0 / pixelRatio))

            if _displayResliceAxes == 2 {
                roiVertex2f(xCrossCenter, Float(Double(yCrossCenter) - 10.0 / pixelRatio))
                roiVertex2f(xCrossCenter, Float(Double(yCrossCenter) + 10.0 / pixelRatio))
            }

            roiColor3f(0.0, 1.0, 0.0)
            roiVertex2f(xCrossCenter, Float(Double(yCrossCenter) + 50.0 / pixelRatio))
            roiVertex2f(xCrossCenter, 4000)

            // horizontal axis
            roiVertex2f(-4000, yCrossCenter)
            roiVertex2f(Float(Double(xCrossCenter) - 50.0), yCrossCenter)

            if _displayResliceAxes == 2 {
                roiVertex2f(Float(Double(xCrossCenter) - 10.0), yCrossCenter)
                roiVertex2f(Float(Double(xCrossCenter) + 10.0), yCrossCenter)
            }

            roiColor3f(0.0, 1.0, 0.0)
            roiVertex2f(Float(Double(xCrossCenter) + 50.0), yCrossCenter)
            roiVertex2f(4000, yCrossCenter)

            var shift: Float
            if thickSlabX > 0 {
                shift = Float(Double(Float(thickSlabX)) / 2.0 * Double(scaleValue))
                roiColor3f(0.0, 0.0, 1.0)
                roiVertex2f(xCrossCenter - shift, -4000)
                roiVertex2f(xCrossCenter - shift, Float(Double(yCrossCenter) - 50.0 / pixelRatio))

                roiVertex2f(xCrossCenter - shift, Float(Double(yCrossCenter) + 50.0 / pixelRatio))
                roiVertex2f(xCrossCenter - shift, 4000)

                roiVertex2f(xCrossCenter + shift, -4000)
                roiVertex2f(xCrossCenter + shift, Float(Double(yCrossCenter) - 50.0 / pixelRatio))

                roiVertex2f(xCrossCenter + shift, Float(Double(yCrossCenter) + 50.0 / pixelRatio))
                roiVertex2f(xCrossCenter + shift, 4000)
            }

            if thickSlabY > 0 {
                shift = Float(Double(Float(thickSlabY)) / 2.0 * Double(scaleValue))
                roiColor3f(0.0, 0.0, 1.0)
                roiVertex2f(-4000, yCrossCenter - shift)
                roiVertex2f(Float(Double(xCrossCenter) - 50.0), yCrossCenter - shift)

                roiVertex2f(Float(Double(xCrossCenter) + 50.0), yCrossCenter - shift)
                roiVertex2f(4000, yCrossCenter - shift)


                roiVertex2f(-4000, yCrossCenter + shift)
                roiVertex2f(Float(Double(xCrossCenter) - 50.0), yCrossCenter + shift)

                roiVertex2f(Float(Double(xCrossCenter) + 50.0), yCrossCenter + shift)
                roiVertex2f(4000, yCrossCenter + shift)
            }

            roiEnd()

            roiDisable(GL_LINE_SMOOTH)
            roiDisable(GL_POLYGON_SMOOTH)
            roiDisable(GL_POINT_SMOOTH)
            roiDisable(GL_BLEND)
        }

        if Int(self.horos_annotationType) != annotNone && self.horos_stringID == nil {
            let drawingFrameRect = self.horos_drawingFrameRect
            roiLoadIdentity() // reset model view matrix to identity (eliminates rotation basically)
            roiScalef(Float(2.0 / (self.horos_xFlipped ? -(Double(drawingFrameRect.size.width)) : Double(drawingFrameRect.size.width))), Float(-2.0 / (self.horos_yFlipped ? -(Double(drawingFrameRect.size.height)) : Double(drawingFrameRect.size.height))), 1.0) // scale to port per pixel scale

            // draw line around key View

            if self.horos_isKeyView && (messages(self.windowController())?.fullScreenON() ?? false) == false {
                let heighthalf = Float(drawingFrameRect.size.height / 2)
                let widthhalf = Float(drawingFrameRect.size.width / 2)

                // red square
                roiColor4f(1.0, 0.0, 0.0, 0.8)
                roiLineWidth(Float(8.0 * (self.window?.backingScaleFactor ?? 0)))
                roiBegin(GL_LINE_LOOP)
                roiVertex2f(-widthhalf, -heighthalf)
                roiVertex2f(-widthhalf, heighthalf)
                roiVertex2f(widthhalf, heighthalf)
                roiVertex2f(widthhalf, -heighthalf)
                roiEnd()
                roiLineWidth(Float(1.0 * (self.window?.backingScaleFactor ?? 0)))
            }
        }
    }

    public override dynamic func blendingPropagate() {
        _controller?.blendingPropagate(self)
    }

    public override dynamic func keyDown(with event: NSEvent) {
        let characters = event.characters as NSString?
        if (characters?.length ?? 0) == 0 { return }

        let c = characters!.character(at: 0)
        if c == unichar(UInt8(ascii: " ")) {
            _controller?.toggleDisplayResliceAxes(self)
        } else if c == unichar(NSEnterCharacter) || c == unichar(NSCarriageReturnCharacter) || c == 27 { // 27 : escape
            _controller?.fullWindowView(self)
        } else if c == unichar(NSLeftArrowFunctionKey) {
            _controller?.saveCrossPositions()
            self.scrollTool(0, -1)
            _controller?.saveCrossPositions()
            self.blendingPropagate()
        } else if c == unichar(NSRightArrowFunctionKey) {
            _controller?.saveCrossPositions()
            self.scrollTool(0, 1)
            _controller?.saveCrossPositions()
            self.blendingPropagate()
        } else if c == unichar(NSUpArrowFunctionKey) {
            self.scaleValue = Float(Double(self.horos_scaleValue) + 1.0 / 50.0)
            self.blendingPropagate()
        } else if c == unichar(NSDownArrowFunctionKey) {
            self.scaleValue = Float(Double(self.horos_scaleValue) - 1.0 / 50.0)
            self.blendingPropagate()
        } else {
            super.keyDown(with: event)
        }
        self.needsDisplay = true
    }

    @objc(toggleDisplayResliceAxes)
    public dynamic func toggleDisplayResliceAxes() {
        _displayResliceAxes += 1
        if _displayResliceAxes >= 3 { _displayResliceAxes = 0 }
        self.needsDisplay = true
    }

    @objc(displayResliceAxes:)
    public dynamic func displayResliceAxes(_ boo: Int) {
        _displayResliceAxes = boo
        self.needsDisplay = true
    }

    public override dynamic func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            _controller?.restoreCrossPositions()
            _controller?.doubleClick(event, self)
        } else {
            _controller?.saveCrossPositions()
            super.mouseDown(with: event)
            NotificationCenter.default.post(name: NSNotification.Name.OsirixDCMViewDidBecomeFirstResponder, object: self)
        }
    }

    @objc(scrollTool::)
    public dynamic func scrollTool(_ from: Int, _ to: Int) {
        _controller?.scrollTool(from, to, self)
    }

    @objc(saveScaleValue)
    public dynamic func saveScaleValue() {
        savedScaleValue = self.horos_scaleValue
    }

    @objc(restoreScaleValue)
    public dynamic func restoreScaleValue() {
        self.adjustScaleValue(savedScaleValue)
    }

    /// -reshape, which DCMView implements without declaring it.
    @objc(reshape)
    private dynamic func reshape() {}

    @objc(setThickSlabXY::)
    public dynamic func setThickSlabXY(_ newThickSlabX: Int, _ newThickSlabY: Int) {
        thickSlabX = newThickSlabX
        thickSlabY = newThickSlabY
    }

    @objc(curCLUTMenu)
    public dynamic func curCLUTMenu() -> String! {
        return _curCLUTMenu
    }

    @objc(setCurCLUTMenu:)
    public dynamic func setCurCLUTMenu(_ clut: String!) {
        _curCLUTMenu = clut
    }

    @objc(setCurWLWWMenu:)
    public dynamic func setCurWLWWMenu(_ str: String!) {
        _curWLWWMenu = str
    }

    @objc(curWLWWMenu)
    public dynamic func curWLWWMenu() -> String! {
        return _curWLWWMenu
    }

    @objc(setCurOpacityMenu:)
    public dynamic func setCurOpacityMenu(_ o: String!) {
        _curOpacityMenu = o
    }

    @objc(curOpacityMenu)
    public dynamic func curOpacityMenu() -> String! {
        return _curOpacityMenu
    }

    // overwrite the DCMView method:
    @objc(addROI:)
    private dynamic func addROI(_ note: Notification) {
        let sender = note.object
        let addedROI = (note.userInfo as NSDictionary?)?.object(forKey: "ROI") as? ROI

        if addedROI?.type != .t2DPoint { return }

        if !objIsEqualTo(self, sender) { // && ![self isEqualTo:[controller xReslicedView]] && ![self isEqualTo:[controller yReslicedView]])
            let controller = _controller
            if (objIsEqualTo(controller?.xReslicedView(), sender) || objIsEqualTo(controller?.yReslicedView(), sender)) && objIsEqualTo(controller?.originalView(), self) {
                if addedROI?.type == .t2DPoint {
                    let originalView = controller?.originalView()
                    let new2DPointROI: ROI = ROI(type: .t2DPoint, Float(originalView?.pixelSpacingX ?? 0), Float(originalView?.pixelSpacingY ?? 0), NSMakePoint(originalView?.origin.x ?? 0, originalView?.origin.y ?? 0))

                    var irect = NSZeroRect
                    if objIsEqualTo(controller?.xReslicedView(), sender) {
                        irect.origin.x = CGFloat((addedROI!.points.object(at: 0) as! MyPoint).x)
                        irect.origin.y = CGFloat(controller?.originalView()?.crossPositionY() ?? 0)
                    } else {
                        irect.origin.x = CGFloat(controller?.originalView()?.crossPositionX() ?? 0)
                        irect.origin.y = CGFloat((addedROI!.points.object(at: 0) as! MyPoint).x)
                    }
                    irect.size.width = 0
                    irect.size.height = 0
                    new2DPointROI.rect = irect

                    controller?.originalView()?.roiSet(new2DPointROI)

                    for loopItem in self.horos_curRoiList ?? NSMutableArray() {
                        (loopItem as? ROI)?.roImode = ROI_sleep
                    }

                    // copy the state
                    new2DPointROI.roImode = ROI_selected

                    // name
                    var finalName: String
                    let roiName = "Point "
                    var counter: Int32 = 1
                    var existsAlready = true
                    repeat {
                        existsAlready = false
                        finalName = roiName + String(format: "%d", counter)
                        counter += 1
                        var i = 0
                        while i < (controller?.originalView()?.dcmRoiList?.count ?? 0) {
                            var x = 0
                            while x < ((controller?.originalView()?.dcmRoiList?.object(at: i) as? NSArray)?.count ?? 0) {
                                if (((controller?.originalView()?.dcmRoiList?.object(at: i) as? NSArray)?.object(at: x) as? ROI)?.name) == finalName {
                                    existsAlready = true
                                }
                                x += 1
                            }
                            i += 1
                        }
                    } while existsAlready
                    addedROI?.name = finalName
                    new2DPointROI.name = finalName

                    // add the 2D Point ROI to the ROI list
                    // The former expression mixed a long and a float: the count
                    // went through a float, as here.
                    let pointY = (addedROI!.points.object(at: 0) as! MyPoint).y
                    var slice: Int = cLong(((controller?.sign() ?? 0) > 0) ? Float((controller?.originalView()?.dcmPixList?.count ?? 0) - 1) - pointY : pointY)

                    let roiCount = controller?.originalView()?.dcmRoiList?.count ?? 0
                    if slice < 0 { slice = 0 }
                    if slice >= roiCount { slice = roiCount - 1 }

                    ((controller?.originalView()?.dcmRoiList as NSArray?)?.object(at: slice) as? NSMutableArray)?.add(new2DPointROI)
                }
                controller?.loadROIonReslicedViews(cLong(controller?.originalView()?.crossPositionX() ?? 0), cLong(controller?.originalView()?.crossPositionY() ?? 0))
            }
        }
    }

    public override dynamic func roiChange(_ note: Notification!) {
        let roi = note?.object as? ROI

        super.roiChange(note)

        if roi?.type != .t2DPoint { return }

        let controller = _controller
        if ((note?.userInfo as NSDictionary?)?.value(forKey: "action") as? String) == "mouseUp" && self.window?.firstResponder === self {
            if roi?.parent != nil {
                var reslicedview: Int32 = 0

                // the ROI has a parent. Thus it is on a resliced view. Which one?
                NSLog("roi is 2D Point and has parent")
                var irect = NSZeroRect
                if controller?.xReslicedView()?.curRoiList?.contains(roi as Any) == true {
                    reslicedview = 1

                    NSLog("this Point belongs to xReslicedView")
                    irect.origin.x = CGFloat((roi!.points.object(at: 0) as! MyPoint).x)
                    irect.origin.y = CGFloat(controller?.originalView()?.crossPositionY() ?? 0)
                } else if controller?.yReslicedView()?.curRoiList?.contains(roi as Any) == true {
                    reslicedview = 2

                    NSLog("this Point belongs to yReslicedView")
                    irect.origin.x = CGFloat(controller?.originalView()?.crossPositionX() ?? 0)
                    irect.origin.y = CGFloat((roi!.points.object(at: 0) as! MyPoint).x)
                } else {
                    NSLog("nobody contains this Point")
                    return
                }

                let originalView = controller?.originalView()
                let new2DPointROI: ROI = ROI(type: .t2DPoint, Float(originalView?.pixelSpacingX ?? 0), Float(originalView?.pixelSpacingY ?? 0), NSMakePoint(originalView?.origin.x ?? 0, originalView?.origin.y ?? 0))

                // remove the parent ROI on original view. (will be replaced by the new one)
                var i = 0
                while i < (controller?.originalView()?.dcmRoiList?.count ?? 0) {
                    let list = controller?.originalView()?.dcmRoiList?.object(at: i) as? NSMutableArray
                    if let parentROI = roi?.parent, list?.contains(parentROI) == true {
                        NSLog("Point removed in originalView")
                        list?.remove(parentROI)
                    }
                    i += 1
                }

                // create the new ROI
                irect.size.width = 0
                irect.size.height = 0
                new2DPointROI.rect = irect
                controller?.originalView()?.roiSet(new2DPointROI)

                // copy the name
                new2DPointROI.name = roi?.name

                // add the 2D Point ROI to the ROI list
                // The former expression mixed a long and a float, as in -addROI:.
                let pointY = (roi!.points.object(at: 0) as! MyPoint).y
                var slice: Int = cLong(((controller?.sign() ?? 0) > 0) ? Float((controller?.originalView()?.dcmPixList?.count ?? 0) - 1) - pointY : pointY)

                let roiCount = controller?.originalView()?.dcmRoiList?.count ?? 0
                if slice < 0 { slice = 0 }
                if slice >= roiCount { slice = roiCount - 1 }

                NSLog("slice : %d", Int32(truncatingIfNeeded: slice))

                ((controller?.originalView()?.dcmRoiList as NSArray?)?.object(at: slice) as? NSMutableArray)?.add(new2DPointROI)
                controller?.originalView()?.needsDisplay = true

                // This is my new father
                roi?.parent = new2DPointROI

                switch reslicedview {
                case 2: controller?.loadROIonXReslicedView(cLong(controller?.originalView()?.crossPositionY() ?? 0))
                case 1: controller?.loadROIonYReslicedView(cLong(controller?.originalView()?.crossPositionX() ?? 0))
                default: break
                }
            } else {
                controller?.loadROIonXReslicedView(cLong(controller?.originalView()?.crossPositionY() ?? 0))
                controller?.loadROIonYReslicedView(cLong(controller?.originalView()?.crossPositionX() ?? 0))
            }
        }
    }

    @objc(removeROI:)
    private dynamic func removeROI(_ note: Notification) {
        if self.window?.firstResponder === self {
            let roi = note.object as? ROI

            if let parentROI = roi?.parent {
                var i = 0
                while i < (_controller?.originalView()?.dcmRoiList?.count ?? 0) {
                    let list = _controller?.originalView()?.dcmRoiList?.object(at: i) as? NSMutableArray
                    if list?.contains(parentROI) == true {
                        NSLog("parent of removed ROI is on original view")
                        list?.remove(parentROI)
                    }
                    i += 1
                }
            }
        }
    }

    @objc(roiRemovedFromArray:)
    private dynamic func roiRemovedFromArray(_ note: Notification) {
        let controller = _controller
        if controller?.yReslicedView() === self { controller?.loadROIonYReslicedView(cLong(controller?.originalView()?.crossPositionX() ?? 0)) }
        if controller?.xReslicedView() === self { controller?.loadROIonXReslicedView(cLong(controller?.originalView()?.crossPositionY() ?? 0)) }
        if controller?.originalView() === self { controller?.originalView()?.needsDisplay = true }
    }

    public override dynamic func is2DViewer() -> Bool {
        return false
    }

    // MARK: - Hot Keys.

    //Hot key action
    public override dynamic func actionForHotKey(_ hotKey: NSString!) -> Bool {
        var returnedVal = true
        if (hotKey?.length ?? 0) > 0 {
            let wlwwDict = UserDefaults.standard.dictionary(forKey: "WLWW3") as NSDictionary?
            let wwwlValues = (wlwwDict?.allKeys as NSArray?)?.sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray?

            let opacityDict = UserDefaults.standard.dictionary(forKey: "OPACITY") as NSDictionary?
            let opacityValues = (opacityDict?.allKeys as NSArray?)?.sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray?

            let lowercaseHotKey = hotKey.lowercased as NSString
            var key: unichar = lowercaseHotKey.character(at: 0)
            if DCMView.hotKeyDictionary()?.object(forKey: lowercaseHotKey) != nil {
                key = unichar(truncatingIfNeeded: intValueOf(DCMView.hotKeyDictionary()?.object(forKey: lowercaseHotKey)))
                let windowController = messages(self.windowController())
                var wwwlMenuString: String

                switch UInt32(key) {

                case DefaultWWWLHotKeyAction.rawValue:	// default WW/WL
                    wwwlMenuString = NSLocalizedString("Default WL & WW", comment: "")	// default WW/WL
                    windowController?.applyWLWW(forString: wwwlMenuString as NSString)
                    NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateWLWWMenu, object: wwwlMenuString, userInfo: nil)
                case FullDynamicWWWLHotKeyAction.rawValue:											// full dynamic WW/WL
                    wwwlMenuString = NSLocalizedString("Full dynamic", comment: "")
                    windowController?.applyWLWW(forString: wwwlMenuString as NSString)
                    NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateWLWWMenu, object: wwwlMenuString, userInfo: nil)

                case Preset1WWWLHotKeyAction.rawValue,			// 1 - 9 will be presets WW/WL
                     Preset2WWWLHotKeyAction.rawValue,
                     Preset3WWWLHotKeyAction.rawValue,
                     Preset4WWWLHotKeyAction.rawValue,
                     Preset5WWWLHotKeyAction.rawValue,
                     Preset6WWWLHotKeyAction.rawValue,
                     Preset7WWWLHotKeyAction.rawValue,
                     Preset8WWWLHotKeyAction.rawValue,
                     Preset9WWWLHotKeyAction.rawValue:
                    if (wwwlValues?.count ?? 0) > Int(key) - Int(Preset1WWWLHotKeyAction.rawValue) {
                        let menuString = wwwlValues?.object(at: Int(key) - Int(Preset1WWWLHotKeyAction.rawValue))
                        windowController?.applyWLWW(forString: menuString as? NSString)
                        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateWLWWMenu, object: menuString, userInfo: nil)
                    }

                case Preset1OpacityHotKeyAction.rawValue,			// 1 - 9 will be presets Opacity
                     Preset2OpacityHotKeyAction.rawValue,
                     Preset3OpacityHotKeyAction.rawValue,
                     Preset4OpacityHotKeyAction.rawValue,
                     Preset5OpacityHotKeyAction.rawValue,
                     Preset6OpacityHotKeyAction.rawValue,
                     Preset7OpacityHotKeyAction.rawValue,
                     Preset8OpacityHotKeyAction.rawValue,
                     Preset9OpacityHotKeyAction.rawValue:
                    if (opacityValues?.count ?? 0) >= Int(key) - Int(Preset1OpacityHotKeyAction.rawValue) {
                        let index = Int32(key) - Int32(Preset1OpacityHotKeyAction.rawValue) - 1

                        var opacityMenuString: Any?

                        if index < 0 {
                            opacityMenuString = NSLocalizedString("Linear Table", comment: "")
                        } else {
                            opacityMenuString = opacityValues?.object(at: Int(index))
                        }

                        windowController?.applyOpacityString(opacityMenuString as? NSString)
                        NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateOpacityMenu, object: opacityMenuString, userInfo: nil)
                    }

                // Flip
                case FlipVerticalHotKeyAction.rawValue: self.flipVertical(nil)
                case FlipHorizontalHotKeyAction.rawValue: self.flipHorizontal(nil)
                // mouse functions
                case WWWLToolHotKeyAction.rawValue,
                     MoveHotKeyAction.rawValue,
                     ZoomHotKeyAction.rawValue,
                     RotateHotKeyAction.rawValue,
                     ScrollHotKeyAction.rawValue,
                     LengthHotKeyAction.rawValue,
                     OvalHotKeyAction.rawValue,
                     AngleHotKeyAction.rawValue,
                     ThreeDPointHotKeyAction.rawValue,
                     OrthoMPRCrossHotKeyAction.rawValue:
                    if ViewerController.getToolEquivalent(toHotKey: Int32(key)).rawValue >= 0 {
                        var tool = ViewerController.getToolEquivalent(toHotKey: Int32(key))

                        if tool == .t2DPoint {
                            tool = .t3Dpoint
                        }

                        windowController?.setCurrentTool(tool)
                    }

                //tCross
                default:
                    returnedVal = false
                }
            } else {
                returnedVal = false
            }
        } else {
            returnedVal = false
        }

        return returnedVal
    }

    public override dynamic func mouseDraggedCrosshair(_ event: NSEvent!) {
        var eventLocation = event?.locationInWindow ?? NSZeroPoint
        if event?.type != .rightMouseDown {
            eventLocation = self.convert(eventLocation, from: nil)
            eventLocation = self.convert(fromNSView2GL: eventLocation)

            // [self isKindOfClass: [OrthogonalMPRView class]], which self is.
            self.setCrossPosition(Float(eventLocation.x), Float(eventLocation.y))

            self.needsDisplay = true
        }
    }

    public override dynamic func mouseDraggedImageScroll(_ event: NSEvent!) {
        let movie4Dmove = false
        let current = self.currentPoint(inView: event)
        let start = self.horos_start
        // The former prev and now were computed here and never read.
        if self.horos_scrollMode == 0 {
            if abs(start.x - current.x) < abs(start.y - current.y) {
                if abs(start.y - current.y) > 3 { self.horos_scrollMode = 1 }
            } else if abs(start.x - current.x) >= abs(start.y - current.y) {
                if abs(start.x - current.x) > 3 { self.horos_scrollMode = 2 }
            }

        //	NSLog(@"scrollMode : %d", scrollMode);
        }


        if movie4Dmove == false {
            var from: Int, to: Int
            if self.horos_scrollMode == 2 {
                from = cLong(Double(current.x))
                to = cLong(Double(start.x))
            } else if self.horos_scrollMode == 1 {
                from = cLong(Double(start.y))
                to = cLong(Double(current.y))
            } else {
                from = 0
                to = 0
            }

            // abs() of the int, which leaves INT_MIN negative.
            let difference = Int32(truncatingIfNeeded: from &- to)
            if (difference == Int32.min ? difference : abs(difference)) >= 1 {
                self.scrollTool(from, to)
            }
        }
    }

    public override dynamic func mouseDraggedBlending(_ event: NSEvent!) {
        super.mouseDraggedBlending(event)
        self.setWLWW(self.horos_curWL, self.horos_curWW)
        let blendingView = self.horos_blending
        blendingView?.setWLWW(blendingView?.curDCM?.wl ?? 0, blendingView?.curDCM?.ww ?? 0)
    }

    public override dynamic func mouseDraggedWindowLevel(_ event: NSEvent!) {
        let current = self.currentPoint(inView: event)
        let start = self.horos_start

        if self.horos_blending == nil {
            var WWAdapter = Float(Double(self.horos_startWW) / 100.0)

            if Double(WWAdapter) < 0.001 { WWAdapter = Float(0.001) }

            if self.is2DViewer() == true {
                messages(messages(self.windowController())?.thickSlabController())?.setLowQuality(true)
            }

            let dcmFilesList = self.horos_dcmFilesList
            if hasModality(dcmFilesList?.object(at: 0), "PT") || (UserDefaults.standard.bool(forKey: "mouseWindowingNM") == true && hasModality(dcmFilesList?.object(at: 0), "NM")) {
                var startlevel: Float
                var endlevel: Float

                var eWW: Float = 5, eWL: Float = 5

                switch UserDefaults.standard.integer(forKey: "PETWindowingMode") {
                case 0:
                    eWL = Float(Double(self.horos_startWL) + Double(current.y - start.y) * Double(WWAdapter))
                    eWW = Float(Double(self.horos_startWW) + Double(current.x - start.x) * Double(WWAdapter))

                    if Double(eWW) < 0.1 { eWW = Float(0.1) }

                case 1:
                    endlevel = Float(Double(self.horos_startMax) + Double(current.y - start.y) * Double(WWAdapter))

                    eWL = (endlevel - self.horos_startMin) / 2 + Float(UserDefaults.standard.integer(forKey: "PETMinimumValue"))
                    eWW = endlevel - self.horos_startMin

                    if Double(eWW) < 0.1 { eWW = Float(0.1) }
                    if eWL - eWW / 2 < 0 { eWL = eWW / 2 }

                case 2:
                    endlevel = Float(Double(self.horos_startMax) + Double(current.y - start.y) * Double(WWAdapter))
                    startlevel = Float(Double(self.horos_startMin) + Double(current.x - start.x) * Double(WWAdapter))

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
                self.curDCM?.changeWLWW(Float(Double(self.horos_startWL) + Double(current.y - start.y) * Double(WWAdapter)),
                                        Float(Double(self.horos_startWW) + Double(current.x - start.x) * Double(WWAdapter)))
            }

            self.horos_curWW = self.curDCM?.ww ?? 0
            self.horos_curWL = self.curDCM?.wl ?? 0

            if self.is2DViewer() == true {
                messages(self.windowController())?.setCurWLWWMenu(DCMView.findWLWWPreset(self.horos_curWL, self.horos_curWW, self.curDCM) as NSString?)
            }

            // change Window level
            self.setWLWW(self.horos_curWL, self.horos_curWW)


            NotificationCenter.default.post(name: NSNotification.Name.OsirixChangeWLWW, object: self.curDCM, userInfo: nil)

            if (self.curDCM?.suvConverted ?? false) == false {
                //set value for Series Object Presentation State
                self.seriesObj()?.setValue(NSNumber(value: self.horos_curWW), forKey: "windowWidth")
                self.seriesObj()?.setValue(NSNumber(value: self.curDCM?.storedWindowLevel(forCalibratedLevel: self.horos_curWL) ?? 0), forKey: "windowLevel")
            } else {
                if self.is2DViewer() == true {
                    let factorPET2SUV = messages(self.windowController())?.factorPET2SUV() ?? 0
                    self.seriesObj()?.setValue(NSNumber(value: self.horos_curWW / factorPET2SUV), forKey: "windowWidth")
                    self.seriesObj()?.setValue(NSNumber(value: self.curDCM?.storedWindowLevel(forCalibratedLevel: self.horos_curWL / factorPET2SUV) ?? 0), forKey: "windowLevel")
                }
            }
        }
        //Blending and OrthogonalMPRVIEW

        else {
            // change blending value
            self.horos_blendingFactor = Float(Double(self.horos_blendingFactorStart) + Double(current.x - start.x))

            if self.horos_blendingFactor < -256.0 { self.horos_blendingFactor = -256.0 }
            if self.horos_blendingFactor > 256.0 { self.horos_blendingFactor = 256.0 }

            self.setBlendingFactor(self.horos_blendingFactor)
        }

    }

    @IBAction public override dynamic func flipVertical(_ sender: Any!) {
        super.flipVertical(sender)
        _controller?.flipVertical(self)
    }

    @IBAction public override dynamic func flipHorizontal(_ sender: Any!) {
        super.flipHorizontal(sender)
        _controller?.flipHorizontal(self)
    }


    public override dynamic func acceptsFirstMouse(for theEvent: NSEvent?) -> Bool {
        return true
    }
}
