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
private let GL_POINTS: UInt32 = 0x0000
private let GL_LINE_LOOP: UInt32 = 0x0002
private let GL_POINT_SMOOTH: UInt32 = 0x0B10
private let GL_BLEND: UInt32 = 0x0BE2
private let GL_ONE: UInt32 = 1
private let GL_ONE_MINUS_SRC_ALPHA: UInt32 = 0x0303

// The static inline functions of ROICanvasGL.h, with the same parameter types.
private func roiBlendFunc(_ source: UInt32, _ destination: UInt32) { ROICanvas.current?.blend(source: source, destination: destination) }
private func roiEnable(_ cap: UInt32) { ROICanvas.current?.enable(cap) }
private func roiPointSize(_ s: Float) { ROICanvas.current?.pointSize(CGFloat(s)) }
private func roiLineWidth(_ w: Float) { ROICanvas.current?.lineWidth(CGFloat(w)) }
private func roiColor4d(_ r: Double, _ g: Double, _ b: Double, _ a: Double) {
    ROICanvas.current?.color(r: CGFloat(r), g: CGFloat(g), b: CGFloat(b), a: CGFloat(a))
}
private func roiBegin(_ mode: UInt32) { ROICanvas.current?.begin(mode) }
private func roiEnd() { ROICanvas.current?.end() }
private func roiVertex2f(_ x: Float, _ y: Float) { ROICanvas.current?.vertex(x: CGFloat(x), y: CGFloat(y)) }
private func roiLoadIdentity() { ROICanvas.current?.loadIdentity() }
private func roiScalef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.scale(x: Double(x), y: Double(y), z: Double(z)) }
private func roiTranslatef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.translate(x: Double(x), y: Double(y), z: Double(z)) }

/// A float converted to int as the arm64 code of the former C did (fcvtzs):
/// toward zero, saturated, NaN to 0; a Swift conversion traps instead.
private func cInt32(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483647.0 { return Int32.max }
    if x <= -2147483648.0 { return Int32.min }
    return Int32(x)
}

/// A double converted to NSUInteger as the arm64 code of the former C did
/// (fcvtzu): toward zero, saturated, negative and NaN to 0.
private func cUInt(_ x: Double) -> UInt {
    if x.isNaN || x <= 0 { return 0 }
    if x >= 18446744073709551615.0 { return UInt.max }
    return UInt(x)
}

/// The MIN and MAX macros of Foundation, which differ from Swift's min and max
/// when an operand is NaN.
private func cMin(_ a: CGFloat, _ b: CGFloat) -> CGFloat { return a < b ? a : b }
private func cMax(_ a: CGFloat, _ b: CGFloat) -> CGFloat { return a < b ? b : a }

/// -[DCMPix setArrayPix::] with the array itself. DCMPix keeps the array it is
/// given without retaining it; bridged to [Any], Swift would hand it a copy
/// that is released right after the call.
private func dcmPixSetArrayPix(_ pix: AnyObject, _ array: NSArray, _ i: Int16) {
    typealias Imp = @convention(c) (AnyObject, Selector, NSArray?, Int16) -> Void
    let selector = #selector(DCMPix.setArray(_:_:))
    let imp = unsafeBitCast(pix.method(for: selector), to: Imp.self)
    imp(pix, selector, array, i)
}

/// One of the three transverse sections (A, B, C) of the Curved MPR: a DCMView
/// showing the oblique slice across the curved path at its section's position.
///
/// Implemented in Swift since #824: the Objective-C name, the selectors and
/// <Horos/CPRTransverseView.h> are those of the former class, a custom view of
/// CPR.xib. Its superclass, DCMView, stays in Objective-C; the ivars it reads
/// of it go through DCMView+SwiftIvars.h.
@objc(CPRTransverseView)
public final class CPRTransverseView: DCMView {
    // MARK: - The former instance variables

    /// _delegate: assigned, not retained.
    private unowned(unsafe) var _delegate: CPRViewDelegate? = nil

    private var _curvedPath: CPRCurvedPath? = nil
    private var _displayInfo: CPRDisplayInfo? = nil
    private var _sectionType: Int = 0
    private var _sectionWidth: CGFloat = 0

    private var _volumeData: CPRVolumeData? = nil
    private var _generatedVolumeData: CPRVolumeData? = nil

    private var _lastRequest: CPRObliqueSliceGeneratorRequest? = nil
    private var _processingRequest = false
    private var _needsNewRequest = false

    private var _displayCrossLines = false
    private var _reformationDisplayStyle: Int = 0

    private var _renderingScale: CGFloat = 0

    private var previousScale: Float = 0

    private var stanStringAttrib: NSMutableDictionary? = nil

    // The former -dealloc only released _volumeData, _generatedVolumeData,
    // _curvedPath, _displayInfo, _lastRequest and stanStringAttrib: Swift
    // releases these properties.

    // MARK: - Properties

    @objc public dynamic var delegate: CPRViewDelegate? {
        get { return _delegate }
        set { _delegate = newValue }
    }

    /// Copied when set; a path whose sections differ asks for a new slice.
    /// The view holds a copy, so the identity test always passed and every
    /// path asked for one (#854); the sections are compared instead.
    @objc public dynamic var curvedPath: CPRCurvedPath! {
        get { return _curvedPath }
        set {
            let curvedPath = newValue
            if curvedPath !== _curvedPath {
                if (curvedPath?.thickness ?? 0) != (_curvedPath?.thickness ?? 0) {
                    self.needsDisplay = true
                }

                let sameSections: Bool
                if let curvedPath = curvedPath, let current = _curvedPath {
                    sameSections = curvedPath.hasSameTransverseSections(as: current)
                } else {
                    sameSections = curvedPath == nil && _curvedPath == nil
                }

                _curvedPath = curvedPath?.copy() as? CPRCurvedPath
                if sameSections == false {
                    self._setNeedsNewRequest()
                }
            }
        }
    }

    /// Copied when set, as the header declares it (#854); the setter
    /// retained, and the three transverse views shared the controller's.
    @objc public dynamic var displayInfo: CPRDisplayInfo! {
        get { return _displayInfo }
        set {
            let displayInfo = newValue
            if displayInfo !== _displayInfo {
                if (displayInfo?.mouseTransverseSection ?? 0) != (_displayInfo?.mouseTransverseSection ?? 0) ||
                    (displayInfo?.mouseTransverseSectionDistance ?? 0) != (_displayInfo?.mouseTransverseSectionDistance ?? 0) {
                    self.needsDisplay = true
                }
                _displayInfo = displayInfo?.copy() as? CPRDisplayInfo
            }
        }
    }

    @objc public dynamic var sectionType: Int {
        get { return _sectionType }
        set {
            if _sectionType != newValue {
                _sectionType = newValue
                self._setNeedsNewRequest()
            }
        }
    }

    /// The width to be displayed in mm.
    @objc public dynamic var sectionWidth: CGFloat {
        get { return _sectionWidth }
        set {
            if _sectionWidth != newValue {
                _sectionWidth = newValue
                self._setNeedsNewRequest()
            }
        }
    }

    @objc public dynamic var volumeData: CPRVolumeData! {
        get { return _volumeData }
        set {
            if newValue !== _volumeData {
                _volumeData = newValue
                self._setNeedsNewRequest()
            }
        }
    }

    @objc public dynamic var renderingScale: CGFloat {
        get { return _renderingScale }
        set {
            if _renderingScale != newValue {
                //		_sectionWidth = _sectionWidth; / (renderingScale/_renderingScale);

                _renderingScale = newValue

                self._setNeedsNewRequest()
            }
        }
    }

    @objc public dynamic var displayCrossLines: Bool {
        get { return _displayCrossLines }
        set {
            _displayCrossLines = newValue
            self.cprController?.updateToolbarItems()
        }
    }

    @objc public dynamic var reformationDisplayStyle: Int {
        get { return _reformationDisplayStyle }
        set {
            if newValue != _reformationDisplayStyle {
                _reformationDisplayStyle = newValue
                self.needsDisplay = true
            }
        }
    }

    // The properties of the former class extension.

    @objc(lastRequest) private dynamic var lastRequest: CPRObliqueSliceGeneratorRequest? {
        get { return _lastRequest }
        set { _lastRequest = newValue }
    }

    @objc(generatedVolumeData) private dynamic var generatedVolumeData: CPRVolumeData? {
        get { return _generatedVolumeData }
        set { _generatedVolumeData = newValue }
    }

    /// [self windowController], the CPRController of the view's window; nil
    /// messages as a message to nil did.
    private var cprController: CPRController? {
        return self.windowController() as? CPRController
    }

    // MARK: - Initializers

    /// The view is a custom view of CPR.xib, made with -initWithFrame:.
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        _renderingScale = 1
        _displayCrossLines = true
    }

    /// Passes through: the former class did not override it, and DCMView's
    /// -initWithFrame: sends it to self.
    public override init(frame frameRect: NSRect, imageRows rows: Int32, imageColumns columns: Int32) {
        super.init(frame: frameRect, imageRows: rows, imageColumns: columns)
    }

    /// Passes through: the former class did not override it.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // MARK: - Drawing

    public override func draw(_ r: NSRect) {
        let name = String(format: "transverse-%ld", self.sectionType)
        let lifecycle = self.cprController?.renderLifecycle
        let decision = lifecycle?.beginDraw(named: name)
        if lifecycle != nil, let decision = decision, decision.accepted == false {
            NSLog("CPR draw skipped: %@", decision.diagnosis)

            // Returning paints nothing, and nothing marks this view again: the
            // panel would stay blank. Only the nested pass is unwanted, so ask
            // for another one once the stack has unwound.
            if decision.phase == "reentrant" {
                DispatchQueue.main.async { self.needsDisplay = true }
            }
            return
        }
        _processingRequest = true
        var raised: NSException? = nil
        do {
            try HorosObjCException.perform {
                self._sendNewRequestIfNeeded()

                // The flag suppresses setNeedsDisplay: while the request is built.
                // Clear it before super draws, or a repaint asked for during the draw
                // is dropped for good - nothing marks the view a second time.
                self._processingRequest = false
                super.draw(r)
            }
        } catch {
            raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        }
        _processingRequest = false
        lifecycle?.endDraw(named: name)
        raised?.raise()
    }

    public override var needsDisplay: Bool {
        get { return super.needsDisplay }
        set {
            if CPRRenderLifecycle.shouldDisplaySynchronously(whileDrawing: _processingRequest) {
                super.needsDisplay = newValue
            }
        }
    }

    // MARK: - Events

    @objc(applyNewScaleValue) private dynamic func applyNewScaleValue() {
        if self.scaleValue != previousScale {
            self.renderingScale /= CGFloat(previousScale / self.scaleValue)

            _delegate?.cprTransverseViewDidChangeRenderingScale?(self)

            self._setNeedsNewRequest()
        }
    }

    public override func magnify(with anEvent: NSEvent!) {
        previousScale = self.scaleValue

        super.magnify(with: anEvent)
        self.cprController?.propagateOriginRotationAndZoom(toTransverseViews: self)

        self.applyNewScaleValue()
    }

    public override func rotate(with anEvent: NSEvent!) {
        super.rotate(with: anEvent)
        self.cprController?.propagateOriginRotationAndZoom(toTransverseViews: self)
    }

    public override func mouseDraggedZoom(_ event: NSEvent!) {
        let copyMouseClickZoomCentered = UserDefaults.standard.bool(forKey: "MouseClickZoomCentered")

        UserDefaults.standard.set(false, forKey: "MouseClickZoomCentered")

        super.mouseDraggedZoom(event)

        UserDefaults.standard.set(copyMouseClickZoomCentered, forKey: "MouseClickZoomCentered")

        self.cprController?.propagateOriginRotationAndZoom(toTransverseViews: self)
    }

    public override func rightMouseDown(with event: NSEvent) {
        previousScale = self.scaleValue
        super.rightMouseDown(with: event)
    }

    public override func mouseDown(with event: NSEvent) {
        previousScale = self.scaleValue

        var clickCount: Int32 = 1

        do {
            try HorosObjCException.perform {
                if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .leftMouseUp || event.type == .rightMouseUp {
                    clickCount = Int32(truncatingIfNeeded: event.clickCount)
                }
            }
        } catch {
            clickCount = 1
        }

        if clickCount == 2 {
            var tempPt = self.convert(event.locationInWindow, from: nil)
            tempPt = self.convert(fromNSView2GL: tempPt)

            let windowController = self.cprController

            let tool = self.getTool(event)

            if self.roiTool(tool) && self.click(inROI: tempPt) != nil {
                self.cprController?.roiGetInfo(self)
            } else if frameZoomed.boolValue == false {
                splitPosition.0 = cInt32(Double((windowController?.mprView1?.frame.origin.x ?? 0) + (windowController?.mprView1?.frame.size.width ?? 0)))	// vert
                splitPosition.1 = cInt32(Double((windowController?.mprView1?.frame.origin.y ?? 0) + (windowController?.mprView1?.frame.size.height ?? 0)))	// hori12
                splitPosition.2 = cInt32(Double((windowController?.mprView3?.frame.origin.y ?? 0) + (windowController?.mprView3?.frame.size.height ?? 0)))	// horiz2

                frameZoomed = ObjCBool(true)

                windowController?.verticalSplit?.setPosition(windowController?.verticalSplit?.minPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)
                windowController?.horizontalSplit1?.setPosition(windowController?.horizontalSplit1?.minPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)
                windowController?.horizontalSplit2?.setPosition(windowController?.horizontalSplit2?.minPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)
            } else {
                frameZoomed = ObjCBool(false)
                windowController?.verticalSplit?.setPosition(CGFloat(splitPosition.0), ofDividerAt: 0)
                windowController?.horizontalSplit1?.setPosition(CGFloat(splitPosition.1), ofDividerAt: 0)
                windowController?.horizontalSplit2?.setPosition(CGFloat(splitPosition.2), ofDividerAt: 0)
            }
        } else {
            super.mouseDown(with: event)
        }
    }

    public override func rightMouseUp(with event: NSEvent) {
        super.rightMouseUp(with: event)
        self.applyNewScaleValue()
    }

    public override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        self.applyNewScaleValue()
    }

    @objc(pixelsPerMm) public dynamic func pixelsPerMm() -> Float {
        return Float(CGFloat(self.curDCM?.pwidth ?? 0) / (_sectionWidth / _renderingScale))
    }

    public override func mouseMoved(with theEvent: NSEvent) {
        let view = theEvent.window?.contentView?.hitTest(theEvent.locationInWindow)
        var viewPoint: NSPoint
        var pixVector: N3Vector
        var line: N3Line
        var newMouseTransverseSectionType: Int
        var newMouseTransverseSectionDistance: CGFloat
        var pixelsPerMm: CGFloat

        if view === self {
            viewPoint = self.convert(theEvent.locationInWindow, from: nil)

            if NSPointInRect(viewPoint, self.bounds) && (self.curDCM?.pwidth ?? 0) > 0 {
                pixVector = N3VectorApplyTransform(N3VectorMakeFromNSPoint(viewPoint), self.viewToPixTransform())
                pixelsPerMm = CGFloat(self.pixelsPerMm())

                line = N3LineMake(N3VectorMake(CGFloat(self.curDCM?.pwidth ?? 0) / 2.0, 0, 0), N3VectorMake(0, 1, 0))
                line = N3LineApplyTransform(line, N3AffineTransformInvert(self.viewToPixTransform()))

                if N3VectorDistanceToLine(N3VectorMakeFromNSPoint(viewPoint), line) < 20.0 {
                    newMouseTransverseSectionType = _sectionType
                    newMouseTransverseSectionDistance = (pixVector.y - CGFloat(self.curDCM?.pheight ?? 0) / 2.0) / pixelsPerMm
                } else {
                    newMouseTransverseSectionType = Int(CPRTransverseViewNoneSectionType.rawValue)
                    newMouseTransverseSectionDistance = 0
                }

                if (_displayInfo?.mouseTransverseSection ?? 0) != newMouseTransverseSectionType ||
                    (_displayInfo?.mouseTransverseSectionDistance ?? 0) != newMouseTransverseSectionDistance {
                    _delegate?.cprViewWillEditDisplayInfo?(self)
                    _displayInfo?.mouseTransverseSection = newMouseTransverseSectionType
                    _displayInfo?.mouseTransverseSectionDistance = newMouseTransverseSectionDistance
                    _delegate?.cprViewDidEditDisplayInfo?(self)
                }
            }

            super.mouseMoved(with: theEvent)
        } else {
            view?.mouseMoved(with: theEvent)
        }
    }

    public override func mouseExited(with theEvent: NSEvent) {
        _delegate?.cprViewWillEditDisplayInfo?(self)
        _displayInfo?.mouseTransverseSection = Int(CPRTransverseViewNoneSectionType.rawValue)
        _displayInfo?.mouseTransverseSectionDistance = 0
        _delegate?.cprViewDidEditDisplayInfo?(self)
        self.needsDisplay = true

        super.mouseExited(with: theEvent)
    }

    public override func mouseDraggedTranslate(_ event: NSEvent!) {
        super.mouseDraggedTranslate(event)
        self.cprController?.propagateOriginRotationAndZoom(toTransverseViews: self)
    }

    public override func mouseDraggedRotate(_ event: NSEvent!) {
        super.mouseDraggedRotate(event)
        self.cprController?.propagateOriginRotationAndZoom(toTransverseViews: self)
    }

    public override func mouseDraggedWindowLevel(_ event: NSEvent!) {
        super.mouseDraggedWindowLevel(event)
        self.cprController?.propagateWLWW(self)
    }

    public override var frame: NSRect {
        get { return super.frame }
        set {
            var needsUpdate: Bool

            needsUpdate = false
            if NSEqualRects(newValue, self.frame) == false {
                needsUpdate = true
            }

            super.frame = newValue

            if needsUpdate {
                self._setNeedsNewRequest()
            }
        }
    }

    public override func scrollWheel(with theEvent: NSEvent) {
        if theEvent.modifierFlags.contains(.command) {
            let transverseSectionSpacing = cMin(cMax((_curvedPath?.transverseSectionSpacing ?? 0) + theEvent.deltaY * 0.4, 0.0), 300)

            _delegate?.cprViewWillEditCurvedPath?(self)

            _curvedPath?.transverseSectionSpacing = transverseSectionSpacing

            _delegate?.cprViewDidEditCurvedPath?(self)

            self._setNeedsNewRequest()
        } else {
            var transverseSectionPosition: CGFloat

            transverseSectionPosition = cMin(cMax((_curvedPath?.transverseSectionPosition ?? 0) + theEvent.deltaY * 0.002, 0.0), 1.0)

            _delegate?.cprViewWillEditCurvedPath?(self)
            _curvedPath?.transverseSectionPosition = transverseSectionPosition
            _delegate?.cprViewDidEditCurvedPath?(self)
            self._setNeedsNewRequest()
        }
    }

    public override func drawFrame(_ aRect: NSRect) {
        let clutBars = Int(CLUTBARS), annotations = Int(self.horos_annotationType)

        CLUTBARS = Int32(barHide)

        if self.horos_annotationType > Int32(annotGraphics) {
            self.horos_annotationType = Int32(annotGraphics)
        }

        let rArray: NSMutableArray? = self.curRoiList

        // [rArray retain], balanced by the autorelease below.
        if let rArray = rArray { _ = Unmanaged.passUnretained(rArray).retain() }

        var i = 0
        while i < (rArray?.count ?? 0) {
            let r = rArray!.object(at: i) as! ROI

            r.displayCMOrPixels = true // We don't want the value in pixels
            r.imageOrigin = NSMakePoint(CGFloat(self.curDCM?.originX ?? 0), CGFloat(self.curDCM?.originY ?? 0))

            if r.type == .t3Dpoint || r.type == .t2DPoint {
                NotificationCenter.default.post(name: NSNotification.Name.OsirixRemoveROI, object: r, userInfo: nil)
                rArray!.removeObject(at: i)
                i -= 1
            }
            i += 1
        }

        if let rArray = rArray { _ = Unmanaged.passUnretained(rArray).autorelease() }

        super.drawFrame(aRect)

        CLUTBARS = Int32(truncatingIfNeeded: clutBars)
        self.horos_annotationType = Int32(truncatingIfNeeded: annotations)
    }

    public override func subDraw(_ rect: NSRect) {
        var cursorVector: N3Vector
        var pixToSubDrawRectTransform: N3AffineTransform
        var pixelsPerMm: CGFloat

        pixelsPerMm = CGFloat(self.pixelsPerMm())
        pixToSubDrawRectTransform = self.pixToSubDrawRectTransform()

        // Dont display cross lines on transverse views, to keep coherence with streched mode
        //	if( displayCrossLines && _reformationDisplayStyle == CPRTransverseViewStraightenedReformationDisplayStyle)
        //	{
        //		roiColor4d(1.0, 1.0, 0.0, 1.0);
        //		lineStart = N3VectorApplyTransform(N3VectorMake((CGFloat)self.curDCM.pwidth/2.0, 0, 0), pixToSubDrawRectTransform);
        //		lineEnd = N3VectorApplyTransform(N3VectorMake((CGFloat)self.curDCM.pwidth/2.0, self.curDCM.pheight, 0), pixToSubDrawRectTransform);
        //		roiLineWidth(1.0 * self.window.backingScaleFactor);
        //		roiBegin(GL_LINE_STRIP);
        //		roiVertex2f(lineStart.x, lineStart.y);
        //		roiVertex2f(lineEnd.x, lineEnd.y);
        //		roiEnd();
        //
        //		if (_curvedPath.thickness > 2.0)
        //		{
        //			roiLineWidth(1.0 * self.window.backingScaleFactor);
        //			roiBegin(GL_LINES);
        //			lineStart = N3VectorApplyTransform(N3VectorMake(((CGFloat)self.curDCM.pwidth+_curvedPath.thickness*pixelsPerMm)/2.0, 0, 0), pixToSubDrawRectTransform);
        //			lineEnd = N3VectorApplyTransform(N3VectorMake(((CGFloat)self.curDCM.pwidth+_curvedPath.thickness*pixelsPerMm)/2.0, self.curDCM.pheight, 0), pixToSubDrawRectTransform);
        //			roiVertex2f(lineStart.x, lineStart.y);
        //			roiVertex2f(lineEnd.x, lineEnd.y);
        //			lineStart = N3VectorApplyTransform(N3VectorMake(((CGFloat)self.curDCM.pwidth-_curvedPath.thickness*pixelsPerMm)/2.0, 0, 0), pixToSubDrawRectTransform);
        //			lineEnd = N3VectorApplyTransform(N3VectorMake(((CGFloat)self.curDCM.pwidth-_curvedPath.thickness*pixelsPerMm)/2.0, self.curDCM.pheight, 0), pixToSubDrawRectTransform);
        //			roiVertex2f(lineStart.x, lineStart.y);
        //			roiVertex2f(lineEnd.x, lineEnd.y);
        //			roiEnd();
        //		}
        //	}

        if (self.cprController?.displayMousePosition ?? false) == true && (_displayInfo?.mouseTransverseSection ?? 0) == _sectionType {
            cursorVector = N3VectorMake(CGFloat(self.curDCM?.pwidth ?? 0) / 2.0, (CGFloat(self.curDCM?.pheight ?? 0) / 2.0) + ((_displayInfo?.mouseTransverseSectionDistance ?? 0) * pixelsPerMm), 0)
            cursorVector = N3VectorApplyTransform(cursorVector, pixToSubDrawRectTransform)

            roiColor4d(1.0, 1.0, 0.0, 1.0)
            roiEnable(GL_POINT_SMOOTH)
            roiPointSize(Float(8 * (self.window?.backingScaleFactor ?? 0)))
            roiBegin(GL_POINTS)
            roiVertex2f(Float(cursorVector.x), Float(cursorVector.y))
            roiEnd()
        }

        let drawingFrameRect = self.drawingFrameRect

        // Red Square
        if self.window?.firstResponder === self && self.stringID == nil {
            roiLoadIdentity() // reset model view matrix to identity (eliminates rotation basically)
            roiScalef(Float(2.0 / (self.xFlipped ? -(drawingFrameRect.size.width) : drawingFrameRect.size.width)), Float(-2.0 / (self.yFlipped ? -(drawingFrameRect.size.height) : drawingFrameRect.size.height)), 1.0) // scale to port per pixel scale

            roiColor4d(1.0, 0, 0.0, 1.0)

            let heighthalf = Float(drawingFrameRect.size.height / 2)
            let widthhalf = Float(drawingFrameRect.size.width / 2)

            roiLineWidth(Float(8.0 * (self.window?.backingScaleFactor ?? 0)))
            roiBegin(GL_LINE_LOOP)
            roiVertex2f(-widthhalf, -heighthalf)
            roiVertex2f(-widthhalf, heighthalf)
            roiVertex2f(widthhalf, heighthalf)
            roiVertex2f(widthhalf, -heighthalf)
            roiEnd()
        }

        if stanStringAttrib == nil {
            stanStringAttrib = NSMutableDictionary()
            // Sent as messages, so that a nil font raises as -setObject:forKey: did.
            _ = stanStringAttrib?.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: NSFont(name: "Helvetica", size: 14.0), with: NSAttributedString.Key.font.rawValue)
            _ = stanStringAttrib?.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: NSColor.white, with: NSAttributedString.Key.foregroundColor.rawValue)
        }

        var textValue: String? = nil
        switch _sectionType {
        case Int(CPRTransverseViewCenterSectionType.rawValue): textValue = "B"
        case Int(CPRTransverseViewLeftSectionType.rawValue): textValue = "A"
        case Int(CPRTransverseViewRightSectionType.rawValue): textValue = "C"
        default: break
        }
        let label: AnnotationText? = textValue != nil ? self.horosLabelText(textValue, font: stanStringAttrib?.object(forKey: NSAttributedString.Key.font.rawValue) as? NSFont) : nil

        roiLoadIdentity() // reset model view matrix to identity (eliminates rotation basically)
        roiScalef(Float(2.0 / (self.xFlipped ? -(drawingFrameRect.size.width) : drawingFrameRect.size.width)), Float(-2.0 / (self.yFlipped ? -(drawingFrameRect.size.height) : drawingFrameRect.size.height)), 1.0) // scale to port per pixel scale

        roiEnable(GL_BLEND)
        roiBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)

        let anchor = NSMakePoint(drawingFrameRect.size.width / -2.0, drawingFrameRect.size.height / -2.0)

        self.horosDrawLabel(label, at: anchor, textColor: NSColor(deviceRed: 1, green: 1, blue: 0, alpha: 1),
                            shadowColor: NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1))

        if self.annotationType != Int32(annotNone) {
            roiLoadIdentity() // reset model view matrix to identity (eliminates rotation basically)
            roiScalef(Float(2.0 / drawingFrameRect.size.width), Float(-2.0 / drawingFrameRect.size.height), 1.0) // scale to port per pixel scale
            roiTranslatef(Float(-(drawingFrameRect.size.width) / 2.0), Float(-(drawingFrameRect.size.height) / 2.0), 0.0) // translate center to upper left

            self.drawOrientation(drawingFrameRect)
        }
    }

    // MARK: - Slice generation

    /// In case we want to go back to using an async-generator for some reason,
    /// we will keep this function around like this.
    @objc(generator:didGenerateVolume:request:)
    private dynamic func generator(_ generator: CPRGenerator?, didGenerateVolume volume: CPRVolumeData?, request: CPRGeneratorRequest?) {
        if self.windowController() == nil {
            return
        }

        // +[NSArchiver archivedDataWithRootObject:] sent as a message: curRoiList
        // may be nil, which Swift cannot pass to it directly.
        let previousROIs = (NSArchiver.self as AnyObject).perform(#selector(NSArchiver.archivedData(withRootObject:)), with: self.curRoiList)?.takeUnretainedValue() as? Data
        var inlineBuffer = CPRVolumeDataInlineBuffer()
        var newPix: DCMPix?

        // make sure this is around long enough so that it doesn't disapear under the old DCMPix
        if let generatedVolumeData = self.generatedVolumeData { _ = Unmanaged.passRetained(generatedVolumeData).autorelease() }
        self.generatedVolumeData = volume

        let pixArray = NSMutableArray()

        var i: Int32 = 0
        while UInt(i) < (self.generatedVolumeData?.pixelsDeep ?? 0) {
            // A plane whose buffer cannot be had is left out (#854): an empty
            // DCMPix took its place, and a buffer never acquired was released.
            guard self.generatedVolumeData?.aquireInlineBuffer(&inlineBuffer) ?? false else {
                NSLog("CPRTransverseView: no data for plane %d of the generated volume", i)
                i += 1
                continue
            }
            let pixelsWide = self.generatedVolumeData?.pixelsWide ?? 0
            let pixelsHigh = self.generatedVolumeData?.pixelsHigh ?? 0
            let pixelSpacingX = self.generatedVolumeData?.pixelSpacingX ?? 0
            let pixelSpacingY = self.generatedVolumeData?.pixelSpacingY ?? 0
            let floatBytes = CPRVolumeDataFloatBytes(&inlineBuffer).map { UnsafeMutablePointer(mutating: $0) + Int(bitPattern: UInt(i) &* pixelsWide &* pixelsHigh) }
            newPix = DCMPix(data: floatBytes, 32,
                            Int(bitPattern: pixelsWide), Int(bitPattern: pixelsHigh), Float(pixelSpacingX), Float(pixelSpacingY),
                            Float(-pixelSpacingX * CGFloat(pixelsWide) / 2.0),
                            Float(-pixelSpacingY * CGFloat(pixelsHigh) / 2.0),
                            0,
                            false)

            self.generatedVolumeData?.releaseInlineBuffer(&inlineBuffer)
            newPix?.displayInverted = self.cprController?.originalPix?.displayInverted ?? false

            var orientation = [Float](repeating: 0, count: 6)
            self.generatedVolumeData?.getOrientation(&orientation)
            newPix?.setOrientation(&orientation)

            // Sent as a message, so that a nil pix raises as -addObject: did.
            _ = pixArray.perform(#selector(NSMutableArray.add(_:)), with: newPix)
            i += 1
        }

        if pixArray.count != 0 {
            var j: Int32 = 0
            while UInt(j) < UInt(pixArray.count) {
                dcmPixSetArrayPix(pixArray.object(at: Int(j)) as AnyObject, pixArray, Int16(truncatingIfNeeded: j))
                j += 1
            }

            self.setPixels(pixArray, files: nil, rois: nil, firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: true)
            self.setScaleValueCentered(1)

            self.cprController?.propagateWLWW(self.cprController?.mprView1)

            let roiArray = previousROIs.flatMap { NSUnarchiver.unarchiveObject(with: $0) } as? NSArray
            for object in roiArray ?? NSArray() {
                let r = object as! ROI
                r.pix = self.curDCM
                r.setOriginAndSpacing(Float(self.curDCM?.pixelSpacingX ?? 0), Float(self.curDCM?.pixelSpacingY ?? 0), NSMakePoint(CGFloat(self.curDCM?.originX ?? 0), CGFloat(self.curDCM?.originY ?? 0)), false, false)
                r.curView = self
            }

            self.curRoiList?.addObjects(from: (roiArray as? [Any]) ?? [])
        }
        self.needsDisplay = true
    }

    /// Since we don't generate these asynchronously anymore, should we really
    /// have all this _sendNewRequest business?
    @objc(_sendNewRequest) private dynamic func _sendNewRequest() {
        var request: CPRObliqueSliceGeneratorRequest
        var subdividedAndFlattenedBezierPath: N3MutableBezierPath?
        var vector: N3Vector
        var normal: N3Vector
        var tangent: N3Vector
        var cross: N3Vector
        var mmPerPixel: CGFloat

        if (_curvedPath?.bezierPath?.elementCount() ?? 0) >= 3 {
            subdividedAndFlattenedBezierPath = _curvedPath?.bezierPath?.mutableCopy() as? N3MutableBezierPath
            subdividedAndFlattenedBezierPath?.subdivide(N3BezierDefaultSubdivideSegmentLength)
            subdividedAndFlattenedBezierPath?.flatten(N3BezierDefaultFlatness)
            vector = subdividedAndFlattenedBezierPath?.vector(atRelativePosition: self._relativeSegmentPosition()) ?? N3Vector()
            tangent = subdividedAndFlattenedBezierPath?.tangent(atRelativePosition: self._relativeSegmentPosition()) ?? N3Vector()
            normal = subdividedAndFlattenedBezierPath?.normal(atRelativePosition: self._relativeSegmentPosition(), initialNormal: _curvedPath?.initialNormal ?? N3Vector()) ?? N3Vector()
            subdividedAndFlattenedBezierPath = nil

            cross = N3VectorNormalize(N3VectorCrossProduct(tangent, normal))

            // * 1.4 : to full the view area, if the matrix is rotated
            mmPerPixel = (_sectionWidth / _renderingScale) / (self.convertToBacking(self.bounds.size).width * 1.4)

            request = CPRObliqueSliceGeneratorRequest(center: vector, pixelsWide: cUInt(Double(self.convertToBacking(self.bounds.size).width * 1.4)), pixelsHigh: cUInt(Double(self.convertToBacking(self.bounds.size).height * 1.4)), xBasis: N3VectorScalarMultiply(cross, mmPerPixel), yBasis: N3VectorScalarMultiply(normal, mmPerPixel))

            request.interpolationMode = self.cprController?.selectedInterpolationMode ?? 0

            if (_lastRequest?.isEqual(request) ?? false) == false {
                var curvedVolume: CPRVolumeData?
                curvedVolume = CPRGenerator.synchronousRequestVolume(request, volumeData: _volumeData)
                self.generator(nil, didGenerateVolume: curvedVolume, request: request)
                self.lastRequest = request
            }
        } else {
            self.setPixels(nil, files: nil, rois: nil, firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: true)
        }

        _needsNewRequest = false
    }

    @objc(_relativeSegmentPosition) private dynamic func _relativeSegmentPosition() -> CGFloat {
        switch _sectionType {
        case Int(CPRTransverseViewLeftSectionType.rawValue):
            return _curvedPath?.leftTransverseSectionPosition ?? 0
        case Int(CPRTransverseViewCenterSectionType.rawValue):
            return _curvedPath?.transverseSectionPosition ?? 0
        case Int(CPRTransverseViewRightSectionType.rawValue):
            return _curvedPath?.rightTransverseSectionPosition ?? 0
        default:
            assert(false)
        }
        return 0
    }

    @objc(_setNeedsNewRequest) public dynamic func _setNeedsNewRequest() {
        _needsNewRequest = true
        self.needsDisplay = true

        //	if (_needsNewRequest == NO) {
        //		[self performSelector:@selector(_sendNewRequestIfNeeded) withObject:nil afterDelay:0 inModes:[NSArray arrayWithObject:NSRunLoopCommonModes]];
        //	}
        //    _needsNewRequest = YES;
    }

    @objc(_sendNewRequestIfNeeded) private dynamic func _sendNewRequestIfNeeded() {
        if _needsNewRequest {
            self._sendNewRequest()
        }
    }
}
