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
//  CPRStretchedView.m
//  OsiriX
//
//  Created by Joël Spaltenstein on 6/4/11.
//  Copyright 2011 OsiriX Team. All rights reserved.
//

import Cocoa

// The file-level static and macro of the former CPRStretchedView.m.
private let deg2rad: Float = Float(Double.pi / 180.0)
private let _extraWidthFactor: Double = 1.2

// The OpenGL enumerants ROICanvasGL.h names, which Swift cannot import: that
// header imports Horos-Swift.h.
private let GL_POINTS: UInt32 = 0x0000
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

// The static inline functions of ROICanvasGL.h, with the same parameter types:
// a GLfloat argument goes through a float, a GLdouble through a double, as it did.
private func roiBlendFunc(_ source: UInt32, _ destination: UInt32) { ROICanvas.current?.blend(source: source, destination: destination) }
private func roiEnable(_ cap: UInt32) { ROICanvas.current?.enable(cap) }
private func roiDisable(_ cap: UInt32) { ROICanvas.current?.disable(cap) }
private func roiPointSize(_ s: Float) { ROICanvas.current?.pointSize(CGFloat(s)) }
private func roiLineWidth(_ w: Float) { ROICanvas.current?.lineWidth(CGFloat(w)) }
private func roiColor3f(_ r: Float, _ g: Float, _ b: Float) {
    ROICanvas.current?.color(r: CGFloat(r), g: CGFloat(g), b: CGFloat(b), a: 1)
}
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
private func roiMatrixMode(_ mode: UInt32) {}
private func roiLoadIdentity() { ROICanvas.current?.loadIdentity() }
private func roiPushMatrix() { ROICanvas.current?.pushMatrix() }
private func roiPopMatrix() { ROICanvas.current?.popMatrix() }
private func roiScalef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.scale(x: Double(x), y: Double(y), z: Double(z)) }
private func roiTranslatef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.translate(x: Double(x), y: Double(y), z: Double(z)) }
private func roiMultMatrixd(_ m: UnsafePointer<Double>) { ROICanvas.current?.mult(m) }

/// A float converted to int as the arm64 code of the former C did (fcvtzs):
/// toward zero, saturated, NaN to 0; a Swift conversion traps instead.
private func cInt32(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483647.0 { return Int32.max }
    if x <= -2147483648.0 { return Int32.min }
    return Int32(x)
}

/// A double converted to NSUInteger as the arm64 code of the former C did
/// (fcvtzu): toward zero, saturated, NaN and negatives to 0.
private func cUInt(_ x: Double) -> UInt {
    if x.isNaN || x <= 0 { return 0 }
    if x >= 18446744073709551615.0 { return UInt.max }
    return UInt(x)
}

// MIN, MAX and ABS of Foundation, whose NaN and -0 results differ from
// Swift's min, max and abs.
private func cMIN(_ a: CGFloat, _ b: CGFloat) -> CGFloat { return a < b ? a : b }
private func cMAX(_ a: CGFloat, _ b: CGFloat) -> CGFloat { return a < b ? b : a }
private func cABS(_ a: CGFloat) -> CGFloat { return a < 0 ? -a : a }

/// assert() of the Objective-C: checked in Debug only.
@inline(__always)
private func debugAssert(_ condition: @autoclosure () -> Bool) {
    #if DEBUG
    precondition(condition())
    #endif
}

/// -[DCMPix setArrayPix::], sent with the NSArray itself: Swift imports the
/// parameter as [Any], whose bridging would hand each pix a copy of the list.
private typealias SetArrayPixIMP = @convention(c) (AnyObject, Selector, NSArray?, Int16) -> Void

/// The private helper class of the former CPRStretchedView.m: a run of
/// consecutive pixel columns and, for each one, the distance in mm from the
/// mid-height of the stretched image.
private final class _CPRStretchedViewPlaneRun: NSObject {
    var range = NSRange(location: 0, length: 0)
    var distances: NSMutableArray!

    override init() {
        super.init()
        distances = NSMutableArray()
    }

    // -dealloc released _distances: Swift releases it.
}

/// -[N3BezierPath initWithCPRStretchedViewPlaneRun:heightPixelsPerMm:], the
/// category of the former file. That init autoreleased the object it was sent
/// to and returned a new N3MutableBezierPath instead: this returns that path.
private func bezierPathWithCPRStretchedViewPlaneRun(_ planeRun: _CPRStretchedViewPlaneRun, heightPixelsPerMm pixelsPerMm: CGFloat) -> N3MutableBezierPath? {
    let mutableBezierPath = N3MutableBezierPath()
    var i = planeRun.range.location
    while UInt(bitPattern: i) < UInt(bitPattern: NSMaxRange(planeRun.range)) {
        let distance = (planeRun.distances.object(at: i - planeRun.range.location) as! NSNumber).doubleValue
        if i == planeRun.range.location {
            mutableBezierPath?.move(to: N3VectorMake(CGFloat(i), CGFloat(distance) * pixelsPerMm, 0))
        } else {
            mutableBezierPath?.line(to: N3VectorMake(CGFloat(i), CGFloat(distance) * pixelsPerMm, 0))
        }
        i += 1
    }

    return mutableBezierPath
}

/// The stretched curved MPR of the CPR window: the volume resampled along the
/// curved path, projected along a normal so that the path keeps its length,
/// with the other planes, the transverse sections and the nodes drawn over it.
///
/// Implemented in Swift since #824: the Objective-C name, the selectors and
/// <Horos/CPRStretchedView.h> are those of the former class, the customClass of
/// the stretched view of CPR.xib. Its superclass, DCMView, stays in
/// Objective-C; the ivars it reads of it go through DCMView+SwiftIvars.h.
@objc(CPRStretchedView)
public final class CPRStretchedView: DCMView, CPRGeneratorDelegate {
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

    private var _transverseVerticalLines: NSMutableDictionary? = nil
    private var _transversePlaneRuns: NSMutableDictionary? = nil

    /// The display info stores on what plane and where in 3D the mouse position
    /// dots are, but we want to cache where the dots should be drawn in this view.
    private var _mousePlanePointsInPix: NSMutableDictionary? = nil

    private var _clippingRangeMode: CPRViewClippingRangeMode = 0

    private var _curvedVolumeData: CPRVolumeData? = nil

    private var _lastRequest: CPRStretchedGeneratorRequest? = nil
    private var _generatedHeight: CGFloat = 0

    private var _draggingTransverse = false
    private var _draggingTransverseSpacing = false

    private var _isDraggingNode = false
    private var _draggedNode: Int = 0
    /// Whether the node drag sent «will edit» (#854): a click on an end node
    /// only moves the cross, and its mouse up must not send «did edit».
    private var _isEditingDraggedNode = false

    private var _editingCurvedPathCount: Int = 0

    private var _drawAllNodes = false

    /// Synchronous new image requests are generated in drawRect, but code that
    /// handles the new image calls setNeedsDisplay, so this variable is used to
    /// short circuit setNeedsDisplay while the image is being generated.
    private var _processingRequest = false
    private var _needsNewRequest = false

    private var _displayCrossLines = false
    private var _displayTransverseLines = false

    /// The centerline path of the most recently generated DCM.
    private var _centerlinePath: N3BezierPath? = nil
    /// A point in patient space that is mid-height in the curDCM.
    private var _midHeightPoint = N3Vector()
    private var _projectionNormal = N3Vector()

    private var stanStringAttrib: NSMutableDictionary? = nil

    /// [self windowController], an id in DCMView.h: the CPRController of the
    /// view's window.
    private var cprController: CPRController? {
        return self.windowController() as? CPRController
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
                self._clearTransversePlanes()
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
                    self.setFusion(Int16(truncatingIfNeeded: type(of: self)._fusionModeForCPRViewClippingRangeMode(_clippingRangeMode)),
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

    /// The readwrite redeclaration of the class extension: -setCurvedVolumeData:.
    @objc(setCurvedVolumeData:)
    private dynamic func setCurvedVolumeData(_ curvedVolumeData: CPRVolumeData?) {
        _curvedVolumeData = curvedVolumeData
    }

    /// Height of the image that is generated in mm. kinda hack sends
    /// CPRViewDidChangeGeneratedHeight to the delegate when this value changes.
    @objc public dynamic var generatedHeight: CGFloat {
        return _generatedHeight
    }

    // The nine plane properties were @dynamic: +resolveInstanceMethod: added
    // them on first use, as the _plane..., _slabThickness... and _planeColor...
    // getters and setters, which read the plane name from _cmd. They are
    // declared here, each passing the selector the runtime would have given;
    // +resolveInstanceMethod: still resolves any other such selector.

    /// Set these to N3PlaneInvalid to keep the plane from appearing.
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
                self.cprController?.updateToolbarItems()
            }
        }
    }

    // The properties of the class extension.

    @objc(lastRequest)
    private dynamic var lastRequest: CPRStretchedGeneratorRequest? {
        get { return _lastRequest }
        set { _lastRequest = newValue }
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

    @objc(centerlinePath)
    private dynamic var centerlinePath: N3BezierPath? {
        get { return _centerlinePath }
        set { _centerlinePath = newValue }
    }

    // MARK: - Dynamic plane accessors

    public override class func resolveInstanceMethod(_ selector: Selector!) -> Bool {
        let methodName: NSString
        var proxySelector: Selector?

        methodName = NSStringFromSelector(selector) as NSString
        proxySelector = nil

        if methodName.hasPrefix("get") == false && methodName.hasPrefix("set") == false {
            if methodName.hasSuffix("Plane") {
                proxySelector = #selector(CPRStretchedView._planeGetter)
            } else if methodName.hasSuffix("SlabThickness") {
                proxySelector = #selector(CPRStretchedView._slabThicknessGetter)
            } else if methodName.hasSuffix("PlaneColor") {
                proxySelector = #selector(CPRStretchedView._planeColorGetter)
            }
        } else if methodName.hasPrefix("set") {
            if methodName.hasSuffix("Plane:") {
                proxySelector = #selector(CPRStretchedView._planeSetter(_:))
            } else if methodName.hasSuffix("SlabThickness:") {
                proxySelector = #selector(CPRStretchedView._slabThicknessSetter(_:))
            } else if methodName.hasSuffix("PlaneColor:") {
                proxySelector = #selector(CPRStretchedView._planeColorSetter(_:))
            }
        }

        if let proxySelector = proxySelector {
            // The former code added the proxy's own IMP, which read the plane
            // name from _cmd; a Swift method cannot, so the IMP is a block that
            // runs the proxy's body with this selector's name.
            let selectorName = methodName as String
            let block: AnyObject
            switch proxySelector {
            case #selector(CPRStretchedView._planeGetter):
                let getter: @convention(block) (CPRStretchedView) -> N3Plane = { view in
                    return view.planeGetterBody(selectorName: selectorName)
                }
                block = unsafeBitCast(getter, to: AnyObject.self)
            case #selector(CPRStretchedView._slabThicknessGetter):
                let getter: @convention(block) (CPRStretchedView) -> CGFloat = { view in
                    return view.slabThicknessGetterBody(selectorName: selectorName)
                }
                block = unsafeBitCast(getter, to: AnyObject.self)
            case #selector(CPRStretchedView._planeColorGetter):
                let getter: @convention(block) (CPRStretchedView) -> NSColor? = { view in
                    return view.planeColorGetterBody(selectorName: selectorName)
                }
                block = unsafeBitCast(getter, to: AnyObject.self)
            case #selector(CPRStretchedView._planeSetter(_:)):
                let setter: @convention(block) (CPRStretchedView, N3Plane) -> Void = { view, plane in
                    view.planeSetterBody(plane, selectorName: selectorName)
                }
                block = unsafeBitCast(setter, to: AnyObject.self)
            case #selector(CPRStretchedView._slabThicknessSetter(_:)):
                let setter: @convention(block) (CPRStretchedView, CGFloat) -> Void = { view, thickness in
                    view.slabThicknessSetterBody(thickness, selectorName: selectorName)
                }
                block = unsafeBitCast(setter, to: AnyObject.self)
            default:
                let setter: @convention(block) (CPRStretchedView, NSColor?) -> Void = { view, color in
                    view.planeColorSetterBody(color, selectorName: selectorName)
                }
                block = unsafeBitCast(setter, to: AnyObject.self)
            }
            let imp = imp_implementationWithBlock(block)
            let typeEncoding = method_getTypeEncoding(class_getInstanceMethod(self, proxySelector)!)
            return class_addMethod(self, selector, imp, typeEncoding)
        }

        return super.resolveInstanceMethod(selector)
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
        _transverseVerticalLines = NSMutableDictionary()
        _transversePlaneRuns = NSMutableDictionary()
        _displayCrossLines = false
        _displayTransverseLines = true

        NotificationCenter.default.addObserver(self, selector: #selector(_osirixUpdateVolumeDataNotification(_:)), name: .OsirixUpdateVolumeData, object: nil)
    }

    /// Not overridden by the former class: passes through, so that DCMView's
    /// -initWithFrame:, which sends it to self, reaches DCMView's.
    public override init(frame frameRect: NSRect, imageRows rows: Int32, imageColumns columns: Int32) {
        super.init(frame: frameRect, imageRows: rows, imageColumns: columns)
    }

    /// Not overridden by the former class: passes through.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        _generator?.delegate = nil
        // The retained ivars (_generator, _volumeData, _curvedVolumeData,
        // _curvedPath, _displayInfo, _lastRequest, _centerlinePath, the plane
        // and line dictionaries, _mousePlanePointsInPix, stanStringAttrib) are
        // released with the Swift properties.

        self._clearAllPlanes()
    }

    // MARK: - Key-value coding

    public override func value(forKey key: String) -> Any? {
        let key = key as NSString
        var planeFullName: NSString // full plane name may include Top or Bottom before the plane name

        if key.hasSuffix("VerticalLines") {
            planeFullName = key.substring(to: key.length - 13) as NSString
            if _verticalLines?.value(forKey: planeFullName as String) == nil {
                self._buildVerticalLinesAndPlaneRuns(forPlaneFullName: planeFullName as String)
            }
            return _verticalLines?.object(forKey: planeFullName)
        } else if key.hasSuffix("PlaneRuns") {
            planeFullName = key.substring(to: key.length - 9) as NSString
            if _planeRuns?.value(forKey: planeFullName as String) == nil {
                self._buildVerticalLinesAndPlaneRuns(forPlaneFullName: planeFullName as String)
            }
            return _planeRuns?.value(forKey: planeFullName as String)
        } else {
            return super.value(forKey: key as String)
        }
    }

    // MARK: - DCMView

    @objc(mouseDraggedWindowLevel:)
    public override dynamic func mouseDraggedWindowLevel(_ event: NSEvent!) {
        super.mouseDraggedWindowLevel(event)

        self.cprController?.propagateWLWW(self)
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
            var length = Float(_curvedPath?.bezierPath?.length() ?? 0)

            let topLeft = self.curDCM?.annotationsDictionary?.object(forKey: "TopLeft") as? NSMutableArray

            length = Float(Double(length) * 0.1) // We want cm

            let transverseSectionPosition = Double(_curvedPath?.transverseSectionPosition ?? 0)
            let leftTransverseSectionPosition = Double(_curvedPath?.leftTransverseSectionPosition ?? 0)
            let rightTransverseSectionPosition = Double(_curvedPath?.rightTransverseSectionPosition ?? 0)

            topLeft?.add(NSArray(object: NSString(format: NSLocalizedString("A-B : %2.2f cm", comment: "") as NSString, Double(length) * fabs(transverseSectionPosition - leftTransverseSectionPosition))))
            topLeft?.add(NSArray(object: NSString(format: NSLocalizedString("B-C : %2.2f cm", comment: "") as NSString, Double(length) * fabs(transverseSectionPosition - rightTransverseSectionPosition))))
            topLeft?.add(NSArray(object: NSString(format: NSLocalizedString("A-C : %2.2f cm", comment: "") as NSString, Double(length) * fabs(leftTransverseSectionPosition - rightTransverseSectionPosition))))

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
            let lifecycle = self.cprController?.renderLifecycle
            let decision = lifecycle?.beginDraw(named: "stretched")
            if lifecycle != nil && (decision?.accepted ?? false) == false {
                NSLog("CPR draw skipped: %@", decision?.diagnosis ?? "(null)")

                // Returning paints nothing, and nothing marks this view again: the
                // panel would stay blank. Only the nested pass is unwanted, so ask
                // for another one once the stack has unwound.
                if decision?.phase == "reentrant" {
                    DispatchQueue.main.async { self.needsDisplay = true }
                }
                return
            }
            _processingRequest = true
            var raised: NSException? = nil
            do {
                try HorosObjCException.perform {
                    if self.curDCM != nil {
                        let geo = CPRRenderLifecycle.diagnoseSpacingX(self.curDCM.pixelSpacingX, spacingY: self.curDCM.pixelSpacingY)
                        if geo != "ready" {
                            NSLog("CPR invalid geometry: %@", geo)
                        }
                    }
                    self._sendNewRequestIfNeeded()

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
            lifecycle?.endDraw(named: "stretched")
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

    @objc(positionWithoutRotation:)
    public override dynamic func positionWithoutRotation(_ tPt: NSPoint) -> NSPoint {
        var tPt = tPt
        let scaleValue = self.horos_scaleValue
        var unrotatedRect = NSMakeRect(tPt.x / CGFloat(scaleValue), tPt.y / CGFloat(scaleValue), 1, 1)
        var centeredRect = unrotatedRect

        var ratio: Float = 1

        if self.pixelSpacingX != 0 && self.pixelSpacingY != 0 {
            ratio = Float(self.pixelSpacingX / self.pixelSpacingY)
        }

        centeredRect.origin.y -= self.origin.y * CGFloat(ratio) / CGFloat(scaleValue)
        centeredRect.origin.x -= -self.origin.x / CGFloat(scaleValue)

        unrotatedRect.origin.x = centeredRect.origin.x * CGFloat(cos(Double(-self.rotation * deg2rad))) + centeredRect.origin.y * CGFloat(sin(Double(-self.rotation * deg2rad))) / CGFloat(ratio)
        unrotatedRect.origin.y = -centeredRect.origin.x * CGFloat(sin(Double(-self.rotation * deg2rad))) + centeredRect.origin.y * CGFloat(cos(Double(-self.rotation * deg2rad))) / CGFloat(ratio)

        unrotatedRect.origin.y *= CGFloat(ratio)

        unrotatedRect.origin.y += self.origin.y * CGFloat(ratio) / CGFloat(scaleValue)
        unrotatedRect.origin.x += -self.origin.x / CGFloat(scaleValue)

        tPt = NSMakePoint(unrotatedRect.origin.x, unrotatedRect.origin.y)
        tPt.x = (tPt.x) * CGFloat(scaleValue) - unrotatedRect.size.width / 2
        tPt.y = (tPt.y) / CGFloat(ratio) * CGFloat(scaleValue) - unrotatedRect.size.height / 2 / CGFloat(ratio)

        return tPt
    }

    @objc(subDrawRect:)
    public override dynamic func subDraw(_ rect: NSRect) {
        var pixToSubdrawRectOpenGLTransform = [Double](repeating: 0, count: 16)
        var i: Int
        var endpoint = N3Vector()
        let centerline: N3BezierPath?
        var planeColor: NSColor?
        let pixToSubDrawRectTransform: N3AffineTransform
        var cursorVector: N3Vector
        var relativePosition: CGFloat

        roiEnable(GL_BLEND)
        roiEnable(GL_POLYGON_SMOOTH)
        roiEnable(GL_POINT_SMOOTH)
        roiEnable(GL_LINE_SMOOTH)
        roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

        if (self.curDCM?.pixelSpacingX ?? 0) == 0 {
            return
        }

        centerline = self.centerlinePath
        pixToSubDrawRectTransform = self.pixToSubDrawRectTransform()

        roiMatrixMode(GL_MODELVIEW)
        roiPushMatrix()
        N3AffineTransformGetOpenGLMatrixd(self.pixToSubDrawRectTransform(), &pixToSubdrawRectOpenGLTransform)
        roiMultMatrixd(pixToSubdrawRectOpenGLTransform)
        // draw the centerline.

        roiColor3f(0, 1, 0)
        roiLineWidth(Float(1.0 * (self.window?.backingScaleFactor ?? 0)))
        roiBegin(GL_LINE_STRIP)
        i = 0
        while i < (centerline?.elementCount() ?? 0) {
            _ = centerline?.element(at: i, control1: nil, control2: nil, endpoint: &endpoint)
            roiVertex2d(Double(endpoint.x), Double(endpoint.y))
            i += 1
        }
        roiEnd()

        roiColor4d(0.0, 1.0, 0.0, 0.8)

        if (self.cprController?.displayMousePosition ?? false) == true && (_displayInfo?.mouseCursorHidden ?? false) == false {
            cursorVector = self._centerlinePixVector(forRelativePosition: _displayInfo?.mouseCursorPosition ?? 0)

            roiEnable(GL_POINT_SMOOTH)
            roiPointSize(Float(8 * (self.window?.backingScaleFactor ?? 0)))

            roiBegin(GL_POINTS)
            roiVertex2f(Float(cursorVector.x), Float(cursorVector.y))
            roiEnd()
            roiDisable(GL_POINT_SMOOTH)
        }

        roiPopMatrix()

        if _displayCrossLines {
            if let planes = _planes {
                for (key, _) in planes {
                    let planeName = key as! NSString
                    planeColor = self.value(forKey: planeName.appending("PlaneColor")) as? NSColor

                    roiLineWidth(Float(2.0 * (self.window?.backingScaleFactor ?? 0)))
                    // draw planes
                    roiColor4f(Float(planeColor?.redComponent ?? 0), Float(planeColor?.greenComponent ?? 0), Float(planeColor?.blueComponent ?? 0), Float(planeColor?.alphaComponent ?? 0))
                    self._drawPlaneRuns(self.value(forKey: planeName.appending("PlaneRuns")) as? NSArray)
                    self._drawVerticalLines(self.value(forKey: planeName.appending("VerticalLines")) as? NSArray)

                    roiLineWidth(Float(1.0 * (self.window?.backingScaleFactor ?? 0)))
                    self._drawPlaneRuns(self.value(forKey: planeName.appending("TopPlaneRuns")) as? NSArray)
                    self._drawPlaneRuns(self.value(forKey: planeName.appending("BottomPlaneRuns")) as? NSArray)
                    self._drawVerticalLines(self.value(forKey: planeName.appending("TopVerticalLines")) as? NSArray)
                    self._drawVerticalLines(self.value(forKey: planeName.appending("BottomVerticalLines")) as? NSArray)
                }
            }
        }

        var exportTransverseSliceInterval: Float = 0

        if self.cprController?.exportSequenceType == Int(CPRSeriesExportSequenceType.rawValue) && self.cprController?.exportSeriesType == Int(CPRTransverseViewsExportSeriesType.rawValue) {
            exportTransverseSliceInterval = Float(self.cprController?.exportTransverseSliceInterval ?? 0)
        }

        if exportTransverseSliceInterval > 0 {
            roiColor4d(1.0, 1.0, 0.0, 1.0)

            let flattenedPath = _curvedPath?.bezierPath?.mutableCopy() as? N3MutableBezierPath
            flattenedPath?.subdivide(N3BezierDefaultSubdivideSegmentLength)
            flattenedPath?.flatten(N3BezierDefaultFlatness)

            let curveLength = Float(flattenedPath?.length() ?? 0)
            var noOfFrames = cInt32(Double(curveLength / exportTransverseSliceInterval))
            noOfFrames = noOfFrames &+ 1

            var startingDistance = curveLength - Float(noOfFrames &- 1) * exportTransverseSliceInterval
            startingDistance /= 2

            // we need to find the tangents to the curve at
            let vectors: N3VectorArray?
            let tangents: N3VectorArray?

            // Freed after the draw (#854); they leaked at each one.
            vectors = malloc(Int(noOfFrames) * MemoryLayout<N3Vector>.size)?.bindMemory(to: N3Vector.self, capacity: Int(max(noOfFrames, 0)))
            tangents = malloc(Int(noOfFrames) * MemoryLayout<N3Vector>.size)?.bindMemory(to: N3Vector.self, capacity: Int(max(noOfFrames, 0)))
            defer {
                free(vectors)
                free(tangents)
            }
            noOfFrames = Int32(truncatingIfNeeded: N3BezierCoreGetVectorInfo(_curvedPath?.bezierPath?.n3BezierCore(), CGFloat(exportTransverseSliceInterval), CGFloat(startingDistance), N3VectorZero, vectors, tangents, nil, CFIndex(noOfFrames)))

            let t = self.cprController?.middleTransverseView
            var transverseWidth = CGFloat(Float(t?.curDCM?.pwidth ?? 0) / (t?.pixelsPerMm() ?? 0))
            transverseWidth /= CGFloat(self.pixelSpacingY)

            var i: Int32 = 0
            while i < noOfFrames {
                var transverseRun: _CPRStretchedViewPlaneRun?
                var transverseIndex: UInt = 0

                relativePosition = (CGFloat(startingDistance) + (CGFloat(exportTransverseSliceInterval) * CGFloat(i))) / CGFloat(curveLength)
                transverseRun = self._limitedRun(forRelativePosition: relativePosition, verticalLineIndex: &transverseIndex, lengthFromCenterline: transverseWidth)

                roiLineWidth(Float(2.0 * (self.window?.backingScaleFactor ?? 0)))

                if let transverseRun = transverseRun {
                    self._drawPlaneRuns(NSArray(object: transverseRun))
                } else {
                    self._drawVerticalLines(NSArray(object: NSNumber(value: transverseIndex)), length: transverseWidth)
                }
                i += 1
            }
        } else if _displayTransverseLines {
            if (_transverseVerticalLines?.count ?? 0) == 0 {
                self._buildTransverseVerticalLinesAndPlaneRuns()
            }

            roiColor4d(1.0, 1.0, 0.0, 1.0)

            if let transverseVerticalLines = _transverseVerticalLines {
                for (key, _) in transverseVerticalLines {
                    let name = key as! NSString
                    let transverseVerticalLine = transverseVerticalLines.object(forKey: name) as? NSArray

                    if name.isEqual(to: "center") {
                        roiLineWidth(Float(2.0 * (self.window?.backingScaleFactor ?? 0)))
                    } else {
                        roiLineWidth(Float(1.0 * (self.window?.backingScaleFactor ?? 0)))
                    }

                    self._drawVerticalLines(transverseVerticalLine, length: CGFloat(Double(self.curDCM?.pheight ?? 0) / 3.0))
                }
            }
            if let transversePlaneRuns = _transversePlaneRuns {
                for (key, _) in transversePlaneRuns {
                    let name = key as! NSString
                    let transversePlaneRun = transversePlaneRuns.object(forKey: name) as? NSArray

                    if name.isEqual(to: "center") {
                        roiLineWidth(Float(2.0 * (self.window?.backingScaleFactor ?? 0)))
                    } else {
                        roiLineWidth(Float(1.0 * (self.window?.backingScaleFactor ?? 0)))
                    }

                    self._drawPlaneRuns(transversePlaneRun)
                }
            }

            var transverseIntersectionA = self._centerlinePixVector(forRelativePosition: _curvedPath?.leftTransverseSectionPosition ?? 0)
            var transverseIntersectionB = self._centerlinePixVector(forRelativePosition: _curvedPath?.transverseSectionPosition ?? 0)
            var transverseIntersectionC = self._centerlinePixVector(forRelativePosition: _curvedPath?.rightTransverseSectionPosition ?? 0)

            transverseIntersectionA = N3VectorApplyTransform(transverseIntersectionA, pixToSubDrawRectTransform)
            transverseIntersectionB = N3VectorApplyTransform(transverseIntersectionB, pixToSubDrawRectTransform)
            transverseIntersectionC = N3VectorApplyTransform(transverseIntersectionC, pixToSubDrawRectTransform)

            // --- Text
            if stanStringAttrib == nil {
                stanStringAttrib = NSMutableDictionary()
                // -setObject:forKey: raised on a nil font.
                if let font = NSFont(name: "Helvetica", size: 14.0) {
                    stanStringAttrib?.setObject(font, forKey: NSAttributedString.Key.font.rawValue as NSString)
                } else {
                    NSException(name: .invalidArgumentException, reason: "-[__NSDictionaryM setObject:forKey:]: object cannot be nil (key: NSFont)", userInfo: nil).raise()
                }
                stanStringAttrib?.setObject(NSColor.white, forKey: NSAttributedString.Key.foregroundColor.rawValue as NSString)
            }

            roiEnable(GL_BLEND)
            roiBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA)

            do {
                roiPushMatrix()

                var ratio: Float = 1

                if self.pixelSpacingX != 0 && self.pixelSpacingY != 0 {
                    ratio = Float(self.pixelSpacingX / self.pixelSpacingY)
                }
                _ = ratio

                roiLoadIdentity() // reset model view matrix to identity (eliminates rotation basically)
                roiScalef(Float(2.0 / (self.xFlipped ? -(self.drawingFrameRect.size.width) : self.drawingFrameRect.size.width)), Float(-2.0 / (self.yFlipped ? -(self.drawingFrameRect.size.height) : self.drawingFrameRect.size.height)), 1.0) // scale to port per pixel scale
                roiTranslatef(Float(self.origin.x), Float(-self.origin.y), 0.0)

                let labelFont = stanStringAttrib?.object(forKey: NSAttributedString.Key.font.rawValue as NSString) as? NSFont
                let textA = self.horosLabelText("A", font: labelFont), textB = self.horosLabelText("B", font: labelFont), textC = self.horosLabelText("C", font: labelFont)
                let labelColor = NSColor(deviceRed: 1, green: 1, blue: 0, alpha: 1), labelShadow = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)

                var tPt: NSPoint

                tPt = self.positionWithoutRotation(NSMakePoint(transverseIntersectionA.x, transverseIntersectionA.y))
                self.horosDrawLabel(textA, at: tPt, textColor: labelColor, shadowColor: labelShadow)

                tPt = self.positionWithoutRotation(NSMakePoint(transverseIntersectionB.x, transverseIntersectionB.y))
                self.horosDrawLabel(textB, at: tPt, textColor: labelColor, shadowColor: labelShadow)

                tPt = self.positionWithoutRotation(NSMakePoint(transverseIntersectionC.x, transverseIntersectionC.y))
                self.horosDrawLabel(textC, at: tPt, textColor: labelColor, shadowColor: labelShadow)

                roiPopMatrix()
            }
        }

        if (self.cprController?.displayMousePosition ?? false) == true {
            // draw the point on the plane lines
            if let mousePlanePointsInPix = _mousePlanePointsInPix {
                for (key, _) in mousePlanePointsInPix {
                    let planeName = key as! NSString
                    planeColor = self.value(forKey: NSString(format: "%@PlaneColor", planeName) as String) as? NSColor
                    roiColor4f(Float(planeColor?.redComponent ?? 0), Float(planeColor?.greenComponent ?? 0), Float(planeColor?.blueComponent ?? 0), Float(planeColor?.alphaComponent ?? 0))
                    roiEnable(GL_POINT_SMOOTH)
                    roiPointSize(Float(8 * (self.window?.backingScaleFactor ?? 0)))
                    cursorVector = N3VectorApplyTransform((mousePlanePointsInPix.object(forKey: planeName) as? NSValue)?.n3VectorValue() ?? N3Vector(), pixToSubDrawRectTransform)
                    roiBegin(GL_POINTS)
                    roiVertex2f(Float(cursorVector.x), Float(cursorVector.y))
                    roiEnd()
                }
            }
        }

        if _drawAllNodes {
            i = 0
            while i < (_curvedPath?.nodes.count ?? 0) {
                relativePosition = _curvedPath?.relativePositionForNode(at: UInt(bitPattern: i)) ?? 0
                cursorVector = self._centerlinePixVector(forRelativePosition: relativePosition)
                cursorVector = N3VectorApplyTransform(cursorVector, pixToSubDrawRectTransform)

                if (_displayInfo?.hoverNodeHidden ?? false) == false && (_displayInfo?.hoverNodeIndex ?? 0) == i {
                    roiColor4d(1.0, 0.5, 0.0, 1.0)
                } else {
                    roiColor4d(1.0, 0.0, 0.0, 1.0)
                }

                roiEnable(GL_POINT_SMOOTH)
                roiPointSize(Float(8 * (self.window?.backingScaleFactor ?? 0)))

                roiBegin(GL_POINTS)
                roiVertex2f(Float(cursorVector.x), Float(cursorVector.y))
                roiEnd()
                i += 1
            }
        }

        // Red Square
        if self.window?.firstResponder === self && self.stringID == nil {
            let drawingFrameRect = self.drawingFrameRect

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

        roiDisable(GL_LINE_SMOOTH)
        roiDisable(GL_POLYGON_SMOOTH)
        roiDisable(GL_POINT_SMOOTH)
        roiDisable(GL_BLEND)
    }

    @objc(updatePresentationStateFromSeriesOnlyImageLevel:)
    public override dynamic func updatePresentationState(fromSeriesOnlyImageLevel onlyImage: Bool) {
    }

    // MARK: - CPRGeneratorDelegate

    @objc(generator:didGenerateVolume:request:)
    public func generator(_ generator: CPRGenerator, didGenerateVolume volume: CPRVolumeData, request: CPRGeneratorRequest) {
        if self.windowController() == nil {
            return
        }

        var i: UInt
        let pixArray: NSMutableArray
        var newPix: DCMPix?
        var inlineBuffer = CPRVolumeDataInlineBuffer()

        self._updateGeneratedHeight()

        let previousOrigin = self.origin
        let previousScale = self.scaleValue
        let previousRotation = self.rotation
        let previousHeight = Int32(truncatingIfNeeded: self.curDCM?.pheight ?? 0), previousWidth = Int32(truncatingIfNeeded: self.curDCM?.pwidth ?? 0)
        // [NSArchiver archivedDataWithRootObject:nil] when there is no ROI list,
        // which unarchives as nil: kept as no data.
        let previousROIs: Data? = self.curRoiList.map { NSArchiver.archivedData(withRootObject: $0) }

        if let curvedVolumeData = self.curvedVolumeData {
            // make sure this is around long enough so that it doesn't disapear under the old DCMPix
            _ = Unmanaged.passRetained(curvedVolumeData).autorelease()
        }
        self.setCurvedVolumeData(volume)

        pixArray = NSMutableArray()

        // blow away local caches of overlay lines
        self.centerlinePath = nil
        _midHeightPoint = N3VectorZero
        _projectionNormal = N3VectorZero

        i = 0
        while i < (self.curvedVolumeData?.pixelsDeep ?? 0) {
            if self.curvedVolumeData?.aquireInlineBuffer(&inlineBuffer) ?? false {
                let floatBytes = UnsafeMutablePointer(mutating: CPRVolumeDataFloatBytes(&inlineBuffer)!) + Int(bitPattern: i &* self.curvedVolumeData.pixelsWide &* self.curvedVolumeData.pixelsHigh)
                newPix = DCMPix(data: floatBytes, 32,
                                Int(bitPattern: self.curvedVolumeData.pixelsWide), Int(bitPattern: self.curvedVolumeData.pixelsHigh), Float(self.curvedVolumeData.pixelSpacingX), Float(self.curvedVolumeData.pixelSpacingY),
                                0.0, 0.0, 0.0, false)
            } else {
                debugAssert(false)
                newPix = DCMPix()
            }
            self.curvedVolumeData?.releaseInlineBuffer(&inlineBuffer)

            newPix?.imageObjectID = self.cprController?.originalPix?.imageObjectID
            newPix?.displayInverted = self.cprController?.originalPix?.displayInverted ?? false
            newPix?.srcFile = self.cprController?.originalPix?.srcFile
            newPix?.annotationsDictionary = self.cprController?.originalPix?.annotationsDictionary

            // -addObject: raised on nil.
            if let newPix = newPix {
                pixArray.add(newPix)
            } else {
                NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil", userInfo: nil).raise()
            }
            i += 1
        }

        if pixArray.count != 0 {
            let stretchedRequest = unsafeDowncast(request, to: CPRStretchedGeneratorRequest.self)

            self._clearAllPlanes()
            self._clearTransversePlanes()
            self.centerlinePath = self._projectedBezierPath(fromStretchedGeneratorRequest: stretchedRequest)
            _midHeightPoint = stretchedRequest.midHeightPoint
            _projectionNormal = stretchedRequest.projectionNormal

            let setArrayPixSelector = #selector(DCMPix.setArray(_:_:))
            i = 0
            while i < UInt(pixArray.count) {
                let pix = pixArray.object(at: Int(i)) as AnyObject
                unsafeBitCast(pix.method(for: setArrayPixSelector), to: SetArrayPixIMP.self)(pix, setArrayPixSelector, pixArray, Int16(truncatingIfNeeded: i))
                i += 1
            }

            self.setPixels(pixArray, files: nil, rois: nil, firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: true)
            self.setScaleValueCentered(Float(0.8 * (self.window?.backingScaleFactor ?? 0)))

            //[self setWLWW:wl :ww];
            self.cprController?.propagateWLWW(self.cprController?.mprView1)

            self.setFusion(Int16(truncatingIfNeeded: type(of: self)._fusionModeForCPRViewClippingRangeMode(_clippingRangeMode)),
                           Int16(truncatingIfNeeded: self.curvedVolumeData?.pixelsDeep ?? 0))

            if Int(previousWidth) == (self.curDCM?.pwidth ?? 0) && Int(previousHeight) == (self.curDCM?.pheight ?? 0) {
                self.origin = previousOrigin
                self.scaleValue = previousScale
                self.rotation = previousRotation
            }

            let roiArray = previousROIs.flatMap { NSUnarchiver.unarchiveObject(with: $0) } as? NSArray
            for element in roiArray ?? NSArray() {
                let r = element as! ROI
                r.pix = self.curDCM
                r.setOriginAndSpacing(Float(self.curDCM?.pixelSpacingX ?? 0), Float(self.curDCM?.pixelSpacingY ?? 0), NSMakePoint(CGFloat(self.curDCM?.originX ?? 0), CGFloat(self.curDCM?.originY ?? 0)), false, false)
                r.curView = self
            }

            if let roiArray = roiArray {
                self.curRoiList?.addObjects(from: roiArray as! [Any])
            }

            self.needsDisplay = true
        }
    }

    @objc(generator:didAbandonRequest:)
    public func generator(_ generator: CPRGenerator, didAbandonRequest request: CPRGeneratorRequest) {
    }

    @objc public dynamic func waitUntilPixUpdate() {
        self._sendNewRequestIfNeeded()
        _generator?.runUntilAllRequestsAreFinished()
    }

    // MARK: - Events

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
        _displayInfo?.mouseTransverseSection = Int(CPRTransverseViewNoneSectionType.rawValue)
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
            var i: Int
            var overNode: Bool
            var hoverNodeIndex: Int
            var relativePosition: CGFloat
            var vector = N3Vector()
            var distanceFromCenterline: CGFloat

            viewPoint = self.convert(theEvent.locationInWindow, from: nil)

            if NSPointInRect(viewPoint, self.bounds) == false {
                return
            }

            pixVector = N3VectorApplyTransform(N3VectorMakeFromNSPoint(viewPoint), self.viewToPixTransform())

            if NSPointInRect(viewPoint, self.bounds) && (self.curDCM?.pwidth ?? 0) > 0 {
                self._sendWillEditDisplayInfo()
                _displayInfo?.mouseCursorPosition = self._relativePosition(forPixPoint: NSPointFromN3Vector(pixVector))
//              _displayInfo.mouseCursorPosition = MIN(MAX(pixVector.x/(CGFloat)self.curDCM.pwidth, 0.0), 1.0);
                self.needsDisplay = true

                self._updateMousePlanePoints(forViewPoint: viewPoint) // this will modify _mousePlanePointsInPix and _displayInfo

                // Without a centerline, no node is near (#854).
                if let centerlinePath = _centerlinePath {
                    _ = centerlinePath.relativePositionClosest(to: N3LineMake(pixVector, N3VectorMake(0, 0, 1)), closestVector: &vector)
                    distanceFromCenterline = N3VectorDistanceToLine(vector, N3LineMake(pixVector, N3VectorMake(0, 0, 1)))
                } else {
                    distanceFromCenterline = CGFloat.greatestFiniteMagnitude
                }
                if distanceFromCenterline < 20.0 {
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

                        if N3VectorDistance(pixVector, self._centerlinePixVector(forRelativePosition: relativePosition)) < 10 {
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
            let allTransverseVerticalLines: NSMutableArray
            let allTransverseRuns: NSMutableArray
            let transverseLineDistance: CGFloat
            let transverseRunDistance: CGFloat

            if self.cprController?.exportSequenceType == Int(CPRSeriesExportSequenceType.rawValue) && self.cprController?.exportSeriesType == Int(CPRTransverseViewsExportSeriesType.rawValue) {
                exportTransverseSliceInterval = Float(self.cprController?.exportTransverseSliceInterval ?? 0)
            }

            allTransverseVerticalLines = NSMutableArray()
            allTransverseRuns = NSMutableArray()

            for values in (_transverseVerticalLines?.allValues ?? []) {
                allTransverseVerticalLines.addObjects(from: values as! [Any])
            }
            for values in (_transversePlaneRuns?.allValues ?? []) {
                allTransverseRuns.addObjects(from: values as! [Any])
            }

            transverseLineDistance = self._distance(to: viewPoint, onVerticalLines: allTransverseVerticalLines, pixVector: nil, volumeVector: nil)
            transverseRunDistance = self._distance(to: viewPoint, onPlaneRuns: allTransverseRuns, pixVector: nil, volumeVector: nil)

            if (self.curDCM?.pwidth ?? 0) != 0 && exportTransverseSliceInterval == 0 && _displayTransverseLines && (transverseLineDistance < 5.0 || transverseRunDistance < 5.0) {
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
        let viewPoint: NSPoint
        let pixVector: N3Vector
        var vector = N3Vector()
        let pixWidth: CGFloat
        var relativePosition: CGFloat
        var distanceFromCenterline: CGFloat
        var i: Int

        viewPoint = self.convert(event.locationInWindow, from: nil)
        pixVector = N3VectorApplyTransform(N3VectorMakeFromNSPoint(viewPoint), self.viewToPixTransform())
        pixWidth = CGFloat(self.curDCM?.pwidth ?? 0)

        if pixWidth == 0.0 {
            super.mouseDown(with: event)
            return
        }

        var exportTransverseSliceInterval: Float = 0
        let outsideTransverseVerticalLines: NSMutableArray
        let outsideTransverseRuns: NSMutableArray
        let outsideTransverseLineDistance: CGFloat
        let outsideTransverseRunDistance: CGFloat
        let centerTransverseLineDistance: CGFloat
        let centerTransverseRunDistance: CGFloat

        outsideTransverseVerticalLines = NSMutableArray()
        outsideTransverseRuns = NSMutableArray()

        if let transverseVerticalLines = _transverseVerticalLines {
            for (element, _) in transverseVerticalLines {
                let key = element as! NSString
                if key.isEqual(to: "center") == false {
                    outsideTransverseVerticalLines.addObjects(from: transverseVerticalLines.object(forKey: key) as! [Any])
                }
            }
        }
        if let transversePlaneRuns = _transversePlaneRuns {
            for (element, _) in transversePlaneRuns {
                let key = element as! NSString
                if key.isEqual(to: "center") == false {
                    outsideTransverseRuns.addObjects(from: transversePlaneRuns.object(forKey: key) as! [Any])
                }
            }
        }

        outsideTransverseLineDistance = self._distance(to: viewPoint, onVerticalLines: outsideTransverseVerticalLines, pixVector: nil, volumeVector: nil)
        outsideTransverseRunDistance = self._distance(to: viewPoint, onPlaneRuns: outsideTransverseRuns, pixVector: nil, volumeVector: nil)
        centerTransverseLineDistance = self._distance(to: viewPoint, onVerticalLines: _transverseVerticalLines?.object(forKey: "center") as? NSArray, pixVector: nil, volumeVector: nil)
        centerTransverseRunDistance = self._distance(to: viewPoint, onPlaneRuns: _transversePlaneRuns?.object(forKey: "center") as? NSArray, pixVector: nil, volumeVector: nil)

        if self.cprController?.exportSequenceType == Int(CPRSeriesExportSequenceType.rawValue) && self.cprController?.exportSeriesType == Int(CPRTransverseViewsExportSeriesType.rawValue) {
            exportTransverseSliceInterval = Float(self.cprController?.exportTransverseSliceInterval ?? 0)
        }

        if exportTransverseSliceInterval == 0 && _displayTransverseLines && cMIN(centerTransverseLineDistance, centerTransverseRunDistance) < 5.0 {
            self._sendWillEditCurvedPath()
            _draggingTransverse = true
            self.mouseMoved(with: event)
        } else if exportTransverseSliceInterval == 0 && _displayTransverseLines && cMIN(outsideTransverseLineDistance, outsideTransverseRunDistance) < 10.0 {
            self._sendWillEditCurvedPath()
            _draggingTransverseSpacing = true
            self.mouseMoved(with: event)
        } else {
            i = 0
            while i < (_curvedPath?.nodes.count ?? 0) {
                relativePosition = _curvedPath?.relativePositionForNode(at: UInt(bitPattern: i)) ?? 0
                if N3VectorDistance(pixVector, self._centerlinePixVector(forRelativePosition: relativePosition)) < 10 {
                    if i == 0 || i == (_curvedPath?.nodes.count ?? 0) - 1 {
                        if _delegate?.responds(to: #selector(CPRViewDelegate.cprView(_:setCrossCenter:))) ?? false {
                            _delegate?.cprView?(self.cprController?.mprView1, setCrossCenter: (_curvedPath?.nodes.object(at: i) as? NSValue)?.n3VectorValue() ?? N3Vector())
                        }
                        _draggedNode = -1
                        _isDraggingNode = true
                        break
                    } else {
                        _draggedNode = i
                        _isDraggingNode = true
                        _isEditingDraggedNode = true
                        self._sendWillEditCurvedPath()

                        break
                    }
                }
                i += 1
            }

            if _isDraggingNode == false {
                // Without a centerline there is no closest point (#854): the
                // zero vector made a click near the origin insert a node.
                if let centerlinePath = _centerlinePath {
                    relativePosition = centerlinePath.relativePositionClosest(to: N3LineMake(pixVector, N3VectorMake(0, 0, 1)), closestVector: &vector)
                    distanceFromCenterline = N3VectorDistanceToLine(vector, N3LineMake(pixVector, N3VectorMake(0, 0, 1)))
                } else {
                    relativePosition = 0
                    distanceFromCenterline = CGFloat.greatestFiniteMagnitude
                }
                if distanceFromCenterline < 5.0 {
                    _isDraggingNode = true
                    _isEditingDraggedNode = true
                    self._sendWillEditCurvedPath()
                    _draggedNode = _curvedPath?.insertNode(atRelativePosition: relativePosition) ?? 0

                    _isDraggingNode = true
                    self.needsDisplay = true
                    self._setNeedsNewRequest()
                }
            }

            if _isDraggingNode == false {
                var clickCount = 1

                do {
                    try HorosObjCException.perform {
                        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .leftMouseUp || event.type == .rightMouseUp {
                            clickCount = event.clickCount
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
                        splitPosition.0 = cInt32(Double((windowController?.mprView1?.frame.origin.x ?? 0) + (windowController?.mprView1?.frame.size.width ?? 0))) // vert
                        splitPosition.1 = cInt32(Double((windowController?.mprView1?.frame.origin.y ?? 0) + (windowController?.mprView1?.frame.size.height ?? 0))) // hori12
                        splitPosition.2 = cInt32(Double((windowController?.mprView3?.frame.origin.y ?? 0) + (windowController?.mprView3?.frame.size.height ?? 0))) // horiz2

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
//                      if( currentTool != tText && currentTool != tArrow)
//                          currentTool = tMesure;
                    }

                    super.mouseDown(with: event)
                }
            }
        }
    }

    public override dynamic func mouseDragged(with event: NSEvent) {
        let viewPoint: NSPoint
        let pixVector: N3Vector
        let relativePosition: CGFloat
        let pixWidth: CGFloat

        viewPoint = self.convert(event.locationInWindow, from: nil)
        pixVector = N3VectorApplyTransform(N3VectorMakeFromNSPoint(viewPoint), self.viewToPixTransform())
        pixWidth = CGFloat(self.curDCM?.pwidth ?? 0)

        if pixWidth == 0.0 {
            super.mouseDragged(with: event)
            return
        }

        if _isDraggingNode {
            if _draggedNode >= 0 {
                _curvedPath?.moveNode(at: _draggedNode, to: self._vector(forPixPoint: NSPointFromN3Vector(pixVector)))
            }
            self._sendDidUpdateCurvedPath()
            self._setNeedsNewRequest()
            self.mouseMoved(with: event)
        } else if _draggingTransverse {
            relativePosition = self._relativePosition(forPixPoint: NSPointFromN3Vector(pixVector))
            _curvedPath?.transverseSectionPosition = cMAX(cMIN(relativePosition, 1.0), 0.0)
            self._sendDidUpdateCurvedPath()

            self._sendWillEditDisplayInfo()
            _displayInfo?.mouseCursorPosition = pixVector.x / pixWidth
            self._sendDidEditDisplayInfo()

            self.needsDisplay = true
            self.mouseMoved(with: event)
        } else if _draggingTransverseSpacing {
            _curvedPath?.transverseSectionSpacing = cABS(self._relativePosition(forPixPoint: NSPointFromN3Vector(pixVector)) - (_curvedPath?.transverseSectionPosition ?? 0)) * (_curvedPath?.bezierPath?.length() ?? 0)
            self._sendDidUpdateCurvedPath()

            self._sendWillEditDisplayInfo()
            _displayInfo?.mouseCursorPosition = self._relativePosition(forPixPoint: NSPointFromN3Vector(pixVector))
            self._sendDidEditDisplayInfo()
            self.needsDisplay = true
            self.mouseMoved(with: event)
        } else {
            self._sendWillEditDisplayInfo()
            _displayInfo?.mouseCursorPosition = self._relativePosition(forPixPoint: NSPointFromN3Vector(pixVector))
            self._sendDidEditDisplayInfo()

            super.mouseDragged(with: event)
        }
    }

    public override dynamic func mouseUp(with event: NSEvent) {
        if _isDraggingNode {
//          [_draggingCenterlinePath release];
//          _draggingCenterlinePath = nil;
//          _draggingMidHeightPoint = N3VectorZero;
//          _draggingProjectionNormal = N3VectorZero;
            // The controller takes the edited path before the costs are
            // recomputed from its nodes (#928).
            if _isEditingDraggedNode {
                self._sendDidEditCurvedPath()
            }
            NotificationCenter.default.post(name: .OsirixUpdateCurvedPathCost, object: nil)

            if _draggedNode >= 0 {
                if _delegate?.responds(to: #selector(CPRViewDelegate.cprView(_:setCrossCenter:))) ?? false {
                    _delegate?.cprView?(self.cprController?.mprView1, setCrossCenter: (_curvedPath?.nodes.object(at: _draggedNode) as? NSValue)?.n3VectorValue() ?? N3Vector())
                }
            }
        }
        _draggedNode = 0
        _isDraggingNode = false
        _isEditingDraggedNode = false

        if _draggingTransverse {
            _draggingTransverse = false
            self._sendDidEditCurvedPath()
        } else if _draggingTransverseSpacing {
            _draggingTransverseSpacing = false
            self._sendDidEditCurvedPath()
        }

        super.mouseUp(with: event)
    }

    public override dynamic func keyDown(with theEvent: NSEvent) {
        if ((theEvent.characters as NSString?)?.length ?? 0) == 0 { return }

        let c = (theEvent.characters! as NSString).character(at: 0)

        if (Int(c) == NSDeleteCharacter || Int(c) == NSDeleteFunctionKey) && _isDraggingNode && _draggedNode != -1 {
            // Delete node
            _curvedPath?.removeNode(at: _draggedNode)
            _draggedNode = -1
            // The controller and the other views learn it now, not on mouse
            // up, as a node deleted in the MPR views (#928).
            self._sendDidUpdateCurvedPath()
            self.needsDisplay = true
            self._setNeedsNewRequest()
            NotificationCenter.default.post(name: .OsirixUpdateCurvedPathCost, object: nil)
        } else {
            super.keyDown(with: theEvent)
        }
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
                factor = Float(self.curDCM.pixelSpacingX)
            }

            let transverseSectionSpacing = cMIN(cMAX((_curvedPath?.transverseSectionSpacing ?? 0) + theEvent.deltaY * CGFloat(factor), 0.0), 300)

            self._sendWillEditCurvedPath()
            _curvedPath?.transverseSectionSpacing = transverseSectionSpacing
            self._sendDidEditCurvedPath()

            self._setNeedsNewRequest()
            self.needsDisplay = true
        }

        // Scroll/push the curve in and out
        else if theEvent.modifierFlags.contains(.control) {
            self._pushBezierPath(theEvent.deltaY * 0.4)
        } else {
            var initialNormal: N3Vector
            let angle: CGFloat

            angle = theEvent.deltaY * CGFloat(Double.pi / 180)

            initialNormal = _curvedPath?.initialNormal ?? N3Vector()
            initialNormal = N3VectorApplyTransform(initialNormal, N3AffineTransformMakeRotationAroundVector(angle, _curvedPath?.bezierPath?.tangentAtStart() ?? N3Vector()))

            self._sendWillEditCurvedPath()
            _curvedPath?.initialNormal = initialNormal
            self._sendDidEditCurvedPath()
            self._setNeedsNewRequest()
        }
    }

    // MARK: - Private

    @objc(_fusionModeForCPRViewClippingRangeMode:)
    private dynamic class func _fusionModeForCPRViewClippingRangeMode(_ clippingRangeMode: CPRViewClippingRangeMode) -> Int {
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
            NSLog("%@ asking for invalid clipping range mode: %d", "+[CPRStretchedView _fusionModeForCPRViewClippingRangeMode:]", Int32(truncatingIfNeeded: clippingRangeMode))
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
        let request: CPRStretchedGeneratorRequest
//      N3Vector curveDirection;
//      N3Vector baseNormal;

        if (_curvedPath?.bezierPath?.elementCount() ?? 0) >= 3 {
            request = CPRStretchedGeneratorRequest()

            request.interpolationMode = self.cprController?.selectedInterpolationMode ?? 0

            if self.cprController?.viewsPosition == Int(VerticalPosition.rawValue) {
                request.pixelsWide = cUInt(Double(self.bounds.size.height) * _extraWidthFactor)
                request.pixelsHigh = cUInt(Double(self.bounds.size.width) * _extraWidthFactor)
            } else {
                request.pixelsWide = cUInt(Double(self.bounds.size.width) * _extraWidthFactor)
                request.pixelsHigh = cUInt(Double(self.bounds.size.height) * _extraWidthFactor)
            }

            request.slabWidth = _curvedPath?.thickness ?? 0

            request.slabSampleDistance = 0
            request.bezierPath = _curvedPath?.bezierPath
            request.projectionMode = _clippingRangeMode
            request.projectionNormal = _curvedPath?.stretchedProjectionNormal() ?? N3Vector()
            request.midHeightPoint = N3VectorLerp(_curvedPath?.bezierPath?.topBoundingPlane(forNormal: request.projectionNormal).point ?? N3Vector(),
                                                  _curvedPath?.bezierPath?.bottomBoundingPlane(forNormal: request.projectionNormal).point ?? N3Vector(), 0.5)
            //        request.vertical = NO;

            if (_lastRequest?.isEqual(request) ?? false) == false {
                // Thin slabs used to be reformatted here, on the main thread, and
                // drawRect waited for them: that is the lag of #221, fixed in the
                // straightened view and left behind in this one. Ask asynchronously
                // and paint when the volume arrives.
                _generator?.requestVolume(request)
                self.lastRequest = request
            }
        } else {
            self.setPixels(nil, files: nil, rois: nil, firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: true)
        }

        _needsNewRequest = false
    }

    @objc public dynamic func _setNeedsNewRequest() {
        _needsNewRequest = true
        self.needsDisplay = true
    }

    @objc(_sendNewRequestIfNeeded)
    private dynamic func _sendNewRequestIfNeeded() {
        if _needsNewRequest {
            self._sendNewRequest()
        }
    }

    @objc(_updateGeneratedHeight)
    private dynamic func _updateGeneratedHeight() {
        let newGeneratedHeight: CGFloat

        newGeneratedHeight = ((_curvedPath?.bezierPath?.length() ?? 0) / NSWidth(self.bounds)) * NSHeight(self.bounds)

        if newGeneratedHeight != _generatedHeight {
            _generatedHeight = newGeneratedHeight
            if _delegate?.responds(to: #selector(CPRViewDelegate.cprViewDidChangeGeneratedHeight(_:))) ?? false {
                _delegate?.cprViewDidChangeGeneratedHeight?(self)
            }
        }
    }

    @objc(_projectedBezierPathFromStretchedGeneratorRequest:)
    private dynamic func _projectedBezierPath(fromStretchedGeneratorRequest generatorRequest: CPRStretchedGeneratorRequest?) -> N3BezierPath? {
        let pixelsWide: Int
        let pixelsHigh: Int
        var numVectors: UInt
        let midHeightPoint: N3Vector
        let projectionNormal: N3Vector
        let flattenedBezierCore: N3BezierCoreRef?
        let projectedBezierCore: N3BezierCoreRef?
        let projectedBezierLength: CGFloat
        let sampleSpacing: CGFloat
        let vectors: N3VectorArray?
        let relativePositions: UnsafeMutablePointer<CGFloat>?
        let centerlinePath: N3MutableBezierPath?
        var newPoint = N3Vector()
        var i: Int

        // figure out how many horizonatal pixels we will have
        pixelsWide = Int(bitPattern: generatorRequest?.pixelsWide ?? 0)
        pixelsHigh = Int(bitPattern: generatorRequest?.pixelsHigh ?? 0)
        projectionNormal = N3VectorNormalize(generatorRequest?.projectionNormal ?? N3Vector())
        midHeightPoint = generatorRequest?.midHeightPoint ?? N3Vector()

        flattenedBezierCore = N3BezierCoreCreateFlattenedCopy(generatorRequest?.bezierPath?.n3BezierCore(), N3BezierDefaultFlatness)
        projectedBezierCore = N3BezierCoreCreateCopyProjectedToPlane(flattenedBezierCore, N3PlaneMake(N3VectorZero, projectionNormal))
        projectedBezierLength = N3BezierCoreLength(projectedBezierCore)
        sampleSpacing = projectedBezierLength / CGFloat(pixelsWide)

        vectors = malloc(MemoryLayout<N3Vector>.size &* pixelsWide)?.bindMemory(to: N3Vector.self, capacity: max(pixelsWide, 0))
        relativePositions = malloc(MemoryLayout<CGFloat>.size &* pixelsWide)?.bindMemory(to: CGFloat.self, capacity: max(pixelsWide, 0))

        numVectors = UInt(bitPattern: N3BezierCoreGetProjectedVectorInfo(flattenedBezierCore, sampleSpacing, 0, projectionNormal, vectors, nil, nil, relativePositions, pixelsWide))

        if numVectors > 0 {
            while numVectors < UInt(bitPattern: pixelsWide) { // make sure that the full array is filled and that there is not a vector that did not get filled due to roundoff error
                vectors![Int(numVectors)] = vectors![Int(numVectors - 1)]
                relativePositions![Int(numVectors)] = relativePositions![Int(numVectors - 1)]
                numVectors += 1
            }
        } else { // there are no vectors at all to copy from, so just zero out everthing
            while numVectors < UInt(bitPattern: pixelsWide) { // make sure that the full array is filled and that there is not a vector that did not get filled due to roundoff error
                vectors![Int(numVectors)] = N3VectorZero
                relativePositions![Int(numVectors)] = 0
                numVectors += 1
            }
        }

        centerlinePath = N3MutableBezierPath.bezierPath() as? N3MutableBezierPath

        if numVectors != 0 {
            newPoint.x = 0
            //        newPoint.y = N3VectorLength(N3VectorProject(N3VectorSubtract(vectors[0], midHeightPoint), projectionNormal));
            newPoint.y = N3VectorDotProduct(N3VectorSubtract(vectors![0], midHeightPoint), projectionNormal)
            newPoint.y /= sampleSpacing
            newPoint.y += CGFloat(pixelsHigh) / 2.0
            newPoint.z = relativePositions![0]

            centerlinePath?.move(to: newPoint)
        }

        i = 1
        while UInt(bitPattern: i) < numVectors {
            newPoint.x = CGFloat(i)
            newPoint.y = N3VectorDotProduct(N3VectorSubtract(vectors![i], midHeightPoint), projectionNormal)
            newPoint.y /= sampleSpacing
            newPoint.y += CGFloat(pixelsHigh) / 2.0
            newPoint.z = relativePositions![i]

            centerlinePath?.line(to: newPoint)
            i += 1
        }

        N3BezierCoreRelease(flattenedBezierCore)
        N3BezierCoreRelease(projectedBezierCore)
        free(vectors)
        free(relativePositions)

        return centerlinePath
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
        for element in verticalLines ?? NSArray() {
            let indexNumber = element as! NSNumber
            lineStart = N3VectorMake(CGFloat(indexNumber.doubleValue), 0, 0)
            lineEnd = N3VectorMake(CGFloat(indexNumber.doubleValue), CGFloat(self.curDCM?.pheight ?? 0), 0)
            roiBegin(GL_LINE_STRIP)
            roiVertex2d(Double(lineStart.x), Double(lineStart.y))
            roiVertex2d(Double(lineEnd.x), Double(lineEnd.y))
            roiEnd()
        }
        roiPopMatrix()
    }

    @objc(_drawVerticalLines:length:)
    private dynamic func _drawVerticalLines(_ verticalLines: NSArray?, length: CGFloat) {
        var relativePostion: CGFloat
        var centerlineVector: N3Vector
        var lineStart: N3Vector
        var lineEnd: N3Vector
        var pixToSubdrawRectOpenGLTransform = [Double](repeating: 0, count: 16)

        N3AffineTransformGetOpenGLMatrixd(self.pixToSubDrawRectTransform(), &pixToSubdrawRectOpenGLTransform)
        roiMatrixMode(GL_MODELVIEW)
        roiPushMatrix()
        roiMultMatrixd(pixToSubdrawRectOpenGLTransform)
        for element in verticalLines ?? NSArray() {
            let indexNumber = element as! NSNumber
            relativePostion = self._relativePosition(forIndex: indexNumber.intValue) // this is dumb, just do one iteration! and do it in log(n) time while your at it to!
            centerlineVector = self._centerlinePixVector(forRelativePosition: relativePostion)

            lineStart = N3VectorMake(CGFloat(indexNumber.doubleValue), centerlineVector.y - length / 2.0, 0)
            lineEnd = N3VectorMake(CGFloat(indexNumber.doubleValue), centerlineVector.y + length / 2.0, 0)
            roiBegin(GL_LINE_STRIP)
            roiVertex2d(Double(lineStart.x), Double(lineStart.y))
            roiVertex2d(Double(lineEnd.x), Double(lineEnd.y))
            roiEnd()
        }
        roiPopMatrix()
    }

    @objc(_drawPlaneRuns:)
    private dynamic func _drawPlaneRuns(_ planeRuns: NSArray?) {
        let pixelsPerMm: CGFloat
        var i: Int
        var planePointVector: N3Vector
        var pixToSubdrawRectOpenGLTransform = [Double](repeating: 0, count: 16)
        let pheight_2: CGFloat

        if (self.curDCM?.pixelSpacingX ?? 0) == 0 {
            return
        }

        pixelsPerMm = 1.0 / CGFloat(self.curDCM.pixelSpacingX)

        pheight_2 = CGFloat(self.curDCM?.pheight ?? 0) / 2.0

        N3AffineTransformGetOpenGLMatrixd(self.pixToSubDrawRectTransform(), &pixToSubdrawRectOpenGLTransform)
        roiMatrixMode(GL_MODELVIEW)
        roiPushMatrix()
        roiMultMatrixd(pixToSubdrawRectOpenGLTransform)
        for element in planeRuns ?? NSArray() {
            let planeRun = element as! _CPRStretchedViewPlaneRun
            roiBegin(GL_LINE_STRIP)
            i = 0
            while UInt(bitPattern: i) < UInt(bitPattern: planeRun.range.length) {
                planePointVector = N3VectorMake(CGFloat(UInt(bitPattern: planeRun.range.location) &+ UInt(bitPattern: i)), (CGFloat((planeRun.distances.object(at: i) as! NSNumber).doubleValue) * pixelsPerMm) + pheight_2, 0)
                roiVertex2d(Double(planePointVector.x), Double(planePointVector.y))
                i += 1
            }
            roiEnd()
        }
        roiPopMatrix()
    }

    @objc(_limitedRunForRelativePosition:verticalLineIndex:lengthFromCenterline:)
    private dynamic func _limitedRun(forRelativePosition relativePosition: CGFloat, verticalLineIndex verticalLinePointer: UnsafeMutablePointer<UInt>?, lengthFromCenterline length: CGFloat) -> _CPRStretchedViewPlaneRun? {
        var length = length
        var transversePlane = N3Plane()
        let mmPerPixel: CGFloat
        let halfHeight: CGFloat
        let pixelsWide: Int
        let projectionNormal: N3Vector
        let topPlane: N3Plane
        let bottomPlane: N3Plane
        let midHeightPoint: N3Vector
        let flattenedBezierCore: N3BezierCoreRef?
        let projectedBezierCore: N3BezierCoreRef?
        let projectedBezierLength: CGFloat
        let sampleSpacing: CGFloat
        let vectors: N3VectorArray?
        let relativePositions: UnsafeMutablePointer<CGFloat>?
        var i: Int
        let relativePositionIndex: Int
        var top: N3Vector
        var bottom: N3Vector
        var topPointAbove: Bool
        var bottomPointAbove: Bool
        var prevBottomPointAbove: Bool
        let planeRun: _CPRStretchedViewPlaneRun
        var range: NSRange
        var distance: CGFloat
        var traveledDistance: CGFloat
        var distanceVector: N3Vector
        var lastDistanceVector: N3Vector
        var numVectors: Int

        transversePlane.point = _curvedPath?.bezierPath?.vector(atRelativePosition: relativePosition) ?? N3Vector()
        transversePlane.normal = _curvedPath?.bezierPath?.tangent(atRelativePosition: relativePosition) ?? N3Vector()

        mmPerPixel = CGFloat(self.curDCM?.pixelSpacingX ?? 0)
        halfHeight = (CGFloat(self.curDCM?.pheight ?? 0) * mmPerPixel) / 2.0
        length /= 2.0 // because the rest of the code uses the length from the centerline

        // figure out how many horizonatal pixels we will have
        pixelsWide = self.curDCM?.pwidth ?? 0
        projectionNormal = _projectionNormal

        midHeightPoint = _midHeightPoint
        topPlane = N3PlaneMake(N3VectorAdd(midHeightPoint, N3VectorScalarMultiply(projectionNormal, halfHeight * 1e2)), projectionNormal) // make the virtual top and bottom of the world be real far away
        bottomPlane = N3PlaneMake(N3VectorAdd(midHeightPoint, N3VectorScalarMultiply(projectionNormal, -halfHeight * 1e2)), projectionNormal)

        flattenedBezierCore = N3BezierCoreCreateFlattenedCopy(_curvedPath?.bezierPath?.n3BezierCore(), N3BezierDefaultFlatness)
        projectedBezierCore = N3BezierCoreCreateCopyProjectedToPlane(flattenedBezierCore, N3PlaneMake(N3VectorZero, projectionNormal))
        projectedBezierLength = N3BezierCoreLength(projectedBezierCore)
        sampleSpacing = projectedBezierLength / CGFloat(pixelsWide)

        vectors = malloc(MemoryLayout<N3Vector>.size &* pixelsWide)?.bindMemory(to: N3Vector.self, capacity: max(pixelsWide, 0))
        relativePositions = malloc(MemoryLayout<CGFloat>.size &* pixelsWide)?.bindMemory(to: CGFloat.self, capacity: max(pixelsWide, 0))

        numVectors = N3BezierCoreGetProjectedVectorInfo(flattenedBezierCore, sampleSpacing, 0, projectionNormal, vectors, nil, nil, relativePositions, pixelsWide)

        if numVectors > 0 {
            while numVectors < pixelsWide { // make sure that the full array is filled and that there is not a vector that did not get filled due to roundoff error
                vectors![numVectors] = vectors![numVectors - 1]
                relativePositions![numVectors] = relativePositions![numVectors - 1]
                numVectors += 1
            }
        } else { // there are no vectors, bail!
            free(vectors)
            free(relativePositions)
            return _CPRStretchedViewPlaneRun()
        }

        i = 0
        while i < numVectors {
            if relativePositions![i] > relativePosition {
                break
            }
            i += 1
        }
        relativePositionIndex = max(0, i - 1)

        if numVectors >= 2 && relativePositionIndex < numVectors - 1 { // it only makes sense to check for a vertical line if numVec is at least 2 and there i is not on the last line
            bottom = N3LineIntersectionWithPlane(N3LineMake(vectors![relativePositionIndex], projectionNormal), bottomPlane)
            top = N3LineIntersectionWithPlane(N3LineMake(vectors![relativePositionIndex], projectionNormal), topPlane)

            bottomPointAbove = N3VectorDotProduct(transversePlane.normal, N3VectorSubtract(bottom, transversePlane.point)) > 0.0
            topPointAbove = N3VectorDotProduct(transversePlane.normal, N3VectorSubtract(top, transversePlane.point)) > 0.0

            if bottomPointAbove == topPointAbove {
                if let verticalLinePointer = verticalLinePointer {
                    verticalLinePointer.pointee = UInt(bitPattern: relativePositionIndex)
                }
                free(vectors)
                free(relativePositions)
                return nil
            }
        }

        // now know that this is not vertical line, and so we have to make a plane run
        planeRun = _CPRStretchedViewPlaneRun()

        // it is easier to extend the curve than to start it, so we will put th first point checking all the edge cases, and then we will worry about extending it
        bottom = N3LineIntersectionWithPlane(N3LineMake(vectors![relativePositionIndex], projectionNormal), bottomPlane) // isn't this already set?
        bottomPointAbove = N3VectorDotProduct(transversePlane.normal, N3VectorSubtract(bottom, transversePlane.point)) > 0.0
        prevBottomPointAbove = bottomPointAbove

        distance = N3VectorDotProduct(N3VectorSubtract(vectors![relativePositionIndex], midHeightPoint), projectionNormal)
        planeRun.distances.add(NSNumber(value: Double(distance)))
        planeRun.range = NSMakeRange(relativePositionIndex, 1)
        lastDistanceVector = N3VectorMake(CGFloat(relativePositionIndex), distance / mmPerPixel, 0)

        // start walking forwards
        traveledDistance = 0
        i = relativePositionIndex + 1
        while i < numVectors {
            bottom = N3LineIntersectionWithPlane(N3LineMake(vectors![i], projectionNormal), bottomPlane)
            top = N3LineIntersectionWithPlane(N3LineMake(vectors![i], projectionNormal), topPlane)
            bottomPointAbove = N3VectorDotProduct(transversePlane.normal, N3VectorSubtract(bottom, transversePlane.point)) > 0.0
            topPointAbove = N3VectorDotProduct(transversePlane.normal, N3VectorSubtract(top, transversePlane.point)) > 0.0

            // if we just walked off the projection
            if bottomPointAbove == topPointAbove {
                // figure out if we just walked up or down
                if prevBottomPointAbove != bottomPointAbove {
                    distance = -(halfHeight * 1e10)
                } else {
                    distance = halfHeight * 1e10
                }
            } else {
                distance = N3VectorDotProduct(N3VectorSubtract(N3LineIntersectionWithPlane(N3LineMakeFromPoints(bottom, top), transversePlane), midHeightPoint), projectionNormal)
            }

            distanceVector = N3VectorMake(CGFloat(i), distance / mmPerPixel, 0)
            if N3VectorDistance(distanceVector, lastDistanceVector) + traveledDistance > length { // we can't make the whole segment
                distanceVector = N3VectorAdd(lastDistanceVector, N3VectorScalarMultiply(N3VectorNormalize(N3VectorSubtract(distanceVector, lastDistanceVector)), length - traveledDistance))
                traveledDistance = length
            } else {
                traveledDistance += N3VectorDistance(distanceVector, lastDistanceVector)
            }

            planeRun.distances.add(NSNumber(value: Double(distanceVector.y * mmPerPixel)))
            lastDistanceVector = distanceVector

            // and now update the range
            range = planeRun.range
            range.length += 1
            planeRun.range = range

            if traveledDistance == length {
                break
            }

            prevBottomPointAbove = bottomPointAbove
            i += 1
        }

        // and walk back
        bottom = N3LineIntersectionWithPlane(N3LineMake(vectors![relativePositionIndex], projectionNormal), bottomPlane) // isn't this already set?
        prevBottomPointAbove = N3VectorDotProduct(transversePlane.normal, N3VectorSubtract(bottom, transversePlane.point)) > 0.0

        distance = N3VectorDotProduct(N3VectorSubtract(vectors![relativePositionIndex], midHeightPoint), projectionNormal)
        lastDistanceVector = N3VectorMake(CGFloat(relativePositionIndex), distance / mmPerPixel, 0)
        traveledDistance = 0
        i = relativePositionIndex - 1
        while i >= 0 {
            bottom = N3LineIntersectionWithPlane(N3LineMake(vectors![i], projectionNormal), bottomPlane)
            top = N3LineIntersectionWithPlane(N3LineMake(vectors![i], projectionNormal), topPlane)
            bottomPointAbove = N3VectorDotProduct(transversePlane.normal, N3VectorSubtract(bottom, transversePlane.point)) > 0.0
            topPointAbove = N3VectorDotProduct(transversePlane.normal, N3VectorSubtract(top, transversePlane.point)) > 0.0

            // if we just walked off the projection
            if bottomPointAbove == topPointAbove {
                // figure out if we just walked up or down
                if prevBottomPointAbove != bottomPointAbove {
                    distance = -(halfHeight * 1e10)
                } else {
                    distance = halfHeight * 1e10
                }
            } else {
                distance = N3VectorDotProduct(N3VectorSubtract(N3LineIntersectionWithPlane(N3LineMakeFromPoints(bottom, top), transversePlane), midHeightPoint), projectionNormal)
            }

            distanceVector = N3VectorMake(CGFloat(i), distance / mmPerPixel, 0)
            if N3VectorDistance(distanceVector, lastDistanceVector) + traveledDistance > length { // we can't make the whole segment
                distanceVector = N3VectorAdd(lastDistanceVector, N3VectorScalarMultiply(N3VectorNormalize(N3VectorSubtract(distanceVector, lastDistanceVector)), length - traveledDistance))
                traveledDistance = length
            } else {
                traveledDistance += N3VectorDistance(distanceVector, lastDistanceVector)
            }

            planeRun.distances.insert(NSNumber(value: Double(distanceVector.y * mmPerPixel)), at: 0)
            lastDistanceVector = distanceVector

            // and now update the range
            range = planeRun.range
            range.location = range.location &- 1
            range.length += 1
            planeRun.range = range

            if traveledDistance == length {
                break
            }

            prevBottomPointAbove = bottomPointAbove
            i -= 1
        }

        free(vectors)
        free(relativePositions)
        return planeRun
    }

    @objc(_runsForPlane:verticalLineIndexes:)
    private dynamic func _runs(forPlane plane: N3Plane, verticalLineIndexes verticalLinesHandle: AutoreleasingUnsafeMutablePointer<NSArray?>?) -> NSArray {
        var numVectors: Int
        var i: Int
        var topPointAbove: Bool
        var bottomPointAbove: Bool
        var prevBottomPointAbove = false
        let runs: NSMutableArray
        let verticalLines: NSMutableArray?
        let mmPerPixel: CGFloat
        let halfHeight: CGFloat
        var distance: CGFloat
        var bottom: N3Vector
        var top: N3Vector
        var planeRun: _CPRStretchedViewPlaneRun?
        var range = NSRange(location: 0, length: 0)
        var aboveOrBelow: Int
        var prevAboveOrBelow: Int = 0
        let pixelsWide: Int
        let projectionNormal: N3Vector
        let flattenedBezierCore: N3BezierCoreRef?
        let projectedBezierCore: N3BezierCoreRef?
        let projectedBezierLength: CGFloat
        let sampleSpacing: CGFloat
        let vectors: N3VectorArray?
        let topPlane: N3Plane
        let bottomPlane: N3Plane
        let midHeightPoint: N3Vector

        runs = NSMutableArray()
        planeRun = nil

        if let verticalLinesHandle = verticalLinesHandle {
            verticalLines = NSMutableArray()
            verticalLinesHandle.pointee = verticalLines
        } else {
            verticalLines = nil
        }

        mmPerPixel = CGFloat(self.curDCM?.pixelSpacingX ?? 0)
        halfHeight = (CGFloat(self.curDCM?.pheight ?? 0) * mmPerPixel) / 2.0

        // figure out how many horizonatal pixels we will have
        pixelsWide = self.curDCM?.pwidth ?? 0
        projectionNormal = _projectionNormal

        midHeightPoint = _midHeightPoint
        topPlane = N3PlaneMake(N3VectorAdd(midHeightPoint, N3VectorScalarMultiply(projectionNormal, halfHeight)), projectionNormal)
        bottomPlane = N3PlaneMake(N3VectorAdd(midHeightPoint, N3VectorScalarMultiply(projectionNormal, -halfHeight)), projectionNormal)

        flattenedBezierCore = N3BezierCoreCreateFlattenedCopy(_curvedPath?.bezierPath?.n3BezierCore(), N3BezierDefaultFlatness)
        projectedBezierCore = N3BezierCoreCreateCopyProjectedToPlane(flattenedBezierCore, N3PlaneMake(N3VectorZero, projectionNormal))
        projectedBezierLength = N3BezierCoreLength(projectedBezierCore)
        sampleSpacing = projectedBezierLength / CGFloat(pixelsWide)

        vectors = malloc(MemoryLayout<N3Vector>.size &* pixelsWide)?.bindMemory(to: N3Vector.self, capacity: max(pixelsWide, 0))

        numVectors = N3BezierCoreGetProjectedVectorInfo(flattenedBezierCore, sampleSpacing, 0, projectionNormal, vectors, nil, nil, nil, pixelsWide)

        if numVectors > 0 {
            while numVectors < pixelsWide { // make sure that the full array is filled and that there is not a vector that did not get filled due to roundoff error
                vectors![numVectors] = vectors![numVectors - 1]
                numVectors += 1
            }
        } else { // there are no vectors at all to copy from, so just zero out everthing
            while numVectors < pixelsWide { // make sure that the full array is filled and that there is not a vector that did not get filled due to roundoff error
                vectors![numVectors] = N3VectorZero
                numVectors += 1
            }
        }

        i = 0
        while i < numVectors {
            bottom = N3LineIntersectionWithPlane(N3LineMake(vectors![i], projectionNormal), bottomPlane)
            top = N3LineIntersectionWithPlane(N3LineMake(vectors![i], projectionNormal), topPlane)

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
                    planeRun = _CPRStretchedViewPlaneRun()
                    range = planeRun!.range
                    if i != 0 {
                        range.location = i - 1
                        range.length = 1
                        if prevBottomPointAbove != bottomPointAbove {
                            planeRun!.distances.add(NSNumber(value: Double(-halfHeight)))
                        } else {
                            planeRun!.distances.add(NSNumber(value: Double(halfHeight)))
                        }
                    }
                }

                distance = N3VectorDotProduct(N3VectorSubtract(N3LineIntersectionWithPlane(N3LineMakeFromPoints(bottom, top), plane), midHeightPoint), projectionNormal)
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

        free(vectors)

        return runs
    }

    /// This will modify _mousePlanePointsInPix and _displayInfo.
    @objc(_updateMousePlanePointsForViewPoint:)
    private dynamic func _updateMousePlanePoints(forViewPoint point: NSPoint) {
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

        if let planes = _planes {
            for (key, _) in planes {
                let planeName = key as! NSString
                verticalLines = self.value(forKey: planeName.appending("VerticalLines")) as? NSArray
                planeRuns = self.value(forKey: planeName.appending("PlaneRuns")) as? NSArray
                lineDistance = self._distance(to: point, onVerticalLines: verticalLines, pixVector: &linePixVector, volumeVector: &lineVolumeVector)
                runDistance = self._distance(to: point, onPlaneRuns: planeRuns, pixVector: &runPixVector, volumeVector: &runVolumeVector)
                if cMIN(lineDistance, runDistance) < 30 {
                    if lineDistance < runDistance {
                        _mousePlanePointsInPix?.setObject(NSValue(n3Vector: linePixVector)!, forKey: planeName)
                        _displayInfo?.setMouseVector(lineVolumeVector, forPlane: planeName as String)
                    } else {
                        _mousePlanePointsInPix?.setObject(NSValue(n3Vector: runPixVector)!, forKey: planeName)
                        _displayInfo?.setMouseVector(runVolumeVector, forPlane: planeName as String)
                    }
                }
            }
        }
    }

    /// point and distance are in view coordinates, vector is in patient
    /// coordinates closestPoint is in pixCoordinates.
    @objc(_distanceToPoint:onVerticalLines:pixVector:volumeVector:)
    private dynamic func _distance(to point: NSPoint, onVerticalLines verticalLines: NSArray?, pixVector closestPixVectorPtr: N3VectorPointer?, volumeVector volumeVectorPtr: N3VectorPointer?) -> CGFloat {
        let pixToViewTransform: N3AffineTransform
        let pixPointVector: N3Vector
        var pixVector: N3Vector
        var lineStart: N3Vector
        var lineEnd: N3Vector
//      CGFloat height;
        var distance: CGFloat
        var minDistance: CGFloat

        if (self.curDCM?.pixelSpacingX ?? 0) == 0 || (verticalLines?.count ?? 0) == 0 {
            return CGFloat.greatestFiniteMagnitude
        }

        pixToViewTransform = N3AffineTransformInvert(self.viewToPixTransform())
        minDistance = CGFloat.greatestFiniteMagnitude
        pixPointVector = N3VectorApplyTransform(N3VectorMakeFromNSPoint(point), self.viewToPixTransform())

        for element in verticalLines ?? NSArray() {
            let indexNumber = element as! NSNumber
            lineStart = N3VectorMake(CGFloat(indexNumber.doubleValue), 0, 0)
            lineEnd = N3VectorMake(CGFloat(indexNumber.doubleValue), CGFloat(self.curDCM?.pheight ?? 0), 0)

            distance = N3VectorDistanceToLine(N3VectorMakeFromNSPoint(point), N3LineApplyTransform(N3LineMakeFromPoints(lineStart, lineEnd), pixToViewTransform))
            if distance < minDistance {
                minDistance = distance
                pixVector = N3VectorMake(CGFloat(indexNumber.doubleValue), pixPointVector.y, 0)
                if let closestPixVectorPtr = closestPixVectorPtr {
                    closestPixVectorPtr.pointee = pixVector
                }

                if let volumeVectorPtr = volumeVectorPtr {
                    volumeVectorPtr.pointee = self._vector(forPixPoint: NSPointFromN3Vector(pixVector))
                }
            }
        }
        return minDistance
    }

    /// point and distance are in view coordinates, vector is in patient
    /// coordinates closestPoint is in pixCoordinates.
    @objc(_distanceToPoint:onPlaneRuns:pixVector:volumeVector:)
    private dynamic func _distance(to point: NSPoint, onPlaneRuns planeRuns: NSArray?, pixVector closestPixVectorPtr: N3VectorPointer?, volumeVector volumeVectorPtr: N3VectorPointer?) -> CGFloat {
        let pixelsPerMm: CGFloat
        var closeVector = N3Vector()
        var closestVector: N3Vector
        let pointVector: N3Vector
        var distance: CGFloat = 0
        var minDistance: CGFloat
        var planeRunBezierPath: N3MutableBezierPath?

        if (self.curDCM?.pixelSpacingX ?? 0) == 0 || (planeRuns?.count ?? 0) == 0 {
            return CGFloat.greatestFiniteMagnitude
        }

        pointVector = N3VectorMakeFromNSPoint(point)
        pixelsPerMm = 1.0 / CGFloat(self.curDCM.pixelSpacingX)

        minDistance = CGFloat.greatestFiniteMagnitude
        closestVector = N3VectorZero

        for element in planeRuns ?? NSArray() {
            let planeRun = element as! _CPRStretchedViewPlaneRun
            planeRunBezierPath = bezierPathWithCPRStretchedViewPlaneRun(planeRun, heightPixelsPerMm: pixelsPerMm)
            planeRunBezierPath?.applyAffineTransform(N3AffineTransformMakeTranslation(0, CGFloat(self.curDCM?.pheight ?? 0) / 2.0, 0))
            planeRunBezierPath?.applyAffineTransform(N3AffineTransformInvert(self.viewToPixTransform()))

            _ = N3BezierCoreRelativePositionClosestToVector(planeRunBezierPath?.n3BezierCore(), pointVector, &closeVector, &distance)
            if distance < minDistance {
                minDistance = distance
                closestVector = N3VectorApplyTransform(closeVector, self.viewToPixTransform())
            }
            planeRunBezierPath = nil
        }

        if let closestPixVectorPtr = closestPixVectorPtr {
            closestPixVectorPtr.pointee = N3VectorMake(closestVector.x, closestVector.y, 0)
        }
        if let volumeVectorPtr = volumeVectorPtr {
            volumeVectorPtr.pointee = self._vector(forPixPoint: NSPointFromN3Vector(closestVector))
        }

        return minDistance
    }

    @objc(_buildVerticalLinesAndPlaneRunsForPlaneFullName:)
    private dynamic func _buildVerticalLinesAndPlaneRuns(forPlaneFullName planeFullName: String) {
        let planeFullName = planeFullName as NSString
        let planeName: NSString
        var plane: N3Plane
        let slabThickness: CGFloat
        let planeRuns: NSArray
        var vertialLines: NSArray?

        if planeFullName.hasSuffix("Top") {
            planeName = planeFullName.substring(to: planeFullName.length - 3) as NSString
            slabThickness = CGFloat((self.value(forKey: planeName.appending("SlabThickness")) as? NSNumber)?.doubleValue ?? 0)
            if slabThickness == 0 {
                return
            }
        } else if planeFullName.hasSuffix("Bottom") {
            planeName = planeFullName.substring(to: planeFullName.length - 6) as NSString
            slabThickness = CGFloat(-((self.value(forKey: planeName.appending("SlabThickness")) as? NSNumber)?.doubleValue ?? 0))
            if slabThickness == 0 {
                return
            }
        } else {
            planeName = planeFullName
            slabThickness = 0
        }

        plane = (self.value(forKey: planeName.appending("Plane")) as? NSValue)?.n3PlaneValue() ?? N3Plane()
        if N3PlaneIsValid(plane) {
            plane.normal = N3VectorNormalize(plane.normal)
            plane.point = N3VectorAdd(plane.point, N3VectorScalarMultiply(plane.normal, slabThickness / 2.0))
            planeRuns = self._runs(forPlane: plane, verticalLineIndexes: &vertialLines)
            _verticalLines?.setValue(vertialLines, forKey: planeFullName as String)
            _planeRuns?.setValue(planeRuns, forKey: planeFullName as String)
        }
    }

    @objc(_clearAllPlanes)
    private dynamic func _clearAllPlanes() {
        _verticalLines?.removeAllObjects()
        _planeRuns?.removeAllObjects()
    }

    // The proxies +resolveInstanceMethod: installs, under their own selectors.

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

    // Their bodies; selectorName is NSStringFromSelector(_cmd).

    private func planeSetterBody(_ plane: N3Plane, selectorName: String) {
        let selectorName = selectorName as NSString
        var planeName: NSString

        planeName = selectorName.replacingCharacters(in: NSMakeRange(0, 4), with: (selectorName.substring(with: NSMakeRange(3, 1)) as NSString).lowercased) as NSString
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
        let planeName: NSString

        planeName = selectorName.substring(to: selectorName.length - 5) as NSString
        return (_planes?.value(forKey: planeName as String) as? NSValue)?.n3PlaneValue() ?? N3Plane()
    }

    private func slabThicknessSetterBody(_ thickness: CGFloat, selectorName: String) {
        let selectorName = selectorName as NSString
        var planeName: NSString

        planeName = selectorName.replacingCharacters(in: NSMakeRange(0, 4), with: (selectorName.substring(with: NSMakeRange(3, 1)) as NSString).lowercased) as NSString
        planeName = planeName.substring(to: planeName.length - 14) as NSString
        _verticalLines?.removeObject(forKey: planeName)
        _planeRuns?.removeObject(forKey: planeName)
        _slabThicknesses?.setValue(NSNumber(value: Double(thickness)), forKey: planeName as String)
        self.needsDisplay = true
    }

    private func slabThicknessGetterBody(selectorName: String) -> CGFloat {
        let selectorName = selectorName as NSString
        let planeName: NSString

        planeName = selectorName.substring(to: selectorName.length - 13) as NSString
        return CGFloat((_slabThicknesses?.value(forKey: planeName as String) as? NSNumber)?.doubleValue ?? 0)
    }

    private func planeColorSetterBody(_ color: NSColor?, selectorName: String) {
        let selectorName = selectorName as NSString
        var planeName: NSString

        planeName = selectorName.replacingCharacters(in: NSMakeRange(0, 4), with: (selectorName.substring(with: NSMakeRange(3, 1)) as NSString).lowercased) as NSString
        planeName = planeName.substring(to: planeName.length - 11) as NSString
        _planeColors?.setValue(color, forKey: planeName as String)
        self.needsDisplay = true
    }

    private func planeColorGetterBody(selectorName: String) -> NSColor? {
        let selectorName = selectorName as NSString
        let planeName: NSString

        planeName = selectorName.substring(to: selectorName.length - 10) as NSString
        if _planeColors?.value(forKey: planeName as String) == nil {
            _planeColors?.setValue(NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1), forKey: planeName as String)
        }
        return _planeColors?.value(forKey: planeName as String) as? NSColor
    }

    @objc(_buildTransverseVerticalLinesAndPlaneRuns)
    private dynamic func _buildTransverseVerticalLinesAndPlaneRuns() {
        var verticalLine: UInt = 0
        var planeRun: _CPRStretchedViewPlaneRun?

        let t = self.cprController?.middleTransverseView
        var transverseWidth = CGFloat(Float(t?.curDCM?.pwidth ?? 0) / (t?.pixelsPerMm() ?? 0))
        transverseWidth /= CGFloat(self.pixelSpacingY)

        planeRun = self._limitedRun(forRelativePosition: _curvedPath?.transverseSectionPosition ?? 0, verticalLineIndex: &verticalLine, lengthFromCenterline: transverseWidth)
        if let planeRun = planeRun {
            _transversePlaneRuns?.setObject(NSArray(object: planeRun), forKey: "center" as NSString)
        } else {
            _transverseVerticalLines?.setObject(NSArray(object: NSNumber(value: verticalLine)), forKey: "center" as NSString)
        }

        planeRun = self._limitedRun(forRelativePosition: _curvedPath?.leftTransverseSectionPosition ?? 0, verticalLineIndex: &verticalLine, lengthFromCenterline: transverseWidth)
        if let planeRun = planeRun {
            _transversePlaneRuns?.setObject(NSArray(object: planeRun), forKey: "left" as NSString)
        } else {
            _transverseVerticalLines?.setObject(NSArray(object: NSNumber(value: verticalLine)), forKey: "left" as NSString)
        }

        planeRun = self._limitedRun(forRelativePosition: _curvedPath?.rightTransverseSectionPosition ?? 0, verticalLineIndex: &verticalLine, lengthFromCenterline: transverseWidth)
        if let planeRun = planeRun {
            _transversePlaneRuns?.setObject(NSArray(object: planeRun), forKey: "right" as NSString)
        } else {
            _transverseVerticalLines?.setObject(NSArray(object: NSNumber(value: verticalLine)), forKey: "right" as NSString)
        }
    }

    @objc(_clearTransversePlanes)
    private dynamic func _clearTransversePlanes() {
        _transverseVerticalLines?.removeAllObjects()
        _transversePlaneRuns?.removeAllObjects()
    }

    @objc(_centerlinePixVectorForRelativePosition:)
    private dynamic func _centerlinePixVector(forRelativePosition relativePosition: CGFloat) -> N3Vector {
        let relativePositionPlane: N3Plane
        let intersections: [Any]?
        let relativePositionIntersection: N3Vector

        if (self.curDCM?.pixelSpacingX ?? 0) == 0 {
            return N3VectorZero
        }

        if relativePosition == 0 {
            relativePositionIntersection = self.centerlinePath?.vectorAtStart() ?? N3Vector()
        } else if relativePosition == 1 {
            relativePositionIntersection = self.centerlinePath?.vectorAtEnd() ?? N3Vector()
        } else {
            relativePositionPlane = N3PlaneMake(N3VectorMake(0, 0, relativePosition), N3VectorMake(0, 0, 1))
            intersections = self.centerlinePath?.intersections(with: relativePositionPlane) // TODO make this O(log(n)) not O(n)

            if (intersections?.count ?? 0) == 0 {
                return N3VectorZero
            }

            relativePositionIntersection = (intersections![0] as? NSValue)?.n3VectorValue() ?? N3Vector()
        }

        return relativePositionIntersection
    }

    @objc(_relativePositionForIndex:)
    private dynamic func _relativePosition(forIndex index: Int) -> CGFloat {
        let plane: N3Plane
        let intersections: [Any]?

        plane = N3PlaneMake(N3VectorMake(CGFloat(index), 0, 0), N3VectorMake(1, 0, 0))

        intersections = _centerlinePath?.intersections(with: plane) // TODO make this O(log(n)) not O(n)
        if (intersections?.count ?? 0) == 0 {
            return 0
        }

        return ((intersections![0] as? NSValue)?.n3VectorValue() ?? N3Vector()).z
    }

    @objc(_relativePositionForPixPoint:)
    private dynamic func _relativePosition(forPixPoint pixPoint: NSPoint) -> CGFloat {
        var pixLine = N3Line()
        var closestVector: N3Vector

        if _centerlinePath == nil {
            return 0
        }

        closestVector = N3VectorZero
        pixLine.point = N3VectorMakeFromNSPoint(pixPoint)
        pixLine.vector = N3VectorMake(0, 0, 1.0)

        _ = _centerlinePath?.relativePositionClosest(to: pixLine, closestVector: &closestVector)

        return cMIN(cMAX(closestVector.z, 0.0), 1.0)
    }

    @objc(_vectorForPixPoint:)
    private dynamic func _vector(forPixPoint pixPoint: NSPoint) -> N3Vector {
        let intersectionPlane: N3Plane
        let intersections: [Any]?
        let intersectionVector: N3Vector
        let vector: N3Vector
        let relativePosition: CGFloat
        let mmPerPixel: CGFloat
        let pixDistance: CGFloat
        let mmDistance: CGFloat
        let projectionNormal: N3Vector

        projectionNormal = _projectionNormal
        mmPerPixel = CGFloat(self.curDCM?.pixelSpacingX ?? 0)
        intersectionPlane = N3PlaneMake(N3VectorMakeFromNSPoint(pixPoint), N3VectorMake(1.0, 0, 0))
        intersections = _centerlinePath?.intersections(with: intersectionPlane)
        if (intersections?.count ?? 0) == 0 {
            return N3VectorZero
        }
        intersectionVector = (intersections![0] as? NSValue)?.n3VectorValue() ?? N3Vector()
        relativePosition = intersectionVector.z
        vector = _curvedPath?.bezierPath?.vector(atRelativePosition: relativePosition) ?? N3Vector()
        pixDistance = pixPoint.y - intersectionVector.y
        mmDistance = pixDistance * mmPerPixel

        return N3VectorAdd(vector, N3VectorScalarMultiply(projectionNormal, mmDistance))
    }

    @objc(_pushBezierPath:)
    private dynamic func _pushBezierPath(_ distance: CGFloat) {
        var i: Int
        var relativePosition: CGFloat
        var tangent: N3Vector
        var normal: N3Vector
        var newNode: N3Vector

        self._sendWillEditCurvedPath()
        i = 0
        while i < (_curvedPath?.nodes.count ?? 0) {
            relativePosition = _curvedPath?.relativePositionForNode(at: UInt(bitPattern: i)) ?? 0

            tangent = _curvedPath?.bezierPath?.tangent(atRelativePosition: relativePosition) ?? N3Vector()
            normal = N3VectorNormalize(N3VectorCrossProduct(_projectionNormal, tangent))

            newNode = N3VectorAdd((_curvedPath?.nodes.object(at: i) as? NSValue)?.n3VectorValue() ?? N3Vector(), N3VectorScalarMultiply(normal, distance))
            _curvedPath?.moveNode(at: i, to: newNode)
            i += 1
        }
        self._sendDidEditCurvedPath()
    }

    @objc(_osirixUpdateVolumeDataNotification:)
    private dynamic func _osirixUpdateVolumeDataNotification(_ notification: Notification) {
        self.lastRequest = nil
        self._setNeedsNewRequest()
    }
}
