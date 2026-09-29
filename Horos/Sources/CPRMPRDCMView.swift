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

// The file-level statics of the former CPRMPRDCMView.m. arePlanesParallel() is
// HorosMPRArePlanesParallel(), the same function; splitPosition and
// frameZoomed, which the four CPR views share, stay C globals
// (CPRMPRDCMView+CAPI.m).
private let deg2rad: Float = Float(Double.pi / 180.0)
private let VIEW_COLOR_LABEL_SIZE: Float = 25
private let BS: Double = 10.0
private let PRECISION: Double = 0.0001
private let CPRMPRDCMViewCurveMouseTrackingDistance: CGFloat = 20.0

/// CPRCurvedPathControlTokenNone (int32_t -1) as a CPRCurvedPathControlToken
/// (uint32_t), the conversion C made in each comparison.
private var controlTokenNone: CPRCurvedPathControlToken {
    return CPRCurvedPathControlToken(bitPattern: CPRCurvedPathControlTokenNone)
}

// The OpenGL enumerants ROICanvasGL.h names, which Swift cannot import: that
// header imports Horos-Swift.h.
private let GL_POINTS: UInt32 = 0x0000
private let GL_LINES: UInt32 = 0x0001
private let GL_LINE_LOOP: UInt32 = 0x0002
private let GL_LINE_STRIP: UInt32 = 0x0003
private let GL_POLYGON: UInt32 = 0x0009
private let GL_POINT_SMOOTH: UInt32 = 0x0B10
private let GL_LINE_SMOOTH: UInt32 = 0x0B20
private let GL_POLYGON_SMOOTH: UInt32 = 0x0B41
private let GL_BLEND: UInt32 = 0x0BE2
private let GL_SRC_ALPHA: UInt32 = 0x0302
private let GL_ONE_MINUS_SRC_ALPHA: UInt32 = 0x0303
private let GL_MODELVIEW: UInt32 = 0x1700

// The static inline functions of ROICanvasGL.h, with the same parameter types:
// a CGFloat argument goes through a float or a double, as it did.
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
private func roiMatrixMode(_ mode: UInt32) {}
private func roiPushMatrix() { ROICanvas.current?.pushMatrix() }
private func roiPopMatrix() { ROICanvas.current?.popMatrix() }
private func roiMultMatrixd(_ m: UnsafePointer<Double>) { ROICanvas.current?.mult(m) }

/// A float converted to int as the arm64 code of the former C did (fcvtzs):
/// toward zero, saturated, NaN to 0; a Swift conversion traps instead.
private func cInt32(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483647.0 { return Int32.max }
    if x <= -2147483648.0 { return Int32.min }
    return Int32(x)
}

/// float[2][3]: the two ends of a cross reference line, as three coordinates.
private typealias CrossLines = ((Float, Float, Float), (Float, Float, Float))

/// One of the three MPR planes of the CPR window: a DCMView that shows the
/// CPR's hidden VRView reslice of its plane, draws the other two planes as
/// lines and the curved path, and turns the mouse into camera moves and curve
/// edits.
///
/// Implemented in Swift since #824: the Objective-C name, the selectors and
/// <Horos/CPRMPRDCMView.h> are those of the former class, the customClass of the
/// three plane views of CPR.xib. Its superclass, DCMView, stays in Objective-C;
/// the ivars it reads of it go through DCMView+SwiftIvars.h. The messages to the
/// VRView, whose header is C++, go through HorosMPRVRViewMessages, which VRView
/// adopts in VRHostBridge.h.
@objc(CPRMPRDCMView)
public final class CPRMPRDCMView: DCMView {
    // MARK: - The former instance variables

    /// delegate: assigned, not retained.
    private unowned(unsafe) var _delegate: CPRViewDelegate? = nil
    private var viewID: Int32 = 0
    /// vrView: assigned, not retained; the CPR's hidden VRView, which its
    /// VRController owns.
    private unowned(unsafe) var _vrView: (NSView & HorosMPRVRViewMessages)? = nil
    /// pix: assigned, not retained; the last pix of the view's list.
    private unowned(unsafe) var _pix: DCMPix? = nil
    /// camera, retained.
    private var _camera: Camera? = nil
    /// windowController: assigned, the CPRController of the view's window.
    private unowned(unsafe) var windowControllerIvar: CPRController? = nil
    /// curvedPath, a retained copy.
    private var _curvedPath: CPRCurvedPath? = nil
    /// displayInfo, a retained copy.
    private var _displayInfo: CPRDisplayInfo? = nil
    private var editingCurvedPathCount: Int = 0
    private var draggedToken: CPRCurvedPathControlToken = 0
    private var _angleMPR: Float = 0
    private var _CPRType: Int = 0
    /// _ROIManager: made once, released with the view (#853).
    private var _ROIManager: OSIROIManager? = nil
    private var _dontUseAutoLOD = false

    private var crossLinesA: CrossLines = ((0, 0, 0), (0, 0, 0))
    private var crossLinesB: CrossLines = ((0, 0, 0), (0, 0, 0))

    private var _viewExport: Int32 = 0
    private var _fromIntervalExport: Float = 0
    private var _toIntervalExport: Float = 0
    private var _LOD: Float = 0
    private var previousResolution: Float = 0
    private var previousPixelSpacing: Float = 0
    private var previousOrientation = [Float](repeating: 0, count: 9)
    private var previousOrigin = [Float](repeating: 0, count: 3)

    private var _rotateLines = false
    private var _moveCenter = false
    private var _displayCrossLines = false
    private var lastRenderingWasMoveCenter = false

    private var rotateLinesStartAngle: Float = 0

    private var dontReenterCrossReferenceLines = false

    private var dontCheckRoiChange = false

    // The former -dealloc only released camera, curvedPath and displayInfo,
    // which Swift releases, as it releases _ROIManager: there is no deinit.

    /// [self window].backingScaleFactor, 0 without a window.
    private var backingScaleFactor: CGFloat {
        return self.window?.backingScaleFactor ?? 0
    }

    // MARK: - Properties

    @objc public dynamic var delegate: CPRViewDelegate? {
        get { return _delegate }
        set { _delegate = newValue }
    }

    @objc public dynamic var pix: DCMPix! {
        return _pix
    }

    @objc public dynamic var camera: Camera! {
        get { return _camera }
        set { _camera = newValue }
    }

    @objc public dynamic var curvedPath: CPRCurvedPath! {
        get { return _curvedPath }
        set {
            let newCurvedPath = newValue
            if _curvedPath !== newCurvedPath {
                _curvedPath = newCurvedPath?.copy() as? CPRCurvedPath
                self.needsDisplay = true
            }
        }
    }

    @objc public dynamic var displayInfo: CPRDisplayInfo! {
        get { return _displayInfo }
        set {
            let newDisplayInfo = newValue
            if _displayInfo !== newDisplayInfo {
                _displayInfo = newDisplayInfo?.copy() as? CPRDisplayInfo
                self.needsDisplay = true
            }
        }
    }

    @objc public dynamic var angleMPR: Float {
        get { return _angleMPR }
        set { _angleMPR = newValue }
    }

    @objc public dynamic var fromIntervalExport: Float {
        get { return _fromIntervalExport }
        set { _fromIntervalExport = newValue }
    }

    @objc public dynamic var toIntervalExport: Float {
        get { return _toIntervalExport }
        set { _toIntervalExport = newValue }
    }

    /// The former -setLOD: only set the ivar.
    @objc public dynamic var LOD: Float {
        get { return _LOD }
        set { _LOD = newValue }
    }

    @objc public dynamic var viewExport: Int32 {
        get { return _viewExport }
        set { _viewExport = newValue }
    }

    @objc public dynamic var displayCrossLines: Bool {
        get { return _displayCrossLines }
        set {
            _displayCrossLines = newValue
            windowControllerIvar?.updateToolbarItems()
        }
    }

    @objc public dynamic var dontUseAutoLOD: Bool {
        get { return _dontUseAutoLOD }
        set { _dontUseAutoLOD = newValue }
    }

    /// The former `VRView *`: VRView.h is C++, so the view is typed by the
    /// messages the view sends it.
    @objc public dynamic var vrView: (NSView & HorosMPRVRViewMessages)! {
        return _vrView
    }

    @objc public dynamic var rotateLines: Bool {
        return _rotateLines
    }

    @objc public dynamic var moveCenter: Bool {
        return _moveCenter
    }

    @objc(CPRType) public dynamic var CPRType: Int {
        get { return _CPRType }
        set {
            let type = newValue
            if type != _CPRType {
                _CPRType = type
                self.needsDisplay = true
            }
        }
    }

    // MARK: -

    public override dynamic func becomeFirstResponder() -> Bool {
        let v = super.becomeFirstResponder()

        windowControllerIvar?.updateToolbarItems()

        return v
    }

    @objc(is2DTool:)
    public dynamic func is2DTool(_ tool: ToolMode) -> Bool {
        switch tool {
        case .tWL:
            if _vrView?.renderingMode == 1 || _vrView?.renderingMode == 3 || _vrView?.renderingMode == 2 { return true } // MIP
            else { return false } // VR

        case .tNext, .tMesure, .tROI, .tOval, .tOPolygon, .tCPolygon, .tAngle, .tArrow, .tText, .tPencil, .tPlain,
             .t2DPoint, .tRepulsor, .tLayerROI, .tROISelector, .tCurvedROI:
            return true

        default:
            break
        }

        return false
    }

    /// The files arrive as an NSArray, so that the list goes to DCMView as the
    /// caller made it.
    @objc(setDCMPixList:filesList:roiList:firstImage:type:reset:)
    public dynamic func setDCMPixList(_ pixList: NSMutableArray!, filesList files: NSArray!, roiList rois: NSMutableArray!,
                                      firstImage: Int16, type: CChar, reset: Bool) {
        super.setPixels(pixList, files: files as? [Any], rois: rois, firstImage: firstImage, level: type, reset: reset)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(removeROI(_:)),
                                               name: NSNotification.Name.OsirixRemoveROI,
                                               object: nil)

        self.horos_rotation = 0

        _pix = pixList?.lastObject as? DCMPix

        self.horos_currentTool = .t3DRotate

        frameZoomed = false
        _displayCrossLines = true

        windowControllerIvar = self.windowController() as? CPRController

        windowControllerIvar?.updateToolbarItems()
        draggedToken = controlTokenNone
    }

    @objc(setVRView:viewID:)
    public dynamic func setVRView(_ v: (NSView & HorosMPRVRViewMessages)!, viewID i: Int32) {
        viewID = i
        _vrView = v
        _vrView?.prepareFullDepthCapture()
    }

    @objc public dynamic func saveCamera() {
        _camera = _vrView?.camera(withThumbnail: false)
    }

    public override dynamic func draw(_ rect: NSRect) {
        if rect.size.width > 10 {
            let name = String(format: "mpr-%d", viewID)
            let lifecycle = windowControllerIvar?.renderLifecycle
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
            // @try { [super drawRect:] } @finally { [lifecycle endDrawNamed:] }
            var raised: NSException? = nil
            do {
                try HorosObjCException.perform {
                    super.draw(rect)
                }
            } catch {
                raised = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
            }
            lifecycle?.endDraw(named: name)
            raised?.raise()
        }
    }

    public override dynamic var frame: NSRect {
        get { return super.frame }
        set {
            let frameRect = newValue

            NSDisableScreenUpdates()

            if NSEqualRects(frameRect, self.frame) == false {
                if let windowController = windowControllerIvar {
                    NSObject.cancelPreviousPerformRequests(withTarget: windowController,
                                                           selector: #selector(CPRController.updateViewsAccordingToFrame(_:)),
                                                           object: nil)
                    windowController.perform(#selector(CPRController.updateViewsAccordingToFrame(_:)), with: nil, afterDelay: 0.1)
                }
            }

            if let blendingView = self.blending {
                blendingView.frame = frameRect
                blendingView.drawingFrameRect = self.convertToBacking(frameRect) // very important to have correct position values with PET-CT
            }

            super.frame = frameRect

            NSEnableScreenUpdates()
        }
    }

    @objc(checkForFrame)
    private dynamic func checkForFrame() {
        let frame = self.convert(self.bounds, to: nil)

        if NSEqualRects(frame, _vrView?.frame ?? NSZeroRect) == false {
            _vrView?.frame = frame
        }
    }

    @objc(hasCameraChanged:)
    private dynamic func hasCameraChanged(_ currentCamera: Camera?) -> Bool {
        if _camera?.forceUpdate ?? false {
            _camera?.forceUpdate = false
            return true
        }

        func moved(_ a: Float, _ b: Float) -> Bool {
            return abs(Double(a - b)) > PRECISION
        }

        if moved(currentCamera?.position?.x ?? 0, _camera?.position?.x ?? 0) { return true }
        if moved(currentCamera?.position?.y ?? 0, _camera?.position?.y ?? 0) { return true }
        if moved(currentCamera?.position?.z ?? 0, _camera?.position?.z ?? 0) { return true }

        if moved(currentCamera?.focalPoint?.x ?? 0, _camera?.focalPoint?.x ?? 0) { return true }
        if moved(currentCamera?.focalPoint?.y ?? 0, _camera?.focalPoint?.y ?? 0) { return true }
        if moved(currentCamera?.focalPoint?.z ?? 0, _camera?.focalPoint?.z ?? 0) { return true }

        if moved(currentCamera?.viewUp?.x ?? 0, _camera?.viewUp?.x ?? 0) { return true }
        if moved(currentCamera?.viewUp?.y ?? 0, _camera?.viewUp?.y ?? 0) { return true }
        if moved(currentCamera?.viewUp?.z ?? 0, _camera?.viewUp?.z ?? 0) { return true }

        if moved(currentCamera?.viewAngle ?? 0, _camera?.viewAngle ?? 0) { return true }
        if moved(currentCamera?.eyeAngle ?? 0, _camera?.eyeAngle ?? 0) { return true }
        if moved(currentCamera?.parallelScale ?? 0, _camera?.parallelScale ?? 0) { return true }

        if (currentCamera?.clippingRangeNear ?? 0) != (_camera?.clippingRangeNear ?? 0) { return true }
        if (currentCamera?.clippingRangeFar ?? 0) != (_camera?.clippingRangeFar ?? 0) { return true }

        //	if( currentCamera.LOD < camera.LOD) return YES;

        if (currentCamera?.wl ?? 0) != (_camera?.wl ?? 0) { return true }
        if (currentCamera?.ww ?? 0) != (_camera?.ww ?? 0) { return true }

        return false
    }

    @objc public dynamic func restoreCamera() {
        return self.restoreCameraAndCheckForFrame(true)
    }

    @objc(restoreCameraAndCheckForFrame:)
    public dynamic func restoreCameraAndCheckForFrame(_ v: Bool) {
        if v {
            self.checkForFrame()
        }
        _vrView?.setCamera(_camera)
    }

    @objc(updateViewMPROnLoading::)
    private dynamic func updateViewMPR(onLoading isLoading: Bool, _ computeCrossReferenceLines: Bool) {
        if self.frame.size.width <= 0 {
            return
        }

        if self.frame.size.height <= 0 {
            return
        }

        var h = 0, w = 0
        var previousWW: Float = 0, previousWL: Float = 0
        var isRGB: ObjCBool = false
        var previousOriginInPlane = false

        self.getWLWW(&previousWL, &previousWW)

        let currentCamera = _vrView?.camera(withThumbnail: false)

        minimumStep = 1

        if self.hasCameraChanged(currentCamera) == true {
            // AutoLOD
            if _dontUseAutoLOD == false && lastRenderingWasMoveCenter == false {
                let o = windowControllerIvar?.originalPix

                var minimumResolution = Float(o?.pixelSpacingX ?? 0)

                if Double(minimumResolution) > (o?.pixelSpacingY ?? 0) {
                    minimumResolution = Float(o?.pixelSpacingY ?? 0)
                }

                if Double(minimumResolution) > (o?.sliceInterval ?? 0) {
                    minimumResolution = Float(o?.sliceInterval ?? 0)
                }

                if (windowControllerIvar?.clippingRangeThickness ?? 0) <= 3 {
                    minimumResolution = Float(Double(minimumResolution) * 0.9)
                } else {
                    minimumResolution = Float(Double(minimumResolution) * 0.7)
                }

                if minimumResolution > previousPixelSpacing && previousPixelSpacing != 0 {
                    _LOD *= (minimumResolution / previousPixelSpacing)
                }

                if previousResolution == 0 {
                    previousResolution = Float(_vrView?.getResolution() ?? 0)
                }

                let currentResolution = Float(_vrView?.getResolution() ?? 0)

                if previousResolution < currentResolution {
                    _LOD *= (previousResolution / currentResolution)
                }

                if _LOD < (windowControllerIvar?.lod ?? 0) {
                    _LOD = windowControllerIvar?.lod ?? 0
                }

                if _LOD > 4 { _LOD = 4 }

                if windowControllerIvar?.lowLOD ?? false {
                    _vrView?.setLOD(_LOD * (_vrView?.lowResLODFactor ?? 0))
                } else {
                    _vrView?.setLOD(_LOD)
                }
            } else {
                _vrView?.setLOD(_LOD)
            }

            if self.frame.size.width > 0 && self.frame.size.height > 0 {
                let clippingRangeMode = windowControllerIvar?.clippingRangeMode ?? 0
                if (windowControllerIvar?.maxMovieIndex ?? 0) > 1 && (clippingRangeMode == 1 || clippingRangeMode == 3 || clippingRangeMode == 2) { // To avoid the wrong pixel value bug...
                    _vrView?.prepareFullDepthCapture()
                }

                if _moveCenter {
                    lastRenderingWasMoveCenter = true
                    _vrView?.setLOD(100) // We dont need to really compute the image - we just want image origin for the other views.
                } else {
                    lastRenderingWasMoveCenter = false
                }

                if isLoading == false {
                    _vrView?.render()
                }
            }

            var imagePtr: UnsafeMutablePointer<Float>? = nil

            if _moveCenter {
                imagePtr = _pix?.fImage
                w = _pix?.pwidth ?? 0
                h = _pix?.pheight ?? 0
                isRGB = ObjCBool(_pix?.isRGB ?? false)

                _vrView?.setLOD(_LOD)
            } else {
                //if (isLoading == NO)
                imagePtr = _vrView?.image(inFullDepthWidth: &w, height: &h, isRGB: &isRGB)
            }

            ////
            var orientation = [Float](repeating: 0, count: 9)
            _vrView?.getOrientation(&orientation)

            var location: [Float] = [previousOrigin[0], previousOrigin[1], previousOrigin[2]]
            var orig: [Float] = [currentCamera?.position?.x ?? 0, currentCamera?.position?.y ?? 0, currentCamera?.position?.z ?? 0]
            var locationTemp = [Float](repeating: 0, count: 3)
            let distance = orientation.withUnsafeMutableBufferPointer { o in
                DCMView.pbase_Plane(&location, &orig, o.baseAddress! + 6, &locationTemp)
            }
            if Double(distance) < (_pix?.sliceThickness ?? 0) / 2.0 {
                previousOriginInPlane = true
            } else {
                previousOriginInPlane = false
            }

            self.saveCamera()

            if let image = imagePtr {
                var cameraMoved = true

                if (self.curRoiList?.count ?? 0) > 0 {
                    let parallel = orientation.withUnsafeMutableBufferPointer { o in
                        previousOrientation.withUnsafeMutableBufferPointer { p in
                            HorosMPRArePlanesParallel(o.baseAddress! + 6, p.baseAddress! + 6)
                        }
                    }
                    if previousOriginInPlane == false || parallel == false {
                        cameraMoved = true
                    } else {
                        cameraMoved = false
                    }

                    if cameraMoved == true {
                        var i = Int32(truncatingIfNeeded: (self.curRoiList?.count ?? 0) - 1)
                        while i >= 0 {
                            let r = self.curRoiList.object(at: Int(i)) as? ROI
                            if r?.type != .t2DPoint {
                                self.curRoiList.removeObject(at: Int(i))
                            }
                            i -= 1
                        }
                    }
                }

                if (_pix?.pwidth ?? 0) == w && (_pix?.pheight ?? 0) == h && isRGB.boolValue == (_pix?.isRGB ?? false) {
                    if image != _pix?.fImage {
                        memcpy(_pix?.fImage, image, w * h * MemoryLayout<Float>.size)
                        free(image)
                    }
                } else {
                    _pix?.isRGB = isRGB.boolValue
                    _pix?.fImage = image
                    _pix?.freefImage(whenDone: true)
                    _pix?.pwidth = w
                    _pix?.pheight = h

                    let savedROIs = self.curRoiList?.copy() as? NSArray

                    self.setIndex(0)

                    self.curRoiList?.addObjects(from: (savedROIs as? [Any]) ?? [])
                }
                var porigin = [Float](repeating: 0, count: 3)
                _vrView?.getOrigin(&porigin, windowCentered: true, sliceMiddle: true)
                _pix?.setOrigin(&porigin)

                var resolution: Float = 0
                if !_moveCenter {
                    resolution = Float((_vrView?.getResolution() ?? 0) * Double(_vrView?.imageSampleDistance() ?? 0))
                    _pix?.pixelSpacingX = Double(resolution)
                    _pix?.pixelSpacingY = Double(resolution)
                }

                self.willChangeValue(forKey: "plane")
                _pix?.setOrientation(&orientation)
                self.didChangeValue(forKey: "plane")
                _pix?.sliceThickness = _vrView?.getClippingRangeThicknessInMm() ?? 0

                self.setWLWW(previousWL, previousWW)

                if !_moveCenter {
                    self.scaleValue = _vrView?.imageSampleDistance() ?? 0

                    var rotationPlane: Float = 0
                    if cameraMoved == false && (self.curRoiList?.count ?? 0) > 0 {
                        if previousOrientation[0] != 0 || previousOrientation[1] != 0 || previousOrientation[2] != 0 {
                            rotationPlane = Float(-CPRController.angleBetweenVector(&orientation, andPlane: &previousOrientation))
                        }
                        if abs(Double(rotationPlane)) < 0.01 {
                            rotationPlane = 0
                        }
                    }

                    let rotationCenter = NSMakePoint(CGFloat(Double(_pix?.pwidth ?? 0) / 2.0), CGFloat(Double(_pix?.pheight ?? 0) / 2.0))

                    for case let r as ROI in self.curRoiList ?? NSMutableArray() {
                        if rotationPlane != 0 {
                            r.setOriginAndSpacing(resolution, resolution, r.imageOrigin, false)

                            r.rotate(rotationPlane, rotationCenter)
                            r.imageOrigin = DCMPix.originCorrected(accordingToOrientation: _pix)
                            r.pixelSpacingX = _pix?.pixelSpacingX ?? 0
                            r.pixelSpacingY = _pix?.pixelSpacingY ?? 0
                        } else {
                            r.setOriginAndSpacing(resolution, resolution, DCMPix.originCorrected(accordingToOrientation: _pix), false)
                        }
                    }

                    _pix?.orientation(&previousOrientation)
                    previousOrigin[0] = currentCamera?.position?.x ?? 0
                    previousOrigin[1] = currentCamera?.position?.y ?? 0
                    previousOrigin[2] = currentCamera?.position?.z ?? 0

                    self.detect2DPointInThisSlice()

                    previousResolution = Float(_vrView?.getResolution() ?? 0)
                    previousPixelSpacing = Float(_pix?.pixelSpacingX ?? 0)
                }
            }

            if let blendingView = self.blending {
                blendingView.getWLWW(&previousWL, &previousWW)

                _vrView?.renderBlendedVolume()

                var blendedImagePtr: UnsafeMutablePointer<Float>? = nil
                let bPix = blendingView.curDCM

                if _moveCenter {
                    blendedImagePtr = bPix?.fImage
                    w = bPix?.pwidth ?? 0
                    h = bPix?.pheight ?? 0
                    isRGB = ObjCBool(bPix?.isRGB ?? false)
                } else {
                    blendedImagePtr = _vrView?.image(inFullDepthWidth: &w, height: &h, isRGB: &isRGB, blendingView: true)
                }

                if (bPix?.pwidth ?? 0) == w && (bPix?.pheight ?? 0) == h && isRGB.boolValue == (bPix?.isRGB ?? false) {
                    if blendedImagePtr != bPix?.fImage {
                        memcpy(bPix?.fImage, blendedImagePtr, w * h * MemoryLayout<Float>.size)
                        free(blendedImagePtr)
                    }
                } else {
                    bPix?.isRGB = isRGB.boolValue
                    bPix?.fImage = blendedImagePtr
                    bPix?.pwidth = w
                    bPix?.pheight = h

                    blendingView.setIndex(0)
                }
                var porigin = [Float](repeating: 0, count: 3)
                _vrView?.getOrigin(&porigin, windowCentered: true, sliceMiddle: true, blendedView: true)
                bPix?.setOrigin(&porigin)

                if !_moveCenter {
                    let resolution = Float((_vrView?.getResolution() ?? 0) * Double(_vrView?.blendingImageSampleDistance() ?? 0))
                    bPix?.pixelSpacingX = Double(resolution)
                    bPix?.pixelSpacingY = Double(resolution)
                }

                var orientation = [Float](repeating: 0, count: 9)
                _vrView?.getOrientation(&orientation)
                bPix?.setOrientation(&orientation)
                bPix?.sliceThickness = _vrView?.getClippingRangeThicknessInMm() ?? 0

                blendingView.setWLWW(previousWL, previousWW)

                if !_moveCenter {
                    blendingView.scaleValue = _vrView?.blendingImageSampleDistance() ?? 0
                }
            }
        }

        if dontReenterCrossReferenceLines == false {
            dontReenterCrossReferenceLines = true

            if computeCrossReferenceLines {
                windowControllerIvar?.computeCrossReferenceLines(self)
            } else {
                windowControllerIvar?.computeCrossReferenceLines(nil)
            }

            dontReenterCrossReferenceLines = false
        }

        self.needsDisplay = true
    }

    @objc(updateViewMPROnLoading:)
    public dynamic func updateViewMPR(onLoading isLoading: Bool) {
        self.updateViewMPR(onLoading: isLoading, true)
    }

    @objc(updateViewMPR:)
    public dynamic func updateViewMPR(_ computeCrossReferenceLines: Bool) {
        self.updateViewMPR(onLoading: false, computeCrossReferenceLines)
    }

    @objc public dynamic func updateViewMPR() {
        self.updateViewMPR(true)
    }

    /// DCMView's -reshape, which only DCMView.m declares: a method with its
    /// selector overrides it, and [super reshape] calls DCMView's
    /// implementation through the runtime.
    @objc(reshape)
    private dynamic func reshape() {
        // To display or hide the resulting plane on the CPR view
        self.willChangeValue(forKey: "plane")
        self.didChangeValue(forKey: "plane")

        typealias Reshape = @convention(c) (AnyObject, Selector) -> Void
        let selector = NSSelectorFromString("reshape")
        let superReshape = unsafeBitCast(class_getMethodImplementation(DCMView.self, selector), to: Reshape.self)
        superReshape(self, selector)
    }

    /// roiColor4f of the axis colour of view 1, 2 or 3, its components read
    /// through a float as before; a nil controller or colour gives 0.
    private func roiColor(axis: Int) {
        let color: NSColor?
        switch axis {
        case 1: color = windowControllerIvar?.colorAxis1
        case 2: color = windowControllerIvar?.colorAxis2
        default: color = windowControllerIvar?.colorAxis3
        }
        roiColor4f(Float(color?.redComponent ?? 0), Float(color?.greenComponent ?? 0),
                   Float(color?.blueComponent ?? 0), Float(color?.alphaComponent ?? 0))
    }

    @objc(colorForView:)
    private dynamic func colorForView(_ v: Int32) {
        switch v {
        case 1:
            //roiColor4f (VIEW_1_RED, VIEW_1_GREEN, VIEW_1_BLUE, VIEW_1_ALPHA);
            self.roiColor(axis: 1)

        case 2:
            //roiColor4f (VIEW_2_RED, VIEW_2_GREEN, VIEW_2_BLUE, VIEW_2_ALPHA);
            self.roiColor(axis: 2)

        case 3:
            //roiColor4f (VIEW_3_RED, VIEW_3_GREEN, VIEW_3_BLUE, VIEW_3_ALPHA);
            self.roiColor(axis: 3)

        default:
            break
        }
    }

    /// Runs `body` with a float[2][3] copy of `lines`, which DCMView's
    /// -drawCrossLines:... only read.
    private func withCrossLines(_ lines: CrossLines, _ body: (UnsafeMutablePointer<(Float, Float, Float)>) -> Void) {
        var copy = lines
        withUnsafeMutablePointer(to: &copy) { pointer in
            pointer.withMemoryRebound(to: (Float, Float, Float).self, capacity: 2) { body($0) }
        }
    }

    /// -drawLine:thickness:, whose float[2][3] Objective-C cannot represent in Swift.
    private func drawLine(_ sft: CrossLines, thickness: Float) {
        withCrossLines(sft) { sft in
            if thickness > 2 {
                roiLineWidth(Float(2.0 * backingScaleFactor))
                self.drawCrossLines(sft, withShift: 0)

                roiLineWidth(Float(1.0 * backingScaleFactor))
                self.drawCrossLines(sft, withShift: Double(-thickness) / 2.0)
                self.drawCrossLines(sft, withShift: Double(thickness) / 2.0)
            } else {
                roiLineWidth(Float(2.0 * backingScaleFactor))
                self.drawCrossLines(sft, withShift: 0)
            }
        }
    }

    /// -drawExportLines:, whose body was commented out.
    private func drawExportLines(_ sft: CrossLines) {
        //	roiLineWidth(1.0 * self.window.backingScaleFactor);
        //
        //	if( fromIntervalExport > 0)
        //	{
        //		for( int i = 1; i <= fromIntervalExport; i++)
        //			[self drawCrossLines: sft withShift: -i * [windowController dcmInterval]];
        //	}
        //
        //	if( !windowController.dcmBatchReverse)
        //		[self drawCrossLines: sft withShift: -fromIntervalExport * [windowController dcmInterval] showPoint: YES];
        //
        //	if( toIntervalExport > 0)
        //	{
        //		for( int i = 1; i <= toIntervalExport; i++)
        //			[self drawCrossLines: sft withShift: i * [windowController dcmInterval]];
        //	}
        //
        //	if( windowController.dcmBatchReverse)
        //		[self drawCrossLines: sft withShift: toIntervalExport * [windowController dcmInterval] showPoint: YES];
    }

    /// -drawRotationLines:, whose body was commented out.
    private func drawRotationLines(_ sft: CrossLines) {
        //	for( int i = 1; i < windowController.dcmNumberOfFrames; i++)
        //	{
        //		roiRotatef( (float) (i * windowController.dcmRotation) / (float) windowController.dcmNumberOfFrames, 0, 0, 1);
        //		[self drawCrossLines: sft perpendicular: NO withShift: 0 half: YES];
        //		roiRotatef( -(float) (i * windowController.dcmRotation) / (float) windowController.dcmNumberOfFrames, 0, 0, 1);
        //	}
    }

    @objc(drawTextualData::)
    public override dynamic func drawTextualData(_ size: NSRect, _ annotations: Int) {
        let copyScale = self.horos_scaleValue
        self.horos_scaleValue = 1
        super.drawTextualData(size, annotations)
        self.horos_scaleValue = copyScale
    }

    @objc(subDrawRect:)
    public override dynamic func subDraw(_ r: NSRect) {
        if self.stringID == "export" {
            return
        }

        if r.size.height < 10 || r.size.width < 10 {
            return
        }

        self.horos_rotation = 0

        roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
        roiEnable(GL_BLEND)
        roiEnable(GL_POINT_SMOOTH)
        roiEnable(GL_LINE_SMOOTH)
        roiPointSize(Float(12 * backingScaleFactor))

        if _displayCrossLines && frameZoomed.boolValue == false {
            // All pix have the same thickness
            let thickness = Float(_pix?.sliceThickness ?? 0)

            switch viewID {
            case 1:
                self.roiColor(axis: 2)
                if crossLinesA.0.0 != Float.infinity {
                    self.drawLine(crossLinesA, thickness: thickness)
                }
                self.roiColor(axis: 3)
                if crossLinesB.0.0 != Float.infinity {
                    self.drawLine(crossLinesB, thickness: thickness)
                }

            case 2:
                self.roiColor(axis: 1)
                if crossLinesA.0.0 != Float.infinity {
                    self.drawLine(crossLinesA, thickness: thickness)
                }

                self.roiColor(axis: 3)
                if crossLinesB.0.0 != Float.infinity {
                    self.drawLine(crossLinesB, thickness: thickness)
                }

            case 3:
                self.roiColor(axis: 1)
                if crossLinesA.0.0 != Float.infinity {
                    self.drawLine(crossLinesA, thickness: thickness)
                }

                self.roiColor(axis: 2)
                if crossLinesB.0.0 != Float.infinity {
                    self.drawLine(crossLinesB, thickness: thickness)
                }

            default:
                break
            }
        }

        let heighthalf = Float(self.convertToBacking(self.frame.size).height / 2)
        let widthhalf = Float(self.convertToBacking(self.frame.size).width / 2)

        self.colorForView(viewID)

        // Red Square
        if self.window?.firstResponder === self && self.stringID == nil && frameZoomed.boolValue == false {
            roiLineWidth(Float(8.0 * backingScaleFactor))
            roiBegin(GL_LINE_LOOP)
            roiVertex2f(-widthhalf, -heighthalf)
            roiVertex2f(-widthhalf, heighthalf)
            roiVertex2f(widthhalf, heighthalf)
            roiVertex2f(widthhalf, -heighthalf)
            roiEnd()
        }

        roiLineWidth(Float(2.0 * backingScaleFactor))
        roiBegin(GL_POLYGON)
        roiVertex2f(widthhalf - VIEW_COLOR_LABEL_SIZE, -heighthalf + VIEW_COLOR_LABEL_SIZE)
        roiVertex2f(widthhalf - VIEW_COLOR_LABEL_SIZE, -heighthalf)
        roiVertex2f(widthhalf, -heighthalf)
        roiVertex2f(widthhalf, -heighthalf + VIEW_COLOR_LABEL_SIZE)
        roiEnd()
        roiLineWidth(Float(1.0 * backingScaleFactor))

        let controller = windowControllerIvar
        if _displayCrossLines && frameZoomed.boolValue == false && (controller?.displayMousePosition ?? false)
            && !(controller?.mprView1?.rotateLines ?? false) && !(controller?.mprView2?.rotateLines ?? false) && !(controller?.mprView3?.rotateLines ?? false)
            && !(controller?.mprView1?.moveCenter ?? false) && !(controller?.mprView2?.moveCenter ?? false) && !(controller?.mprView3?.moveCenter ?? false) {
            // Mouse Position
            if viewID == (controller?.mouseViewID ?? 0) {
                let pixA: DCMPix?, pixB: DCMPix?
                let viewIDA: Int32, viewIDB: Int32

                switch viewID {
                case 2:
                    pixA = controller?.mprView1?.pix
                    pixB = controller?.mprView3?.pix
                    viewIDA = 1
                    viewIDB = 3
                case 3:
                    pixA = controller?.mprView1?.pix
                    pixB = controller?.mprView2?.pix
                    viewIDA = 1
                    viewIDB = 2
                default: // and case 1
                    pixA = controller?.mprView2?.pix
                    pixB = controller?.mprView3?.pix
                    viewIDA = 2
                    viewIDB = 3
                }

                self.colorForView(viewIDA)
                var pt = controller?.mousePosition
                var sc = [Float](repeating: 0, count: 3)
                var dc: [Float] = [pt?.x ?? 0, pt?.y ?? 0, pt?.z ?? 0]
                var location = [Float](repeating: 0, count: 3)
                pixA?.convertDICOMCoords(&dc, toSliceCoords: &sc, pixelCenter: true)
                sc[0] = Float(Double(sc[0]) / (pixA?.pixelSpacingX ?? 0))
                sc[1] = Float(Double(sc[1]) / (pixA?.pixelSpacingY ?? 0))
                pixA?.convertX(sc[0], pixY: sc[1], toDICOMCoords: &location, pixelCenter: true)
                _pix?.convertDICOMCoords(&location, toSliceCoords: &sc, pixelCenter: true)

                roiPointSize(Float(10 * backingScaleFactor))
                roiBegin(GL_POINTS)
                sc[0] = Float(Double(sc[0]) / (self.curDCM?.pixelSpacingX ?? 0))
                sc[1] = Float(Double(sc[1]) / (self.curDCM?.pixelSpacingY ?? 0))
                sc[0] -= Float(self.curDCM?.pwidth ?? 0) * 0.5
                sc[1] -= Float(self.curDCM?.pheight ?? 0) * 0.5
                roiVertex2f(self.scaleValue * sc[0], self.scaleValue * sc[1])
                roiEnd()

                self.colorForView(viewIDB)
                pt = controller?.mousePosition
                dc[0] = pt?.x ?? 0; dc[1] = pt?.y ?? 0; dc[2] = pt?.z ?? 0
                pixB?.convertDICOMCoords(&dc, toSliceCoords: &sc, pixelCenter: true)
                sc[0] = Float(Double(sc[0]) / (pixB?.pixelSpacingX ?? 0))
                sc[1] = Float(Double(sc[1]) / (pixB?.pixelSpacingY ?? 0))
                pixB?.convertX(sc[0], pixY: sc[1], toDICOMCoords: &location, pixelCenter: true)
                _pix?.convertDICOMCoords(&location, toSliceCoords: &sc, pixelCenter: true)

                roiPointSize(Float(10 * backingScaleFactor))
                roiBegin(GL_POINTS)
                sc[0] = Float(Double(sc[0]) / (self.curDCM?.pixelSpacingX ?? 0))
                sc[1] = Float(Double(sc[1]) / (self.curDCM?.pixelSpacingY ?? 0))
                sc[0] -= Float(self.curDCM?.pwidth ?? 0) * 0.5
                sc[1] -= Float(self.curDCM?.pheight ?? 0) * 0.5
                roiVertex2f(self.scaleValue * sc[0], self.scaleValue * sc[1])
                roiEnd()
            }
            if viewID != (controller?.mouseViewID ?? 0) {
                self.colorForView(viewID)
                //			[self colorForView: windowController.mouseViewID];
                let pt = controller?.mousePosition
                var sc = [Float](repeating: 0, count: 3)
                var dc: [Float] = [pt?.x ?? 0, pt?.y ?? 0, pt?.z ?? 0]

                _pix?.convertDICOMCoords(&dc, toSliceCoords: &sc, pixelCenter: true)

                roiPointSize(Float(10 * backingScaleFactor))
                roiBegin(GL_POINTS)
                sc[0] = Float(Double(sc[0]) / (self.curDCM?.pixelSpacingX ?? 0))
                sc[1] = Float(Double(sc[1]) / (self.curDCM?.pixelSpacingY ?? 0))
                sc[0] -= Float(self.curDCM?.pwidth ?? 0) * 0.5
                sc[1] -= Float(self.curDCM?.pheight ?? 0) * 0.5
                roiVertex2f(self.scaleValue * sc[0], self.scaleValue * sc[1])
                roiEnd()
            }
        }

        self.drawCurvedPathInGL()
        self.drawOSIROIs()

        if windowControllerIvar?.displayMousePosition ?? false {
            for case let planeName as String in (_displayInfo?.planesWithMouseVectors() ?? []) {
                if planeName == self.planeName() {
                    var cursorVector: N3Vector
                    var transform: N3AffineTransform
                    self.colorForView(viewID)
                    roiEnable(GL_POINT_SMOOTH)
                    roiPointSize(Float(8 * backingScaleFactor))
                    transform = N3AffineTransformConcat(N3AffineTransformInvert(self.pixToDicomTransform()), self.pixToSubDrawRectTransform())
                    cursorVector = N3VectorApplyTransform(_displayInfo?.mouseVector(forPlane: planeName) ?? N3Vector(), transform)
                    roiBegin(GL_POINTS)
                    roiVertex2f(Float(cursorVector.x), Float(cursorVector.y))
                    roiEnd()
                }
            }
        }

        roiDisable(GL_LINE_SMOOTH)
        roiDisable(GL_POLYGON_SMOOTH)
        roiDisable(GL_POINT_SMOOTH)
        roiDisable(GL_BLEND)
    }

    /// The former `float[2][3]` parameters, as the float pointers they decay to.
    @objc(setCrossReferenceLines:and:)
    public dynamic func setCrossReferenceLines(_ a: UnsafeMutablePointer<Float>!, and b: UnsafeMutablePointer<Float>!) {
        crossLinesA.0.0 = a[0]
        crossLinesA.0.1 = a[1]
        crossLinesA.0.2 = a[2]
        crossLinesA.1.0 = a[3]
        crossLinesA.1.1 = a[4]
        crossLinesA.1.2 = a[5]

        crossLinesB.0.0 = b[0]
        crossLinesB.0.1 = b[1]
        crossLinesB.0.2 = b[2]
        crossLinesB.1.0 = b[3]
        crossLinesB.1.1 = b[4]
        crossLinesB.1.2 = b[5]
    }

    public override dynamic var currentTool: ToolMode {
        get { return super.currentTool }
        set {
            if newValue != .tRepulsor {
                super.currentTool = newValue
            }
        }
    }

    @objc(horosCurvedPathSession)
    private dynamic func horosCurvedPathSession() -> CurvedMPRPathSession {
        let session = CurvedMPRPathSession()
        for case let value as NSValue in _curvedPath?.nodes ?? NSArray() {
            let node = value.n3VectorValue()
            _ = session.addPatientNodeX(Double(node.x), y: Double(node.y), z: Double(node.z))
        }
        return session
    }

    @objc(stopCurvedPathCreationMode)
    private dynamic func stopCurvedPathCreationMode() {
        let decision = self.horosCurvedPathSession().complete()
        windowControllerIvar?.curvedPathCreationMode = false
        draggedToken = controlTokenNone

        if decision.accepted == false {
            // Delete this curve
            self.sendWillEditCurvedPath()
            _curvedPath?.clearPath()
            self.sendDidUpdateCurvedPath()
            self.sendDidEditCurvedPath()
            self.needsDisplay = true
        } else {
            _ = windowControllerIvar?.renderLifecycle?.markCurveReady()
        }
    }

    /// Whether the curve was deleted: not when it had no node, nor when the
    /// alert was cancelled (#853).
    @objc(deleteCurrentCurvedPath)
    @discardableResult
    private dynamic func deleteCurrentCurvedPath() -> Bool {
        if (_curvedPath?.nodes.count ?? 0) > 0 {
            if HorosAlertPanel.runInformational(title: NSLocalizedString("Delete the Curve", comment: ""),
                                                message: NSLocalizedString("Are you sure you want to delete the entire curve?", comment: ""),
                                                defaultButton: NSLocalizedString("OK", comment: ""),
                                                alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                otherButton: nil) == NSAlertDefaultReturn {
                self.sendWillEditCurvedPath()
                _curvedPath?.clearPath()
                self.sendDidUpdateCurvedPath()
                self.sendDidEditCurvedPath()
                self.needsDisplay = true
                return true
            }
        }
        return false
    }

    public override dynamic func keyDown(with theEvent: NSEvent) {
        if ((theEvent.characters as NSString?)?.length ?? 0) == 0 { return }

        var c = Int((theEvent.characters! as NSString).character(at: 0))

        let tool = self.getTool(theEvent)

        if (c == NSCarriageReturnCharacter || c == NSEnterCharacter || c == NSNewlineCharacter) && tool == .tCurvedROI {
            if windowControllerIvar?.curvedPathCreationMode ?? false {
                self.stopCurvedPathCreationMode()
            }
        } else if c == 32 || c == 27 { // 27 : escape
            if c == 27 && tool == .tCurvedROI {
                if windowControllerIvar?.curvedPathCreationMode ?? false {
                    self.stopCurvedPathCreationMode()
                } else {
                    self.deleteCurrentCurvedPath()
                }
            } else {
                windowControllerIvar?.keyDown(with: theEvent)
            }
        } else if tool == .tCurvedROI && (c == NSDeleteCharacter || c == NSDeleteFunctionKey) {
            // Delete node
            if CPRCurvedPath.controlTokenIsNode(draggedToken) {
                self.sendWillEditCurvedPath()
                _curvedPath?.removeNode(at: CPRCurvedPath.nodeIndexForToken(draggedToken))
                self.sendDidUpdateCurvedPath()
                self.sendDidEditCurvedPath()
                draggedToken = controlTokenNone
                self.needsDisplay = true
                // update costs
                NotificationCenter.default.post(name: NSNotification.Name.OsirixUpdateCurvedPathCost, object: nil)
            } else if self.deleteCurrentCurvedPath() { // Delete the entire curve
                NotificationCenter.default.post(name: NSNotification.Name.OsirixDeletedCurvedPath, object: nil)
            }
        } else if c == NSUpArrowFunctionKey || c == NSDownArrowFunctionKey || c == NSRightArrowFunctionKey || c == NSLeftArrowFunctionKey {
            _moveCenter = true

            self.restoreCamera()

            var center = NSMakePoint(self.frame.size.width / 2.0, self.frame.size.height / 2.0)

            let b1 = NSMakePoint(CGFloat(crossLinesA.0.0), CGFloat(crossLinesA.0.1))
            let b2 = NSMakePoint(CGFloat(crossLinesA.1.0), CGFloat(crossLinesA.1.1))

            let vector = NSMakePoint(b2.x - b1.x, b2.y - b1.y)

            let length = Float(sqrt((vector.x * vector.x) + (vector.y * vector.y)))

            var slopeX = Float(vector.x / CGFloat(length))
            var slopeY = Float(vector.y / CGFloat(length))

            // A flipped image swaps the arrows once (#853): the second test
            // swapped them back, and both arrows moved the same way.
            if self.xFlipped {
                if c == NSLeftArrowFunctionKey {
                    c = NSRightArrowFunctionKey
                } else if c == NSRightArrowFunctionKey {
                    c = NSLeftArrowFunctionKey
                }
            }

            if self.yFlipped {
                if c == NSUpArrowFunctionKey {
                    c = NSDownArrowFunctionKey
                } else if c == NSDownArrowFunctionKey {
                    c = NSUpArrowFunctionKey
                }
            }

            if c == NSDownArrowFunctionKey || c == NSUpArrowFunctionKey {
                if abs(slopeY) < abs(slopeX) {
                    let c = slopeY
                    slopeY = -slopeX
                    slopeX = c
                }

                if slopeY < 0 {
                    slopeY = -slopeY
                    slopeX = -slopeX
                }
            } else {
                if abs(slopeX) < abs(slopeY) {
                    let c = slopeY
                    slopeY = -slopeX
                    slopeX = c
                }

                if slopeX < 0 {
                    slopeY = -slopeY
                    slopeX = -slopeX
                }
            }

            var move: Float = 2

            if theEvent.modifierFlags.contains(.option) { move = 6 }
            if theEvent.modifierFlags.contains(.command) { move = 1 }

            if c == NSDownArrowFunctionKey { center.y -= CGFloat(move * slopeY); center.x += CGFloat(move * slopeX) }
            if c == NSUpArrowFunctionKey { center.y += CGFloat(move * slopeY); center.x -= CGFloat(move * slopeX) }

            if c == NSRightArrowFunctionKey { center.y -= CGFloat(move * slopeY); center.x += CGFloat(move * slopeX) }
            if c == NSLeftArrowFunctionKey { center.y += CGFloat(move * slopeY); center.x -= CGFloat(move * slopeX) }

            _vrView?.setWindowCenter(self.convertToBacking(center))
            self.updateViewMPR()

            _moveCenter = false
            _camera?.windowCenterX = 0
            _camera?.windowCenterY = 0
            _camera?.forceUpdate = true
            self.restoreCamera()
            self.updateViewMPR()

            _moveCenter = false
        } else {
            let scale = self.scaleValue

            super.keyDown(with: theEvent)

            self.scaleValue = scale

            windowControllerIvar?.propagateWLWW(self)
        }
    }

    // MARK: - 3D ROI Point

    @objc public dynamic func detect2DPointInThisSlice() {
        let viewer2D = windowControllerIvar?.viewer()

        if let viewer2D = viewer2D {
            // First delete all 2D Points in our pix

            let ROIsStateSaved = NSMutableDictionary()

            var i = Int32(truncatingIfNeeded: (self.curRoiList?.count ?? 0) - 1)
            while i >= 0 {
                if let r = self.curRoiList.object(at: Int(i)) as? ROI, r.type == .t2DPoint {
                    if let parent = r.parent {
                        ROIsStateSaved.setObject(NSNumber(value: Int32(truncatingIfNeeded: r.roImode)), forKey: NSValue(pointer: Unmanaged.passUnretained(parent).toOpaque()))
                    }
                    self.curRoiList.removeObject(at: Int(i))
                }
                i -= 1
            }

            let roiList = viewer2D.roiList(Int(windowControllerIvar?.curMovieIndex ?? 0)) as NSArray?
            let pixList = viewer2D.pixList(Int(windowControllerIvar?.curMovieIndex ?? 0)) as NSArray?

            var i2: Int32 = 0
            while Int(i2) < (roiList?.count ?? 0) {
                let pts = roiList?.object(at: Int(i2)) as? NSArray
                let p = pixList?.object(at: Int(i2)) as? DCMPix

                for case let r as ROI in pts ?? NSArray() {
                    if r.type == .t2DPoint {
                        var location = [Float](repeating: 0, count: 3)

                        p?.convertX(Float(r.rect.origin.x), pixY: Float(r.rect.origin.y), toDICOMCoords: &location, pixelCenter: true)

                        // Is this point in our plane?

                        var vectors = [Float](repeating: 0, count: 9)
                        var orig = [Float](repeating: 0, count: 3)
                        var locationTemp = [Float](repeating: 0, count: 3)
                        var distance: Float = 999999

                        orig[0] = Float(_pix?.originX ?? 0)
                        orig[1] = Float(_pix?.originY ?? 0)
                        orig[2] = Float(_pix?.originZ ?? 0)

                        _pix?.orientation(&vectors)

                        distance = vectors.withUnsafeMutableBufferPointer { v in
                            DCMView.pbase_Plane(&location, &orig, v.baseAddress! + 6, &locationTemp)
                        }

                        if Double(distance) < (_pix?.sliceThickness ?? 0) {
                            var sc = [Float](repeating: 0, count: 3)

                            _pix?.convertDICOMCoords(&location, toSliceCoords: &sc, pixelCenter: true)

                            sc[0] = Float(Double(sc[0]) / (_pix?.pixelSpacingX ?? 0))
                            sc[1] = Float(Double(sc[1]) / (_pix?.pixelSpacingY ?? 0))

                            let new2DPointROI: ROI = ROI(type: .t2DPoint, Float(_pix?.pixelSpacingX ?? 0), Float(_pix?.pixelSpacingY ?? 0),
                                                         DCMPix.originCorrected(accordingToOrientation: _pix))
                            // curRoiList holds the point (#853); the former
                            // [[ROI alloc] init...] was never released. A point taken
                            // out of the list posts OsirixRemoveROINotification from
                            // -dealloc once it has let its parent go, so -removeROI:
                            // leaves the 2D viewer's point alone.

                            new2DPointROI.rect = NSMakeRect(CGFloat(sc[0]), CGFloat(sc[1]), 0, 0)

                            new2DPointROI.parent = r
                            self.roiSet(new2DPointROI)
                            self.curRoiList?.add(new2DPointROI)

                            let mode = (ROIsStateSaved.object(forKey: NSValue(pointer: Unmanaged.passUnretained(r).toOpaque())) as? NSNumber)?.int32Value ?? 0
                            if mode != 0 {
                                new2DPointROI.roImode = Int(mode)
                            }
                        }
                    }
                }
                i2 += 1
            }

            self.needsDisplay = true
        }
    }

    @objc(add2DPoint:)
    private dynamic func add2DPoint(_ r: UnsafeMutablePointer<Float>) {
        let viewer2D = windowControllerIvar?.viewer()

        if let viewer2D = viewer2D {
            let p = (viewer2D.pixList() as NSArray?)?.object(at: 0) as? DCMPix

            var sc = [Float](repeating: 0, count: 3)

            p?.convertDICOMCoords(r, toSliceCoords: &sc, pixelCenter: true)

            sc[0] = Float(Double(sc[0]) / (p?.pixelSpacingX ?? 0))
            sc[1] = Float(Double(sc[1]) / (p?.pixelSpacingY ?? 0))
            sc[2] = Float(Double(sc[2]) / (p?.sliceInterval ?? 0))

            sc[2] = Float(round(Double(sc[2])))

            if sc[2] >= 0 && sc[2] < Float((viewer2D.pixList() as NSArray?)?.count ?? 0) {
                // Create the new 2D Point ROI
                let new2DPointROI: ROI = ROI(type: .t2DPoint, Float(p?.pixelSpacingX ?? 0), Float(p?.pixelSpacingY ?? 0),
                                             DCMPix.originCorrected(accordingToOrientation: p))

                new2DPointROI.rect = NSMakeRect(CGFloat(sc[0]), CGFloat(sc[1]), 0, 0)

                viewer2D.imageView()?.roiSet(new2DPointROI)
                ((viewer2D.roiList() as NSArray?)?.object(at: Int(sc[2])) as? NSMutableArray)?.add(new2DPointROI)

                // notify the change
                NotificationCenter.default.post(name: NSNotification.Name.OsirixROIChange, object: new2DPointROI, userInfo: nil)
            }
        }
    }

    @objc(roiChange:)
    public override dynamic func roiChange(_ note: Notification!) {
        if dontCheckRoiChange == false {
            let r = note?.object as? ROI

            if r?.curView != nil && r?.curView === windowControllerIvar?.viewer()?.imageView() {
                self.detect2DPointInThisSlice()
            }
        }

        super.roiChange(note)
    }

    @objc(removeROI:)
    public dynamic func removeROI(_ note: Notification!) {
        let r = note?.object as? ROI

        if r?.type == .t2DPoint, let parent = r?.parent {
            windowControllerIvar?.viewer()?.delete(parent)
            r?.parent = nil
        }

        if dontCheckRoiChange == false {
            if r?.curView != nil && r?.curView === windowControllerIvar?.viewer()?.imageView() {
                self.detect2DPointInThisSlice()
            }
        }
    }

    // MARK: - Mouse Events

    //- (BOOL)acceptsFirstResponder
    //{
    //	return NO;
    //}

    public override dynamic func acceptsFirstMouse(for theEvent: NSEvent?) -> Bool {
        return true
    }

    @objc(angleBetween:center:)
    private dynamic func angleBetween(_ mouseLocation: NSPoint, center: NSPoint) -> Float {
        var mouseLocation = mouseLocation
        mouseLocation.x -= center.x
        mouseLocation.y -= center.y

        return Float(-atan2(Double(mouseLocation.x), Double(mouseLocation.y)) / Double(deg2rad))
    }

    @objc(centerLines)
    private dynamic func centerLines() -> NSPoint {
        var r = NSMakePoint(0, 0)

        // One line or no lines : find the middle of the line
        if crossLinesB.0.0 == Float.infinity {
            let a1 = NSMakePoint(CGFloat(crossLinesA.0.0), CGFloat(crossLinesA.0.1))
            let a2 = NSMakePoint(CGFloat(crossLinesA.1.0), CGFloat(crossLinesA.1.1))

            r.x = a2.x + (a1.x - a2.x) / 2.0
            r.y = a2.y + (a1.y - a2.y) / 2.0

            return r
        }

        // One line or no lines : find the middle of the line
        if crossLinesA.0.0 == Float.infinity {
            let b1 = NSMakePoint(CGFloat(crossLinesB.0.0), CGFloat(crossLinesB.0.1))
            let b2 = NSMakePoint(CGFloat(crossLinesB.1.0), CGFloat(crossLinesB.1.1))

            r.x = b2.x + (b1.x - b2.x) / 2.0
            r.y = b2.y + (b1.y - b2.y) / 2.0

            return r
        }

        let a1 = NSMakePoint(CGFloat(crossLinesA.0.0), CGFloat(crossLinesA.0.1))
        let a2 = NSMakePoint(CGFloat(crossLinesA.1.0), CGFloat(crossLinesA.1.1))

        let b1 = NSMakePoint(CGFloat(crossLinesB.0.0), CGFloat(crossLinesB.0.1))
        let b2 = NSMakePoint(CGFloat(crossLinesB.1.0), CGFloat(crossLinesB.1.1))

        DCMView.intersectionBetweenTwoLinesA1(a1, a2: a2, b1: b1, b2: b2, result: &r)

        return r
    }

    @objc(mouseOnLines:)
    private dynamic func mouseOnLines(_ mouseLocation: NSPoint) -> Int32 {
        var mouseLocation = mouseLocation

        if UserDefaults.standard.integer(forKey: "ANNOTATIONS") == annotNone {
            return 0
        }

        if _displayCrossLines == false || frameZoomed.boolValue {
            return 0
        }

        if _LOD == 0 {
            return 0
        }

        if (self.curDCM?.pixelSpacingX ?? 0) == 0 {
            return 0
        }

        // Intersection of the lines
        let r = self.centerLines()

        if r.x != 0 || r.y != 0 {
            mouseLocation = self.convert(fromNSView2GL: mouseLocation)

            mouseLocation.x *= CGFloat(self.curDCM?.pixelSpacingX ?? 0)
            mouseLocation.y *= CGFloat(self.curDCM?.pixelSpacingY ?? 0)

            let f = Float((self.curDCM?.pixelSpacingX ?? 0) / Double(_LOD) * Double(backingScaleFactor))

            if Double(mouseLocation.x) > Double(r.x) - BS * Double(f) && Double(mouseLocation.x) < Double(r.x) + BS * Double(f)
                && Double(mouseLocation.y) > Double(r.y) - BS * Double(f) && Double(mouseLocation.y) < Double(r.y) + BS * Double(f) {
                return 2
            } else {
                var distance1: Float = 1000, distance2: Float = 1000

                if crossLinesA.0.0 != Float.infinity {
                    let a1 = NSMakePoint(CGFloat(crossLinesA.0.0), CGFloat(crossLinesA.0.1))
                    let a2 = NSMakePoint(CGFloat(crossLinesA.1.0), CGFloat(crossLinesA.1.1))
                    DCMView.distancePointLine(mouseLocation, a1, a2, &distance1)
                    distance1 = Float(Double(distance1) / (self.curDCM?.pixelSpacingX ?? 0))
                }

                if crossLinesB.0.0 != Float.infinity {
                    let b1 = NSMakePoint(CGFloat(crossLinesB.0.0), CGFloat(crossLinesB.0.1))
                    let b2 = NSMakePoint(CGFloat(crossLinesB.1.0), CGFloat(crossLinesB.1.1))

                    DCMView.distancePointLine(mouseLocation, b1, b2, &distance2)
                    distance2 = Float(Double(distance2) / (self.curDCM?.pixelSpacingX ?? 0))
                }

                if Double(distance1 * self.scaleValue) < Double(10 * backingScaleFactor) || Double(distance2 * self.scaleValue) < Double(10 * backingScaleFactor) {
                    return 1
                }
            }
        }

        return 0
    }

    /// [NSObject cancelPreviousPerformRequestsWithTarget: windowController selector:@selector(delayedFullLODRendering:) object: object]
    /// and [windowController performSelector: @selector(delayedFullLODRendering:) withObject: object afterDelay: delay].
    private func scheduleDelayedFullLODRendering(_ object: Any?, afterDelay delay: TimeInterval) {
        guard let windowController = windowControllerIvar else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: windowController, selector: #selector(CPRController.delayedFullLODRendering(_:)), object: object)
        windowController.perform(#selector(CPRController.delayedFullLODRendering(_:)), with: object, afterDelay: delay)
    }

    /// windowController.mprViewN.LOD *= 0.9, a double product stored as a float.
    private func reduceLODOfThePlaneViews() {
        for view in [windowControllerIvar?.mprView1, windowControllerIvar?.mprView2, windowControllerIvar?.mprView3] {
            if let view = view {
                view.LOD = Float(Double(view.LOD) * 0.9)
            }
        }
    }

    /// The transform from this view's coordinates to the DICOM space, which the
    /// curve edits pass to CPRCurvedPath.
    private func viewToDicomTransform() -> N3AffineTransform {
        return N3AffineTransformConcat(self.viewToPixTransform(), self.pixToDicomTransform())
    }

    public override dynamic func scrollWheel(with theEvent: NSEvent) {
        var mouseLocation: NSPoint

        windowControllerIvar?.add(toUndoQueue: "mprCamera")

        if self.window?.firstResponder !== self {
            self.window?.makeFirstResponder(self)
        }

        if draggedToken != controlTokenNone {
            mouseLocation = self.convert(theEvent.locationInWindow, from: nil)
            self.sendWillEditCurvedPath()
            let transform = self.viewToDicomTransform()
            _curvedPath?.moveControlToken(draggedToken, to: mouseLocation, transform: transform)
            self.sendDidEditCurvedPath()

            if CPRCurvedPath.controlTokenIsNode(draggedToken) {
                self.sendWillEditDisplayInfo()
                let draggedPosition = _curvedPath?.relativePosition(forControlToken: draggedToken) ?? 0
                _displayInfo?.draggedPosition = draggedPosition
                self.sendDidEditDisplayInfo()
            }

            self.needsDisplay = true
        }

        self.restoreCamera()

        windowControllerIvar?.lowLOD = true

        _vrView?.scrollWheel(with: theEvent)

        self.updateViewMPR(false)
        self.updateMousePosition(theEvent)

        self.displayIfNeeded()

        self.scheduleDelayedFullLODRendering(self, afterDelay: 0.2)
    }

    public override dynamic func rightMouseDown(with theEvent: NSEvent) {
        self.flagsChanged(with: theEvent)

        windowControllerIvar?.add(toUndoQueue: "mprCamera")

        if self.window?.firstResponder !== self {
            self.window?.makeFirstResponder(self)
        }

        self.magicTrick()

        _rotateLines = false
        _moveCenter = false

        self.restoreCamera()

        _vrView?.rightMouseDown(with: theEvent)

        self.updateViewMPR()
    }

    public override dynamic func rightMouseDragged(with theEvent: NSEvent) {
        self.flagsChanged(with: theEvent)

        self.restoreCamera()

        windowControllerIvar?.lowLOD = true

        _vrView?.rightMouseDragged(with: theEvent)

        self.updateViewMPR(false)

        self.updateMousePosition(theEvent)

        self.scheduleDelayedFullLODRendering(nil, afterDelay: 0.4)
    }

    public override dynamic func rightMouseUp(with theEvent: NSEvent) {
        self.flagsChanged(with: theEvent)

        if let windowController = windowControllerIvar {
            NSObject.cancelPreviousPerformRequests(withTarget: windowController, selector: #selector(CPRController.delayedFullLODRendering(_:)), object: nil)
        }

        windowControllerIvar?.lowLOD = false

        self.reduceLODOfThePlaneViews()

        self.restoreCamera()

        _vrView?.rightMouseUp(with: theEvent)

        if (_vrView?.lowResLODFactor ?? 0) > 1 {
            windowControllerIvar?.mprView1?.camera?.forceUpdate = true
            windowControllerIvar?.mprView2?.camera?.forceUpdate = true
            windowControllerIvar?.mprView3?.camera?.forceUpdate = true
        }

        self.updateViewMPR()

        self.updateMousePosition(theEvent)
    }

    /// Dont ask me to explain this function... it's just magic : rendering time is increased by 2 after this call...
    @objc public dynamic func magicTrick() {
        self.restoreCamera()
        _camera?.forceUpdate = true
        _dontUseAutoLOD = true
        _moveCenter = true
        self.updateViewMPR(false)
        _moveCenter = false
        _dontUseAutoLOD = false
    }

    /// cursor = [[NSCursor closedHandCursor] retain], the former cursor released; then [cursor set].
    private func setClosedHandCursor() {
        self.horos_cursor = NSCursor.closedHand
        self.cursor?.set()
    }

    /// The display info edits that start a node drag.
    private func beginDraggingNode() {
        self.sendWillEditCurvedPath()
        self.sendWillEditDisplayInfo()
        _displayInfo?.draggedPositionHidden = false
        let draggedPosition = _curvedPath?.relativePosition(forControlToken: draggedToken) ?? 0
        _displayInfo?.draggedPosition = draggedPosition
        _displayInfo?.mouseCursorHidden = true
        _displayInfo?.mouseCursorPosition = 0
        self.sendDidEditDisplayInfo()

        self.setClosedHandCursor()
    }

    public override dynamic func mouseDown(with theEvent: NSEvent) {
        var relativePositionOnCurve: CGFloat
        var distanceToCurve: CGFloat = 0

        if self.window?.firstResponder !== self {
            self.window?.makeFirstResponder(self)
            if !((windowControllerIvar?.curvedPathCreationMode ?? false) && self.getTool(theEvent) == .tCurvedROI) {
                return
            }
        }

        dontCheckRoiChange = true

        self.checkCursor()

        var clickCount = 1

        do {
            try HorosObjCException.perform {
                if theEvent.type == .leftMouseDown || theEvent.type == .rightMouseDown || theEvent.type == .leftMouseUp || theEvent.type == .rightMouseUp {
                    clickCount = theEvent.clickCount
                }
            }
        } catch {
            clickCount = 1
        }

        if clickCount == 2 && self.horos_drawingROI == false {
            let tool = self.getTool(theEvent)

            if tool == .tText {
                (self.windowController() as? CPRController)?.roiGetInfo(self)
            } else if tool == .tCurvedROI {
                if windowControllerIvar?.curvedPathCreationMode ?? false {
                    self.stopCurvedPathCreationMode()
                } else {
                    let mouseLocation = self.convert(theEvent.locationInWindow, from: nil)

                    let transform = self.viewToDicomTransform()
                    let token = _curvedPath?.controlTokenNear(mouseLocation, transform: transform) ?? 0
                    if CPRCurvedPath.controlTokenIsNode(token) {
                        windowControllerIvar?.curvedPathCreationMode = true // Switch back to Creation Mode
                        //                    draggedToken = token;
                        //					[windowController CPRView:self setCrossCenter:[[curvedPath.nodes objectAtIndex: [CPRCurvedPath nodeIndexForToken: token]] N3VectorValue]];
                    }
                }
            } else {
                let controller = windowControllerIvar
                if frameZoomed.boolValue == false {
                    let frame1 = controller?.mprView1?.frame ?? NSZeroRect
                    let frame3 = controller?.mprView3?.frame ?? NSZeroRect
                    splitPosition.0 = cInt32(Double(frame1.origin.x + frame1.size.width)) // vert
                    splitPosition.1 = cInt32(Double(frame1.origin.y + frame1.size.height)) // hori12
                    splitPosition.2 = cInt32(Double(frame3.origin.y + frame3.size.height)) // horiz2

                    frameZoomed = true
                    switch viewID {
                    case 1:
                        controller?.verticalSplit?.setPosition(controller?.verticalSplit?.maxPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)
                        controller?.horizontalSplit1?.setPosition(controller?.horizontalSplit1?.maxPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)

                    case 2:
                        controller?.verticalSplit?.setPosition(controller?.verticalSplit?.maxPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)
                        controller?.horizontalSplit1?.setPosition(controller?.horizontalSplit1?.minPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)

                    case 3:
                        controller?.verticalSplit?.setPosition(controller?.verticalSplit?.minPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)
                        controller?.horizontalSplit2?.setPosition(controller?.horizontalSplit2?.maxPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)

                    default:
                        break
                    }
                } else {
                    frameZoomed = false
                    controller?.verticalSplit?.setPosition(CGFloat(splitPosition.0), ofDividerAt: 0)
                    controller?.horizontalSplit1?.setPosition(CGFloat(splitPosition.1), ofDividerAt: 0)
                    controller?.horizontalSplit2?.setPosition(CGFloat(splitPosition.2), ofDividerAt: 0)

                    controller?.mprView1?.restoreCamera()
                    controller?.mprView1?.camera?.forceUpdate = true
                    controller?.mprView1?.updateViewMPR()

                    controller?.mprView2?.restoreCamera()
                    controller?.mprView2?.camera?.forceUpdate = true
                    controller?.mprView2?.updateViewMPR()

                    controller?.mprView3?.restoreCamera()
                    controller?.mprView3?.camera?.forceUpdate = true
                    controller?.mprView3?.updateViewMPR()

                    controller?.cprView?.scaleValue = 0.8
                }

                self.restoreCamera()
                windowControllerIvar?.lowLOD = false
                self.updateViewMPR()
            }
        } else {
            self.magicTrick()

            windowControllerIvar?.add(toUndoQueue: "mprCamera")

            _rotateLines = false
            _moveCenter = false

            let mouseOnLines = self.mouseOnLines(self.convert(theEvent.locationInWindow, from: nil))
            if mouseOnLines == 2 {
                _moveCenter = true

                self.mouseDragged(with: theEvent)

                NSCursor.closedHand.set()
            } else if mouseOnLines == 1 {
                _rotateLines = true

                var mouseLocation = self.convert(fromNSView2GL: self.convert(theEvent.locationInWindow, from: nil))
                mouseLocation.x *= CGFloat(self.curDCM?.pixelSpacingX ?? 0); mouseLocation.y *= CGFloat(self.curDCM?.pixelSpacingY ?? 0)
                rotateLinesStartAngle = self.angleBetween(mouseLocation, center: self.centerLines()) - _angleMPR

                self.mouseDragged(with: theEvent)

                NSCursor.rotateAxisCursor()?.set()
            } else {
                let tool = self.getTool(theEvent)

                _vrView?.keep3DRotateCentered = true
                if tool == .tCamera3D {
                    if _displayCrossLines == false || frameZoomed.boolValue == true {
                        _vrView?.keep3DRotateCentered = false
                    } else {
                        if theEvent.modifierFlags.contains(.option) {
                            _vrView?.keep3DRotateCentered = false
                        }
                    }
                }

                self.restoreCamera()

                if self.is2DTool(tool) {
                    if tool != .tCurvedROI {
                        super.mouseDown(with: theEvent)
                        windowControllerIvar?.propagateWLWW(self)

                        for case let r as ROI in self.curRoiList ?? NSMutableArray() {
                            var mode: Int32

                            if r.type == .t2DPoint, let parent = r.parent {
                                mode = Int32(truncatingIfNeeded: r.roImode)
                                if mode == ROI_selected || mode == ROI_selectedModify || mode == ROI_drawing {
                                    windowControllerIvar?.viewer()?.delete(parent)
                                    r.parent = nil
                                }
                            }
                        }
                    } else { // tool == tCurvedROI
                        super.mouseDown(with: theEvent)
                        self.deleteMouseDownTimer()

                        let mouseLocation = self.convert(theEvent.locationInWindow, from: nil)

                        if (windowControllerIvar?.curvedPathCreationMode ?? false) == false && (_curvedPath?.nodes.count ?? 0) == 0 {
                            windowControllerIvar?.curvedPathCreationMode = true
                        }

                        if windowControllerIvar?.curvedPathCreationMode ?? false {
                            let transform = self.viewToDicomTransform()
                            draggedToken = _curvedPath?.controlTokenNear(mouseLocation, transform: transform) ?? 0

                            //						if( draggedToken != CPRCurvedPathControlTokenNone && [CPRCurvedPath nodeIndexForToken: draggedToken] > 1) // Two clicks on the last point to close the curved and stop edition
                            //						{
                            //							windowController.curvedPathCreationMode = NO;
                            //							draggedToken = CPRCurvedPathControlTokenNone;
                            //						}

                            if (_curvedPath?.nodes.count ?? 0) <= 1 {
                                draggedToken = controlTokenNone
                            }

                            if CPRCurvedPath.controlTokenIsNode(draggedToken) {
                                self.beginDraggingNode()
                            } else {
                                var viewToDicomTransform = self.viewToDicomTransform()
                                let newCrossCenter = N3VectorApplyTransform(N3VectorMakeFromNSPoint(mouseLocation), viewToDicomTransform)

                                self.sendWillEditCurvedPath()

                                // if the shift key is down, place the point at the same level as the previous point
                                if (_curvedPath?.nodes.count ?? 0) > 0 && theEvent.modifierFlags.contains(.control) {
                                    let lastPoint = (_curvedPath?.nodes.lastObject as? NSValue)?.n3VectorValue() ?? N3Vector()
                                    viewToDicomTransform = N3AffineTransformConcat(N3AffineTransformMakeTranslation(0, 0,
                                                                                                                    N3VectorApplyTransform(lastPoint, N3AffineTransformInvert(viewToDicomTransform)).z), viewToDicomTransform)
                                }
                                let patientNode = N3VectorApplyTransform(N3VectorMakeFromNSPoint(mouseLocation), viewToDicomTransform)
                                let decision = self.horosCurvedPathSession().addPatientNodeX(Double(patientNode.x), y: Double(patientNode.y), z: Double(patientNode.z))
                                if decision.accepted == false {
                                    NSLog("Curved MPR node refused: %@", decision.diagnosis)
                                    self.sendDidEditCurvedPath()
                                    return
                                }
                                _curvedPath?.addNode(mouseLocation, transform: viewToDicomTransform)
                                self.sendDidUpdateCurvedPath()
                                self.sendDidEditCurvedPath()
                                self.needsDisplay = true

                                // Center the views to the last point
                                windowControllerIvar?.cprView(self, setCrossCenter: newCrossCenter)
                            }
                        } else {
                            let transform = self.viewToDicomTransform()
                            draggedToken = _curvedPath?.controlTokenNear(mouseLocation, transform: transform) ?? 0
                            if CPRCurvedPath.controlTokenIsNode(draggedToken) {
                                self.beginDraggingNode()
                            } else if draggedToken != controlTokenNone {
                                self.setClosedHandCursor()

                                self.sendWillEditCurvedPath()
                            }

                            if draggedToken != controlTokenNone {
                                return
                            }

                            let positionTransform = self.viewToDicomTransform()
                            relativePositionOnCurve = _curvedPath?.relativePosition(for: mouseLocation,
                                                                                    transform: positionTransform,
                                                                                    distanceToPoint: &distanceToCurve) ?? 0

                            if distanceToCurve < 5 {
                                self.sendWillEditCurvedPath()
                                _ = _curvedPath?.insertNode(atRelativePosition: relativePositionOnCurve)
                                self.sendDidEditCurvedPath()
                                return
                            }
                        }
                    }
                } else {
                    _vrView?.mouseDown(with: theEvent)

                    if _vrView?._tool() == .tRotate {
                        self.updateViewMPR(false)
                    } else {
                        self.updateViewMPR()
                    }
                }
            }
        }
    }

    public override dynamic func mouseUp(with theEvent: NSEvent) {
        var relativePositionOnCurve: CGFloat
        var distanceToCurve: CGFloat = 0
        let viewPoint: NSPoint

        viewPoint = self.convert(theEvent.locationInWindow, from: nil)
        self.checkCursor()

        if let windowController = windowControllerIvar {
            NSObject.cancelPreviousPerformRequests(withTarget: windowController, selector: #selector(CPRController.delayedFullLODRendering(_:)), object: nil)
        }

        windowControllerIvar?.lowLOD = false

        self.restoreCamera()

        if _rotateLines || _moveCenter {
            if _moveCenter {
                _camera?.windowCenterX = 0
                _camera?.windowCenterY = 0
                _camera?.forceUpdate = true
            }

            if (_vrView?.lowResLODFactor ?? 0) > 1 {
                windowControllerIvar?.mprView1?.camera?.forceUpdate = true
                windowControllerIvar?.mprView2?.camera?.forceUpdate = true
                windowControllerIvar?.mprView3?.camera?.forceUpdate = true
            }

            _rotateLines = false
            _moveCenter = false

            self.reduceLODOfThePlaneViews()

            self.restoreCamera()
            self.updateViewMPR()

            self.cursor?.set()
        } else {
            let tool = self.getTool(theEvent)

            if self.is2DTool(tool) {
                super.mouseUp(with: theEvent)
                windowControllerIvar?.propagateWLWW(self)

                if tool == .tNext {
                    windowControllerIvar?.updateViewsAccordingToFrame(self)
                }

                for case let r as ROI in self.curRoiList ?? NSMutableArray() {
                    if r.type == .t2DPoint && r.parent == nil {
                        var location = [Float](repeating: 0, count: 3)
                        _pix?.convertX(Float(r.rect.origin.x), pixY: Float(r.rect.origin.y), toDICOMCoords: &location, pixelCenter: true)
                        self.add2DPoint(&location)
                    }
                }

                self.detect2DPointInThisSlice()
            } else {
                _vrView?.mouseUp(with: theEvent)

                if (_vrView?.lowResLODFactor ?? 0) > 1 {
                    windowControllerIvar?.mprView1?.camera?.forceUpdate = true
                    windowControllerIvar?.mprView2?.camera?.forceUpdate = true
                    windowControllerIvar?.mprView3?.camera?.forceUpdate = true
                }

                self.reduceLODOfThePlaneViews()

                if _vrView?._tool() == .tRotate {
                    self.updateViewMPR(false)
                } else {
                    self.updateViewMPR()
                }
            }
        }

        if draggedToken != controlTokenNone {
            // Only a node moves the cross (#853): the transverse section and
            // spacing tokens have no node index, and -1 read past the nodes.
            let nodeIndex = CPRCurvedPath.nodeIndexForToken(draggedToken)
            if CPRCurvedPath.controlTokenIsNode(draggedToken), let nodes = _curvedPath?.nodes, nodeIndex >= 0, nodeIndex < nodes.count {
                let node = (nodes.object(at: nodeIndex) as? NSValue)?.n3VectorValue() ?? N3Vector()
                windowControllerIvar?.cprView(self, setCrossCenter: node)
            }

            draggedToken = controlTokenNone
            self.sendDidEditCurvedPath()
        }

        if (_displayInfo?.draggedPositionHidden ?? false) == false {
            let transform = self.viewToDicomTransform()
            relativePositionOnCurve = _curvedPath?.relativePosition(for: viewPoint,
                                                                    transform: transform,
                                                                    distanceToPoint: &distanceToCurve) ?? 0

            self.sendWillEditDisplayInfo()
            _displayInfo?.draggedPositionHidden = true
            _displayInfo?.draggedPosition = 0.0

            if distanceToCurve < CPRMPRDCMViewCurveMouseTrackingDistance {
                _displayInfo?.mouseCursorHidden = false
                _displayInfo?.mouseCursorPosition = relativePositionOnCurve
            } else {
                _displayInfo?.mouseCursorHidden = true
                _displayInfo?.mouseCursorPosition = 0.0
            }

            self.sendDidEditDisplayInfo()
        }

        self.updateMousePosition(theEvent)

        dontCheckRoiChange = false
    }

    @objc(mouseDraggedImageScroll:)
    public override dynamic func mouseDraggedImageScroll(_ event: NSEvent!) {
        self.checkCursor()

        let current = self.currentPoint(inView: event)
        let start = self.horos_start
        let previous = self.horos_previous

        if self.horos_scrollMode == 0 {
            if abs(start.x - current.x) < abs(start.y - current.y) {
                if abs(start.y - current.y) > 3 { self.horos_scrollMode = 1 }
            } else if abs(start.x - current.x) >= abs(start.y - current.y) {
                if abs(start.x - current.x) > 3 { self.horos_scrollMode = 2 }
            }
        }

        let delta: Float

        if self.horos_scrollMode == 1 {
            delta = Float(((previous.y - current.y) * 512.0) / (self.convertToBacking(self.frame.size).width / 2))
        } else {
            delta = Float(((current.x - previous.x) * 512.0) / (self.convertToBacking(self.frame.size).width / 2))
        }

        self.restoreCamera()
        windowControllerIvar?.lowLOD = true
        _vrView?.scroll(inStack: delta)
        self.updateViewMPR()
        self.updateMousePosition(event)
        windowControllerIvar?.lowLOD = false
    }

    public override dynamic func magnify(with anEvent: NSEvent) {
    }

    public override dynamic func rotate(with anEvent: NSEvent) {
    }

    public override dynamic func mouseDragged(with theEvent: NSEvent) {
        self.restoreCamera()

        if _rotateLines {
            NSCursor.rotateAxisCursor()?.set()

            windowControllerIvar?.lowLOD = true

            var mouseLocation = self.convert(fromNSView2GL: self.convert(theEvent.locationInWindow, from: nil))
            mouseLocation.x *= CGFloat(self.curDCM?.pixelSpacingX ?? 0); mouseLocation.y *= CGFloat(self.curDCM?.pixelSpacingY ?? 0)
            _angleMPR = self.angleBetween(mouseLocation, center: self.centerLines())

            _angleMPR -= rotateLinesStartAngle

            self.updateViewMPR()

            self.scheduleDelayedFullLODRendering(nil, afterDelay: 0.4)
        } else if _moveCenter {
            windowControllerIvar?.lowLOD = true

            var point = self.convert(theEvent.locationInWindow, from: nil)

            if self.yFlipped {
                point.y = self.frame.size.height - point.y
            }

            if self.xFlipped {
                point.x = self.frame.size.width - point.x
            }

            _vrView?.setWindowCenter(self.convertToBacking(point))

            self.updateViewMPR()

            self.scheduleDelayedFullLODRendering(nil, afterDelay: 0.4)
        } else {
            let tool = self.getTool(theEvent)

            if self.is2DTool(tool) {
                if draggedToken != controlTokenNone {
                    let mouseLocation = self.convert(theEvent.locationInWindow, from: nil)

                    let transform = self.viewToDicomTransform()
                    _curvedPath?.moveControlToken(draggedToken, to: mouseLocation, transform: transform)
                    self.sendDidUpdateCurvedPath()

                    if CPRCurvedPath.controlTokenIsNode(draggedToken) {
                        self.sendWillEditDisplayInfo()
                        let draggedPosition = _curvedPath?.relativePosition(forControlToken: draggedToken) ?? 0
                        _displayInfo?.draggedPosition = draggedPosition
                        self.sendDidEditDisplayInfo()
                    }

                    super.mouseDragged(with: theEvent)

                    self.needsDisplay = true
                } else {
                    super.mouseDragged(with: theEvent)
                    windowControllerIvar?.propagateWLWW(self)
                }
            } else {
                var before = [Float](repeating: 0, count: 9), after = [Float](repeating: 0, count: 9)

                windowControllerIvar?.lowLOD = true

                if _vrView?._tool() == .tRotate {
                    self.pix?.orientation(&before)
                }

                _vrView?.mouseDragged(with: theEvent)

                if _vrView?._tool() == .tRotate {
                    _ = _vrView?.getCosMatrix(&after)
                    _angleMPR = Float(Double(_angleMPR) - CPRController.angleBetweenVector(&after, andPlane: &before))

                    self.updateViewMPR(false)
                } else if _vrView?._tool() == .tZoom {
                    self.updateViewMPR(false)
                } else {
                    self.updateViewMPR()
                }

                self.scheduleDelayedFullLODRendering(nil, afterDelay: 0.4)
            }
        }

        self.updateMousePosition(theEvent)
    }

    @objc(updateMousePosition:)
    public dynamic func updateMousePosition(_ theEvent: NSEvent!) {
        var location = [Float](repeating: 0, count: 3)

        _pix?.convertX(self.mouseXPos, pixY: self.mouseYPos, toDICOMCoords: &location, pixelCenter: true)

        let pt = Point3D.point(withX: location[0], y: location[1], z: location[2])
        windowControllerIvar?.mousePosition = pt
        windowControllerIvar?.mouseViewID = viewID
    }

    /// The event is optional: CPRController sends the application's current
    /// event, which can be nil, as the former Objective-C did.
    public override dynamic func mouseMoved(with theEvent: NSEvent?) {
        var relativePositionOnCurve: CGFloat
        var distanceToCurve: CGFloat = 0
        let viewPoint: NSPoint
        var curveToken: CPRCurvedPathControlToken
        var needToModifyCurve: Bool

        if windowControllerIvar?.windowWillClose() ?? false {
            return
        }

        let view = theEvent?.window?.contentView?.hitTest(theEvent?.locationInWindow ?? NSZeroPoint)

        viewPoint = self.convert(theEvent?.locationInWindow ?? NSZeroPoint, from: nil)

        if view === self {
            if NSPointInRect(viewPoint, self.bounds) == false {
                return
            }

            // A nil event has no window, so no view is hit: here it is not nil.
            super.mouseMoved(with: theEvent!)

            let tool = self.getTool(theEvent)

            if tool == .tCurvedROI {
                self.horos_cursor = NSCursor.crosshair

                let positionTransform = self.viewToDicomTransform()
                relativePositionOnCurve = _curvedPath?.relativePosition(for: viewPoint, transform: positionTransform,
                                                                        distanceToPoint: &distanceToCurve) ?? 0
                let tokenTransform = self.viewToDicomTransform()
                curveToken = _curvedPath?.controlTokenNear(viewPoint, transform: tokenTransform) ?? 0

                needToModifyCurve = false

                if CPRCurvedPath.controlTokenIsNode(curveToken) {
                    if (_displayInfo?.hoverNodeHidden ?? false) == true || (_displayInfo?.hoverNodeIndex ?? 0) != CPRCurvedPath.nodeIndexForToken(curveToken) {
                        needToModifyCurve = true
                    }
                } else {
                    if (_displayInfo?.hoverNodeHidden ?? false) == false {
                        needToModifyCurve = true
                    }
                }

                if distanceToCurve < CPRMPRDCMViewCurveMouseTrackingDistance {
                    needToModifyCurve = true
                } else {
                    if (_displayInfo?.mouseCursorHidden ?? false) == false {
                        needToModifyCurve = true
                    }
                }

                if needToModifyCurve {
                    self.sendWillEditDisplayInfo()
                }

                if CPRCurvedPath.controlTokenIsNode(curveToken) {
                    if theEvent?.type == .leftMouseDragged || theEvent?.type == .leftMouseDown {
                        self.horos_cursor = NSCursor.closedHand
                    } else {
                        self.horos_cursor = NSCursor.openHand
                    }

                    _displayInfo?.hoverNodeHidden = false
                    _displayInfo?.hoverNodeIndex = CPRCurvedPath.nodeIndexForToken(curveToken)
                } else if curveToken != controlTokenNone {
                    if theEvent?.type == .leftMouseDragged || theEvent?.type == .leftMouseDown {
                        self.horos_cursor = NSCursor.closedHand
                    } else {
                        self.horos_cursor = NSCursor.openHand
                    }
                } else {
                    _displayInfo?.hoverNodeHidden = true
                    _displayInfo?.hoverNodeIndex = 0
                }

                if distanceToCurve < CPRMPRDCMViewCurveMouseTrackingDistance {
                    _displayInfo?.mouseCursorHidden = false
                    _displayInfo?.mouseCursorPosition = relativePositionOnCurve
                } else {
                    _displayInfo?.mouseCursorHidden = true
                    _displayInfo?.mouseCursorPosition = 0
                }

                if needToModifyCurve {
                    self.sendDidEditDisplayInfo()
                    self.needsDisplay = true
                }
            }

            let mouseOnLines = self.mouseOnLines(viewPoint)
            if mouseOnLines == 2 {
                if theEvent?.type == .leftMouseDragged || theEvent?.type == .leftMouseDown { NSCursor.closedHand.set() }
                else { NSCursor.openHand.set() }
            } else if mouseOnLines == 1 {
                NSCursor.rotateAxisCursor()?.set()
            } else {
                self.cursor?.set()
            }

            self.updateMousePosition(theEvent)
        } else {
            if let theEvent = theEvent {
                view?.mouseMoved(with: theEvent)
            }
        }
    }

    public override dynamic func mouseExited(with theEvent: NSEvent) {
        var needToModifyCurve: Bool

        needToModifyCurve = false
        if (_displayInfo?.hoverNodeHidden ?? false) == false {
            needToModifyCurve = true
        }

        if (_displayInfo?.mouseCursorHidden ?? false) == false {
            needToModifyCurve = true
        }

        if needToModifyCurve {
            self.sendWillEditDisplayInfo()
        }

        _displayInfo?.hoverNodeHidden = true
        _displayInfo?.hoverNodeIndex = 0

        _displayInfo?.mouseCursorHidden = true
        _displayInfo?.mouseCursorPosition = 0

        if needToModifyCurve {
            self.sendDidEditDisplayInfo()
            self.needsDisplay = true
        }

        super.mouseExited(with: theEvent)
    }

    // MARK: -

    @objc(sendWillEditCurvedPath)
    private dynamic func sendWillEditCurvedPath() {
        if editingCurvedPathCount == 0 {
            if let delegate = _delegate, delegate.responds(to: #selector(CPRViewDelegate.cprViewWillEditCurvedPath(_:))) {
                delegate.cprViewWillEditCurvedPath!(self)
            }
        }
        editingCurvedPathCount += 1
    }

    @objc(sendDidUpdateCurvedPath)
    private dynamic func sendDidUpdateCurvedPath() {
        if let delegate = _delegate, delegate.responds(to: #selector(CPRViewDelegate.cprViewDidUpdateCurvedPath(_:))) {
            delegate.cprViewDidUpdateCurvedPath!(self)
        }
    }

    @objc(sendDidEditCurvedPath)
    private dynamic func sendDidEditCurvedPath() {
        editingCurvedPathCount -= 1
        if editingCurvedPathCount == 0 {
            if let delegate = _delegate, delegate.responds(to: #selector(CPRViewDelegate.cprViewDidEditCurvedPath(_:))) {
                delegate.cprViewDidEditCurvedPath!(self)
            }
        }
    }

    //- (void)sendWillEditAssistedCurvedPath
    //{
    //	if (editingCurvedPathCount == 0) {
    //		if ([delegate respondsToSelector:@selector(CPRViewWillEditCurvedPath:)]) {
    //			[delegate CPRViewWillEditCurvedPath:self];
    //		}
    //	}
    //	editingCurvedPathCount++;
    //}

    @objc(sendDidEditAssistedCurvedPath)
    private dynamic func sendDidEditAssistedCurvedPath() {
        editingCurvedPathCount -= 1
        if editingCurvedPathCount == 0 {
            // The delegate is asked for the message it is sent (#853): it
            // was asked for -CPRViewDidEditCurvedPath:, and one without the
            // assisted method raised an unrecognized selector.
            if let delegate = _delegate, delegate.responds(to: #selector(CPRViewDelegate.cprViewDidEditAssistedCurvedPath(_:))) {
                delegate.cprViewDidEditAssistedCurvedPath!(self)
            }
        }
    }

    @objc(sendWillEditDisplayInfo)
    private dynamic func sendWillEditDisplayInfo() {
        if let delegate = _delegate, delegate.responds(to: #selector(CPRViewDelegate.cprViewWillEditDisplayInfo(_:))) {
            delegate.cprViewWillEditDisplayInfo!(self)
        }
    }

    @objc(sendDidEditDisplayInfo)
    private dynamic func sendDidEditDisplayInfo() {
        if let delegate = _delegate, delegate.responds(to: #selector(CPRViewDelegate.cprViewDidEditDisplayInfo(_:))) {
            delegate.cprViewDidEditDisplayInfo!(self)
        }
    }

    @objc(setCrossCenter:)
    public dynamic func setCrossCenter(_ crossCenter: NSPoint) {
        self.restoreCamera()

        _vrView?.setWindowCenter(self.convertToBacking(crossCenter))

        _dontUseAutoLOD = true
        _LOD = 40

        self.updateViewMPR()

        _camera?.windowCenterX = 0
        _camera?.windowCenterY = 0

        windowControllerIvar?.delayedFullLODRendering(self)

        _dontUseAutoLOD = false
        _LOD = windowControllerIvar?.lod ?? 0
    }

    @objc(_debugDrawDebugPoints)
    private dynamic func _debugDrawDebugPoints() {
        // first off find the points like the operation would and draw a point at each of the nodes
        var vectors = [N3Vector](repeating: N3Vector(), count: 40)
        var normals = [N3Vector](repeating: N3Vector(), count: 40)
        var numVectors = 40
        let directionVector: N3Vector
        let projectionDirection: N3Vector
        let baseNormal: N3Vector
        let flattenedBezierPath: N3BezierPath?
        let projectedBezierPath: N3BezierPath?
        let projectedLength: CGFloat
        let sampleSpacing: CGFloat
        let transform: N3AffineTransform

        if (_curvedPath?.bezierPath?.elementCount() ?? 0) < 3 {
            return
        }
        // Not nil: a nil path has no elements.
        let curvedPath = _curvedPath!
        let bezierPath = curvedPath.bezierPath!

        transform = N3AffineTransformConcat(N3AffineTransformInvert(self.pixToDicomTransform()), self.pixToSubDrawRectTransform())

        directionVector = N3VectorNormalize(N3VectorSubtract(bezierPath.vectorAtEnd(), bezierPath.vectorAtStart()))
        baseNormal = N3VectorNormalize(N3VectorCrossProduct(curvedPath.baseDirection, directionVector))
        projectionDirection = N3VectorApplyTransform(baseNormal, N3AffineTransformMakeRotationAroundVector(curvedPath.angle, directionVector))

        flattenedBezierPath = bezierPath.flattening(N3BezierDefaultFlatness)
        projectedBezierPath = flattenedBezierPath?.projecting(to: N3PlaneMake(N3VectorZero, projectionDirection))

        projectedLength = projectedBezierPath?.length() ?? 0
        sampleSpacing = projectedLength / CGFloat(numVectors)

        numVectors = N3BezierCoreGetProjectedVectorInfo(flattenedBezierPath?.n3BezierCore(), sampleSpacing, 0, projectionDirection, &vectors, nil, &normals, nil, numVectors)

        for i in 0 ..< max(numVectors, 0) {
            normals[i] = N3VectorApplyTransform(N3VectorAdd(vectors[i], N3VectorScalarMultiply(normals[i], 10)), transform)
            vectors[i] = N3VectorApplyTransform(vectors[i], transform)

            roiColor4d(1.0, 1.0, 1.0, 1.0)
            self.drawCircle(at: NSPointFromN3Vector(vectors[i]))

            roiColor4d(1.0, 0.0, 1.0, 1.0)
            roiBegin(GL_LINES)
            roiVertex2f(Float(vectors[i].x), Float(vectors[i].y))
            roiVertex2f(Float(normals[i].x), Float(normals[i].y))
            roiEnd()
        }
    }

    /// The outline of the path at `distance` from it, as the two slab outlines of
    /// -drawCurvedPathInGL made it: a mutable copy, transformed.
    private func slabOutlinePath(_ bezierPath: N3BezierPath?, distance: CGFloat, flattenedBezierPath: N3MutableBezierPath?) -> N3MutableBezierPath? {
        let outline: N3BezierPath?
        if _CPRType == Int(CPRMPRDCMViewCPRStraightenedType.rawValue) {
            outline = bezierPath?.outlineBezierPath(atDistance: distance, initialNormal: N3VectorCrossProduct(_curvedPath?.initialNormal ?? N3Vector(), flattenedBezierPath?.tangentAtStart() ?? N3Vector()), spacing: 1.0)
        } else {
            outline = bezierPath?.outlineBezierPath(atDistance: distance, projectionNormal: _curvedPath?.stretchedProjectionNormal() ?? N3Vector(), spacing: 1.0)
        }
        return outline?.mutableCopy() as? N3MutableBezierPath
    }

    @objc(drawCurvedPathInGL)
    private dynamic func drawCurvedPathInGL() {
        if (_curvedPath?.nodes.count ?? 0) == 0 {
            return
        }

        let transform: N3AffineTransform
        let bezierPath: N3BezierPath?
        let transformedBezierPath: N3MutableBezierPath? // transformed path to be used to draw control points
        let flattenedBezierPath: N3MutableBezierPath? // path used for rendering
        let flattenedNotTransformedBezierPath: N3BezierPath?
        var outlinePath: N3MutableBezierPath?
        var vector = N3Vector()
        var cursorVector: N3Vector

        let geometry = CPRRenderLifecycle.diagnoseSpacingX(self.curDCM?.pixelSpacingX ?? 0, spacingY: self.curDCM?.pixelSpacingY ?? 0)
        if geometry != "ready" {
            NSLog("CPR invalid geometry: %@", geometry)
            return
        }

        transform = N3AffineTransformConcat(N3AffineTransformInvert(self.pixToDicomTransform()), self.pixToSubDrawRectTransform())

        if N3AffineTransformIsAffine(transform) == false { // Is this usefull?
            return
        }

        bezierPath = _curvedPath?.bezierPath
        flattenedBezierPath = bezierPath?.mutableCopy() as? N3MutableBezierPath
        //    [flattenedBezierPath subdivide:N3BezierDefaultSubdivideSegmentLength];
        //    [flattenedBezierPath flatten:N3BezierDefaultFlatness];
        flattenedNotTransformedBezierPath = bezierPath?.flattening(N3BezierDefaultFlatness)

        let length: CGFloat

        length = flattenedBezierPath?.length() ?? 0

        flattenedBezierPath?.applyAffineTransform(transform)

        transformedBezierPath = bezierPath?.mutableCopy() as? N3MutableBezierPath
        transformedBezierPath?.applyAffineTransform(transform)
        flattenedBezierPath?.flatten(N3BezierDefaultFlatness)

        // Just a single point
        if (_curvedPath?.nodes.count ?? 0) == 1 {
            cursorVector = N3VectorApplyTransform((_curvedPath?.nodes.object(at: 0) as? NSValue)?.n3VectorValue() ?? N3Vector(), transform)
            roiColor4d(1.0, 0.0, 0.0, 1.0)
            self.drawCircle(at: NSPointFromN3Vector(cursorVector))

            return
        }

        let pathRed = Float(windowControllerIvar?.curvedPathColor?.redComponent ?? 0)
        let pathGreen = Float(windowControllerIvar?.curvedPathColor?.greenComponent ?? 0)
        let pathBlue = Float(windowControllerIvar?.curvedPathColor?.blueComponent ?? 0)

        flattenedBezierPath?.addEndpointsAtIntersections(with: N3PlaneMake(N3VectorMake(0, 0, 1.0), N3VectorMake(0, 0, 1)))
        flattenedBezierPath?.addEndpointsAtIntersections(with: N3PlaneMake(N3VectorMake(0, 0, 0.5), N3VectorMake(0, 0, 1)))
        flattenedBezierPath?.addEndpointsAtIntersections(with: N3PlaneMake(N3VectorMake(0, 0, -0.5), N3VectorMake(0, 0, 1)))
        flattenedBezierPath?.addEndpointsAtIntersections(with: N3PlaneMake(N3VectorMake(0, 0, -1.0), N3VectorMake(0, 0, 1)))

        roiLineWidth(Float(2.0 * backingScaleFactor))
        roiBegin(GL_LINE_STRIP)
        for i in 0 ..< max(flattenedBezierPath?.elementCount() ?? 0, 0) { // draw the line segments
            flattenedBezierPath?.element(at: i, control1: nil, control2: nil, endpoint: &vector)

            if abs(vector.z) <= 0.5 {
                roiColor4d(Double(pathRed), Double(pathGreen), Double(pathBlue), 1.0)
            } else if abs(vector.z) >= 1.0 {
                roiColor4d(Double(pathRed), Double(pathGreen), Double(pathBlue), 0.2)
            } else {
                roiColor4d(Double(pathRed), Double(pathGreen), Double(pathBlue), Double(abs(vector.z) * -1.6 + 1.8))
            }

            roiVertex2d(Double(vector.x), Double(vector.y))
        }
        roiEnd()

        // draw the thick slab outline
        if (bezierPath?.elementCount() ?? 0) >= 2 && (_curvedPath?.thickness ?? 0) > 2.0 && length > 3.0 {
            roiLineWidth(Float(1.0 * backingScaleFactor))
            outlinePath = self.slabOutlinePath(bezierPath, distance: (_curvedPath?.thickness ?? 0) / 2.0, flattenedBezierPath: flattenedBezierPath)
            outlinePath?.applyAffineTransform(transform)
            roiColor4d(0.0, 1.0, 0.0, 1.0)
            roiBegin(GL_LINE_STRIP)
            for i in 0 ..< max(outlinePath?.elementCount() ?? 0, 0) {
                if outlinePath?.element(at: i, control1: nil, control2: nil, endpoint: &vector) == Int(N3LineToBezierPathElement.rawValue) {
                    roiVertex2d(Double(vector.x), Double(vector.y))
                } else {
                    roiEnd()
                    roiBegin(GL_LINE_STRIP)
                    roiVertex2d(Double(vector.x), Double(vector.y))
                }
            }
            roiEnd()
            outlinePath = nil
        }

        let exportSlabThickness = { (self.windowController() as? CPRController)?.exportSlabThickness ?? 0 }
        if exportSlabThickness() > 0 {
            roiLineWidth(Float(1.0 * backingScaleFactor))
            outlinePath = self.slabOutlinePath(bezierPath, distance: exportSlabThickness() / 2.0, flattenedBezierPath: flattenedBezierPath)
            outlinePath?.applyAffineTransform(transform)
            roiColor4d(0.0, 1.0, 0.0, 1.0)
            roiBegin(GL_LINE_STRIP)
            for i in 0 ..< max(outlinePath?.elementCount() ?? 0, 0) {
                if outlinePath?.element(at: i, control1: nil, control2: nil, endpoint: &vector) == Int(N3LineToBezierPathElement.rawValue) {
                    roiVertex2d(Double(vector.x), Double(vector.y))
                } else {
                    roiEnd()
                    roiBegin(GL_LINE_STRIP)
                    roiVertex2d(Double(vector.x), Double(vector.y))
                }
            }
            roiEnd()
            outlinePath = nil
        }

        //    roiColor4d(1.0, 0.0, 1.0, 1.0); // draw the normal lines
        //    roiBegin(GL_LINES);
        //    for (i = 0; i < numVectors; i++) {
        //        N3Vector start = N3VectorApplyTransform(N3VectorAdd(vectors[i], N3VectorScalarMultiply(normals[i], 10)), transform);
        //        N3Vector end = N3VectorApplyTransform(N3VectorSubtract(vectors[i], N3VectorScalarMultiply(normals[i], 10)), transform);
        //        roiVertex2d(start.x, start.y);
        //        roiVertex2d(end.x, end.y);
        //    }
        //    roiEnd();

        roiColor4d(1.0, 0.0, 0.0, 1.0) // draw the ends of the line segements
        for i in 0 ..< max(transformedBezierPath?.elementCount() ?? 0, 0) {
            transformedBezierPath?.element(at: i, control1: nil, control2: nil, endpoint: &vector)

            if abs(Double(vector.z)) <= 0.5 {
                roiColor4d(Double(pathRed), Double(pathGreen), Double(pathBlue), 1.0)
            } else {
                roiColor4d(Double(pathRed), Double(pathGreen), Double(pathBlue), 0.2)
            }

            self.drawCircle(at: NSMakePoint(vector.x, vector.y))
        }

        // draw the cursor positions

        if (_displayInfo?.mouseCursorHidden ?? false) == false {
            cursorVector = N3VectorApplyTransform(flattenedNotTransformedBezierPath?.vector(atRelativePosition: _displayInfo?.mouseCursorPosition ?? 0) ?? N3Vector(), transform)
            roiColor4d(0.0, 1.0, 0.0, 1.0)
            self.drawCircle(at: NSPointFromN3Vector(cursorVector))
        }

        // draw the cursor positions

        // NSInteger < NSUInteger: C compared them as unsigned.
        if (_displayInfo?.hoverNodeHidden ?? false) == false && UInt(bitPattern: _displayInfo?.hoverNodeIndex ?? 0) < UInt(_curvedPath?.nodes.count ?? 0) {
            cursorVector = N3VectorApplyTransform((_curvedPath?.nodes.object(at: _displayInfo?.hoverNodeIndex ?? 0) as? NSValue)?.n3VectorValue() ?? N3Vector(), transform)
            roiColor4d(1.0, 0.5, 0.0, 1.0)
            self.drawCircle(at: NSPointFromN3Vector(cursorVector))
        }

        if (windowControllerIvar?.curvedPathCreationMode ?? false) == false {
            // draw the transverse positions
            cursorVector = N3VectorApplyTransform(flattenedNotTransformedBezierPath?.vector(atRelativePosition: _curvedPath?.transverseSectionPosition ?? 0) ?? N3Vector(), transform)
            roiColor4d(1.0, 1.0, 0.0, 1.0)
            self.drawCircle(at: NSPointFromN3Vector(cursorVector))

            cursorVector = N3VectorApplyTransform(flattenedNotTransformedBezierPath?.vector(atRelativePosition: _curvedPath?.leftTransverseSectionPosition ?? 0) ?? N3Vector(), transform)
            roiColor4d(1.0, 1.0, 0.0, 1.0)
            self.drawCircle(at: NSPointFromN3Vector(cursorVector), pointSize: 4)

            cursorVector = N3VectorApplyTransform(flattenedNotTransformedBezierPath?.vector(atRelativePosition: _curvedPath?.rightTransverseSectionPosition ?? 0) ?? N3Vector(), transform)
            roiColor4d(1.0, 1.0, 0.0, 1.0)
            self.drawCircle(at: NSPointFromN3Vector(cursorVector), pointSize: 4)
        }

        //    roiColor4d(1.0, 1.0, 0.0, 1.0); // draw the endpoints
        //    for (i = 0; i < [flattenedBezierPath elementCount]; i++) {
        //        [flattenedBezierPath elementAtIndex:i control1:NULL control2:NULL endpoint:&vector];
        //        [self drawCircleAtPoint:NSMakePoint(vector.x, vector.y)];
        //    }

        //    roiColor4d(0.0, 1.0, 1.0, 1.0); // draw the control points
        //    for (i = 0; i < [transformedBezierPath elementCount]; i++) {
        //        if ([transformedBezierPath elementAtIndex:i control1:&control1 control2:&control2 endpoint:&vector] == N3CurveToBezierPathElement) {
        //            [self drawCircleAtPoint:NSMakePoint(control1.x, control1.y)];
        //            [self drawCircleAtPoint:NSMakePoint(control2.x, control2.y)];
        //        }
        //    }
        //    [self _debugDrawDebugPoints];
    }

    @objc(drawOSIROIs)
    private dynamic func drawOSIROIs() {
        var pixToSubdrawRectOpenGLTransform = [Double](repeating: 0, count: 16)

        if self.ROIManager() == nil {
            return
        }

        N3AffineTransformGetOpenGLMatrixd(self.pixToSubDrawRectTransform(), &pixToSubdrawRectOpenGLTransform)

        for case let roi as OSIROI in (self.ROIManager()?.rois() as NSArray?) ?? NSArray() {
            roiMatrixMode(GL_MODELVIEW)
            roiPushMatrix()
            roiMultMatrixd(pixToSubdrawRectOpenGLTransform)

            roi.draw(OSISlabMake(self.plane(), 0), dicomToPixTransform: N3AffineTransformInvert(self.pixToDicomTransform()))

            roiMatrixMode(GL_MODELVIEW)
            roiPopMatrix()
        }
    }

    @objc(ROIManager)
    private dynamic func ROIManager() -> OSIROIManager? {
        if _ROIManager == nil {
            let environment = OSIEnvironment.shared()

            if environment == nil {
                return nil
            }

            let volumeWindow = environment?.volumeWindow(for: windowControllerIvar?.viewer())
            _ROIManager = OSIROIManager(volumeWindow: volumeWindow, coalesceROIs: true)
        }

        return _ROIManager
    }

    @objc(drawCircleAtPoint:pointSize:)
    private dynamic func drawCircle(at point: NSPoint, pointSize: CGFloat) {
        roiEnable(GL_POINT_SMOOTH)
        roiPointSize(Float(pointSize * backingScaleFactor))

        roiBegin(GL_POINTS)
        roiVertex2f(Float(point.x), Float(point.y))
        roiEnd()
    }

    @objc(drawCircleAtPoint:)
    private dynamic func drawCircle(at point: NSPoint) {
        self.drawCircle(at: point, pointSize: 8)
    }

    /// converts points in the DCMPix's coordinate space ("Slice Coordinates") into the DICOM space (patient space with mm units)
    @objc public dynamic func pixToDicomTransform() -> N3AffineTransform {
        var pixToDicomTransform: N3AffineTransform
        let spacingX: Double
        let spacingY: Double
        //    double spacingZ;
        var orientation = [Double](repeating: 0, count: 9)

        _pix?.orientationDouble(&orientation)
        spacingX = _pix?.pixelSpacingX ?? 0
        spacingY = _pix?.pixelSpacingY ?? 0
        //    spacingZ = pix.sliceInterval;

        pixToDicomTransform = N3AffineTransformIdentity
        pixToDicomTransform.m41 = CGFloat(_pix?.originX ?? 0)
        pixToDicomTransform.m42 = CGFloat(_pix?.originY ?? 0)
        pixToDicomTransform.m43 = CGFloat(_pix?.originZ ?? 0)
        pixToDicomTransform.m11 = CGFloat(orientation[0] * spacingX)
        pixToDicomTransform.m12 = CGFloat(orientation[1] * spacingX)
        pixToDicomTransform.m13 = CGFloat(orientation[2] * spacingX)
        pixToDicomTransform.m21 = CGFloat(orientation[3] * spacingY)
        pixToDicomTransform.m22 = CGFloat(orientation[4] * spacingY)
        pixToDicomTransform.m23 = CGFloat(orientation[5] * spacingY)
        pixToDicomTransform.m31 = CGFloat(orientation[6])
        pixToDicomTransform.m32 = CGFloat(orientation[7])
        pixToDicomTransform.m33 = CGFloat(orientation[8])

        #if DEBUG
        let psx = _pix?.pixelSpacingX ?? 0, psy = _pix?.pixelSpacingY ?? 0
        if psx.isNaN || psy.isNaN || psx <= 0 || psy <= 0 || psx > 1000 || psy > 1000 {
            NSLog("******* CPR pixel spacing incorrect for pixToSubDrawRectTransform")
        }
        #endif

        return pixToDicomTransform
    }

    @objc public dynamic func plane() -> N3Plane {
        let pixToDicomTransform: N3AffineTransform
        var plane = N3Plane()

        pixToDicomTransform = self.pixToDicomTransform()

        plane.point = N3VectorApplyTransform(N3VectorMake(CGFloat(self.curDCM?.pwidth ?? 0) / 2.0, CGFloat(self.curDCM?.pheight ?? 0) / 2.0, 0.0), pixToDicomTransform)
        plane.normal = N3VectorNormalize(N3VectorApplyTransformToDirectionalVector(N3VectorMake(0.0, 0.0, 1.0), pixToDicomTransform))

        if N3PlaneIsValid(plane) {
            return plane
        } else {
            return N3PlaneInvalid
        }
    }

    @objc public dynamic func planeName() -> String! {
        switch viewID {
        case 1:
            return "orange"

        case 2:
            return "purple"

        case 3:
            return "blue"

        default:
            break
        }
        assert(false)
        return nil
    }

    @objc(colorForPlaneName:)
    public dynamic func colorForPlaneName(_ planeName: String!) -> NSColor! {
        if planeName == "orange" {
            return windowControllerIvar?.colorAxis1
        } else if planeName == "purple" {
            return windowControllerIvar?.colorAxis2
        } else if planeName == "blue" {
            return windowControllerIvar?.colorAxis3
        }
        assert(false)
        return nil
    }
}

extension DCMView {
    /// converts coordinates in the NSView's space to coordinates on a DCMPix object in "Slice Coordinates"
    /// (the former DCMView (CPRAdditions) category of CPRMPRDCMView.m)
    @objc(viewToPixTransform) public func viewToPixTransform() -> N3AffineTransform {
        // since there is no way to get matrix values directly for this transformation, we will figure out how the basis vectors get transformed, and contruct the matrix from these values
        var viewToPixTransform: N3AffineTransform
        let orginBasis: NSPoint
        let xBasis: NSPoint
        let yBasis: NSPoint

        orginBasis = self.convert(fromNSView2GL: NSMakePoint(0, 0))
        xBasis = self.convert(fromNSView2GL: NSMakePoint(1, 0))
        yBasis = self.convert(fromNSView2GL: NSMakePoint(0, 1))

        viewToPixTransform = N3AffineTransformIdentity
        viewToPixTransform.m41 = orginBasis.x
        viewToPixTransform.m42 = orginBasis.y
        viewToPixTransform.m11 = xBasis.x - orginBasis.x
        viewToPixTransform.m12 = xBasis.y - orginBasis.y
        viewToPixTransform.m21 = yBasis.x - orginBasis.x
        viewToPixTransform.m22 = yBasis.y - orginBasis.y

        return viewToPixTransform
    }
}
