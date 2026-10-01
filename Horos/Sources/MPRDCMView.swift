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
import simd

enum MPRTrackpadGesture {
    static func parallelScale(_ scale: Float, magnification: CGFloat) -> Float? {
        let factor = 1 + Float(magnification)
        let result = scale / factor
        guard scale.isFinite, scale > 0, factor.isFinite, factor > 0,
              result.isFinite, result > 0 else { return nil }
        return result
    }

    static func viewUp(_ up: SIMD3<Float>, position: SIMD3<Float>,
                       focalPoint: SIMD3<Float>, rotation: CGFloat) -> SIMD3<Float>? {
        let direction = focalPoint - position
        let length = simd_length(direction)
        let angle = Float(rotation) * .pi / 180
        guard length.isFinite, length > 0, angle.isFinite,
              up.x.isFinite, up.y.isFinite, up.z.isFinite,
              simd_length(up) > 0 else { return nil }
        let result = simd_quatf(angle: angle, axis: direction / length).act(up)
        guard result.x.isFinite, result.y.isFinite, result.z.isFinite else { return nil }
        return result
    }
}

// The file-level statics of the former MPRDCMView.m.
private let deg2rad: Float = Float(Double.pi / 180.0)
private let VIEW_COLOR_LABEL_SIZE: Float = 25
private let BS: Double = 10.0
private let PRECISION: Double = 0.0001
/// The divider positions before a double click zoomed one view, shared by the three views.
@MainActor private var splitPosition: [Int32] = [0, 0]
/// Whether a double click zoomed one view to the whole window.
@MainActor private var frameZoomed = false

// The OpenGL enumerants ROICanvasGL.h names, which Swift cannot import: that
// header imports Horos-Swift.h.
private let GL_POINTS: UInt32 = 0x0000
private let GL_LINE_LOOP: UInt32 = 0x0002
private let GL_POLYGON: UInt32 = 0x0009
private let GL_POINT_SMOOTH: UInt32 = 0x0B10
private let GL_LINE_SMOOTH: UInt32 = 0x0B20
private let GL_POLYGON_SMOOTH: UInt32 = 0x0B41
private let GL_BLEND: UInt32 = 0x0BE2
private let GL_SRC_ALPHA: UInt32 = 0x0302
private let GL_ONE_MINUS_SRC_ALPHA: UInt32 = 0x0303
private let GL_MODELVIEW: UInt32 = 0x1700

// The static inline functions of ROICanvasGL.h, with the same parameter types:
// a CGFloat argument goes through a float, as it did.
private func roiBlendFunc(_ source: UInt32, _ destination: UInt32) { ROICanvas.current?.blend(source: source, destination: destination) }
private func roiEnable(_ cap: UInt32) { ROICanvas.current?.enable(cap) }
private func roiDisable(_ cap: UInt32) { ROICanvas.current?.disable(cap) }
private func roiPointSize(_ s: Float) { ROICanvas.current?.pointSize(CGFloat(s)) }
private func roiLineWidth(_ w: Float) { ROICanvas.current?.lineWidth(CGFloat(w)) }
private func roiColor4f(_ r: Float, _ g: Float, _ b: Float, _ a: Float) {
    ROICanvas.current?.color(r: CGFloat(r), g: CGFloat(g), b: CGFloat(b), a: CGFloat(a))
}
private func roiBegin(_ mode: UInt32) { ROICanvas.current?.begin(mode) }
private func roiEnd() { ROICanvas.current?.end() }
private func roiVertex2f(_ x: Float, _ y: Float) { ROICanvas.current?.vertex(x: CGFloat(x), y: CGFloat(y)) }
private func roiRotatef(_ angle: Float, _ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.rotate(Double(z < 0 ? -angle : angle)) }
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

/// One of the three planes of the 3D MPR: a DCMView that shows the MPR's hidden
/// VRView reslice of its plane, draws the other two planes as lines and turns
/// the mouse into camera moves.
///
/// Implemented in Swift since #823: the Objective-C name, the selectors and
/// <Horos/MPRDCMView.h> are those of the former class, the customClass of the
/// three views of MPR.xib. Its superclass, DCMView, stays in Objective-C; the
/// ivars it reads of it go through DCMView+SwiftIvars.h. The messages to the
/// VRView, whose header is C++, go through HorosMPRVRViewMessages, which VRView
/// adopts in VRHostBridge.h.
@objc(MPRDCMView)
public final class MPRDCMView: DCMView {
    // MARK: - The former instance variables

    private var viewID: Int32 = 0
    private var mouseDownTool: ToolMode = .tWL
    /// vrView: assigned, not retained; the MPR's hidden VRView, which its
    /// VRController owns.
    private unowned(unsafe) var _vrView: (NSView & HorosMPRVRViewMessages)? = nil
    /// pix: assigned, not retained; the last pix of the view's list.
    private unowned(unsafe) var _pix: DCMPix? = nil
    /// camera, retained.
    private var _camera: Camera? = nil
    /// windowController: assigned, the MPRController of the view's window.
    private unowned(unsafe) var windowControllerIvar: MPRController? = nil
    private var _angleMPR: Float = 0
    private var _dontUseAutoLOD = false
    /// _ROIManager: made once, retained, and released with the view.
    private var _ROIManager: OSIROIManager? = nil

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

    /// The bridge's own messages to this view (MPRHostBridge.m): MPRHostBridge.h
    /// declares them in a category of this class, which Swift cannot read.
    private var host: HorosMPRHostViewMessages {
        return (self as AnyObject) as! HorosMPRHostViewMessages
    }

    /// [self window].backingScaleFactor, 0 without a window.
    private var backingScaleFactor: CGFloat {
        return self.window?.backingScaleFactor ?? 0
    }

    // MARK: - Properties

    /// The windowController ivar, for MPRHostBridge.m.
    @objc(horosMPRWindowController)
    var horosMPRWindowController: MPRController? {
        return windowControllerIvar
    }

    @objc public dynamic var pix: DCMPix! {
        return _pix
    }

    @objc public dynamic var camera: Camera! {
        get { return _camera }
        set { _camera = newValue }
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
    /// messages the MPR sends it.
    @objc public dynamic var vrView: (NSView & HorosMPRVRViewMessages)! {
        return _vrView
    }

    @objc public dynamic var rotateLines: Bool {
        return _rotateLines
    }

    @objc public dynamic var moveCenter: Bool {
        return _moveCenter
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
            let renderingMode = _vrView?.renderingMode ?? 0
            if renderingMode == 1 || renderingMode == 3 || renderingMode == 2 { return true } // MIP
            else { return false } // VR

        case .tNext, .tMesure, .tROI, .tOval, .tOPolygon, .tCPolygon, .tAngle, .tArrow, .tText, .tPencil, .tPlain,
             .t2DPoint, .tRepulsor, .tLayerROI, .tROISelector:
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

        windowControllerIvar = self.windowController() as? MPRController

        windowControllerIvar?.updateToolbarItems()
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

    public override dynamic var frame: NSRect {
        get { return super.frame }
        set {
            let frameRect = newValue


            if NSEqualRects(frameRect, self.frame) == false {
                if let windowController = windowControllerIvar {
                    NSObject.cancelPreviousPerformRequests(withTarget: windowController,
                                                           selector: #selector(MPRController.updateViewsAccordingToFrame(_:)),
                                                           object: nil)
                    windowController.perform(#selector(MPRController.updateViewsAccordingToFrame(_:)), with: nil, afterDelay: 0.1)
                }
            }

            if let blendingView = self.blending {
                blendingView.frame = frameRect
                blendingView.drawingFrameRect = self.convertToBacking(frameRect) // very important to have correct position values with PET-CT
            }

            super.frame = frameRect

        }
    }

    @objc(checkForFrame)
    private dynamic func checkForFrame() {
        // NSView frames are in points; vtkCocoaRenderWindow converts to pixels.
        let frameRect = self.convert(self.bounds, to: nil)

        if NSEqualRects(frameRect, _vrView?.frame ?? NSZeroRect) == false {
            _vrView?.frame = frameRect
        }
    }

    /// DCMView's -displayedScaleValue, which only DCMView.m declares: a method
    /// with its selector overrides it.
    @objc(displayedScaleValue)
    override dynamic func displayedScaleValue() -> Float {
        let o = windowControllerIvar?.originalPix

        return Float((o?.pixelSpacingX ?? 0) / Double(previousResolution))
    }

    /// DCMView's -displayedRotation, likewise.
    @objc(displayedRotation)
    override dynamic func displayedRotation() -> Float {
        return _camera?.rollAngle ?? 0
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

    @objc(actualSize:)
    public override dynamic func actualSize(_ sender: Any!) {
        self.setOriginX(0, y: 0)
        self.rotation = 0.0

        let o = windowControllerIvar?.originalPix

        _camera?.forceUpdate = true
        if let camera = _camera {
            camera.parallelScale = Float(Double(camera.parallelScale) * ((o?.pixelSpacingX ?? 0) / Double(previousResolution)))
        }

        self.restoreCamera()
        self.updateViewMPR()
    }

    @objc(realSize:)
    public override dynamic func realSize(_ sender: Any!) {
        let screenNumber = ((self.window?.screen?.deviceDescription as NSDictionary?)?.value(forKey: "NSScreenNumber") as AnyObject?)?.intValue ?? 0
        let display = CGDirectDisplayID(UInt32(bitPattern: Int32(truncatingIfNeeded: screenNumber)))
        let f = CGDisplayScreenSize(display)
        let r = CGDisplayBounds(display)

        if f.width != 0 && f.height != 0 {
            NSLog("screen pixel ratio: %f", abs((f.width / r.size.width) - (f.height / r.size.height)))
            if abs((f.width / r.size.width) - (f.height / r.size.height)) < 0.01 {
                _camera?.forceUpdate = true
                if let camera = _camera {
                    camera.parallelScale = Float(Double(camera.parallelScale) * (Double(f.width / r.size.width) / Double(previousResolution)))
                }

                self.restoreCamera()
                self.updateViewMPR()
            } else {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Actual Size Error", comment: ""),
                                            message: NSLocalizedString("Displayed pixels are non-squared pixel. Images cannot be displayed at actual size.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }
        } else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Actual Size Error", comment: ""),
                                        message: NSLocalizedString("This screen doesn't support this function.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    /// DCMView's -validateMenuItem:, which no header declares: a method with its
    /// selector overrides it.
    @objc(validateMenuItem:)
    private dynamic func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == NSSelectorFromString("scaleToFit:") {
            return false
        }

        return true
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

                if _LOD < (windowControllerIvar?.LOD ?? 0) {
                    _LOD = windowControllerIvar?.LOD ?? 0
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

            var imagePtr: UnsafeMutablePointer<Float>? = _moveCenter ? nil : host.horosMPRCopyImageWidth(&w, height: &h)
            if imagePtr != nil { isRGB = ObjCBool(host.horosMPRCopiedImageIsRGB()); lastRenderingWasMoveCenter = false }

            if imagePtr == nil && self.frame.size.width > 0 && self.frame.size.height > 0 {
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

            if _moveCenter {
                imagePtr = _pix?.fImage
                w = _pix?.pwidth ?? 0
                h = _pix?.pheight ?? 0
                isRGB = ObjCBool(_pix?.isRGB ?? false)

                _vrView?.setLOD(_LOD)
            } else if imagePtr == nil {
                imagePtr = _vrView?.image(inFullDepthWidth: &w, height: &h, isRGB: &isRGB)
            }
            host.horosMPRVolumeRendered()

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
                        var i = (self.curRoiList?.count ?? 0) - 1
                        while i >= 0 {
                            let r = self.curRoiList.object(at: i) as? ROI
                            if r?.type != .t2DPoint {
                                self.curRoiList.removeObject(at: i)
                            }
                            i -= 1
                        }
                    }
                }

                // A new plane replaces the cubic display plane, or drops it (#702);
                // moving the centre keeps the image, and so its display plane.
                if _moveCenter == false {
                    host.horosMPRAttachDisplayPlane(to: _pix)
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
                    if resolution > 0 {
                        _pix?.pixelSpacingX = Double(resolution)
                        _pix?.pixelSpacingY = Double(resolution)
                    }
                }

                _pix?.setOrientation(&orientation)
                _pix?.sliceThickness = _vrView?.getClippingRangeThicknessInMm() ?? 0

                self.setWLWW(previousWL, previousWW)

                if !_moveCenter {
                    self.scaleValue = _vrView?.imageSampleDistance() ?? 0

                    var rotationPlane: Float = 0
                    if cameraMoved == false && (self.curRoiList?.count ?? 0) > 0 {
                        if previousOrientation[0] != 0 || previousOrientation[1] != 0 || previousOrientation[2] != 0 {
                            rotationPlane = Float(-MPRController.angleBetweenVector(&orientation, andPlane: &previousOrientation))
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

                    if ROITemporalStatistics.mustRefreshCachedValuesAfterReconstructedBufferChange() {
                        for case let r as ROI in self.curRoiList ?? NSMutableArray() {
                            r.recompute()
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

                // Metal resliced the fused series with the plane (#658); otherwise VTK does.
                var blendedImagePtr: UnsafeMutablePointer<Float>? = _moveCenter ? nil : host.horosMPRTakeFusedImageWidth(&w, height: &h)
                if blendedImagePtr != nil {
                    isRGB = false
                } else {
                    _vrView?.renderBlendedVolume()
                }

                let bPix = blendingView.curDCM

                if _moveCenter {
                    blendedImagePtr = bPix?.fImage
                    w = bPix?.pwidth ?? 0
                    h = bPix?.pheight ?? 0
                    isRGB = ObjCBool(bPix?.isRGB ?? false)
                } else if blendedImagePtr == nil {
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

    private func drawExportLines(_ sft: CrossLines) {
        withCrossLines(sft) { sft in
            let dcmInterval = { self.windowControllerIvar?.dcmInterval ?? 0 }

            roiLineWidth(Float(1.0 * backingScaleFactor))

            if _fromIntervalExport > 0 {
                var i: Int32 = 1
                while Float(i) <= _fromIntervalExport {
                    self.drawCrossLines(sft, withShift: Double(Float(-i) * dcmInterval()))
                    i += 1
                }
            }

            if !(windowControllerIvar?.dcmBatchReverse ?? false) {
                self.drawCrossLines(sft, withShift: Double(-_fromIntervalExport * dcmInterval()), showPoint: true)
            }

            if _toIntervalExport > 0 {
                var i: Int32 = 1
                while Float(i) <= _toIntervalExport {
                    self.drawCrossLines(sft, withShift: Double(Float(i) * dcmInterval()))
                    i += 1
                }
            }

            if windowControllerIvar?.dcmBatchReverse ?? false {
                self.drawCrossLines(sft, withShift: Double(_toIntervalExport * dcmInterval()), showPoint: true)
            }
        }
    }

    private func drawRotationLines(_ sft: CrossLines) {
        withCrossLines(sft) { sft in
            var i: Int32 = 1
            while i < (windowControllerIvar?.dcmNumberOfFrames ?? 0) {
                let dcmRotation = windowControllerIvar?.dcmRotation ?? 0
                let dcmNumberOfFrames = windowControllerIvar?.dcmNumberOfFrames ?? 0
                roiRotatef(Float(i &* dcmRotation) / Float(dcmNumberOfFrames), 0, 0, 1)
                self.drawCrossLines(sft, perpendicular: false, withShift: 0, half: true)
                roiRotatef(-Float(i &* (windowControllerIvar?.dcmRotation ?? 0)) / Float(windowControllerIvar?.dcmNumberOfFrames ?? 0), 0, 0, 1)
                i += 1
            }
        }
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
        if self.stringID == "export" && UserDefaults.standard.bool(forKey: "exportDCMIncludeAllViews") == false {
            return
        }

        self.horos_rotation = 0

        roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
        roiEnable(GL_BLEND)
        roiEnable(GL_POINT_SMOOTH)
        roiEnable(GL_LINE_SMOOTH)
        roiPointSize(Float(12 * backingScaleFactor))

        if _displayCrossLines && frameZoomed == false {
            // All pix have the same thickness
            let thickness = Float(_pix?.sliceThickness ?? 0)

            // The two lines of this view: line A in the colour of axis `a`,
            // line B in that of axis `b`, each with its export or rotation lines.
            func drawCrossLines(axisA a: Int, axisB b: Int) {
                let dcmMode = { self.windowControllerIvar?.dcmMode ?? 0 }
                let dcmSeriesMode = { self.windowControllerIvar?.dcmSeriesMode ?? 0 }

                self.roiColor(axis: a)
                if crossLinesA.0.0 != Float.infinity {
                    self.drawLine(crossLinesA, thickness: thickness)

                    if _viewExport == 0 && dcmMode() == 0 && dcmSeriesMode() == 0 {
                        self.drawExportLines(crossLinesA)
                    }

                    if _viewExport == 0 && dcmMode() == 0 && dcmSeriesMode() == 1 { // Rotation
                        self.drawRotationLines(crossLinesA)
                    }
                }

                self.roiColor(axis: b)
                if crossLinesB.0.0 != Float.infinity {
                    self.drawLine(crossLinesB, thickness: thickness)

                    if _viewExport == 1 && dcmMode() == 0 && dcmSeriesMode() == 0 {
                        self.drawExportLines(crossLinesB)
                    }

                    if _viewExport == 1 && dcmMode() == 0 && dcmSeriesMode() == 1 { // Rotation
                        self.drawRotationLines(crossLinesB)
                    }
                }
            }

            switch viewID {
            case 1:
                drawCrossLines(axisA: 2, axisB: 3)

            case 2:
                drawCrossLines(axisA: 1, axisB: 3)

            case 3:
                drawCrossLines(axisA: 1, axisB: 2)

            default:
                break
            }
        }

        if self.stringID == "export" {
            return
        }

        let heighthalf = Float(self.convertToBacking(self.frame.size).height / 2)
        let widthhalf = Float(self.convertToBacking(self.frame.size).width / 2)

        self.colorForView(viewID)

        // Red Square
        if self.window?.firstResponder === self && frameZoomed == false {
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
        if _displayCrossLines && frameZoomed == false && (controller?.displayMousePosition ?? false)
            && !(controller?.mprView1?.rotateLines ?? false) && !(controller?.mprView2?.rotateLines ?? false) && !(controller?.mprView3?.rotateLines ?? false)
            && !(controller?.mprView1?.moveCenter ?? false) && !(controller?.mprView2?.moveCenter ?? false) && !(controller?.mprView3?.moveCenter ?? false)
            && _vrView != nil && _pix != nil {
            var pixA: DCMPix? = nil, pixB: DCMPix? = nil
            var viewIDA: Int32 = 0, viewIDB: Int32 = 0
            switch viewID {
            case 1:
                pixA = controller?.mprView2?.pix
                pixB = controller?.mprView3?.pix
                viewIDA = 2
                viewIDB = 3
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
            default:
                break
            }
            if MPROpenGeometry.canConvertSliceCoords(destinationPix: true,
                                                     companionA: pixA != nil,
                                                     companionB: pixB != nil,
                                                     spacingX: _pix?.pixelSpacingX ?? 0,
                                                     spacingY: _pix?.pixelSpacingY ?? 0,
                                                     vrAttached: true,
                                                     displayMousePosition: true) {
                // Mouse Position
                if viewID == (controller?.mouseViewID ?? 0) {
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
                    //[self colorForView: windowController.mouseViewID];
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
        }

        self.drawOSIROIs()

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

    /// The arrow key as the image sees it: a horizontally mirrored image swaps
    /// left and right, a vertically mirrored one up and down. Each key is
    /// swapped once; any other character is returned as it is.
    static func arrowKeyInImage(_ c: Int, xFlipped: Bool, yFlipped: Bool) -> Int {
        switch c {
        case NSLeftArrowFunctionKey where xFlipped: return NSRightArrowFunctionKey
        case NSRightArrowFunctionKey where xFlipped: return NSLeftArrowFunctionKey
        case NSUpArrowFunctionKey where yFlipped: return NSDownArrowFunctionKey
        case NSDownArrowFunctionKey where yFlipped: return NSUpArrowFunctionKey
        default: return c
        }
    }

    public override dynamic func keyDown(with theEvent: NSEvent) {
        if ((theEvent.characters as NSString?)?.length ?? 0) == 0 { return }

        var c = Int((theEvent.characters! as NSString).character(at: 0))

        if c == 32 || c == 27 { // 27 : escape
            windowControllerIvar?.keyDown(with: theEvent)
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

            c = MPRDCMView.arrowKeyInImage(c, xFlipped: self.xFlipped, yFlipped: self.yFlipped)

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

            _vrView?.setWindowCenter(center)
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

    // MARK: - 3D ROI Point

    @objc public dynamic func detect2DPointInThisSlice() {
        let viewer2D = windowControllerIvar?.viewer()

        if let viewer2D = viewer2D {
            // First delete all 2D Points in our pix

            let ROIsStateSaved = NSMutableDictionary()
            // The points taken out live until this method returns. A point
            // released posts OsirixRemoveROINotification from its -dealloc,
            // after it gives back its parent; a parent the viewer no longer
            // holds goes with it and posts the notification too, whose
            // -removeROI: runs this method again. That must not happen while
            // this one goes through curRoiList.
            var removedPoints: [ROI] = []
            defer { withExtendedLifetime(removedPoints) {} }

            var i = (self.curRoiList?.count ?? 0) - 1
            while i >= 0 {
                if let r = self.curRoiList.object(at: i) as? ROI, r.type == .t2DPoint {
                    if let parent = r.parent {
                        ROIsStateSaved.setObject(NSNumber(value: Int32(truncatingIfNeeded: r.roImode)), forKey: NSValue(pointer: Unmanaged.passUnretained(parent).toOpaque()))
                    }
                    removedPoints.append(r)
                    self.curRoiList.removeObject(at: i)
                }
                i -= 1
            }

            let roiList = viewer2D.roiList(Int(windowControllerIvar?.curMovieIndex ?? 0)) as NSArray?
            let pixList = viewer2D.pixList(Int(windowControllerIvar?.curMovieIndex ?? 0)) as NSArray?

            for i in 0 ..< (roiList?.count ?? 0) {
                let pts = roiList?.object(at: i) as? NSArray
                let p = pixList?.object(at: i) as? DCMPix

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

                            // Released once curRoiList drops it (see removedPoints).
                            let new2DPointROI: ROI = ROI(type: .t2DPoint, Float(_pix?.pixelSpacingX ?? 0), Float(_pix?.pixelSpacingY ?? 0),
                                                         DCMPix.originCorrected(accordingToOrientation: _pix))

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

        if _displayCrossLines == false || frameZoomed {
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

    /// -[MPRController delayedFullLODRendering:], sent after a delay.
    private static let delayedFullLODRendering = NSSelectorFromString("delayedFullLODRendering:")

    /// [NSObject cancelPreviousPerformRequestsWithTarget: windowController selector:@selector(delayedFullLODRendering:) object: object]
    /// and [windowController performSelector: @selector(delayedFullLODRendering:) withObject: object afterDelay: delay].
    private func scheduleDelayedFullLODRendering(_ object: Any?, afterDelay delay: TimeInterval) {
        guard let windowController = windowControllerIvar else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: windowController, selector: MPRDCMView.delayedFullLODRendering, object: object)
        windowController.perform(MPRDCMView.delayedFullLODRendering, with: object, afterDelay: delay)
    }

    public override dynamic func scrollWheel(with theEvent: NSEvent) {
        windowControllerIvar?.add(toUndoQueue: "mprCamera")

        if self.window?.firstResponder !== self {
            self.window?.makeFirstResponder(self)
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
            NSObject.cancelPreviousPerformRequests(withTarget: windowController, selector: MPRDCMView.delayedFullLODRendering, object: nil)
        }

        windowControllerIvar?.lowLOD = false

        windowControllerIvar?.mprView1?.LOD = Float(Double(windowControllerIvar?.mprView1?.LOD ?? 0) * 0.9)
        windowControllerIvar?.mprView2?.LOD = Float(Double(windowControllerIvar?.mprView2?.LOD ?? 0) * 0.9)
        windowControllerIvar?.mprView3?.LOD = Float(Double(windowControllerIvar?.mprView3?.LOD ?? 0) * 0.9)

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

    public override dynamic func mouseDown(with theEvent: NSEvent) {
        if self.window?.firstResponder !== self {
            self.window?.makeFirstResponder(self)
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
            mouseDownTool = self.getTool(theEvent)

            var tempPt = self.convert(theEvent.locationInWindow, from: nil)
            tempPt = self.convert(fromNSView2GL: tempPt)

            if self.roiTool(mouseDownTool) && self.click(inROI: tempPt) != nil {
                (self.windowController() as? MPRController)?.roiGetInfo(self)
            } else {
                let controller = windowControllerIvar
                if frameZoomed == false {
                    if controller?.horizontalSplit?.isVertical ?? false {
                        splitPosition[0] = cInt32(Double(controller?.mprView2?.frame.origin.x ?? 0))
                    } else {
                        splitPosition[0] = cInt32(Double(controller?.mprView2?.frame.origin.y ?? 0))
                    }

                    if controller?.verticalSplit?.isVertical ?? false {
                        splitPosition[1] = cInt32(Double(controller?.mprView3?.frame.origin.x ?? 0))
                    } else {
                        splitPosition[1] = cInt32(Double(controller?.mprView3?.frame.origin.y ?? 0))
                    }

                    frameZoomed = true
                    switch viewID {
                    case 1:
                        controller?.horizontalSplit?.setPosition(controller?.horizontalSplit?.maxPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)
                        controller?.verticalSplit?.setPosition(controller?.verticalSplit?.maxPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)

                    case 2:
                        controller?.horizontalSplit?.setPosition(controller?.horizontalSplit?.minPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)
                        controller?.verticalSplit?.setPosition(controller?.verticalSplit?.maxPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)

                    case 3:
                        controller?.horizontalSplit?.setPosition(controller?.horizontalSplit?.minPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)
                        controller?.verticalSplit?.setPosition(controller?.verticalSplit?.minPossiblePositionOfDivider(at: 0) ?? 0, ofDividerAt: 0)

                    default:
                        break
                    }
                } else {
                    frameZoomed = false
                    controller?.verticalSplit?.setPosition(CGFloat(splitPosition[1]), ofDividerAt: 0)
                    controller?.horizontalSplit?.setPosition(CGFloat(splitPosition[0]), ofDividerAt: 0)
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
                mouseDownTool = self.getTool(theEvent)

                if self.roiTool(self.horos_currentTool) {
                    let tempPt = self.convert(fromNSView2GL: self.convert(theEvent.locationInWindow, from: nil))
                    if self.click(inROI: tempPt) != nil {
                        mouseDownTool = self.horos_currentTool
                    }
                }

                _vrView?.keep3DRotateCentered = true
                if mouseDownTool == .tCamera3D {
                    if _displayCrossLines == false || frameZoomed == true {
                        _vrView?.keep3DRotateCentered = false
                    } else {
                        if theEvent.modifierFlags.contains(.option) {
                            _vrView?.keep3DRotateCentered = false
                        }
                    }
                }

                self.restoreCamera()

                if self.is2DTool(mouseDownTool) {
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
        self.checkCursor()

        if let windowController = windowControllerIvar {
            NSObject.cancelPreviousPerformRequests(withTarget: windowController, selector: MPRDCMView.delayedFullLODRendering, object: nil)
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

            windowControllerIvar?.mprView1?.LOD = Float(Double(windowControllerIvar?.mprView1?.LOD ?? 0) * 0.9)
            windowControllerIvar?.mprView2?.LOD = Float(Double(windowControllerIvar?.mprView2?.LOD ?? 0) * 0.9)
            windowControllerIvar?.mprView3?.LOD = Float(Double(windowControllerIvar?.mprView3?.LOD ?? 0) * 0.9)

            self.restoreCamera()
            self.updateViewMPR()

            self.cursor?.set()
        } else {
            if self.is2DTool(mouseDownTool) {
                super.mouseUp(with: theEvent)
                windowControllerIvar?.propagateWLWW(self)

                if mouseDownTool == .tNext {
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

                windowControllerIvar?.mprView1?.LOD = Float(Double(windowControllerIvar?.mprView1?.LOD ?? 0) * 0.9)
                windowControllerIvar?.mprView2?.LOD = Float(Double(windowControllerIvar?.mprView2?.LOD ?? 0) * 0.9)
                windowControllerIvar?.mprView3?.LOD = Float(Double(windowControllerIvar?.mprView3?.LOD ?? 0) * 0.9)

                if _vrView?._tool() == .tRotate {
                    self.updateViewMPR(false)
                } else {
                    self.updateViewMPR()
                }
            }
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
        guard _camera != nil, _pix != nil, _vrView != nil else { return }
        defer {
            if anEvent.phase.contains(.ended) || anEvent.phase.contains(.cancelled) {
                if let controller = windowControllerIvar {
                    NSObject.cancelPreviousPerformRequests(withTarget: controller,
                        selector: MPRDCMView.delayedFullLODRendering, object: nil)
                    controller.lowLOD = false
                }
                _camera?.forceUpdate = true
                self.restoreCamera()
                self.updateViewMPR(false)
            }
        }
        guard anEvent.magnification != 0, let camera = _camera,
              let scale = MPRTrackpadGesture.parallelScale(camera.parallelScale,
                                                         magnification: anEvent.magnification) else { return }
        self.restoreCamera()
        camera.parallelScale = scale
        camera.forceUpdate = true
        self.restoreCamera()
        windowControllerIvar?.lowLOD = true
        self.updateViewMPR(false)
        self.scheduleDelayedFullLODRendering(nil, afterDelay: 0.4)
    }

    public override dynamic func rotate(with anEvent: NSEvent) {
        guard _camera != nil, _pix != nil, _vrView != nil else { return }
        defer {
            if anEvent.phase.contains(.ended) || anEvent.phase.contains(.cancelled) {
                if let controller = windowControllerIvar {
                    NSObject.cancelPreviousPerformRequests(withTarget: controller,
                        selector: MPRDCMView.delayedFullLODRendering, object: nil)
                    controller.lowLOD = false
                }
                _camera?.forceUpdate = true
                self.restoreCamera()
                self.updateViewMPR(false)
            }
        }
        guard anEvent.rotation != 0, let camera = _camera,
              let up = camera.viewUp, let position = camera.position,
              let focalPoint = camera.focalPoint,
              let rotated = MPRTrackpadGesture.viewUp(SIMD3(up.x, up.y, up.z),
                  position: SIMD3(position.x, position.y, position.z),
                  focalPoint: SIMD3(focalPoint.x, focalPoint.y, focalPoint.z),
                  rotation: CGFloat(anEvent.rotation)) else { return }
        self.restoreCamera()
        var before = [Float](repeating: 0, count: 9), after = before
        _pix?.orientation(&before)
        camera.viewUp = Point3D.point(withX: rotated.x, y: rotated.y, z: rotated.z)
        camera.forceUpdate = true
        self.restoreCamera()
        _ = _vrView?.getCosMatrix(&after)
        _angleMPR -= Float(MPRController.angleBetweenVector(&after, andPlane: &before))
        windowControllerIvar?.lowLOD = true
        self.updateViewMPR(false)
        self.scheduleDelayedFullLODRendering(nil, afterDelay: 0.4)
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

            point = self.convertToBacking(point)

            if self.yFlipped {
                point.y = self.convertToBacking(self.frame.size).height - point.y
            }

            if self.xFlipped {
                point.x = self.convertToBacking(self.frame.size).width - point.x
            }

            _vrView?.setWindowCenter(point)

            self.updateViewMPR()

            self.scheduleDelayedFullLODRendering(nil, afterDelay: 0.4)
        } else {
            if self.is2DTool(mouseDownTool) {
                super.mouseDragged(with: theEvent)
                windowControllerIvar?.propagateWLWW(self)
            } else {
                var before = [Float](repeating: 0, count: 9), after = [Float](repeating: 0, count: 9)

                windowControllerIvar?.lowLOD = true

                if _vrView?._tool() == .tRotate {
                    self.pix?.orientation(&before)
                }

                _vrView?.mouseDragged(with: theEvent)

                if _vrView?._tool() == .tRotate {
                    _ = _vrView?.getCosMatrix(&after)
                    _angleMPR = Float(Double(_angleMPR) - MPRController.angleBetweenVector(&after, andPlane: &before))

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

    /// The event is optional: MPRController sends the application's current
    /// event, which can be nil, as the former Objective-C did.
    public override dynamic func mouseMoved(with theEvent: NSEvent?) {
        if !(self.window?.isVisible ?? false) {
            return
        }

        if windowControllerIvar?.windowWillClose() ?? false {
            return
        }

        let view = theEvent?.window?.contentView?.hitTest(theEvent?.locationInWindow ?? NSZeroPoint)

        if view === self {
            if NSPointInRect(self.convert(theEvent?.locationInWindow ?? NSZeroPoint, from: nil), self.bounds) == false {
                return
            }

            // A nil event has no window, so no view is hit: here it is not nil.
            super.mouseMoved(with: theEvent!)

            let mouseOnLines = self.mouseOnLines(self.convert(theEvent?.locationInWindow ?? NSZeroPoint, from: nil))
            if mouseOnLines == 2 {
                if theEvent?.type == .leftMouseDragged { NSCursor.closedHand.set() }
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

    // MARK: - Private Methods

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

    @objc(plane)
    private dynamic func plane() -> N3Plane {
        var plane = N3Plane()

        let pixToDicomTransform = self.pixToDicomTransform()

        plane.point = N3VectorApplyTransform(N3VectorMake(CGFloat(self.curDCM?.pwidth ?? 0) / 2.0, CGFloat(self.curDCM?.pheight ?? 0) / 2.0, 0.0), pixToDicomTransform)
        plane.normal = N3VectorNormalize(N3VectorApplyTransformToDirectionalVector(N3VectorMake(0.0, 0.0, 1.0), pixToDicomTransform))

        if N3PlaneIsValid(plane) {
            return plane
        } else {
            return N3PlaneInvalid
        }
    }
}
