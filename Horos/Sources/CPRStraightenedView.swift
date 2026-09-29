/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)

 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.

 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.

 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.

 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html

 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
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
private let GL_LINES: UInt32 = 0x0001
private let GL_LINE_LOOP: UInt32 = 0x0002
private let GL_LINE_STRIP: UInt32 = 0x0003
private let GL_POINT_SMOOTH: UInt32 = 0x0B10
private let GL_LINE_SMOOTH: UInt32 = 0x0B20
private let GL_POLYGON_SMOOTH: UInt32 = 0x0B41
private let GL_BLEND: UInt32 = 0x0BE2
private let GL_ONE: UInt32 = 1
private let GL_SRC_ALPHA: UInt32 = 0x0302
private let GL_ONE_MINUS_SRC_ALPHA: UInt32 = 0x0303
private let GL_MODELVIEW: UInt32 = 0x1700

// The static inline functions of ROICanvasGL.h, with the same parameter types.
private func roiBlendFunc(_ source: UInt32, _ destination: UInt32) { ROICanvas.current?.blend(source: source, destination: destination) }
private func roiEnable(_ cap: UInt32) { ROICanvas.current?.enable(cap) }
private func roiDisable(_ cap: UInt32) { ROICanvas.current?.disable(cap) }
private func roiPointSize(_ s: Float) { ROICanvas.current?.pointSize(CGFloat(s)) }
private func roiLineWidth(_ w: Float) { ROICanvas.current?.lineWidth(CGFloat(w)) }
private func roiColor4f(_ r: Float, _ g: Float, _ b: Float, _ a: Float) {
    ROICanvas.current?.color(r: CGFloat(r), g: CGFloat(g), b: CGFloat(b), a: CGFloat(a))
}
private func roiColor4d(_ r: Double, _ g: Double, _ b: Double, _ a: Double) {
    ROICanvas.current?.color(r: CGFloat(r), g: CGFloat(g), b: CGFloat(b), a: CGFloat(a))
}
private func roiBegin(_ mode: UInt32) { ROICanvas.current?.begin(mode) }
private func roiEnd() { ROICanvas.current?.end() }
private func roiVertex2f(_ x: Float, _ y: Float) { ROICanvas.current?.vertex(x: CGFloat(x), y: CGFloat(y)) }
private func roiVertex2d(_ x: Double, _ y: Double) { ROICanvas.current?.vertex(x: CGFloat(x), y: CGFloat(y)) }
private func roiLoadIdentity() { ROICanvas.current?.loadIdentity() }
private func roiScalef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.scale(x: Double(x), y: Double(y), z: Double(z)) }
private func roiTranslatef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.translate(x: Double(x), y: Double(y), z: Double(z)) }
private func roiMatrixMode(_ mode: UInt32) {}
private func roiPushMatrix() { ROICanvas.current?.pushMatrix() }
private func roiPopMatrix() { ROICanvas.current?.popMatrix() }
private func roiMultMatrixd(_ m: UnsafePointer<Double>) { ROICanvas.current?.mult(m) }

/// assert() of the Objective-C: checked in Debug only.
@inline(__always)
private func debugAssert(_ condition: @autoclosure () -> Bool) {
    #if DEBUG
    precondition(condition())
    #endif
}

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

/// The MIN and MAX macros of the C, which keep their NaN behaviour.
private func cMIN(_ a: CGFloat, _ b: CGFloat) -> CGFloat { return a < b ? a : b }
private func cMAX(_ a: CGFloat, _ b: CGFloat) -> CGFloat { return a > b ? a : b }

/// The CPRTransverseViewSectionType values of CPRTransverseView.h, as the Int of
/// CPRDisplayInfo.mouseTransverseSection.
private let noneSectionType = Int(CPRTransverseViewNoneSectionType.rawValue)
private let centerSectionType = Int(CPRTransverseViewCenterSectionType.rawValue)
private let leftSectionType = Int(CPRTransverseViewLeftSectionType.rawValue)
private let rightSectionType = Int(CPRTransverseViewRightSectionType.rawValue)

/// -[DCMPix setArrayPix::] sent with the NSArray itself: DCMPix keeps the array
/// it gets without retaining it, so it must be the list the view keeps, not the
/// copy that bridging to [Any] would pass.
private func sendSetArrayPix(_ pix: AnyObject, _ array: NSArray, _ i: Int16) {
    typealias SetArrayPix = @convention(c) (AnyObject, Selector, NSArray, Int16) -> Void
    let selector = NSSelectorFromString("setArrayPix::")
    let imp = (pix as! NSObject).method(for: selector)
    unsafeBitCast(imp, to: SetArrayPix.self)(pix, selector, array, i)
}

/// A run of columns of the straightened image where a plane crosses it.
private final class _CPRStraightenedViewPlaneRun: NSObject {
    var range = NSRange(location: 0, length: 0)
    var distances: NSMutableArray! = NSMutableArray()
}

/// -[N3BezierPath initWithCPRStraightenedViewPlaneRun:heightPixelsPerMm:] of the
/// former category, which returned a new N3MutableBezierPath in place of the
/// receiver it autoreleased.
private func mutableBezierPath(withCPRStraightenedViewPlaneRun planeRun: _CPRStraightenedViewPlaneRun, heightPixelsPerMm pixelsPerMm: CGFloat) -> N3MutableBezierPath? {
    let mutableBezierPath = N3MutableBezierPath()
    var i = planeRun.range.location
    while i < NSMaxRange(planeRun.range) {
        if i == planeRun.range.location {
            mutableBezierPath?.move(to: N3VectorMake(CGFloat(i), CGFloat((planeRun.distances.object(at: i - planeRun.range.location) as AnyObject).doubleValue) * pixelsPerMm, 0))
        } else {
            mutableBezierPath?.line(to: N3VectorMake(CGFloat(i), CGFloat((planeRun.distances.object(at: i - planeRun.range.location) as AnyObject).doubleValue) * pixelsPerMm, 0))
        }
        i += 1
    }

    return mutableBezierPath
}

/// The straightened CPR: the curved path unrolled along its length, with the
/// transverse section lines, the planes of the three MPR views and the nodes.
///
/// Implemented in Swift since #824: the Objective-C name, the selectors and
/// <Horos/CPRStraightenedView.h> are those of the former class. Its superclass,
/// DCMView, stays in Objective-C; the ivars it reads of it go through
/// DCMView+SwiftIvars.h.
@objc(CPRStraightenedView)
public final class CPRStraightenedView: DCMView, CPRGeneratorDelegate {
    // MARK: - The former instance variables

    /// _delegate: assigned, not retained.
    private unowned(unsafe) var _delegate: CPRViewDelegate? = nil

    private var _volumeData: CPRVolumeData? = nil
    private var _generator: CPRGenerator? = nil

    private var _curvedPath: CPRCurvedPath? = nil
    private var _displayInfo: CPRDisplayInfo? = nil

    private var _planes: NSMutableDictionary? = nil
    private var _slabThicknesses: NSMutableDictionary? = nil
    private var _verticalLines: NSMutableDictionary? = nil
    private var _planeRuns: NSMutableDictionary? = nil
    private var _planeColors: NSMutableDictionary? = nil

    private var _clippingRangeMode: CPRViewClippingRangeMode = 0

    private var _curvedVolumeData: CPRVolumeData? = nil

    private var _lastRequest: CPRStraightenedGeneratorRequest? = nil
    private var _straightenedSession: CPRStraightenedSession? = nil
    private var _generatedHeight: CGFloat = 0

    private var _draggingTransverse = false
    private var _draggingTransverseSpacing = false
    private var _clickedNode = false
    /// The display info stores on what plane and where in 3D the mouse position
    /// dots are, but we want to cache where the dots should be drawn in this view.
    private var _mousePlanePointsInPix: NSMutableDictionary? = nil

    private var _editingCurvedPathCount: Int = 0

    private var _drawAllNodes = false

    /// Synchronous new image requests are generated in drawRect, but code that
    /// handles the new image calls setNeedsDisplay, so this variable is used to
    /// short circuit setNeedsDisplay while the image is being generated.
    private var _processingRequest = false
    private var _needsNewRequest = false

    private var _displayCrossLines = false
    private var _displayTransverseLines = false

    private var stanStringAttrib: NSMutableDictionary? = nil

    /// [self windowController], a CPRController.
    private var cprWindowController: CPRController? {
        return self.windowController() as? CPRController
    }

    /// [self window].backingScaleFactor, 0 without a window.
    private var backingScaleFactor: CGFloat {
        return self.window?.backingScaleFactor ?? 0
    }

    /// self.curDCM.pwidth and pheight, 0 without a pix.
    private var curPWidth: Int {
        return self.curDCM?.pwidth ?? 0
    }

    private var curPHeight: Int {
        return self.curDCM?.pheight ?? 0
    }

    /// [_curvedPath.bezierPath length], 0 without a path.
    private var curvedPathLength: CGFloat {
        return _curvedPath?.bezierPath?.length() ?? 0
    }

    // MARK: - Initialization

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        _planes = NSMutableDictionary()
        _slabThicknesses = NSMutableDictionary()
        _verticalLines = NSMutableDictionary()
        _planeRuns = NSMutableDictionary()
        _planeColors = NSMutableDictionary()
        _mousePlanePointsInPix = NSMutableDictionary()
        _displayCrossLines = false
        _displayTransverseLines = true

        NotificationCenter.default.addObserver(self, selector: #selector(_osirixUpdateVolumeDataNotification(_:)), name: NSNotification.Name.OsirixUpdateVolumeData, object: nil)
    }

    /// Not overridden by the former class: DCMView's -initWithFrame: sends it.
    public override init(frame frameRect: NSRect, imageRows rows: Int32, imageColumns columns: Int32) {
        super.init(frame: frameRect, imageRows: rows, imageColumns: columns)
    }

    /// Not overridden by the former class.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        _generator?.delegate = nil
        // _generator, _volumeData, _curvedVolumeData, _curvedPath, _displayInfo,
        // _lastRequest, _straightenedSession, the plane dictionaries,
        // _mousePlanePointsInPix and stanStringAttrib: Swift releases them.

        self._clearAllPlanes()
    }

    /// The plane, slab thickness and plane color accessors of any plane name
    /// (orangePlane, setPurpleSlabThickness:, bluePlaneColor...), added on demand.
    /// The former proxies read the plane name in _cmd; here each added
    /// implementation carries the name of the selector it was added for.
    public override class func resolveInstanceMethod(_ selector: Selector!) -> Bool {
        var methodName: NSString
        var imp: IMP? = nil
        var typeEncoding: UnsafePointer<CChar>?
        var proxySelector: Selector?

        methodName = NSStringFromSelector(selector) as NSString
        proxySelector = nil

        if methodName.hasPrefix("get") == false && methodName.hasPrefix("set") == false {
            if methodName.hasSuffix("Plane") {
                proxySelector = #selector(_planeGetter)
            } else if methodName.hasSuffix("SlabThickness") {
                proxySelector = #selector(_slabThicknessGetter)
            } else if methodName.hasSuffix("PlaneColor") {
                proxySelector = #selector(_planeColorGetter)
            }
        } else if methodName.hasPrefix("set") {
            if methodName.hasSuffix("Plane:") {
                proxySelector = #selector(_planeSetter(_:))
            } else if methodName.hasSuffix("SlabThickness:") {
                proxySelector = #selector(_slabThicknessSetter(_:))
            } else if methodName.hasSuffix("PlaneColor:") {
                proxySelector = #selector(_planeColorSetter(_:))
            }
        }

        if let proxySelector {
            let selectorName = methodName as String
            switch proxySelector {
            case #selector(_planeGetter):
                let block: @convention(block) (CPRStraightenedView) -> N3Plane = { view in
                    return view.planeGetterBody(selectorName: selectorName)
                }
                imp = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
            case #selector(_slabThicknessGetter):
                let block: @convention(block) (CPRStraightenedView) -> CGFloat = { view in
                    return view.slabThicknessGetterBody(selectorName: selectorName)
                }
                imp = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
            case #selector(_planeColorGetter):
                let block: @convention(block) (CPRStraightenedView) -> NSColor? = { view in
                    return view.planeColorGetterBody(selectorName: selectorName)
                }
                imp = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
            case #selector(_planeSetter(_:)):
                let block: @convention(block) (CPRStraightenedView, N3Plane) -> Void = { view, plane in
                    view.planeSetterBody(plane, selectorName: selectorName)
                }
                imp = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
            case #selector(_slabThicknessSetter(_:)):
                let block: @convention(block) (CPRStraightenedView, CGFloat) -> Void = { view, thickness in
                    view.slabThicknessSetterBody(thickness, selectorName: selectorName)
                }
                imp = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
            default:
                let block: @convention(block) (CPRStraightenedView, NSColor?) -> Void = { view, color in
                    view.planeColorSetterBody(color, selectorName: selectorName)
                }
                imp = imp_implementationWithBlock(unsafeBitCast(block, to: AnyObject.self))
            }
            typeEncoding = class_getInstanceMethod(self, proxySelector).flatMap { method_getTypeEncoding($0) }
            return class_addMethod(self, selector, imp!, typeEncoding)
        }

        return super.resolveInstanceMethod(selector)
    }

    // MARK: - Properties

    @objc public dynamic var delegate: CPRViewDelegate? {
        get { return _delegate }
        set { _delegate = newValue }
    }

    /// The volume data of the original data.
    @objc public dynamic var volumeData: CPRVolumeData! {
        get { return _volumeData }
        set {
            let volumeData = newValue
            if volumeData !== _volumeData {
                _generator?.delegate = nil
                _volumeData = volumeData
                _generator = CPRGenerator(volumeData: _volumeData)
                _generator?.delegate = self
                self._setNeedsNewRequest()
            }
        }
    }

    /// copy.
    @objc public dynamic var curvedPath: CPRCurvedPath! {
        get { return _curvedPath }
        set {
            let curvedPath = newValue
            if curvedPath !== _curvedPath {
                _curvedPath = curvedPath?.copy() as? CPRCurvedPath
                self._setNeedsNewRequest()
                self.needsDisplay = true
            }
        }
    }

    /// copy.
    @objc public dynamic var displayInfo: CPRDisplayInfo! {
        get { return _displayInfo }
        set {
            let dispalyInfo = newValue
            debugAssert(dispalyInfo != nil) // doesn't really need to be the case, but for debugging
            if dispalyInfo !== _displayInfo {
                _displayInfo = dispalyInfo?.copy() as? CPRDisplayInfo
                self.needsDisplay = true
            }
        }
    }

    @objc public dynamic var clippingRangeMode: CPRViewClippingRangeMode {
        get { return _clippingRangeMode }
        set {
            let mode = newValue
            if mode != _clippingRangeMode {
                _clippingRangeMode = mode

                if self.curDCM != nil {
                    self.setFusion(Int16(truncatingIfNeeded: type(of: self)._fusionMode(forCPRViewClippingRangeMode: _clippingRangeMode)),
                                   Int16(truncatingIfNeeded: self.curvedVolumeData?.pixelsDeep ?? 0))
                }
                self._setNeedsNewRequest()
            }
        }
    }

    /// The volume data that was generated.
    @objc public dynamic var curvedVolumeData: CPRVolumeData! {
        return _curvedVolumeData
    }

    /// The setter of the class extension's readwrite curvedVolumeData.
    @objc(setCurvedVolumeData:)
    private dynamic func setCurvedVolumeData(_ curvedVolumeData: CPRVolumeData!) {
        _curvedVolumeData = curvedVolumeData
    }

    /// Height of the image that is generated in mm. kinda hack sends
    /// CPRViewDidChangeGeneratedHeight to the delegate when this value changes.
    @objc public dynamic var generatedHeight: CGFloat {
        return _generatedHeight
    }

    // Set these to N3PlaneInvalid to keep the plane from appearing. The former
    // class declared them @dynamic and added them in +resolveInstanceMethod:.
    @objc public dynamic var orangePlane: N3Plane {
        get { return planeGetterBody(selectorName: "orangePlane") }
        set { planeSetterBody(newValue, selectorName: "setOrangePlane:") }
    }

    @objc public dynamic var purplePlane: N3Plane {
        get { return planeGetterBody(selectorName: "purplePlane") }
        set { planeSetterBody(newValue, selectorName: "setPurplePlane:") }
    }

    @objc public dynamic var bluePlane: N3Plane {
        get { return planeGetterBody(selectorName: "bluePlane") }
        set { planeSetterBody(newValue, selectorName: "setBluePlane:") }
    }

    @objc public dynamic var orangeSlabThickness: CGFloat {
        get { return slabThicknessGetterBody(selectorName: "orangeSlabThickness") }
        set { slabThicknessSetterBody(newValue, selectorName: "setOrangeSlabThickness:") }
    }

    @objc public dynamic var purpleSlabThickness: CGFloat {
        get { return slabThicknessGetterBody(selectorName: "purpleSlabThickness") }
        set { slabThicknessSetterBody(newValue, selectorName: "setPurpleSlabThickness:") }
    }

    @objc public dynamic var blueSlabThickness: CGFloat {
        get { return slabThicknessGetterBody(selectorName: "blueSlabThickness") }
        set { slabThicknessSetterBody(newValue, selectorName: "setBlueSlabThickness:") }
    }

    @objc public dynamic var orangePlaneColor: NSColor! {
        get { return planeColorGetterBody(selectorName: "orangePlaneColor") }
        set { planeColorSetterBody(newValue, selectorName: "setOrangePlaneColor:") }
    }

    @objc public dynamic var purplePlaneColor: NSColor! {
        get { return planeColorGetterBody(selectorName: "purplePlaneColor") }
        set { planeColorSetterBody(newValue, selectorName: "setPurplePlaneColor:") }
    }

    @objc public dynamic var bluePlaneColor: NSColor! {
        get { return planeColorGetterBody(selectorName: "bluePlaneColor") }
        set { planeColorSetterBody(newValue, selectorName: "setBluePlaneColor:") }
    }

    @objc public dynamic var displayTransverseLines: Bool {
        get { return _displayTransverseLines }
        set { _displayTransverseLines = newValue }
    }

    @objc public dynamic var displayCrossLines: Bool {
        get { return _displayCrossLines }
        set {
            let displayCrossLines = newValue
            if displayCrossLines != _displayCrossLines {
                _displayCrossLines = displayCrossLines
                if _displayCrossLines == false {
                    self._clearAllPlanes()
                }

                self.needsDisplay = true
                cprWindowController?.updateToolbarItems()
            }
        }
    }

    // The properties of the class extension.

    @objc(lastRequest)
    private dynamic var lastRequest: CPRStraightenedGeneratorRequest? {
        get { return _lastRequest }
        set { _lastRequest = newValue }
    }

    @objc(straightenedSession)
    private dynamic var straightenedSession: CPRStraightenedSession? {
        get { return _straightenedSession }
        set { _straightenedSession = newValue }
    }

    @objc(drawAllNodes)
    private dynamic var drawAllNodes: Bool {
        get { return _drawAllNodes }
        set {
            let drawAllNodes = newValue
            if drawAllNodes != _drawAllNodes {
                _drawAllNodes = drawAllNodes
                self.needsDisplay = true
            }
        }
    }

    @objc(mousePlanePointsInPix)
    private dynamic var mousePlanePointsInPix: NSMutableDictionary? {
        get { return _mousePlanePointsInPix }
        set { _mousePlanePointsInPix = newValue }
    }

    // MARK: -

    public override func value(forKey key: String) -> Any? {
        var planeFullName: String // full plane name may include Top or Bottom before the plane name
        let key = key as NSString

        if key.hasSuffix("VerticalLines") {
            planeFullName = key.substring(to: key.length - 13)
            if _verticalLines?.value(forKey: planeFullName) == nil {
                self._buildVerticalLinesAndPlaneRuns(forPlaneFullName: planeFullName)
            }
            return _verticalLines?.object(forKey: planeFullName)
        } else if key.hasSuffix("PlaneRuns") {
            planeFullName = key.substring(to: key.length - 9)
            if _planeRuns?.value(forKey: planeFullName) == nil {
                self._buildVerticalLinesAndPlaneRuns(forPlaneFullName: planeFullName)
            }
            return _planeRuns?.value(forKey: planeFullName)
        } else {
            return super.value(forKey: key as String)
        }
    }

    public override dynamic func mouseDraggedWindowLevel(_ event: NSEvent!) {
        super.mouseDraggedWindowLevel(event)

        cprWindowController?.propagateWLWW(self)
    }

    public override dynamic var frame: NSRect {
        get { return super.frame }
        set {
            let frameRect = newValue
            var needsUpdate: Bool

            needsUpdate = false
            if NSEqualRects(frameRect, self.frame) == false {
                needsUpdate = true
            }

            super.frame = frameRect

            if needsUpdate {
                self._setNeedsNewRequest()
            }
        }
    }

    @objc(drawTextualData::)
    public override dynamic func drawTextualData(_ size: NSRect, _ annotations: Int) {
        if _displayTransverseLines {
            var length = Float(curvedPathLength)

            let topLeft = self.curDCM?.annotationsDictionary?.object(forKey: "TopLeft") as? NSMutableArray

            length = Float(Double(length) * 0.1) // We want cm

            let transverseSectionPosition = _curvedPath?.transverseSectionPosition ?? 0
            let leftTransverseSectionPosition = _curvedPath?.leftTransverseSectionPosition ?? 0
            let rightTransverseSectionPosition = _curvedPath?.rightTransverseSectionPosition ?? 0
            topLeft?.add(NSArray(object: String(format: NSLocalizedString("A-B : %2.2f cm", comment: ""), Double(length) * abs(Double(transverseSectionPosition - leftTransverseSectionPosition)))))
            topLeft?.add(NSArray(object: String(format: NSLocalizedString("B-C : %2.2f cm", comment: ""), Double(length) * abs(Double(transverseSectionPosition - rightTransverseSectionPosition)))))
            topLeft?.add(NSArray(object: String(format: NSLocalizedString("A-C : %2.2f cm", comment: ""), Double(length) * abs(Double(leftTransverseSectionPosition - rightTransverseSectionPosition)))))

            super.drawTextualData(size, annotations)

            topLeft?.removeLastObject()
            topLeft?.removeLastObject()
            topLeft?.removeLastObject()
        } else {
            super.drawTextualData(size, annotations)
        }
    }

    public override dynamic func draw(_ rect: NSRect) {
        if rect.size.width > 10 {
            let lifecycle = cprWindowController?.renderLifecycle
            let decision = lifecycle?.beginDraw(named: "straightened")
            if lifecycle != nil, let decision, decision.accepted == false {
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
                    if let curDCM = self.curDCM {
                        let geo = CPRRenderLifecycle.diagnoseSpacingX(curDCM.pixelSpacingX, spacingY: curDCM.pixelSpacingY)
                        if geo != "ready" {
                            NSLog("CPR invalid geometry: %@", geo)
                        }
                    }
                    self._sendNewRequestIfNeeded()
                    self._adjustROIs()

                    // The flag suppresses setNeedsDisplay: while the request is built.
                    // Clear it before super draws: the generator's callback is delivered
                    // inside that draw, and a repaint asked for while the flag is up is
                    // dropped for good - nothing marks the view a second time.
                    self._processingRequest = false
                    super.draw(rect)
                }
            } catch {
                raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
            }
            _processingRequest = false
            lifecycle?.endDraw(named: "straightened")
            raised?.raise()
        }
    }

    public override dynamic var needsDisplay: Bool {
        get { return super.needsDisplay }
        set {
            if CPRRenderLifecycle.shouldDisplaySynchronously(whileDrawing: _processingRequest) {
                super.needsDisplay = newValue
            }
        }
    }

    @objc(subDrawRect:)
    public override dynamic func subDraw(_ rect: NSRect) {
        var lineStart: N3Vector
        var lineEnd: N3Vector
        var cursorVector: N3Vector
        var pixToSubDrawRectTransform: N3AffineTransform
        var relativePosition: CGFloat
        var draggedPosition: CGFloat
        var transverseSectionPosition: CGFloat
        var leftTransverseSectionPosition: CGFloat
        var rightTransverseSectionPosition: CGFloat
        var pixelsPerMm: CGFloat
        var planeColor: NSColor?
        var i: Int

        roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
        roiEnable(GL_BLEND)
        roiEnable(GL_POINT_SMOOTH)
        roiEnable(GL_LINE_SMOOTH)
        roiPointSize(Float(12 * backingScaleFactor))

        pixToSubDrawRectTransform = self.pixToSubDrawRectTransform()
        pixelsPerMm = CGFloat(curPWidth) / curvedPathLength

        if _displayCrossLines {
            for (key, _) in _planes ?? NSMutableDictionary() {
                guard let planeName = key as? String else { continue }
                planeColor = self.value(forKey: planeName + "PlaneColor") as? NSColor

                roiLineWidth(Float(2.0 * backingScaleFactor))
                // draw planes
                roiColor4f(Float(planeColor?.redComponent ?? 0), Float(planeColor?.greenComponent ?? 0), Float(planeColor?.blueComponent ?? 0), Float(planeColor?.alphaComponent ?? 0))
                self._drawPlaneRuns(self.value(forKey: planeName + "PlaneRuns") as? NSArray)
                self._drawVerticalLines(self.value(forKey: planeName + "VerticalLines") as? NSArray)

                roiLineWidth(Float(1.0 * backingScaleFactor))
                self._drawPlaneRuns(self.value(forKey: planeName + "TopPlaneRuns") as? NSArray)
                self._drawPlaneRuns(self.value(forKey: planeName + "BottomPlaneRuns") as? NSArray)
                self._drawVerticalLines(self.value(forKey: planeName + "TopVerticalLines") as? NSArray)
                self._drawVerticalLines(self.value(forKey: planeName + "BottomVerticalLines") as? NSArray)
            }
        }

        lineStart = N3VectorMake(0, CGFloat(curPHeight) / 2.0, 0)
        lineEnd = N3VectorMake(CGFloat(curPWidth), CGFloat(curPHeight) / 2.0, 0)

        lineStart = N3VectorApplyTransform(lineStart, pixToSubDrawRectTransform)
        lineEnd = N3VectorApplyTransform(lineEnd, pixToSubDrawRectTransform)

        roiLineWidth(Float(2.0 * backingScaleFactor))
        roiBegin(GL_LINES)
        roiColor4d(0.0, 1.0, 0.0, 0.2)
        roiVertex2d(Double(lineStart.x), Double(lineStart.y))
        roiVertex2d(Double(lineEnd.x), Double(lineEnd.y))
        roiEnd()

        roiColor4d(0.0, 1.0, 0.0, 0.8)

        if (cprWindowController?.displayMousePosition ?? false) == true && (_displayInfo?.mouseCursorHidden ?? false) == false {
            cursorVector = N3VectorMake(CGFloat(curPWidth) * (_displayInfo?.mouseCursorPosition ?? 0), CGFloat(curPHeight) / 2.0, 0)
            cursorVector = N3VectorApplyTransform(cursorVector, pixToSubDrawRectTransform)

            roiEnable(GL_POINT_SMOOTH)
            roiPointSize(Float(8 * backingScaleFactor))

            roiBegin(GL_POINTS)
            roiVertex2f(Float(cursorVector.x), Float(cursorVector.y))
            roiEnd()
        }

        if (_displayInfo?.draggedPositionHidden ?? false) == false {
            roiColor4d(1.0, 0.0, 0.0, 1.0)
            draggedPosition = _displayInfo?.draggedPosition ?? 0
            lineStart = N3VectorApplyTransform(N3VectorMake(CGFloat(curPWidth) * draggedPosition, 0, 0), pixToSubDrawRectTransform)
            lineEnd = N3VectorApplyTransform(N3VectorMake(CGFloat(curPWidth) * draggedPosition, CGFloat(curPHeight), 0), pixToSubDrawRectTransform)
            roiLineWidth(Float(2.0 * backingScaleFactor))
            roiBegin(GL_LINE_STRIP)
            roiVertex2f(Float(lineStart.x), Float(lineStart.y))
            roiVertex2f(Float(lineEnd.x), Float(lineEnd.y))
            roiEnd()
        }

        var exportTransverseSliceInterval: Float = 0

        if (cprWindowController?.exportSequenceType ?? 0) == CPRExportSequenceType(CPRSeriesExportSequenceType.rawValue) && (cprWindowController?.exportSeriesType ?? 0) == CPRExportSeriesType(CPRTransverseViewsExportSeriesType.rawValue) {
            exportTransverseSliceInterval = Float(cprWindowController?.exportTransverseSliceInterval ?? 0)
        }

        if exportTransverseSliceInterval > 0 {
            roiColor4d(1.0, 1.0, 0.0, 1.0)

            let flattenedPath = _curvedPath?.bezierPath?.mutableCopy() as? N3MutableBezierPath
            flattenedPath?.subdivide(N3BezierDefaultSubdivideSegmentLength)
            flattenedPath?.flatten(N3BezierDefaultFlatness)

            let curveLength = Float(flattenedPath?.length() ?? 0)
            var noOfFrames = cInt32(Double(curveLength / exportTransverseSliceInterval))
            noOfFrames &+= 1

            var startingDistance: Float = curveLength - Float(noOfFrames &- 1) * exportTransverseSliceInterval
            startingDistance /= 2

            let t = cprWindowController?.middleTransverseView
            var transverseWidth = CGFloat(Float(t?.curDCM?.pwidth ?? 0) / (t?.pixelsPerMm() ?? 0))
            transverseWidth /= self.pixelSpacingY

            var i: Int32 = 0
            while i < noOfFrames {
                transverseSectionPosition = CGFloat((startingDistance + (Float(i) * exportTransverseSliceInterval)) / Float(curvedPathLength))
                lineStart = N3VectorApplyTransform(N3VectorMake(CGFloat(curPWidth) * transverseSectionPosition, CGFloat(curPHeight) / 2.0 - transverseWidth / 2.0, 0), pixToSubDrawRectTransform)
                lineEnd = N3VectorApplyTransform(N3VectorMake(CGFloat(curPWidth) * transverseSectionPosition, CGFloat(curPHeight) / 2.0 + transverseWidth / 2.0, 0), pixToSubDrawRectTransform)
                roiLineWidth(Float(2.0 * backingScaleFactor))
                roiBegin(GL_LINE_STRIP)
                roiVertex2f(Float(lineStart.x), Float(lineStart.y))
                roiVertex2f(Float(lineEnd.x), Float(lineEnd.y))
                roiEnd()
                i += 1
            }
        } else if _displayTransverseLines {
            var lineAStart: N3Vector, lineAEnd: N3Vector, lineBStart: N3Vector, lineBEnd: N3Vector, lineCStart: N3Vector, lineCEnd: N3Vector

            let t = cprWindowController?.middleTransverseView
            var transverseWidth = CGFloat(Float(t?.curDCM?.pwidth ?? 0) / (t?.pixelsPerMm() ?? 0))
            transverseWidth /= self.pixelSpacingY

            // draw the transverse section lines
            roiColor4d(1.0, 1.0, 0.0, 1.0)
            transverseSectionPosition = _curvedPath?.transverseSectionPosition ?? 0
            lineBStart = N3VectorApplyTransform(N3VectorMake(CGFloat(curPWidth) * transverseSectionPosition, CGFloat(curPHeight) / 2.0 - transverseWidth / 2.0, 0), pixToSubDrawRectTransform)
            lineBEnd = N3VectorApplyTransform(N3VectorMake(CGFloat(curPWidth) * transverseSectionPosition, CGFloat(curPHeight) / 2.0 + transverseWidth / 2.0, 0), pixToSubDrawRectTransform)
            roiLineWidth(Float(2.0 * backingScaleFactor))
            roiBegin(GL_LINE_STRIP)
            roiVertex2f(Float(lineBStart.x), Float(lineBStart.y))
            roiVertex2f(Float(lineBEnd.x), Float(lineBEnd.y))
            roiEnd()

            leftTransverseSectionPosition = _curvedPath?.leftTransverseSectionPosition ?? 0
            lineAStart = N3VectorApplyTransform(N3VectorMake(CGFloat(curPWidth) * leftTransverseSectionPosition, CGFloat(curPHeight) / 2.0 - transverseWidth / 2.0, 0), pixToSubDrawRectTransform)
            lineAEnd = N3VectorApplyTransform(N3VectorMake(CGFloat(curPWidth) * leftTransverseSectionPosition, CGFloat(curPHeight) / 2.0 + transverseWidth / 2.0, 0), pixToSubDrawRectTransform)
            roiLineWidth(Float(1.0 * backingScaleFactor))
            roiBegin(GL_LINE_STRIP)
            roiVertex2f(Float(lineAStart.x), Float(lineAStart.y))
            roiVertex2f(Float(lineAEnd.x), Float(lineAEnd.y))
            roiEnd()

            rightTransverseSectionPosition = _curvedPath?.rightTransverseSectionPosition ?? 0
            lineCStart = N3VectorApplyTransform(N3VectorMake(CGFloat(curPWidth) * rightTransverseSectionPosition, CGFloat(curPHeight) / 2.0 - transverseWidth / 2.0, 0), pixToSubDrawRectTransform)
            lineCEnd = N3VectorApplyTransform(N3VectorMake(CGFloat(curPWidth) * rightTransverseSectionPosition, CGFloat(curPHeight) / 2.0 + transverseWidth / 2.0, 0), pixToSubDrawRectTransform)
            roiBegin(GL_LINE_STRIP)
            roiVertex2f(Float(lineCStart.x), Float(lineCStart.y))
            roiVertex2f(Float(lineCEnd.x), Float(lineCEnd.y))
            roiEnd()

            // --- Text
            if stanStringAttrib == nil {
                stanStringAttrib = NSMutableDictionary()
                // -setObject:forKey: sent as the former code did: a nil font raises.
                _ = stanStringAttrib?.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: NSFont(name: "Helvetica", size: 14.0), with: NSAttributedString.Key.font.rawValue)
                _ = stanStringAttrib?.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: NSColor.white, with: NSAttributedString.Key.foregroundColor.rawValue)
            }

            roiEnable(GL_BLEND)
            roiBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)

            do {
                roiPushMatrix()

                var ratio: Float = 1

                if self.pixelSpacingX != 0 && self.pixelSpacingY != 0 {
                    ratio = Float(self.pixelSpacingX / self.pixelSpacingY)
                }

                roiLoadIdentity() // reset model view matrix to identity (eliminates rotation basically)
                roiScalef(Float(2.0 / (self.xFlipped ? -(self.drawingFrameRect.size.width) : self.drawingFrameRect.size.width)), Float(-2.0 / (self.yFlipped ? -(self.drawingFrameRect.size.height) : self.drawingFrameRect.size.height)), 1.0) // scale to port per pixel scale
                roiTranslatef(Float(self.origin.x), Float(-self.origin.y), 0.0)

                let labelFont = stanStringAttrib?.object(forKey: NSAttributedString.Key.font.rawValue) as? NSFont
                let textA = self.horosLabelText("A", font: labelFont), textB = self.horosLabelText("B", font: labelFont), textC = self.horosLabelText("C", font: labelFont)
                let labelColor = NSColor(deviceRed: 1, green: 1, blue: 0, alpha: 1), labelShadow = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)

                let quarter = Float(-(lineAStart.y - lineAEnd.y) / 3.0)

                var tPt: NSPoint

                tPt = self.positionWithoutRotation(NSMakePoint(lineAStart.x - (textA?.frameSize.width ?? 0), CGFloat(quarter) + lineAStart.y))
                self.horosDrawLabel(textA, at: tPt, textColor: labelColor, shadowColor: labelShadow)

                tPt = self.positionWithoutRotation(NSMakePoint(lineBStart.x - (textB?.frameSize.width ?? 0), CGFloat(quarter) + lineBStart.y))
                self.horosDrawLabel(textB, at: tPt, textColor: labelColor, shadowColor: labelShadow)

                tPt = self.positionWithoutRotation(NSMakePoint(lineCStart.x - (textC?.frameSize.width ?? 0), CGFloat(quarter) + lineCStart.y))
                self.horosDrawLabel(textC, at: tPt, textColor: labelColor, shadowColor: labelShadow)

                roiPopMatrix()
                _ = ratio
            }
        }

        if (cprWindowController?.displayMousePosition ?? false) == true {
            // draw the point on the plane lines
            for (key, _) in _mousePlanePointsInPix ?? NSMutableDictionary() {
                guard let planeName = key as? String else { continue }
                planeColor = self.value(forKey: String(format: "%@PlaneColor", planeName)) as? NSColor
                roiColor4f(Float(planeColor?.redComponent ?? 0), Float(planeColor?.greenComponent ?? 0), Float(planeColor?.blueComponent ?? 0), Float(planeColor?.alphaComponent ?? 0))
                roiEnable(GL_POINT_SMOOTH)
                roiPointSize(Float(8 * backingScaleFactor))
                cursorVector = N3VectorApplyTransform((_mousePlanePointsInPix?.object(forKey: planeName) as? NSValue)?.n3VectorValue() ?? N3Vector(), pixToSubDrawRectTransform)
                roiBegin(GL_POINTS)
                roiVertex2f(Float(cursorVector.x), Float(cursorVector.y))
                roiEnd()
            }

            if (_displayInfo?.mouseTransverseSection ?? 0) != noneSectionType {
                switch _displayInfo?.mouseTransverseSection ?? 0 {
                case leftSectionType:
                    relativePosition = _curvedPath?.leftTransverseSectionPosition ?? 0
                case centerSectionType:
                    relativePosition = _curvedPath?.transverseSectionPosition ?? 0
                case rightSectionType:
                    relativePosition = _curvedPath?.rightTransverseSectionPosition ?? 0
                default:
                    relativePosition = 0
                }

                cursorVector = N3VectorMake(CGFloat(curPWidth) * relativePosition, (CGFloat(curPHeight) / 2.0) + ((_displayInfo?.mouseTransverseSectionDistance ?? 0) * pixelsPerMm), 0)
                cursorVector = N3VectorApplyTransform(cursorVector, pixToSubDrawRectTransform)

                roiColor4d(1.0, 1.0, 0.0, 1.0)
                roiEnable(GL_POINT_SMOOTH)
                roiPointSize(Float(8 * backingScaleFactor))
                roiBegin(GL_POINTS)
                roiVertex2f(Float(cursorVector.x), Float(cursorVector.y))
                roiEnd()
            }
        }

        if _drawAllNodes {
            i = 0
            while i < (_curvedPath?.nodes.count ?? 0) {
                relativePosition = _curvedPath?.relativePositionForNode(at: UInt(bitPattern: i)) ?? 0
                cursorVector = N3VectorMake(CGFloat(curPWidth) * relativePosition, CGFloat(curPHeight) / 2.0, 0)
                cursorVector = N3VectorApplyTransform(cursorVector, pixToSubDrawRectTransform)

                if (_displayInfo?.hoverNodeHidden ?? false) == false && (_displayInfo?.hoverNodeIndex ?? 0) == i {
                    roiColor4d(1.0, 0.5, 0.0, 1.0)
                } else {
                    roiColor4d(1.0, 0.0, 0.0, 1.0)
                }

                roiEnable(GL_POINT_SMOOTH)
                roiPointSize(Float(8 * backingScaleFactor))

                roiBegin(GL_POINTS)
                roiVertex2f(Float(cursorVector.x), Float(cursorVector.y))
                roiEnd()
                i += 1
            }
        }

        roiLineWidth(Float(1.0 * backingScaleFactor))

        // Red Square
        if self.window?.firstResponder === self && self.stringID == nil {
            let drawingFrameRect = self.drawingFrameRect
            roiLoadIdentity() // reset model view matrix to identity (eliminates rotation basically)
            roiScalef(Float(2.0 / (self.xFlipped ? -(drawingFrameRect.size.width) : drawingFrameRect.size.width)), Float(-2.0 / (self.yFlipped ? -(drawingFrameRect.size.height) : drawingFrameRect.size.height)), 1.0) // scale to port per pixel scale

            roiColor4d(1.0, 0, 0.0, 1.0)

            let heighthalf = Float(drawingFrameRect.size.height / 2)
            let widthhalf = Float(drawingFrameRect.size.width / 2)

            roiLineWidth(Float(8.0 * backingScaleFactor))
            roiBegin(GL_LINE_LOOP)
            roiVertex2f(-widthhalf, -heighthalf)
            roiVertex2f(-widthhalf, heighthalf)
            roiVertex2f(widthhalf, heighthalf)
            roiVertex2f(widthhalf, -heighthalf)
            roiEnd()
        }

        roiDisable(GL_LINE_SMOOTH)
        roiDisable(GL_POLYGON_SMOOTH)
        roiDisable(GL_POINT_SMOOTH)
        roiDisable(GL_BLEND)
    }

    // MARK: - Mouse

    public override dynamic func mouseEntered(with theEvent: NSEvent) {
        self._sendWillEditDisplayInfo()
        _displayInfo?.mouseCursorHidden = false
        self._sendDidEditDisplayInfo()
        super.mouseEntered(with: theEvent)
    }

    public override dynamic func mouseExited(with theEvent: NSEvent) {
        self._sendWillEditDisplayInfo()
        _displayInfo?.mouseCursorHidden = true
        _displayInfo?.clearAllMouseVectors()
        _displayInfo?.mouseTransverseSection = noneSectionType
        _displayInfo?.mouseTransverseSectionDistance = 0
        self._sendDidEditDisplayInfo()
        _mousePlanePointsInPix?.removeAllObjects()

        self.drawAllNodes = false

        self.needsDisplay = true

        super.mouseExited(with: theEvent)
    }

    public override dynamic func mouseMoved(with theEvent: NSEvent) {
        let view = theEvent.window?.contentView?.hitTest(theEvent.locationInWindow)

        if view === self {
            var viewPoint: NSPoint
            var pixVector: N3Vector
            var line: N3Line
            var i: Int
            var overNode: Bool
            var hoverNodeIndex: Int
            var relativePosition: CGFloat
            var distance: CGFloat
            var minDistance: CGFloat

            viewPoint = self.convert(theEvent.locationInWindow, from: nil)

            if NSPointInRect(viewPoint, self.bounds) == false {
                return
            }

            pixVector = N3VectorApplyTransform(N3VectorMakeFromNSPoint(viewPoint), self.viewToPixTransform())

            if NSPointInRect(viewPoint, self.bounds) && curPWidth > 0 {
                self._sendWillEditDisplayInfo()
                _displayInfo?.mouseCursorPosition = cMIN(cMAX(pixVector.x / CGFloat(curPWidth), 0.0), 1.0)
                self.needsDisplay = true

                self._updateMousePlanePoints(forViewPoint: viewPoint) // this will modify _mousePlanePointsInPix and _displayInfo

                // test to see if the mouse is near a trasverse line
                _displayInfo?.mouseTransverseSection = noneSectionType
                _displayInfo?.mouseTransverseSectionDistance = 0.0
                if _displayTransverseLines {
                    distance = abs(pixVector.x - (_curvedPath?.leftTransverseSectionPosition ?? 0) * CGFloat(curPWidth))
                    minDistance = distance
                    if distance < 20.0 {
                        _displayInfo?.mouseTransverseSection = leftSectionType
                        _displayInfo?.mouseTransverseSectionDistance = (pixVector.y - (CGFloat(curPHeight) / 2.0)) * (curvedPathLength / CGFloat(curPWidth))
                    }
                    distance = abs(pixVector.x - (_curvedPath?.rightTransverseSectionPosition ?? 0) * CGFloat(curPWidth))
                    if distance < 20.0 && distance < minDistance {
                        _displayInfo?.mouseTransverseSection = rightSectionType
                        _displayInfo?.mouseTransverseSectionDistance = (pixVector.y - (CGFloat(curPHeight) / 2.0)) * (curvedPathLength / CGFloat(curPWidth))
                        minDistance = distance
                    }
                    distance = abs(pixVector.x - (_curvedPath?.transverseSectionPosition ?? 0) * CGFloat(curPWidth))
                    if distance < 20.0 && distance < minDistance {
                        _displayInfo?.mouseTransverseSection = centerSectionType
                        _displayInfo?.mouseTransverseSectionDistance = (pixVector.y - (CGFloat(curPHeight) / 2.0)) * (curvedPathLength / CGFloat(curPWidth))
                    }
                }

                line = N3LineMake(N3VectorMake(0, CGFloat(curPHeight) / 2.0, 0), N3VectorMake(1, 0, 0))
                line = N3LineApplyTransform(line, N3AffineTransformInvert(self.viewToPixTransform()))

                if N3VectorDistanceToLine(N3VectorMakeFromNSPoint(viewPoint), line) < 20.0 {
                    self.drawAllNodes = true
                } else {
                    self.drawAllNodes = false
                }

                overNode = false
                hoverNodeIndex = 0
                if self.drawAllNodes {
                    i = 0
                    while i < (_curvedPath?.nodes.count ?? 0) {
                        relativePosition = _curvedPath?.relativePositionForNode(at: UInt(bitPattern: i)) ?? 0

                        if N3VectorDistance(N3VectorMakeFromNSPoint(viewPoint),
                                            N3VectorApplyTransform(N3VectorMake(CGFloat(curPWidth) * relativePosition, CGFloat(curPHeight) / 2.0, 0), N3AffineTransformInvert(self.viewToPixTransform()))) < 10.0 {
                            overNode = true
                            hoverNodeIndex = i
                            break
                        }
                        i += 1
                    }

                    if overNode {
                        if (_displayInfo?.hoverNodeHidden ?? false) == true || (_displayInfo?.hoverNodeIndex ?? 0) != hoverNodeIndex {
                            _displayInfo?.hoverNodeHidden = false
                            _displayInfo?.hoverNodeIndex = hoverNodeIndex
                        }
                    } else {
                        if (_displayInfo?.hoverNodeHidden ?? false) == false {
                            _displayInfo?.hoverNodeHidden = true
                            _displayInfo?.hoverNodeIndex = 0
                        }
                    }
                }

                self._sendDidEditDisplayInfo()
            }

            var exportTransverseSliceInterval: Float = 0

            if (cprWindowController?.exportSequenceType ?? 0) == CPRExportSequenceType(CPRSeriesExportSequenceType.rawValue) && (cprWindowController?.exportSeriesType ?? 0) == CPRExportSeriesType(CPRTransverseViewsExportSeriesType.rawValue) {
                exportTransverseSliceInterval = Float(cprWindowController?.exportTransverseSliceInterval ?? 0)
            }

            if curPWidth != 0 && exportTransverseSliceInterval == 0 && _displayTransverseLines && ((abs((pixVector.x / CGFloat(curPWidth)) - (_curvedPath?.transverseSectionPosition ?? 0)) * CGFloat(curPWidth) < 5.0) || (abs((pixVector.x / CGFloat(curPWidth)) - (_curvedPath?.leftTransverseSectionPosition ?? 0)) * CGFloat(curPWidth) < 10.0) || (abs((pixVector.x / CGFloat(curPWidth)) - (_curvedPath?.rightTransverseSectionPosition ?? 0)) * CGFloat(curPWidth) < 10.0)) {
                if theEvent.type == .leftMouseDragged || theEvent.type == .leftMouseDown {
                    NSCursor.closedHand.set()
                } else {
                    NSCursor.openHand.set()
                }
            } else {
                self.cursor?.set()

                super.mouseMoved(with: theEvent)
            }
        } else {
            view?.mouseMoved(with: theEvent)
        }
    }

    public override dynamic func mouseDown(with event: NSEvent) {
        var viewPoint: NSPoint
        var pixVector: N3Vector
        var pixWidth: CGFloat
        var relativePosition: CGFloat
        var i: Int

        viewPoint = self.convert(event.locationInWindow, from: nil)
        pixVector = N3VectorApplyTransform(N3VectorMakeFromNSPoint(viewPoint), self.viewToPixTransform())
        pixWidth = CGFloat(curPWidth)
        _clickedNode = false

        if pixWidth == 0.0 {
            super.mouseDown(with: event)
            return
        }

        var exportTransverseSliceInterval: Float = 0

        if (cprWindowController?.exportSequenceType ?? 0) == CPRExportSequenceType(CPRSeriesExportSequenceType.rawValue) && (cprWindowController?.exportSeriesType ?? 0) == CPRExportSeriesType(CPRTransverseViewsExportSeriesType.rawValue) {
            exportTransverseSliceInterval = Float(cprWindowController?.exportTransverseSliceInterval ?? 0)
        }

        if exportTransverseSliceInterval == 0 && _displayTransverseLines && (abs((pixVector.x / pixWidth) - (_curvedPath?.transverseSectionPosition ?? 0)) * pixWidth < 5.0) {
            self._sendWillEditCurvedPath()
            _draggingTransverse = true
            self.mouseMoved(with: event)
        } else if exportTransverseSliceInterval == 0 && _displayTransverseLines && ((abs((pixVector.x / pixWidth) - (_curvedPath?.leftTransverseSectionPosition ?? 0)) * pixWidth < 10.0) || (abs((pixVector.x / pixWidth) - (_curvedPath?.rightTransverseSectionPosition ?? 0)) * pixWidth < 10.0)) {
            self._sendWillEditCurvedPath()
            _draggingTransverseSpacing = true
            self.mouseMoved(with: event)
        } else {
            i = 0
            while i < (_curvedPath?.nodes.count ?? 0) {
                relativePosition = _curvedPath?.relativePositionForNode(at: UInt(bitPattern: i)) ?? 0

                if N3VectorDistance(N3VectorMakeFromNSPoint(viewPoint),
                                    N3VectorApplyTransform(N3VectorMake(CGFloat(curPWidth) * relativePosition, CGFloat(curPHeight) / 2.0, 0), N3AffineTransformInvert(self.viewToPixTransform()))) < 10.0 {
                    if _delegate?.responds(to: #selector(CPRViewDelegate.cprView(_:setCrossCenter:))) ?? false {
                        _delegate?.cprView?(cprWindowController?.mprView1, setCrossCenter: (_curvedPath?.nodes.object(at: i) as? NSValue)?.n3VectorValue() ?? N3Vector())
                    }
                    _clickedNode = true
                    break
                }
                i += 1
            }
            if _clickedNode == false {
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

                    let windowController = cprWindowController

                    let tool = self.getTool(event)

                    if self.roiTool(tool) && self.click(inROI: tempPt) != nil {
                        cprWindowController?.roiGetInfo(self)
                    } else if frameZoomed.boolValue == false {
                        let frame1 = windowController?.mprView1?.frame ?? NSZeroRect
                        let frame3 = windowController?.mprView3?.frame ?? NSZeroRect
                        splitPosition.0 = cInt32(Double(frame1.origin.x + frame1.size.width))  // vert
                        splitPosition.1 = cInt32(Double(frame1.origin.y + frame1.size.height)) // hori12
                        splitPosition.2 = cInt32(Double(frame3.origin.y + frame3.size.height)) // horiz2

                        frameZoomed = ObjCBool(true)

                        windowController?.verticalSplit?.setPosition(windowController?.verticalSplit?.minPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)
                        windowController?.horizontalSplit1?.setPosition(windowController?.horizontalSplit1?.minPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)
                        windowController?.horizontalSplit2?.setPosition(windowController?.horizontalSplit2?.minPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)
                    } else {
                        frameZoomed = ObjCBool(false)
                        windowController?.verticalSplit?.setPosition(CGFloat(splitPosition.0), ofDividerAt: 0)
                        windowController?.horizontalSplit1?.setPosition(CGFloat(splitPosition.1), ofDividerAt: 0)
                        windowController?.horizontalSplit2?.setPosition(CGFloat(splitPosition.2), ofDividerAt: 0)

                        windowController?.mprView1?.restoreCamera()
                        windowController?.mprView1?.camera?.forceUpdate = true
                        windowController?.mprView1?.updateViewMPR()

                        windowController?.mprView2?.restoreCamera()
                        windowController?.mprView2?.camera?.forceUpdate = true
                        windowController?.mprView2?.updateViewMPR()

                        windowController?.mprView3?.restoreCamera()
                        windowController?.mprView3?.camera?.forceUpdate = true
                        windowController?.mprView3?.updateViewMPR()
                    }
                } else {
                    if self.roiTool(self.horos_currentTool) {
                        if self.horos_currentTool != .tText && self.horos_currentTool != .tArrow {
                            self.horos_currentTool = .tMesure
                        }
                    }

                    super.mouseDown(with: event)
                }
            }
        }
    }

    public override dynamic func mouseDragged(with event: NSEvent) {
        var viewPoint: NSPoint
        var pixVector: N3Vector
        var relativePosition: CGFloat
        var pixWidth: CGFloat

        if _clickedNode {
            return
        }

        viewPoint = self.convert(event.locationInWindow, from: nil)
        pixVector = N3VectorApplyTransform(N3VectorMakeFromNSPoint(viewPoint), self.viewToPixTransform())
        pixWidth = CGFloat(curPWidth)

        if pixWidth == 0.0 {
            super.mouseDragged(with: event)
            return
        }

        if _draggingTransverse {
            relativePosition = pixVector.x / pixWidth
            _curvedPath?.transverseSectionPosition = cMAX(cMIN(relativePosition, 1.0), 0.0)
            self._sendDidUpdateCurvedPath()

            self._sendWillEditDisplayInfo()
            _displayInfo?.mouseCursorPosition = pixVector.x / pixWidth
            self._sendDidEditDisplayInfo()

            self.needsDisplay = true
            self.mouseMoved(with: event)
        } else if _draggingTransverseSpacing {
            _curvedPath?.transverseSectionSpacing = abs(pixVector.x / pixWidth - (_curvedPath?.transverseSectionPosition ?? 0)) * curvedPathLength
            self._sendDidUpdateCurvedPath()

            self._sendWillEditDisplayInfo()
            _displayInfo?.mouseCursorPosition = pixVector.x / pixWidth
            self._sendDidEditDisplayInfo()
            self.needsDisplay = true
            self.mouseMoved(with: event)
        } else {
            self._sendWillEditDisplayInfo()
            _displayInfo?.mouseCursorPosition = pixVector.x / pixWidth
            self._sendDidEditDisplayInfo()

            super.mouseDragged(with: event)
        }
    }

    public override dynamic func mouseUp(with event: NSEvent) {
        if _draggingTransverse {
            _draggingTransverse = false
            self._sendDidEditCurvedPath()
        } else if _draggingTransverseSpacing {
            _draggingTransverseSpacing = false
            self._sendDidEditCurvedPath()
        }

        super.mouseUp(with: event)
    }

    public override dynamic func scrollWheel(with theEvent: NSEvent) {
        // Scroll/Move transverse lines
        if theEvent.modifierFlags.contains(.option) {
            let transverseSectionPosition = cMIN(cMAX((_curvedPath?.transverseSectionPosition ?? 0) + theEvent.deltaY * 0.002, 0.0), 1.0)

            self._sendWillEditCurvedPath()
            _curvedPath?.transverseSectionPosition = transverseSectionPosition
            self._sendDidEditCurvedPath()

            self._setNeedsNewRequest()
            self.needsDisplay = true
        }

        // Scroll/Move transverse lines
        else if theEvent.modifierFlags.contains(.command) {
            var factor: Float = 0.4

            if (self.curDCM?.pixelSpacingX ?? 0) != 0 {
                factor = Float(self.curDCM?.pixelSpacingX ?? 0)
            }

            let transverseSectionSpacing = cMIN(cMAX((_curvedPath?.transverseSectionSpacing ?? 0) + theEvent.deltaY * CGFloat(factor), 0.0), 300)

            self._sendWillEditCurvedPath()
            _curvedPath?.transverseSectionSpacing = transverseSectionSpacing
            self._sendDidEditCurvedPath()

            self._setNeedsNewRequest()
            self.needsDisplay = true
        } else {
            var initialNormal: N3Vector
            var angle: CGFloat

            angle = theEvent.deltaY * (CGFloat.pi / 180)

            initialNormal = _curvedPath?.initialNormal ?? N3Vector()
            initialNormal = N3VectorApplyTransform(initialNormal, N3AffineTransformMakeRotationAroundVector(angle, _curvedPath?.bezierPath?.tangentAtStart() ?? N3Vector()))

            self._sendWillEditCurvedPath()
            _curvedPath?.initialNormal = initialNormal
            self._sendDidEditCurvedPath()
            self._setNeedsNewRequest()
        }
    }

    public override dynamic func updatePresentationState(fromSeriesOnlyImageLevel onlyImage: Bool) {
    }

    // MARK: - CPRGeneratorDelegate

    @objc(generator:didGenerateVolume:request:)
    public func generator(_ generator: CPRGenerator, didGenerateVolume volume: CPRVolumeData, request: CPRGeneratorRequest) {
        if self.windowController() == nil {
            return
        }
        let volumeOrNil: CPRVolumeData? = volume
        if volumeOrNil == nil {
            return
        }
        _ = self.straightenedSession?.completeGeneration()

        var i: UInt
        var pixArray: NSMutableArray
        var newPix: DCMPix
        var inlineBuffer = CPRVolumeDataInlineBuffer()

        self._updateGeneratedHeight()

        let previousOrigin = self.origin
        let previousScale = self.scaleValue
        let previousRotation = self.rotation
        let previousHeight = Int32(truncatingIfNeeded: self.curDCM?.pheight ?? 0), previousWidth = Int32(truncatingIfNeeded: self.curDCM?.pwidth ?? 0)
        let previousROIs = self.curRoiList.map { NSArchiver.archivedData(withRootObject: $0) }

        // make sure this is around long enough so that it doesn't disapear under the old DCMPix
        if let curvedVolumeData = self.curvedVolumeData {
            _ = Unmanaged.passRetained(curvedVolumeData).autorelease()
        }
        self.setCurvedVolumeData(volume)

        pixArray = NSMutableArray()

        i = 0
        while i < (self.curvedVolumeData?.pixelsDeep ?? 0) {
            if self.curvedVolumeData?.aquireInlineBuffer(&inlineBuffer) ?? false {
                let pixelsWide = self.curvedVolumeData?.pixelsWide ?? 0
                let pixelsHigh = self.curvedVolumeData?.pixelsHigh ?? 0
                // A nil pix raised in -addObject: before; it traps here.
                newPix = DCMPix(data: UnsafeMutablePointer(mutating: CPRVolumeDataFloatBytes(&inlineBuffer)) + Int(bitPattern: i &* pixelsWide &* pixelsHigh), 32,
                                Int(bitPattern: self.curvedVolumeData?.pixelsWide ?? 0), Int(bitPattern: self.curvedVolumeData?.pixelsHigh ?? 0),
                                Float(self.curvedVolumeData?.pixelSpacingX ?? 0), Float(self.curvedVolumeData?.pixelSpacingY ?? 0),
                                0.0, 0.0, 0.0, false)
            } else {
                debugAssert(false)
                newPix = DCMPix()
            }
            self.curvedVolumeData?.releaseInlineBuffer(&inlineBuffer)

            newPix.imageObjectID = cprWindowController?.originalPix?.imageObjectID
            newPix.displayInverted = cprWindowController?.originalPix?.displayInverted ?? false
            newPix.srcFile = cprWindowController?.originalPix?.srcFile
            newPix.annotationsDictionary = cprWindowController?.originalPix?.annotationsDictionary

            pixArray.add(newPix)
            i += 1
        }

        if pixArray.count != 0 {
            var j = 0
            while j < pixArray.count {
                sendSetArrayPix(pixArray.object(at: j) as AnyObject, pixArray, Int16(truncatingIfNeeded: j))
                j += 1
            }

            self.setPixels(pixArray, files: nil, rois: nil, firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: true)
            self.setScaleValueCentered(Float(0.8 * backingScaleFactor))

            //[self setWLWW:wl :ww];
            cprWindowController?.propagateWLWW(cprWindowController?.mprView1)

            self.setFusion(Int16(truncatingIfNeeded: type(of: self)._fusionMode(forCPRViewClippingRangeMode: _clippingRangeMode)),
                           Int16(truncatingIfNeeded: self.curvedVolumeData?.pixelsDeep ?? 0))

            if Int(previousWidth) == curPWidth && Int(previousHeight) == curPHeight {
                self.origin = previousOrigin
                self.scaleValue = previousScale
                self.rotation = previousRotation
            }

            let roiArray = previousROIs.flatMap { NSUnarchiver.unarchiveObject(with: $0) } as? NSArray
            for case let r as ROI in roiArray ?? NSArray() {
                r.pix = self.curDCM
                r.setOriginAndSpacing(Float(self.curDCM?.pixelSpacingX ?? 0), Float(self.curDCM?.pixelSpacingY ?? 0), NSMakePoint(CGFloat(self.curDCM?.originX ?? 0), CGFloat(self.curDCM?.originY ?? 0)), false, false)
                r.curView = self
            }

            self.curRoiList?.addObjects(from: (roiArray as? [Any]) ?? [])

            self._clearAllPlanes()
            self.needsDisplay = true
        }
    }

    @objc(generator:didAbandonRequest:)
    public func generator(_ generator: CPRGenerator, didAbandonRequest request: CPRGeneratorRequest) {
    }

    // MARK: -

    @objc(cancelStraightenedGeneration)
    public dynamic func cancelStraightenedGeneration() -> Bool {
        guard let straightenedSession = self.straightenedSession else {
            return false
        }
        let decision = straightenedSession.cancel()
        if decision.accepted == false {
            return false
        }
        _generator?.cancelOutstandingRequests()
        return true
    }

    @objc(horosStraightenedSession)
    private dynamic func horosStraightenedSession() -> CPRStraightenedSession! {
        if self.straightenedSession == nil {
            self.straightenedSession = CPRStraightenedSession()
        }
        return self.straightenedSession
    }

    /// Returns once this view's DCM pix object has been updated to reflect any
    /// changes made to the view.
    @objc(waitUntilPixUpdate)
    public dynamic func waitUntilPixUpdate() {
        self._sendNewRequestIfNeeded()
        _generator?.runUntilAllRequestsAreFinished()
    }

    @objc(_fusionModeForCPRViewClippingRangeMode:)
    private dynamic class func _fusionMode(forCPRViewClippingRangeMode clippingRangeMode: CPRViewClippingRangeMode) -> Int {
        switch clippingRangeMode {
        case CPRViewClippingRangeMode(CPRViewClippingRangeVRMode.rawValue):
            return 0 // not supported
        case CPRViewClippingRangeMode(CPRViewClippingRangeMIPMode.rawValue):
            return 2
        case CPRViewClippingRangeMode(CPRViewClippingRangeMinIPMode.rawValue):
            return 3
        case CPRViewClippingRangeMode(CPRViewClippingRangeMeanMode.rawValue):
            return 1
        default:
            NSLog("%@ asking for invalid clipping range mode: %d", "+[CPRStraightenedView _fusionModeForCPRViewClippingRangeMode:]", Int32(truncatingIfNeeded: clippingRangeMode))
            return 0
        }
    }

    @objc(_sendWillEditCurvedPath)
    private dynamic func _sendWillEditCurvedPath() {
        if _editingCurvedPathCount == 0 {
            if _delegate?.responds(to: #selector(CPRViewDelegate.cprViewWillEditCurvedPath(_:))) ?? false {
                _delegate?.cprViewWillEditCurvedPath?(self)
            }
        }
        _editingCurvedPathCount += 1
    }

    @objc(_sendDidUpdateCurvedPath)
    private dynamic func _sendDidUpdateCurvedPath() {
        if _delegate?.responds(to: #selector(CPRViewDelegate.cprViewDidUpdateCurvedPath(_:))) ?? false {
            _delegate?.cprViewDidUpdateCurvedPath?(self)
        }
    }

    @objc(_sendDidEditCurvedPath)
    private dynamic func _sendDidEditCurvedPath() {
        _editingCurvedPathCount -= 1
        if _editingCurvedPathCount == 0 {
            if _delegate?.responds(to: #selector(CPRViewDelegate.cprViewDidEditCurvedPath(_:))) ?? false {
                _delegate?.cprViewDidEditCurvedPath?(self)
            }
        }
    }

    @objc(_sendWillEditDisplayInfo)
    private dynamic func _sendWillEditDisplayInfo() {
        if _delegate?.responds(to: #selector(CPRViewDelegate.cprViewWillEditDisplayInfo(_:))) ?? false {
            _delegate?.cprViewWillEditDisplayInfo?(self)
        }
    }

    @objc(_sendDidEditDisplayInfo)
    private dynamic func _sendDidEditDisplayInfo() {
        if _delegate?.responds(to: #selector(CPRViewDelegate.cprViewDidEditDisplayInfo(_:))) ?? false {
            _delegate?.cprViewDidEditDisplayInfo?(self)
        }
    }

    @objc(_sendNewRequest)
    private dynamic func _sendNewRequest() {
        var request: CPRStraightenedGeneratorRequest

        if (_curvedPath?.bezierPath?.elementCount() ?? 0) >= 3 {
            request = CPRStraightenedGeneratorRequest()

            request.interpolationMode = cprWindowController?.selectedInterpolationMode ?? 0

            if (cprWindowController?.viewsPosition ?? 0) == ViewsPosition(VerticalPosition.rawValue) {
                request.pixelsWide = cUInt(Double(self.bounds.size.height * 1.2))
                request.pixelsHigh = cUInt(Double(self.bounds.size.width * 1.2))
            } else {
                request.pixelsWide = cUInt(Double(self.bounds.size.width * 1.2))
                request.pixelsHigh = cUInt(Double(self.bounds.size.height * 1.2))
            }
            request.slabWidth = _curvedPath?.thickness ?? 0

            request.slabSampleDistance = 0
            request.bezierPath = _curvedPath?.bezierPath
            request.initialNormal = _curvedPath?.initialNormal ?? N3Vector()
            request.projectionMode = _clippingRangeMode
            //        request.vertical = NO;

            if (_lastRequest?.isEqual(request) ?? false) == false {
                var packed: [NSNumber] = []
                for case let value as NSValue in _curvedPath?.nodes ?? NSArray() {
                    let node = value.n3VectorValue()
                    packed.append(NSNumber(value: Double(node.x)))
                    packed.append(NSNumber(value: Double(node.y)))
                    packed.append(NSNumber(value: Double(node.z)))
                }
                let session = self.horosStraightenedSession()
                session?.replacePackedNodes(packed)
                let decision = session?.beginGeneration(pixelsWide: Int(bitPattern: request.pixelsWide))
                if (decision?.accepted ?? false) == false {
                    NSLog("CPR straightened: %@", decision?.diagnosis ?? "(null)")

                    // lastRequest names the request the generator is working on.
                    // Recording one that was never sent made an identical request
                    // compare equal and be skipped for ever, so a panel refused
                    // once stayed blank even after the curve became valid again.
                    _needsNewRequest = false
                    return
                }
                _generator?.requestVolume(request)
                self.lastRequest = request
            }
        } else {
            self.setPixels(nil, files: nil, rois: nil, firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: true)
        }

        _needsNewRequest = false
    }

    @objc(_setNeedsNewRequest)
    public dynamic func _setNeedsNewRequest() {
        _needsNewRequest = true
        self.needsDisplay = true
        //	if (_needsNewRequest == NO) {
        //		[self performSelector:@selector(_sendNewRequestIfNeeded) withObject:nil afterDelay:0 inModes:[NSArray arrayWithObject:NSRunLoopCommonModes]];
        //	}
        //    _needsNewRequest = YES;
    }

    @objc(_sendNewRequestIfNeeded)
    private dynamic func _sendNewRequestIfNeeded() {
        if _needsNewRequest {
            self._sendNewRequest()
        }
    }

    @objc(_updateGeneratedHeight)
    private dynamic func _updateGeneratedHeight() {
        var newGeneratedHeight: CGFloat

        newGeneratedHeight = (curvedPathLength / NSWidth(self.bounds)) * NSHeight(self.bounds)

        if newGeneratedHeight != _generatedHeight {
            _generatedHeight = newGeneratedHeight
            if _delegate?.responds(to: #selector(CPRViewDelegate.cprViewDidChangeGeneratedHeight(_:))) ?? false {
                _delegate?.cprViewDidChangeGeneratedHeight?(self)
            }
        }
    }

    @objc(_adjustROIs)
    private dynamic func _adjustROIs() {
        if (self.curvedPath?.isPlaneMeasurable() ?? false) == false {
            var i = 0
            while i < (self.curRoiList?.count ?? 0) {
                let r = self.curRoiList?.object(at: i) as? ROI
                if r?.type != .tMesure && r?.type != .tText && r?.type != .tArrow {
                    NotificationCenter.default.post(name: NSNotification.Name.OsirixRemoveROI, object: r, userInfo: nil)
                    self.curRoiList?.removeObject(at: i)
                    i -= 1
                } else {
                    r?.displayCMOrPixels = true // We don't want the value in pixels
                }
                i += 1
            }

            for case let c as ROI in self.curRoiList ?? NSMutableArray() {
                if c.type == .tMesure {
                    let points = c.points

                    var A = (points?.object(at: 0) as? MyPoint)?.point ?? NSZeroPoint
                    var B = (points?.object(at: 1) as? MyPoint)?.point ?? NSZeroPoint

                    if abs(A.x - B.x) > 4 || abs(A.y - B.y) > 4 {
                        if abs(A.x - B.x) > abs(A.y - B.y) || A.y == CGFloat(curPHeight / 2) {
                            // Horizontal length -> centered in y, and horizontal

                            A.y = CGFloat(curPHeight / 2)
                            B.y = CGFloat(curPHeight / 2)

                            (points?.object(at: 0) as? MyPoint)?.point = A
                            (points?.object(at: 1) as? MyPoint)?.point = B
                        } else {
                            // Vectical length -> vertical

                            A.x = B.x

                            (points?.object(at: 0) as? MyPoint)?.point = A
                            (points?.object(at: 1) as? MyPoint)?.point = B
                        }
                    }
                }
            }
        } else {
            for case let r as ROI in self.curRoiList ?? NSMutableArray() {
                r.displayCMOrPixels = true
            }
        }

        self.needsDisplay = true
    }

    @objc(_drawVerticalLines:)
    private dynamic func _drawVerticalLines(_ verticalLines: NSArray?) {
        var lineStart: N3Vector
        var lineEnd: N3Vector
        var pixToSubdrawRectOpenGLTransform = [Double](repeating: 0, count: 16)

        N3AffineTransformGetOpenGLMatrixd(self.pixToSubDrawRectTransform(), &pixToSubdrawRectOpenGLTransform)
        roiMatrixMode(GL_MODELVIEW)
        roiPushMatrix()
        roiMultMatrixd(pixToSubdrawRectOpenGLTransform)
        for indexNumber in verticalLines ?? NSArray() {
            lineStart = N3VectorMake(CGFloat((indexNumber as AnyObject).doubleValue), 0, 0)
            lineEnd = N3VectorMake(CGFloat((indexNumber as AnyObject).doubleValue), CGFloat(curPHeight), 0)
            roiBegin(GL_LINE_STRIP)
            roiVertex2d(Double(lineStart.x), Double(lineStart.y))
            roiVertex2d(Double(lineEnd.x), Double(lineEnd.y))
            roiEnd()
        }
        roiPopMatrix()
    }

    @objc(_drawPlaneRuns:)
    private dynamic func _drawPlaneRuns(_ planeRuns: NSArray?) {
        var pixelsPerMm: CGFloat
        var i: Int
        var planePointVector: N3Vector
        var pixToSubdrawRectOpenGLTransform = [Double](repeating: 0, count: 16)
        var pheight_2: CGFloat

        pixelsPerMm = CGFloat(curPWidth) / curvedPathLength
        pheight_2 = CGFloat(curPHeight) / 2.0

        N3AffineTransformGetOpenGLMatrixd(self.pixToSubDrawRectTransform(), &pixToSubdrawRectOpenGLTransform)
        roiMatrixMode(GL_MODELVIEW)
        roiPushMatrix()
        roiMultMatrixd(pixToSubdrawRectOpenGLTransform)
        for case let planeRun as _CPRStraightenedViewPlaneRun in planeRuns ?? NSArray() {
            roiBegin(GL_LINE_STRIP)
            i = 0
            while i < planeRun.range.length {
                planePointVector = N3VectorMake(CGFloat(planeRun.range.location + i), (CGFloat((planeRun.distances.object(at: i) as AnyObject).doubleValue) * pixelsPerMm) + pheight_2, 0)
                roiVertex2d(Double(planePointVector.x), Double(planePointVector.y))
                i += 1
            }
            roiEnd()
        }
        roiPopMatrix()
    }

    @objc(_runsForPlane:verticalLineIndexes:)
    private dynamic func _runs(forPlane plane: N3Plane, verticalLineIndexes verticalLinesHandle: AutoreleasingUnsafeMutablePointer<NSArray?>?) -> NSArray {
        var numVectors: Int
        var i: Int
        var topPointAbove: Bool
        var bottomPointAbove: Bool
        var prevBottomPointAbove = false
        var runs: NSMutableArray
        var verticalLines: NSMutableArray?
        var mmPerPixel: CGFloat
        var halfHeight: CGFloat
        var distance: CGFloat
        var normals: UnsafeMutablePointer<N3Vector>?
        var points: UnsafeMutablePointer<N3Vector>?
        var bottom: N3Vector
        var top: N3Vector
        var planeRun: _CPRStraightenedViewPlaneRun?
        var range = NSRange(location: 0, length: 0)
        var aboveOrBelow: Int
        var prevAboveOrBelow = 0

        points = malloc(curPWidth &* MemoryLayout<N3Vector>.size)?.assumingMemoryBound(to: N3Vector.self)
        normals = malloc(curPWidth &* MemoryLayout<N3Vector>.size)?.assumingMemoryBound(to: N3Vector.self)
        runs = NSMutableArray()
        planeRun = nil

        if let verticalLinesHandle {
            verticalLines = NSMutableArray()
            verticalLinesHandle.pointee = verticalLines
        } else {
            verticalLines = nil
        }

        mmPerPixel = curvedPathLength / CGFloat(curPWidth)
        halfHeight = (CGFloat(curPHeight) * mmPerPixel) / 2.0
        numVectors = N3BezierCoreGetVectorInfo(_curvedPath?.bezierPath?.n3BezierCore(), curvedPathLength / CGFloat(curPWidth), 0, _curvedPath?.initialNormal ?? N3Vector(), points, nil, normals, curPWidth)

        i = 0
        while i < numVectors {
            bottom = N3VectorAdd(points![i], N3VectorScalarMultiply(normals![i], -halfHeight))
            top = N3VectorAdd(points![i], N3VectorScalarMultiply(normals![i], halfHeight))

            bottomPointAbove = N3VectorDotProduct(plane.normal, N3VectorSubtract(bottom, plane.point)) > 0.0
            topPointAbove = N3VectorDotProduct(plane.normal, N3VectorSubtract(top, plane.point)) > 0.0

            if !bottomPointAbove && !topPointAbove {
                aboveOrBelow = -1
            } else if bottomPointAbove && topPointAbove {
                aboveOrBelow = 1
            } else {
                aboveOrBelow = 0
            }

            if i == 0 {
                prevAboveOrBelow = aboveOrBelow
            }

            if bottomPointAbove != topPointAbove {
                if planeRun == nil { //start a new run
                    planeRun = _CPRStraightenedViewPlaneRun()
                    range = planeRun!.range
                    if i != 0 {
                        range.location = i - 1
                        range.length = 1
                        if prevBottomPointAbove != bottomPointAbove {
                            planeRun?.distances.add(NSNumber(value: Double(-halfHeight)))
                        } else {
                            planeRun?.distances.add(NSNumber(value: Double(halfHeight)))
                        }
                    }
                }
                distance = N3VectorDotProduct(N3VectorSubtract(N3LineIntersectionWithPlane(N3LineMakeFromPoints(bottom, top), plane), points![i]), normals![i])
                planeRun?.distances.add(NSNumber(value: Double(distance)))
                range.length += 1
            } else {
                if let run = planeRun { // finish up and save the last run
                    if NSMaxRange(range) < numVectors {
                        range.length += 1
                        if prevBottomPointAbove != bottomPointAbove {
                            run.distances.add(NSNumber(value: Double(-halfHeight)))
                        } else {
                            run.distances.add(NSNumber(value: Double(halfHeight)))
                        }
                    }
                    run.range = range
                    runs.add(run)
                    planeRun = nil
                } else if abs(prevAboveOrBelow - aboveOrBelow) == 2 { // if we switched sides without ever getting any points, put in a vertical line
                    verticalLines?.add(NSNumber(value: i))
                }
            }

            prevAboveOrBelow = aboveOrBelow
            prevBottomPointAbove = bottomPointAbove
            i += 1
        }

        if let run = planeRun {
            run.range = range
            runs.add(run)
            planeRun = nil
        }

        free(points)
        free(normals)

        return runs
    }

    @objc(_updateMousePlanePointsForViewPoint:)
    private dynamic func _updateMousePlanePoints(forViewPoint point: NSPoint) { // this will modify _mousePlanePointsInPix and _displayInfo
        var lineDistance: CGFloat
        var runDistance: CGFloat
        var linePixVector: N3Vector
        var lineVolumeVector: N3Vector
        var runPixVector: N3Vector
        var runVolumeVector: N3Vector
        var verticalLines: NSArray?
        var planeRuns: NSArray?

        linePixVector = N3VectorZero
        lineVolumeVector = N3VectorZero
        runPixVector = N3VectorZero
        runVolumeVector = N3VectorZero

        _displayInfo?.clearAllMouseVectors()
        _mousePlanePointsInPix?.removeAllObjects()

        for (key, _) in _planes ?? NSMutableDictionary() {
            guard let planeName = key as? String else { continue }
            verticalLines = self.value(forKey: planeName + "VerticalLines") as? NSArray
            planeRuns = self.value(forKey: planeName + "PlaneRuns") as? NSArray
            lineDistance = self._distance(toPoint: point, onVerticalLines: verticalLines, pixVector: &linePixVector, volumeVector: &lineVolumeVector)
            runDistance = self._distance(toPoint: point, onPlaneRuns: planeRuns, pixVector: &runPixVector, volumeVector: &runVolumeVector)
            if cMIN(lineDistance, runDistance) < 30 {
                if lineDistance < runDistance {
                    _mousePlanePointsInPix?.setObject(NSValue(n3Vector: linePixVector)!, forKey: planeName as NSString)
                    _displayInfo?.setMouseVector(lineVolumeVector, forPlane: planeName)
                } else {
                    _mousePlanePointsInPix?.setObject(NSValue(n3Vector: runPixVector)!, forKey: planeName as NSString)
                    _displayInfo?.setMouseVector(runVolumeVector, forPlane: planeName)
                }
            }
        }
    }

    /// point and distance are in view coordinates, vector is in patient
    /// coordinates closestPoint is in pixCoordinates.
    @objc(_distanceToPoint:onVerticalLines:pixVector:volumeVector:)
    private dynamic func _distance(toPoint point: NSPoint, onVerticalLines verticalLines: NSArray?, pixVector closestPixVectorPtr: UnsafeMutablePointer<N3Vector>?, volumeVector volumeVectorPtr: UnsafeMutablePointer<N3Vector>?) -> CGFloat {
        var pixToViewTransform: N3AffineTransform
        var pixelsPerMm: CGFloat
        var pixPointVector: N3Vector
        var pixVector: N3Vector
        var lineStart: N3Vector
        var lineEnd: N3Vector
        var relativePosition: CGFloat
        var distance: CGFloat
        var minDistance: CGFloat
        var normalVector: N3Vector

        pixToViewTransform = N3AffineTransformInvert(self.viewToPixTransform())
        minDistance = CGFloat.greatestFiniteMagnitude
        pixPointVector = N3VectorApplyTransform(N3VectorMakeFromNSPoint(point), self.viewToPixTransform())
        pixelsPerMm = CGFloat(curPWidth) / curvedPathLength

        for indexNumber in verticalLines ?? NSArray() {
            let indexValue = CGFloat((indexNumber as AnyObject).doubleValue)
            lineStart = N3VectorMake(indexValue, 0, 0)
            lineEnd = N3VectorMake(indexValue, CGFloat(curPHeight), 0)

            distance = N3VectorDistanceToLine(N3VectorMakeFromNSPoint(point), N3LineApplyTransform(N3LineMakeFromPoints(lineStart, lineEnd), pixToViewTransform))
            if distance < minDistance {
                minDistance = distance
                if let closestPixVectorPtr {
                    pixVector = N3VectorMake(indexValue, pixPointVector.y, 0)
                    closestPixVectorPtr.pointee = pixVector
                }

                if let volumeVectorPtr {
                    relativePosition = indexValue / CGFloat(curPWidth)
                    normalVector = _curvedPath?.bezierPath?.normal(atRelativePosition: relativePosition, initialNormal: _curvedPath?.initialNormal ?? N3Vector()) ?? N3Vector()
                    volumeVectorPtr.pointee = N3VectorAdd(_curvedPath?.bezierPath?.vector(atRelativePosition: relativePosition) ?? N3Vector(), N3VectorScalarMultiply(normalVector, (pixPointVector.y - CGFloat(curPHeight) / 2.0) / pixelsPerMm))
                }
            }
        }
        return minDistance
    }

    /// point and distance are in view coordinates, vector is in patient
    /// coordinates closestPoint is in pixCoordinates.
    @objc(_distanceToPoint:onPlaneRuns:pixVector:volumeVector:)
    private dynamic func _distance(toPoint point: NSPoint, onPlaneRuns planeRuns: NSArray?, pixVector closestPixVectorPtr: UnsafeMutablePointer<N3Vector>?, volumeVector volumeVectorPtr: UnsafeMutablePointer<N3Vector>?) -> CGFloat {
        var pixelsPerMm: CGFloat
        var closeVector = N3Vector()
        var closestVector: N3Vector
        var pointVector: N3Vector
        var normalVector: N3Vector
        var distance: CGFloat = 0
        var minDistance: CGFloat
        var relativePosition: CGFloat
        var planeRunBezierPath: N3MutableBezierPath?

        pointVector = N3VectorMakeFromNSPoint(point)
        pixelsPerMm = CGFloat(curPWidth) / curvedPathLength
        minDistance = CGFloat.greatestFiniteMagnitude
        closestVector = N3VectorZero

        for case let planeRun as _CPRStraightenedViewPlaneRun in planeRuns ?? NSArray() {
            planeRunBezierPath = mutableBezierPath(withCPRStraightenedViewPlaneRun: planeRun, heightPixelsPerMm: pixelsPerMm)
            planeRunBezierPath?.applyAffineTransform(N3AffineTransformMakeTranslation(0, CGFloat(curPHeight) / 2.0, 0))
            planeRunBezierPath?.applyAffineTransform(N3AffineTransformInvert(self.viewToPixTransform()))

            N3BezierCoreRelativePositionClosestToVector(planeRunBezierPath?.n3BezierCore(), pointVector, &closeVector, &distance)
            if distance < minDistance {
                minDistance = distance
                closestVector = N3VectorApplyTransform(closeVector, self.viewToPixTransform())
                closestVector.y -= CGFloat(curPHeight) / 2.0
            }
            planeRunBezierPath = nil
        }

        if let closestPixVectorPtr {
            closestPixVectorPtr.pointee = N3VectorMake(closestVector.x, closestVector.y + CGFloat(curPHeight) / 2.0, 0)
        }
        if let volumeVectorPtr {
            relativePosition = closestVector.x / CGFloat(curPWidth)
            normalVector = _curvedPath?.bezierPath?.normal(atRelativePosition: relativePosition, initialNormal: _curvedPath?.initialNormal ?? N3Vector()) ?? N3Vector()
            volumeVectorPtr.pointee = N3VectorAdd(_curvedPath?.bezierPath?.vector(atRelativePosition: relativePosition) ?? N3Vector(), N3VectorScalarMultiply(normalVector, closestVector.y / pixelsPerMm))
        }

        return minDistance
    }

    @objc(_buildVerticalLinesAndPlaneRunsForPlaneFullName:)
    private dynamic func _buildVerticalLinesAndPlaneRuns(forPlaneFullName planeFullName: String) {
        var planeName: String
        var plane: N3Plane
        var slabThickness: CGFloat
        var planeRuns: NSArray
        var vertialLines: NSArray? = nil
        let fullName = planeFullName as NSString

        if fullName.hasSuffix("Top") {
            planeName = fullName.substring(to: fullName.length - 3)
            slabThickness = CGFloat((self.value(forKey: planeName + "SlabThickness") as AnyObject?)?.doubleValue ?? 0)
            if slabThickness == 0 {
                return
            }
        } else if fullName.hasSuffix("Bottom") {
            planeName = fullName.substring(to: fullName.length - 6)
            slabThickness = -CGFloat((self.value(forKey: planeName + "SlabThickness") as AnyObject?)?.doubleValue ?? 0)
            if slabThickness == 0 {
                return
            }
        } else {
            planeName = planeFullName
            slabThickness = 0
        }

        plane = (self.value(forKey: planeName + "Plane") as? NSValue)?.n3PlaneValue() ?? N3Plane()
        if N3PlaneIsValid(plane) {
            plane.normal = N3VectorNormalize(plane.normal)
            plane.point = N3VectorAdd(plane.point, N3VectorScalarMultiply(plane.normal, slabThickness / 2.0))
            planeRuns = self._runs(forPlane: plane, verticalLineIndexes: &vertialLines)
            _verticalLines?.setValue(vertialLines, forKey: planeFullName)
            _planeRuns?.setValue(planeRuns, forKey: planeFullName)
        }
    }

    @objc(_clearAllPlanes)
    private dynamic func _clearAllPlanes() {
        _verticalLines?.removeAllObjects()
        _planeRuns?.removeAllObjects()
    }

    // The proxies of +resolveInstanceMethod:. Sent under their own selector they
    // read their own name as the former ones read _cmd.

    @objc(_planeSetter:)
    private dynamic func _planeSetter(_ plane: N3Plane) {
        planeSetterBody(plane, selectorName: "_planeSetter:")
    }

    @objc(_planeGetter)
    private dynamic func _planeGetter() -> N3Plane {
        return planeGetterBody(selectorName: "_planeGetter")
    }

    @objc(_slabThicknessSetter:)
    private dynamic func _slabThicknessSetter(_ thickness: CGFloat) {
        slabThicknessSetterBody(thickness, selectorName: "_slabThicknessSetter:")
    }

    @objc(_slabThicknessGetter)
    private dynamic func _slabThicknessGetter() -> CGFloat {
        return slabThicknessGetterBody(selectorName: "_slabThicknessGetter")
    }

    @objc(_planeColorSetter:)
    private dynamic func _planeColorSetter(_ color: NSColor?) {
        planeColorSetterBody(color, selectorName: "_planeColorSetter:")
    }

    @objc(_planeColorGetter)
    private dynamic func _planeColorGetter() -> NSColor? {
        return planeColorGetterBody(selectorName: "_planeColorGetter")
    }

    /// The bodies of the proxies, given the name of the selector they answer.
    private func planeSetterBody(_ plane: N3Plane, selectorName: String) {
        let selectorName = selectorName as NSString
        var planeName: NSString

        planeName = selectorName.replacingCharacters(in: NSMakeRange(0, 4), with: selectorName.substring(with: NSMakeRange(3, 1)).lowercased()) as NSString
        planeName = planeName.substring(to: planeName.length - 6) as NSString
        _verticalLines?.removeObject(forKey: planeName)
        _verticalLines?.removeObject(forKey: planeName.appending("Top"))
        _verticalLines?.removeObject(forKey: planeName.appending("Bottom"))
        _planeRuns?.removeObject(forKey: planeName)
        _planeRuns?.removeObject(forKey: planeName.appending("Top"))
        _planeRuns?.removeObject(forKey: planeName.appending("Bottom"))

        _planes?.setValue(NSValue(n3Plane: plane), forKey: planeName as String)
        self.needsDisplay = true
    }

    private func planeGetterBody(selectorName: String) -> N3Plane {
        let selectorName = selectorName as NSString
        var planeName: String

        planeName = selectorName.substring(to: selectorName.length - 5)
        return (_planes?.value(forKey: planeName) as? NSValue)?.n3PlaneValue() ?? N3Plane()
    }

    private func slabThicknessSetterBody(_ thickness: CGFloat, selectorName: String) {
        let selectorName = selectorName as NSString
        var planeName: NSString

        planeName = selectorName.replacingCharacters(in: NSMakeRange(0, 4), with: selectorName.substring(with: NSMakeRange(3, 1)).lowercased()) as NSString
        planeName = planeName.substring(to: planeName.length - 14) as NSString
        _verticalLines?.removeObject(forKey: planeName)
        _planeRuns?.removeObject(forKey: planeName)
        _slabThicknesses?.setValue(NSNumber(value: Double(thickness)), forKey: planeName as String)
        self.needsDisplay = true
    }

    private func slabThicknessGetterBody(selectorName: String) -> CGFloat {
        let selectorName = selectorName as NSString
        var planeName: String

        planeName = selectorName.substring(to: selectorName.length - 13)
        return CGFloat((_slabThicknesses?.value(forKey: planeName) as AnyObject?)?.doubleValue ?? 0)
    }

    private func planeColorSetterBody(_ color: NSColor?, selectorName: String) {
        let selectorName = selectorName as NSString
        var planeName: NSString

        planeName = selectorName.replacingCharacters(in: NSMakeRange(0, 4), with: selectorName.substring(with: NSMakeRange(3, 1)).lowercased()) as NSString
        planeName = planeName.substring(to: planeName.length - 11) as NSString
        _planeColors?.setValue(color, forKey: planeName as String)
        self.needsDisplay = true
    }

    private func planeColorGetterBody(selectorName: String) -> NSColor? {
        let selectorName = selectorName as NSString
        var planeName: String

        planeName = selectorName.substring(to: selectorName.length - 10)
        if _planeColors?.value(forKey: planeName) == nil {
            _planeColors?.setValue(NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1), forKey: planeName)
        }
        return _planeColors?.value(forKey: planeName) as? NSColor
    }

    @objc(_osirixUpdateVolumeDataNotification:)
    private dynamic func _osirixUpdateVolumeDataNotification(_ notification: Notification?) {
        self.lastRequest = nil
        self._setNeedsNewRequest()
    }
}
