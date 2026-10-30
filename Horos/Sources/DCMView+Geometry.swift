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

// The geometry, transforms and presentation state of DCMView are implemented
// in Swift: an extension of DCMView, with the same
// selectors. Scale,
// pan, rotation and flips, the orientation as shown, the fit to the view, the
// slice intersections, the window sizes, fusion's alpha and colour tables,
// SUV, the study colours and the presentation saved with the series. The
// setters of the class's properties (scaleValue, rotation, origin, the
// flips, blendingMode) and -reshape, in DCMView.swift, call the horos* methods
// here. The arithmetic is in IsiXImaging (ViewGeometry).

/// Runs `body` as an @try block: the NSException it raises is returned.
private func geometryTry(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    return nil
}

/// The viewers by the date of their study, newest first; the order of two
/// without a date is left to the sort (studyCompare of the Objective-C).
@MainActor
func dcmViewersByStudyDate(_ displayed: NSArray) -> [ViewerController] {
    return displayed.sortedArray({ a, b, _ in
        let d1 = ((a as? ViewerController)?.currentStudy() as NSObject?)?.value(forKey: "date") as? NSDate
        let d2 = ((b as? ViewerController)?.currentStudy() as NSObject?)?.value(forKey: "date") as? NSDate
        guard let d1, let d2 else {
            NSLog("d1 == nil || d2 == nil : studyCompare")
            return ComparisonResult.orderedSame.rawValue
        }
        return d2.compare(d1 as Date).rawValue
    }, context: nil).compactMap { $0 as? ViewerController }
}

extension DCMView {

    // MARK: - The C functions

    // What the C functions of DCMView+CAPI.m (intersect3D_SegmentPlane,
    // intersect3D_2Planes, ArbitraryRotate, lineIntersectsRect), which the
    // MPR, CPR and DCMPix code calls, hand to Swift. Pure arithmetic, from
    // any thread.

    @objc(horosSegmentPlane:::::)
    public nonisolated class func horosSegmentPlane(_ p0: UnsafeMutablePointer<Float>!, _ p1: UnsafeMutablePointer<Float>!,
                                                    _ normal: UnsafeMutablePointer<Float>!, _ point: UnsafeMutablePointer<Float>!,
                                                    _ result: UnsafeMutablePointer<Float>!) -> Int32 {
        return PlaneGeometry.segmentPlane(p0, p1, normal: normal, point: point, result: result)
    }

    /// The line where two planes meet: noErr with its direction in `u` and
    /// a point in `iP`, or -1 (the direction written) when the planes are
    /// closer to parallel than the PARALLELPLANETOLERANCE preference.
    @objc(horosTwoPlanes::::::)
    public nonisolated class func horosTwoPlanes(_ pn1: UnsafeMutablePointer<Float>!, _ pv1: UnsafeMutablePointer<Float>!,
                                                 _ pn2: UnsafeMutablePointer<Float>!, _ pv2: UnsafeMutablePointer<Float>!,
                                                 _ u: UnsafeMutablePointer<Float>!, _ iP: UnsafeMutablePointer<Float>!) -> Int16 {
        PlaneGeometry.twoPlanesDirection(n1: pn1, n2: pn2, u: u)
        if PlaneGeometry.angle(pn1, pn2) < UserDefaults.standard.float(forKey: "PARALLELPLANETOLERANCE") {
            return -1
        }
        PlaneGeometry.twoPlanesLine(n1: pn1, p1: pv1, n2: pn2, p2: pv2, u: u, point: iP)
        return Int16(noErr)
    }

    @objc(horosArbitraryRotate:theta:axis:)
    public nonisolated class func horosArbitraryRotate(_ p: XYZ, theta: Double, axis r: XYZ) -> XYZ {
        let q = PlaneGeometry.arbitraryRotate(SIMD3(p.x, p.y, p.z), theta: theta, axis: SIMD3(r.x, r.y, r.z))
        return XYZ(x: q.x, y: q.y, z: q.z)
    }

    @objc(horosLineFrom:to:intersectsRect:)
    public nonisolated class func horosLine(from start: NSPoint, to end: NSPoint, intersectsRect rect: NSRect) -> Bool {
        return LineGeometry.segment(from: start, to: end, intersects: rect)
    }

    // MARK: - 2D segments

    @objc(intersectionBetweenTwoLinesA1:A2:B1:B2:result:)
    @discardableResult
    public dynamic class func intersectionBetweenTwoLinesA1(_ a1: NSPoint, a2: NSPoint, b1: NSPoint, b2: NSPoint,
                                                           result r: UnsafeMutablePointer<NSPoint>!) -> Bool {
        guard let point = LineGeometry.intersection(a1: a1, a2: a2, b1: b1, b2: b2) else { return false }
        r?.pointee = point
        return true
    }

    @objc(Magnitude::)
    @discardableResult
    public dynamic class func magnitude(_ point1: NSPoint, _ point2: NSPoint) -> Float {
        return LineGeometry.magnitude(point1, point2)
    }

    /// The distance from `point` to the line through the two others, in
    /// `distance`; always 1.
    @objc(DistancePointLine::::)
    @discardableResult
    public dynamic class func distancePointLine(_ point: NSPoint, _ startPoint: NSPoint, _ endPoint: NSPoint,
                                                _ distance: UnsafeMutablePointer<Float>!) -> Int32 {
        distance.pointee = LineGeometry.distance(from: point, toLineFrom: startPoint, to: endPoint)
        return 1
    }

    // MARK: - The viewer the view is in

    private var viewer: ViewerController? { self.windowController() as? ViewerController }

    /// Writes `value` under `key` in the series and, unless the settings are
    /// copied to the whole series, in the image shown (nil otherwise).
    private func savePresentation(_ value: Any?, forKey key: String, imageValue: Any?? = .none) {
        (self.seriesObj() as NSObject?)?.setValue(value, forKey: key)
        let image = self.imageObj() as NSObject?
        if self.horos_curImage >= 0 && !self.horos_COPYSETTINGSINSERIES {
            image?.setValue(imageValue ?? value, forKey: key)
        } else {
            image?.setValue(nil, forKey: key)
        }
    }

    // MARK: - Scale

    /// -setScaleValue:, the body of the property's setter (DCMView.swift); the setter
    /// is what subclasses override and Objective-C sends, so this is called directly.
    final func horosSetScaleValue(_ value: Float) {
        var x = value
        if x.isNaN { return }
        if self.horos_curImage < 0 { return }
        if self.curDCM == nil { return }
        if x < 0.01 { x = 0.01 }
        if x > 100 { x = 100 }

        if self.horos_scaleValue != x {
            self.horos_scaleValue = x

            if self.softwareInterpolation() || self.horos_blending?.softwareInterpolation() == true {
                self.loadTextures()
            } else if self.horos_zoomIsSoftwareInterpolated || self.horos_blending?.horos_zoomIsSoftwareInterpolated == true {
                self.loadTextures()
            }

            if self.is2DViewer() && self.horos_firstTimeDisplay {
                if viewer?.isPostprocessed() == false {
                    if let e = geometryTry({ self.saveScale() }) {
                        _N2LogExceptionImpl(e, true, "-[DCMView setScaleValue:]")
                    }
                }
            }

            self.updateTilingViews()
            self.needsDisplay = true
        }
    }

    /// The scale with the series (relative to the view's size) and the image.
    private func saveScale() {
        let series = self.seriesObj() as NSObject?
        if !self.isScaledFit() {
            series?.setValue(NSNumber(value: ViewTransform.seriesScale(self.horos_scaleValue, frameSize: self.frame.size)), forKey: "scale")
        } else {
            series?.setValue(nil, forKey: "scale")
        }
        series?.setValue(NSNumber(value: Int32(3)), forKey: "displayStyle")

        let image = self.imageObj() as NSObject?
        if self.horos_curImage >= 0 && !self.horos_COPYSETTINGSINSERIES && !self.isScaledFit() {
            image?.setValue(NSNumber(value: self.horos_scaleValue), forKey: "scale")
        } else {
            image?.setValue(nil, forKey: "scale")
        }
    }

    /// The scale, the pan scaled with it so that the centre of the view
    /// stays on the same point of the image.
    @objc(setScaleValueCentered:)
    public dynamic func setScaleValueCentered(_ x: Float) {
        if x < 0.01 { return }
        if x > 100 { return }
        if x.isNaN { return }
        if self.horos_curImage < 0 { return }

        if x != self.horos_scaleValue {
            if self.horos_scaleValue != 0 {
                let origin = self.horos_origin
                self.setOriginX(Float((origin.x * CGFloat(x)) / CGFloat(self.horos_scaleValue)),
                                y: Float((origin.y * CGFloat(x)) / CGFloat(self.horos_scaleValue)))
            }

            self.horos_scaleValue = x

            if self.horos_scaleValue < 0.01 { self.horos_scaleValue = 0.01 }
            if self.horos_scaleValue > 100 { self.horos_scaleValue = 100 }
            if self.horos_scaleValue.isNaN { self.horos_scaleValue = 100 }

            if self.softwareInterpolation() || self.horos_blending?.softwareInterpolation() == true {
                self.loadTextures()
            } else if self.horos_zoomIsSoftwareInterpolated || self.horos_blending?.horos_zoomIsSoftwareInterpolated == true {
                self.loadTextures()
            }

            if self.is2DViewer() {
                let series = self.seriesObj() as NSObject?
                if !self.isScaledFit() {
                    series?.setValue(NSNumber(value: ViewTransform.seriesScale(self.horos_scaleValue, frameSize: self.frame.size)), forKey: "scale")
                } else {
                    series?.setValue(nil, forKeyPath: "scale")
                }
                series?.setValue(NSNumber(value: Int32(3)), forKey: "displayStyle")

                let image = self.imageObj() as NSObject?
                if self.horos_curImage >= 0 && !self.horos_COPYSETTINGSINSERIES && !self.isScaledFit() {
                    image?.setValue(NSNumber(value: self.horos_scaleValue), forKey: "scale")
                } else {
                    image?.setValue(nil, forKey: "scale")
                }
            }

            self.updateTilingViews()
            self.needsDisplay = true
        }
    }

    /// Whether the zoom is above 2 and drawn by software interpolation (the
    /// preferences allow it and the image is narrow enough).
    @objc(softwareInterpolation)
    public dynamic func softwareInterpolation() -> Bool {
        return self.horos_scaleValue > 2 && !DCMView.horos_static_NOINTERPOLATION
            && DCMView.horos_static_SOFTWAREINTERPOLATION && (self.curDCM?.pwidth ?? 0) <= Int(SOFTWAREINTERPOLATION_MAX)
    }

    // MARK: - Fit

    /// Whether the view shows the image fitted: not panned, and within 0.1
    /// of the fitting scale.
    @objc(isScaledFit)
    public dynamic func isScaledFit() -> Bool {
        let s = self.scaleToFit(for: self.curDCM)
        let origin = self.horos_origin
        if origin.x != 0 && origin.y != 0 { return false }
        return abs(Double(s - self.scaleValue)) < 0.1
    }

    /// The scale at which `d` (its shutter, when it has one) fits the view,
    /// turned as the view is.
    @objc(scaleToFitForDCMPix:)
    public dynamic func scaleToFit(for d: DCMPix!) -> Float {
        let sizeView = self.convertToBacking(self.bounds) // Retina
        var w = Double(d?.pwidth ?? 0)
        var h = Double(d?.pheight ?? 0)
        if d?.shutterEnabled == true {
            w = Double(d.shutterRect.size.width)
            h = Double(d.shutterRect.size.height)
        }
        let fallback: Float = self.scaleValue > 0 ? self.scaleValue : 1
        return ViewTransform.fitScale(viewSize: sizeView.size, width: w, height: h, pixelRatio: d?.pixelRatio ?? 0,
                                      rotation: self.rotation, fallback: fallback)
    }

    @objc(scaleToFit)
    public dynamic func scaleToFit() {
        if self.horos_scaleToFitNoReentry { return }
        self.horos_scaleToFitNoReentry = true

        self.scaleValue = self.scaleToFit(for: self.curDCM)

        if let pix = self.curDCM, pix.shutterEnabled {
            self.horos_origin = ViewTransform.shutterOrigin(width: pix.pwidth, height: pix.pheight, shutter: pix.shutterRect,
                                                            scale: self.horos_scaleValue, pixelRatio: pix.pixelRatio)
        } else {
            self.horos_origin = .zero
        }

        self.needsDisplay = true

        self.horos_scaleToFitNoReentry = false
    }

    /// The first draw also restores the presentation: restored now, it
    /// cannot overwrite the fit, and its rotation, flips and window level
    /// are kept.
    @objc(prepareForWorkspacePresentation)
    public dynamic func prepareForWorkspacePresentation() {
        if !self.horos_firstTimeDisplay {
            self.horos_firstTimeDisplay = true
            self.updatePresentationStateFromSeries()
        }
    }

    /// The opening framing: the part of the image with something in it
    /// (`content`, found by the loading worker; empty while unknown), or the
    /// whole image when that adds nothing.
    @objc(applyOpeningScaleToFit:)
    public dynamic func applyOpeningScale(toFit content: NSRect) {
        self.prepareForWorkspacePresentation()
        let pix = self.curDCM
        if pix?.shutterEnabled == true || NSIsEmptyRect(content) {
            self.scaleToFit()
            return
        }
        let viewport = self.convertToBacking(self.bounds)
        let fullFit = Double(self.scaleToFit(for: pix))
        guard let zoom = ViewTransform.openingScale(content: content, viewport: viewport.size, pixelRatio: pix?.pixelRatio ?? 0,
                                                    rotation: self.rotation, fullFit: fullFit) else {
            self.scaleToFit()
            return
        }
        self.scaleValue = Float(zoom)
        // Through the setter, which saves the pan with the series as the
        // scale was: the series shown again later has this framing.
        let origin = ViewTransform.openingOrigin(content: content, width: pix?.pwidth ?? 0, height: pix?.pheight ?? 0,
                                                 scale: self.horos_scaleValue, pixelRatio: pix?.pixelRatio ?? 0)
        self.setOriginX(origin.x, y: origin.y)
        self.needsDisplay = true
    }

    @objc(cancelOpeningScaleToFitForInteraction)
    public dynamic func cancelOpeningScaleToFitForInteraction() {
        if self.is2DViewer() {
            viewer?.cancelOpeningScaleToFit()
        }
    }

    @objc(scaleToFit:)
    @IBAction public dynamic func scaleToFit(_ sender: Any!) {
        self.setOriginX(0, y: 0)
        self.rotation = 0
        self.scaleToFit()
        self.propagateIfMain()
    }

    @objc(actualSize:)
    @IBAction public dynamic func actualSize(_ sender: Any!) {
        self.setOriginX(0, y: 0)
        self.rotation = 0
        self.scaleValue = 1
        self.propagateIfMain()
    }

    private func propagateIfMain() {
        if self.is2DViewer() && self.window?.isMainWindow == true {
            viewer?.propagateSettings()
        }
    }

    /// The image at its physical size on this screen, when the image is
    /// calibrated and the screen's pixels are square.
    @objc(realSize:)
    @IBAction public dynamic func realSize(_ sender: Any!) {
        guard let pix = self.curDCM, pix.pixelSpacingX != 0, pix.pixelSpacingY != 0 else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("Actual Size Error", comment: ""),
                                        message: NSLocalizedString("This image is not calibrated.", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        let screenNumber = (self.window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        let f = CGDisplayScreenSize(screenNumber)
        let r = CGDisplayBounds(screenNumber)

        if f.width != 0 && f.height != 0 {
            let ratio = abs((f.width / r.size.width) - (f.height / r.size.height))
            NSLog("screen pixel ratio: %f", ratio)
            if ratio < 0.01 {
                self.scaleValue = Float(pix.pixelSpacingX / Double(f.width / r.size.width))
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

    // MARK: - Pan

    /// -setOrigin:, the body of the property's setter (DCMView.swift); the setter
    /// is what subclasses override and Objective-C sends, so this is called directly.
    final func horosSetOrigin(_ x: NSPoint) {
        self.setOriginX(Float(x.x), y: Float(x.y))
    }

    /// The pan, given in the image's axes.
    @objc(setOriginWithRotationX:Y:)
    public dynamic func setOriginWithRotationX(_ x: Float, y: Float) {
        let turned = ViewTransform.rotatedOrigin(x: x, y: y, rotation: self.horos_rotation, deg2rad: DCMView.horos_static_deg2rad)
        self.setOriginX(turned.x, y: turned.y)
    }

    /// The pan, within ±100000, saved with the series and the image.
    @objc(setOriginX:Y:)
    public dynamic func setOriginX(_ value: Float, y yValue: Float) {
        if self.horos_curImage < 0 { return }
        if self.curDCM == nil { return }

        let x: Float = value > -100000 && value < 100000 ? value : 0
        let y: Float = yValue > -100000 && yValue < 100000 ? yValue : 0

        let origin = self.horos_origin
        if origin.x != CGFloat(x) || origin.y != CGFloat(y) {
            self.horos_origin = NSPoint(x: CGFloat(x), y: CGFloat(y))
            self.updateTilingViews()
            self.needsDisplay = true

            if self.is2DViewer() && viewer?.isPostprocessed() == false {
                let series = self.seriesObj() as NSObject?
                series?.setValue(NSNumber(value: x), forKey: "xOffset")
                series?.setValue(NSNumber(value: y), forKey: "yOffset")

                let image = self.imageObj() as NSObject?
                if self.horos_curImage >= 0 && !self.horos_COPYSETTINGSINSERIES {
                    image?.setValue(NSNumber(value: x), forKey: "xOffset")
                    image?.setValue(NSNumber(value: y), forKey: "yOffset")
                } else {
                    image?.setValue(nil, forKey: "xOffset")
                    image?.setValue(nil, forKey: "yOffset")
                }
            }
        }
    }

    // MARK: - Rotation and flips

    /// -setRotation:, the body of the property's setter (DCMView.swift); the setter
    /// is what subclasses override and Objective-C sends, so this is called directly.
    final func horosSetRotation(_ x: Float) {
        if self.horos_rotation != x {
            var rotation = x
            if rotation < 0 { rotation += 360 }
            if rotation > 360 { rotation -= 360 }
            self.horos_rotation = rotation

            self.savePresentation(NSNumber(value: rotation), forKey: "rotationAngle")

            self.updateTilingViews()
            self.needsDisplay = true
        }
    }

    /// -setXFlipped:, called by the property's setter (DCMView.swift).
    @objc(horosSetXFlipped:)
    public dynamic func horosSetXFlipped(_ v: Bool) {
        self.horos_xFlipped = v
        self.saveFlip(v, forKey: "xFlipped", function: "-[DCMView setXFlipped:]")
    }

    /// -setYFlipped:, called by the property's setter (DCMView.swift).
    @objc(horosSetYFlipped:)
    public dynamic func horosSetYFlipped(_ v: Bool) {
        self.horos_yFlipped = v
        self.saveFlip(v, forKey: "yFlipped", function: "-[DCMView setYFlipped:]")
    }

    private func saveFlip(_ v: Bool, forKey key: String, function: StaticString) {
        if self.is2DViewer() && viewer?.isPostprocessed() == false {
            if let e = geometryTry({
                (self.seriesObj() as NSObject?)?.setValue(NSNumber(value: v), forKey: key)
                let image = self.imageObj() as NSObject?
                if self.horos_curImage >= 0 && (self.horos_dcmFilesList?.count ?? 0) > Int(self.horos_curImage)
                    && !self.horos_COPYSETTINGSINSERIES {
                    image?.setValue(NSNumber(value: v), forKey: key)
                } else {
                    image?.setValue(nil, forKey: key)
                }
            }) {
                function.withUTF8Buffer { buffer in
                    buffer.withMemoryRebound(to: CChar.self) { _N2LogExceptionImpl(e, true, $0.baseAddress) }
                }
            }
        }
        self.updateTilingViews()
        self.needsDisplay = true
    }

    @objc(flipVertical:)
    @IBAction public dynamic func flipVertical(_ sender: Any!) {
        self.yFlipped = !self.horos_yFlipped
    }

    @objc(flipHorizontal:)
    @IBAction public dynamic func flipHorizontal(_ sender: Any!) {
        self.xFlipped = !self.horos_xFlipped
    }

    /// The image's orientation as the view shows it, turned and flipped, in
    /// `correctedOrientation` (9 values).
    @objc(orientationCorrectedToView:)
    public dynamic func orientationCorrected(toView correctedOrientation: UnsafeMutablePointer<Float>!) {
        var o = [Float](repeating: 0, count: 9)
        o.withUnsafeMutableBufferPointer { self.curDCM?.orientation($0.baseAddress) }
        let corrected = ViewTransform.correctedOrientation(o, rotation: self.horos_rotation, xFlipped: self.horos_xFlipped,
                                                           yFlipped: self.horos_yFlipped, deg2rad: DCMView.horos_static_deg2rad)
        for i in 0..<9 { correctedOrientation[i] = corrected[i] }
    }

    /// Slice coordinates of the image to those the subclasses' -subDrawRect:
    /// draws in.
    @objc(pixToSubDrawRectTransform)
    public dynamic func pixToSubDrawRectTransform() -> N3AffineTransform {
        #if DEBUG
        if let pix = self.curDCM, pix.pixelSpacingX.isNaN || pix.pixelSpacingY.isNaN || pix.pixelSpacingX <= 0
            || pix.pixelSpacingY <= 0 || pix.pixelSpacingX > 1000 || pix.pixelSpacingY > 1000 {
            NSLog("******* CPR pixel spacing incorrect for pixToSubDrawRectTransform")
        }
        #endif
        var transform = N3AffineTransformIdentity
        transform = N3AffineTransformConcat(transform, N3AffineTransformMakeTranslation(CGFloat(self.curDCM?.pwidth ?? 0) * -0.5,
                                                                                         CGFloat(self.curDCM?.pheight ?? 0) * -0.5, 0))
        transform = N3AffineTransformConcat(transform, N3AffineTransformMakeScale(CGFloat(self.horos_scaleValue),
                                                                                   CGFloat(self.horos_scaleValue), 1))
        transform.m14 = 0.0
        transform.m24 = 0.0
        transform.m34 = 0.0
        transform.m44 = 1.0
        return transform
    }

    /// The ROI canvas set to draw in the image's coordinates as the view shows it.
    @objc(applyImageTransformation)
    public dynamic func applyImageTransformation() {
        let canvas = ROICanvas.current
        let size = self.horos_drawingFrameRect.size
        canvas?.loadIdentity()
        canvas?.scale(x: Double(Float(2.0 / (self.horos_xFlipped ? -size.width : size.width))),
                      y: Double(Float(-2.0 / (self.horos_yFlipped ? -size.height : size.height))), z: 1)
        canvas?.rotate(Double(self.horos_rotation))
        canvas?.translate(x: Double(Float(self.horos_origin.x)), y: Double(Float(-self.horos_origin.y)), z: 0)
        canvas?.scale(x: 1, y: Double(Float(self.curDCM?.pixelRatio ?? 0)), z: 1)
    }

    // MARK: - Slice intersection

    /// -computeSliceIntersection:sliceFromTo:vector:origin:, which DCMView+CAPI.m
    /// keeps for its float[2][3] parameter: where the plane of normal
    /// `vectorB[6...8]` through `originB` crosses the edges of `oPix`, in
    /// slice coordinates of the image shown, in `sft` (its 6 values); all
    /// infinite when it does not cross twice.
    @objc(horosComputeSliceIntersection:sliceFromTo:vector:origin:)
    public dynamic func horosComputeSliceIntersection(_ oPix: DCMPix!, sliceFromTo sft: UnsafeMutablePointer<Float>!,
                                                      vector vectorB: UnsafeMutablePointer<Float>!, origin originB: UnsafeMutablePointer<Float>!) {
        // originB is the physical DICOM plane origin, shared by all slice
        // references; pixel-centre offsets belong to the conversions.
        let shown = self.curDCM
        PlaneGeometry.sliceIntersection(width: Float(oPix?.pwidth ?? 0), height: Float(oPix?.pheight ?? 0),
                                        normal: vectorB + 6, point: originB,
                                        toDICOM: { x, y, d in oPix?.convertX(x, pixY: y, toDICOMCoords: d, pixelCenter: true) },
                                        toSlice: { d, s in shown?.convertDICOMCoords(d, toSliceCoords: s, pixelCenter: true) },
                                        into: sft)
    }

    // MARK: - Size

    /// The frame, and the size the next -reshape compares with.
    open override var frame: NSRect {
        get { return super.frame }
        set {
            super.frame = newValue
            self.horos_previousViewSize = newValue.size
        }
    }

    /// -reshape (scrolled, moved or resized), called by DCMView's: the
    /// image keeps its framing when the view changes size, fitted again
    /// with AlwaysScaleToFit.
    @objc(horosReshape)
    public dynamic func horosReshape() {
        guard self.horos_dcmPixList != nil else { return }
        let is2DViewer = self.is2DViewer()
        let rect = self.frame
        let previous = self.horos_previousViewSize

        if UserDefaults.standard.bool(forKey: "AlwaysScaleToFit") && is2DViewer {
            if !NSEqualSizes(previous, rect.size) {
                viewer?.setUpdateTilingViewsValue(true)

                self.scaleToFit()

                if self.horos_curImage >= 0 && !self.horos_COPYSETTINGSINSERIES, let v = viewer {
                    for i in 0..<Int(v.maxMovieIndex()) {
                        for case let pix as DCMPix in v.pixList(i) ?? [] where pix !== self.curDCM {
                            let image = pix.imageObj() as NSObject?
                            image?.setValue(nil, forKey: "scale")
                            var o = NSPoint.zero
                            if pix.shutterEnabled, let shown = self.curDCM {
                                o = ViewTransform.shutterOrigin(width: shown.pwidth, height: shown.pheight, shutter: shown.shutterRect,
                                                                scale: self.horos_scaleValue, pixelRatio: nil)
                            }
                            image?.setValue(NSNumber(value: Float(o.x)), forKey: "xOffset")
                            image?.setValue(NSNumber(value: Float(o.y)), forKey: "yOffset")
                        }
                    }
                }

                viewer?.setUpdateTilingViewsValue(false)

                if self.window?.isMainWindow == true {
                    viewer?.propagateSettings()
                }
            }
        } else if previous.width != 0 && previous.height != 0 {
            let yChanged = ViewTransform.resizeFactor(from: previous, to: rect.size)

            if is2DViewer {
                viewer?.setUpdateTilingViewsValue(true)

                if self.horos_curImage >= 0 && !self.horos_COPYSETTINGSINSERIES, let v = viewer,
                   (v.imageViews() as NSArray?)?.firstObject as AnyObject? === self {
                    for i in 0..<Int(v.maxMovieIndex()) {
                        for case let pix as DCMPix in v.pixList(i) ?? [] where pix !== self.curDCM {
                            let image = pix.imageObj() as NSObject?
                            let s = (image?.value(forKey: "scale") as? NSNumber)?.floatValue ?? 0
                            if s != 0 {
                                image?.setValue(NSNumber(value: s * yChanged), forKey: "scale")
                            } else {
                                image?.setValue(nil, forKeyPath: "scale")
                            }
                        }
                    }
                }
            }

            self.scaleValue = self.horos_scaleValue * yChanged

            if is2DViewer {
                viewer?.setUpdateTilingViewsValue(false)
            }

            var origin = self.horos_origin
            origin.x *= CGFloat(yChanged)
            origin.y *= CGFloat(yChanged)
            self.horos_origin = origin

            if is2DViewer && self.window?.isMainWindow == true {
                viewer?.propagateSettings()
            }
        }
    }

    /// In a 2D viewer, the tile's place in the grid, fitted again if it was.
    open override func resize(withOldSuperviewSize oldSize: NSSize) {
        if !self.is2DViewer() {
            super.resize(withOldSuperviewSize: oldSize)
            return
        }
        let superFrame = self.superview?.bounds ?? .zero
        let newFrame = ViewTransform.tileFrame(superSize: superFrame.size, rows: self.rows, columns: self.columns, tag: self.tag)

        let wasScaledToFit = self.isScaledFit()
        self.frame = newFrame
        if wasScaledToFit {
            self.scaleToFit()
        }
        self.needsDisplay = true
    }

    @objc(setRows:columns:)
    public dynamic func setRows(_ rows: Int32, columns: Int32) {
        if self.rows == 1 && self.columns == 1 && rows == 1 && columns == 1 { return }
        self.rows = Int(rows)
        self.columns = Int(columns)
        self.resize(withOldSuperviewSize: self.superview?.bounds.size ?? .zero)
        self.needsDisplay = true
    }

    /// Resizes the window so that the image shows at `resizeScale`.
    @objc(resizeWindowToScale:)
    public dynamic func resizeWindow(toScale resizeScale: Float) {
        guard let window = self.window else { return }
        let screens = NSScreen.screens.map { (frame: $0.frame, usable: AppController.usefullRect(for: $0)) }
        let windowFrame = ViewTransform.windowFrame(window.frame, viewSize: self.frame.size, width: self.curDCM?.pwidth ?? 0,
                                                    height: self.curDCM?.pheight ?? 0, scale: resizeScale, rows: self.rows,
                                                    columns: self.columns, screens: screens)
        if self.is2DViewer() {
            viewer?.setWindowFrame(windowFrame)
        } else {
            window.setFrame(windowFrame, display: true)
        }
        self.needsDisplay = true
    }

    /// The "Resize Window" items: 25 % to 300 %, or 320 pixels.
    @objc(resizeWindow:)
    @IBAction public dynamic func resizeWindow(_ sender: Any!) {
        if (self.windowController() as AnyObject?)?.fullScreenON?() == true { return }
        let tag = (sender as AnyObject?)?.tag ?? 0
        self.resizeWindow(toScale: ViewTransform.windowResizeScale(tag: tag, width: self.curDCM?.pwidth ?? 0,
                                                                   height: self.curDCM?.pheight ?? 0))
    }

    // MARK: - Tiles and presentation state

    /// The settings of the tile `aView` handed to this tile: the image at
    /// the same distance, and, when the settings are copied to the whole
    /// series, the window level, scale, rotation, pan, flips, fusion and
    /// colour table.
    @objc(setImageParamatersFromView:)
    public dynamic func setImageParamatersFrom(_ aView: DCMView!) {
        guard let aView, aView !== self, self.horos_dcmPixList != nil else { return }

        var offset = self.tag - aView.tag
        let prevCurImage = self.curImage
        if self.horos_flippedData { offset = -offset }

        var curImage = aView.curImage + offset
        if curImage < 0 {
            curImage = -1
            if !self.horos_flippedData { self.selectFirstTilingViewLater() }
        } else if curImage >= self.horos_dcmPixList.count {
            curImage = -1
            if self.horos_flippedData { self.selectFirstTilingViewLater() }
        }
        self.horos_curImage = curImage

        if aView.curDCM != nil {
            self.setCOPYSETTINGSINSERIESdirectly(aView.copysettingsinseries)

            if self.horos_curImage < 0 {
            } else if self.horos_COPYSETTINGSINSERIES {
                if aView.curWL != 0 && aView.curWW != 0 {
                    if self.horos_curWL != aView.curWL || self.horos_curWW != aView.curWW {
                        self.setWLWW(aView.curWL, aView.curWW)
                    }
                }
                self.scaleValue = aView.scaleValue
                self.rotation = aView.rotation
                self.origin = aView.origin

                self.xFlipped = aView.xFlipped
                self.yFlipped = aView.yFlipped

                // Fusion
                if self.blending !== aView.blending { self.blending = aView.blending }
                if self.blendingFactor != aView.blendingFactor { self.setBlendingFactor(aView.blendingFactor) }
                if self.blendingMode != aView.blendingMode { self.blendingMode = aView.blendingMode }

                // Colour table
                var r: UnsafeMutablePointer<UInt8>? = nil, g: UnsafeMutablePointer<UInt8>? = nil, b: UnsafeMutablePointer<UInt8>? = nil
                aView.getCLUT(&r, &g, &b)
                self.setCLUT(r, g, b)
            }
        }

        self.flippedData = aView.flippedData
        self.menu = aView.menu

        if prevCurImage != self.curImage {
            self.setIndex(self.curImage)
        }
    }

    private func selectFirstTilingViewLater() {
        guard self.is2DViewer(), let controller = self.windowController() as AnyObject? else { return }
        NSObject.cancelPreviousPerformRequests(withTarget: controller, selector: NSSelectorFromString("selectFirstTilingView"), object: nil)
        controller.perform(NSSelectorFromString("selectFirstTilingView"), with: nil, afterDelay: 0)
    }

    @objc(updatePresentationStateFromSeries)
    public dynamic func updatePresentationStateFromSeries() {
        self.updatePresentationState(fromSeriesOnlyImageLevel: false)
    }

    @objc(updatePresentationStateFromSeriesOnlyImageLevel:)
    public dynamic func updatePresentationState(fromSeriesOnlyImageLevel onlyImage: Bool) {
        self.updatePresentationState(fromSeriesOnlyImageLevel: onlyImage, scale: self.horos_firstTimeDisplay, offset: self.is2DViewer())
    }

    /// Restores what the image, or else the series, saved: flips, scale
    /// (absolute, or relative to the view's size), rotation, pan and window
    /// level, PET windows following their preference. `onlyImage` ignores
    /// the series; `scale` and `offset` restore those unless every view
    /// is fitted.
    @objc(updatePresentationStateFromSeriesOnlyImageLevel:scale:offset:)
    public dynamic func updatePresentationState(fromSeriesOnlyImageLevel onlyImage: Bool, scale: Bool, offset: Bool) {
        guard let series = self.seriesObj() as NSObject? else { return }
        let image = self.imageObj() as NSObject?
        let defaults = UserDefaults.standard
        func value(_ object: NSObject?, _ key: String) -> NSNumber? { object?.value(forKey: key) as? NSNumber }
        let isPreview = self.horos_stringID == "previewDatabase"
        let alwaysFit = defaults.bool(forKey: "AlwaysScaleToFit")

        if let flipped = value(image, "xFlipped") {
            self.xFlipped = flipped.boolValue
        } else if !onlyImage {
            self.xFlipped = value(series, "xFlipped")?.boolValue ?? false
        } else {
            self.xFlipped = false
        }

        if let flipped = value(image, "yFlipped") {
            self.yFlipped = flipped.boolValue
        } else if !onlyImage {
            self.yFlipped = value(series, "yFlipped")?.boolValue ?? false
        } else {
            self.yFlipped = false
        }

        if !isPreview {
            if (scale && !alwaysFit) || !self.horos_COPYSETTINGSINSERIES {
                if let imageScale = value(image, "scale") {
                    if imageScale.floatValue != 0 {
                        self.scaleValue = imageScale.floatValue
                    } else {
                        self.scaleToFit()
                    }
                } else if !onlyImage {
                    if let seriesScale = value(series, "scale"), seriesScale.floatValue != 0 {
                        self.scaleValue = ViewTransform.restoredScale(seriesScale.floatValue,
                                                                      displayStyle: Int(value(series, "displayStyle")?.int32Value ?? 0),
                                                                      frameSize: self.frame.size)
                    } else {
                        self.scaleToFit()
                    }
                } else {
                    self.scaleToFit()
                }
            } else {
                self.scaleToFit()
            }
        } else {
            self.scaleToFit()
        }

        if let angle = value(image, "rotationAngle") {
            self.rotation = angle.floatValue
        } else if !onlyImage {
            self.rotation = value(series, "rotationAngle")?.floatValue ?? 0
        } else {
            self.rotation = 0
        }

        if !isPreview {
            if (offset && !alwaysFit) || !self.horos_COPYSETTINGSINSERIES {
                var o = NSPoint(x: CGFloat(Float.infinity), y: CGFloat(Float.infinity))
                if let x = value(image, "xOffset") { o.x = CGFloat(x.floatValue) } else if !onlyImage { o.x = CGFloat(value(series, "xOffset")?.floatValue ?? 0) }
                if let y = value(image, "yOffset") { o.y = CGFloat(y.floatValue) } else if !onlyImage { o.y = CGFloat(value(series, "yOffset")?.floatValue ?? 0) }
                if o.x != CGFloat(Float.infinity) && o.y != CGFloat(Float.infinity) {
                    self.origin = o
                }
            }
        }

        var ww: Float = 0, wl: Float = 0
        if let width = value(image, "windowWidth") {
            ww = width.floatValue
        } else if !onlyImage, let width = value(series, "windowWidth") {
            ww = width.floatValue
        } else if !self.is2DViewer() {
            ww = self.horos_curWW
        }

        if let level = value(image, "windowLevel") {
            wl = self.curDCM?.calibratedWindowLevel(forStoredLevel: level.floatValue) ?? 0
        } else if !onlyImage, let level = value(series, "windowLevel") {
            wl = self.curDCM?.calibratedWindowLevel(forStoredLevel: level.floatValue) ?? 0
        } else if !self.is2DViewer() {
            wl = self.horos_curWL
        }

        if ww == 0 {
            if self.horos_curImage >= 0 || !self.horos_COPYSETTINGSINSERIES || !self.is2DViewer() {
                ww = self.curDCM?.savedWW ?? 0
                wl = self.curDCM?.savedWL ?? 0
            } else {
                let list = self.horos_dcmPixList as NSArray
                let middle = list.object(at: list.count / 2) as? DCMPix
                ww = middle?.savedWW ?? 0
                wl = middle?.savedWL ?? 0
            }
        }

        let modality = (self.horos_dcmFilesList as NSArray?).map { ($0.object(at: Int(self.horos_curImage)) as? NSObject)?.value(forKey: "modality") as? String } ?? nil
        let petLike = modality == "PT" || (defaults.bool(forKey: "mouseWindowingNM") && modality == "NM")
        let maximum = self.curDCM?.maxValueOfSeries ?? 0
        let suvConverted = self.curDCM?.suvConverted ?? false

        if ww != 0 || wl != 0 {
            if ww != 0 {
                if petLike {
                    switch defaults.integer(forKey: "DEFAULTPETWLWW") {
                    case 0:
                        if !suvConverted {
                            self.horos_curWW = ww
                            self.horos_curWL = wl
                        } else if self.is2DViewer() {
                            let factor = viewer?.factorPET2SUV() ?? 0
                            self.horos_curWW = ww * factor
                            self.horos_curWL = wl * factor
                        }
                    case 1:
                        let from = ViewTransform.percentOfMaximum(maximum, defaults.float(forKey: "PETWLWWFROM"))
                        let to = ViewTransform.percentOfMaximum(maximum, defaults.float(forKey: "PETWLWWTO"))
                        if to - from != 0 {
                            let window = ViewTransform.window(from: from, to: to)
                            self.horos_curWW = window.width
                            self.horos_curWL = window.level
                        }
                    case 2:
                        if suvConverted {
                            let from = defaults.float(forKey: "PETWLWWFROMSUV")
                            let to = defaults.float(forKey: "PETWLWWTOSUV")
                            if to - from != 0 {
                                let window = ViewTransform.window(from: from, to: to)
                                self.horos_curWW = window.width
                                self.horos_curWL = window.level
                            }
                        } else {
                            self.horos_curWW = ww
                            self.horos_curWL = wl
                        }
                    default:
                        break
                    }
                } else {
                    self.horos_curWW = ww
                    self.horos_curWL = wl
                }
                self.setWLWW(self.horos_curWL, self.horos_curWW)
            }
        } else if !onlyImage {
            if petLike {
                self.horos_curWW = ww
                self.horos_curWL = wl

                switch defaults.integer(forKey: "DEFAULTPETWLWW") {
                case 1:
                    let from = ViewTransform.percentOfMaximum(maximum, defaults.float(forKey: "PETWLWWFROM"))
                    let to = ViewTransform.percentOfMaximum(maximum, defaults.float(forKey: "PETWLWWTO"))
                    let window = ViewTransform.window(from: from, to: to)
                    self.horos_curWW = window.width
                    self.horos_curWL = window.level
                case 2:
                    if suvConverted {
                        let from = defaults.float(forKey: "PETWLWWFROMSUV")
                        let to = defaults.float(forKey: "PETWLWWTOSUV")
                        let window = ViewTransform.window(from: from, to: to)
                        self.horos_curWW = window.width
                        self.horos_curWL = window.level
                    } else {
                        self.horos_curWW = ww
                        self.horos_curWL = wl
                    }
                default:
                    break
                }

                self.setWLWW(self.horos_curWL, self.horos_curWW)
            }
        }
    }

    // MARK: - Fusion

    /// -setBlendingMode:, called by the property's setter (DCMView.swift).
    @objc(horosSetBlendingMode:)
    public dynamic func horosSetBlendingMode(_ f: Int) {
        self.horos_blendingMode = f

        if self.horos_blending?.blendingMode != f {
            self.horos_blending?.blendingMode = f
        }
        self.horos_blending?.setAlpha(self.horos_blendingFactor)

        self.loadTextures()
        self.needsDisplay = true
    }

    /// The fusion's alpha ramp for blending factor `a`, in the view's mode.
    @objc(setAlpha:)
    public dynamic func setAlpha(_ a: Float) {
        let table = ViewTransform.alphaTable(mode: self.horos_blendingMode, alpha: a)
        let alpha = self.horos_alphaTable!
        for i in 0..<256 { alpha[i] = table[i] }
    }

    /// The blending factor, within ±256, given to the fused view and shown
    /// on the viewer's slider.
    @objc(setBlendingFactor:)
    public dynamic func setBlendingFactor(_ f: Float) {
        var factor = f
        if factor < -256 { factor = -256 }
        if factor > 256 { factor = 256 }
        self.horos_blendingFactor = factor

        self.horos_blending?.setAlpha(factor)
        self.loadTextures()
        self.needsDisplay = true

        if self.is2DViewer(), let v = viewer, let slider = v.blendingSlider() {
            if factor != slider.floatValue {
                slider.floatValue = factor
                v.blendingSlider(slider)
            }
        }
    }

    /// The fused view takes this view's scale, rotation and pan.
    @objc(blendingPropagate)
    public dynamic func blendingPropagate() {
        if let blending = self.horos_blending {
            blending.scaleValue = self.horos_scaleValue
            blending.rotation = self.horos_rotation
            blending.origin = self.horos_origin
        }
    }

    @objc(colorTables::::)
    public dynamic func colorTables(_ a: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>!, _ r: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>!,
                                    _ g: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>!, _ b: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>!) {
        a.pointee = self.horos_alphaTable
        r.pointee = self.horos_redTable
        g.pointee = self.horos_greenTable
        b.pointee = self.horos_blueTable
    }

    /// The colour tables the fused image is drawn with: the PET tables in
    /// "B/W Inverse" PET mode, else the fused view's.
    @objc(blendingColorTables::::)
    public dynamic func blendingColorTables(_ a: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>!, _ r: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>!,
                                            _ g: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>!, _ b: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>!) {
        if UserDefaults.standard.string(forKey: "PET Clut Mode") == "B/W Inverse" {
            a.pointee = self.horos_alphaTable
            r.pointee = DCMView.horos_static_PETredTable
            g.pointee = DCMView.horos_static_PETgreenTable
            b.pointee = DCMView.horos_static_PETblueTable
        } else {
            self.horos_blending?.colorTables(a, r, g, b)
        }
    }

    /// The red, green or blue factor of a colour image, from its slider.
    @objc(sliderRGBFactor:)
    @IBAction public dynamic func sliderRGBFactor(_ sender: Any!) {
        let control = sender as AnyObject?
        let value = (control as? NSControl)?.floatValue ?? 0
        switch (control as? NSView)?.tag ?? (control as? NSCell)?.tag ?? 0 {
        case 0: self.horos_redFactor = value
        case 1: self.horos_greenFactor = value
        case 2: self.horos_blueFactor = value
        default: break
        }
        self.reapplyWindowLevel()
        self.loadTextures()
        self.needsDisplay = true
    }

    /// This view's image with the fused one over it, both as shown, at the
    /// full resolution of this one.
    @objc(mergeFused)
    public dynamic func mergeFused() -> DCMPix! {
        guard let blending = self.horos_blending else { return nil }
        let deg2rad = DCMView.horos_static_deg2rad
        let oScale: Float = 1.0 // the back image at full resolution
        let scaleRatio = Float(1.0 / Double(self.scaleValue))
        let blendingScale = blending.scaleValue * scaleRatio

        let fusedPix = blending.curDCM?.render(withRotation: blending.rotation, scale: blendingScale,
                                               xFlipped: blending.xFlipped, yFlipped: blending.yFlipped)
        let originalPix = self.curDCM?.render(withRotation: self.rotation, scale: oScale, xFlipped: self.xFlipped,
                                              yFlipped: self.yFlipped)

        var oo = blending.origin
        oo.x *= CGFloat(scaleRatio)
        oo.y *= CGFloat(scaleRatio)
        if blending.xFlipped { oo.x = -oo.x }
        if blending.yFlipped { oo.y = -oo.y }
        oo = DCMPix.rotatePoint(oo, aroundPoint: .zero, angle: Float(Double(-blending.rotation) * deg2rad))

        var cc = self.origin
        cc.x *= CGFloat(scaleRatio)
        cc.y *= CGFloat(scaleRatio)
        if self.xFlipped { cc.x = -cc.x }
        if self.yFlipped { cc.y = -cc.y }
        cc = DCMPix.rotatePoint(cc, aroundPoint: .zero, angle: Float(Double(-self.rotation) * deg2rad))

        oo.x -= cc.x
        oo.y -= cc.y
        oo.y = -oo.y

        return originalPix?.merge(with: fusedPix, offset: oo)
    }

    /// A new viewer with the fused images (every slice when both series
    /// are volumes), in place of this one.
    @objc(mergeFusedImages:)
    @IBAction public dynamic func mergeFusedImages(_ sender: Any!) {
        let applyToEntireSeries = self.horos_blending?.volumicSeries == true && self.volumicSeries

        let pixA = NSMutableArray()
        let objA = NSMutableArray()
        var newData: NSMutableData?

        if applyToEntireSeries {
            let data = NSMutableData()
            newData = data
            let count = self.horos_dcmPixList.count
            for i in 0..<count {
                self.setIndex(Int(truncatingIfNeeded: i))
                self.sendSyncMessage(1)
                viewer?.propagateSettings()

                let merged = self.mergeFused()
                pixA.add(merged as Any)
                objA.add(merged?.imageObj() as Any)
                data.append(merged!.fImage, length: merged!.pheight * merged!.pwidth * MemoryLayout<Float>.size)
            }
            let last = pixA.lastObject as? DCMPix
            let sliceBytes = (last?.pheight ?? 0) * (last?.pwidth ?? 0) * MemoryLayout<Float>.size
            for i in 0..<count {
                let pix = pixA.object(at: i) as? DCMPix
                pix?.fImage = data.mutableBytes.advanced(by: sliceBytes * i).assumingMemoryBound(to: Float.self)
                pix?.freefImage(whenDone: false)
            }
        } else {
            let merged = self.mergeFused()
            pixA.add(merged as Any)
            objA.add(merged?.imageObj() as Any)
            let data = NSMutableData(bytes: merged!.fImage, length: merged!.pheight * merged!.pwidth * MemoryLayout<Float>.size)
            newData = data
            merged?.fImage = data.mutableBytes.assumingMemoryBound(to: Float.self)
            merged?.freefImage(whenDone: false)
        }

        (self.windowController() as? NSWindowController)?.close()

        // +newWindow::: hands over the +1 of the viewer's alloc, which the viewer
        // releases itself when its window closes: keep it, as the former code did.
        if let viewer = ViewerController.newWindow(pixA, objA, newData) { _ = Unmanaged.passRetained(viewer) }
    }

    // MARK: - SUV

    /// The value under the mouse in SUV.
    @objc(getSUV)
    public dynamic func getSUV() -> Float {
        guard let pix = self.curDCM else { return Float.nan }
        let value = self.horos_pixelMouseValue
        if pix.suvConverted { return value }
        if pix.units == "CNTS" { return value * pix.philipsFactor }
        return ViewTransform.suv(value, weight: pix.patientsWeight, dose: pix.radionuclideTotalDoseCorrected, decay: pix.decayFactor)
    }

    /// The fused image's value under the mouse in SUV.
    @objc(getBlendedSUV)
    public dynamic func getBlendedSUV() -> Float {
        let fused = self.horos_blending?.curDCM
        let value = self.horos_blendingPixelMouseValue
        if fused?.suvConverted == true { return value }
        if fused?.units == "CNTS" { return value * (fused?.philipsFactor ?? 0) }
        return ViewTransform.blendedSUV(value, weight: fused?.patientsWeight ?? 0, dose: fused?.radionuclideTotalDoseCorrected ?? 0,
                                        decay: self.curDCM?.decayFactor ?? 0)
    }

    // MARK: - Study colours

    /// The colour and the date order of each 2D viewer's study among the
    /// patient's studies, and the "Previous" mark of older studies.
    @objc(computeColor)
    public dynamic func computeColor() {
        if !self.is2DViewer() { return }
        if let e = geometryTry({ self.computeStudyColours() }) {
            NSLog("**** computeColor exception: %@", e)
        }
    }

    private func computeStudyColours() {
        let viewers = dcmViewersByStudyDate((ViewerController.getDisplayed2DViewers() as NSArray?) ?? [])

        // "Previous" on the viewers whose study is older than another open
        // study of the same patient.
        var patients: [String] = [], dates: [Any] = []
        for v in viewers {
            let study = v.currentStudy()
            patients.append(study?.patientUID ?? "")
            dates.append(study?.date ?? NSNull())
        }
        let previous = PreviousStudyMark.previousIndices(patients: patients, dates: dates)
        for (i, v) in viewers.enumerated() {
            PreviousStudyMark.setPrevious(previous.contains(i), for: v)
        }

        var studies: [NSObject] = []
        var colorsStudy: [String: NSColor] = [:]

        for v in viewers {
            if let study = v.currentStudy(), v.currentSeries() != nil {
                studies.append(study)
            }
            for case let view as DCMView in (v.imageViews() as NSArray?) ?? [] {
                view.studyColorR = 0
                view.studyColorG = 0
                view.studyColorB = 0
                view.studyDateIndex = UInt(NSNotFound)
                view.needsDisplay = true
            }
        }

        guard !studies.isEmpty else { return }
        let study = self.studyObj()
        var allStudies: NSArray?

        // The browser's history, with the distant studies, when it is this patient's.
        let browser = BrowserController.currentBrowser()
        let comparativeUID = browser?.comparativePatientUID as NSString?
        if let comparativeUID, let patientUID = study?.patientUID,
           comparativeUID.compare(patientUID, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame,
           browser?.comparativeStudies != nil {
            allStudies = browser?.comparativeStudies as NSArray?
        } else if let db = browser?.database {
            // Every study of this patient.
            var search = (study as NSObject?)?.value(forKey: "patientUID") as? String
            let predicate: NSPredicate
            if (search?.count ?? 0) == 0 || search == "0" {
                search = (study as NSObject?)?.value(forKey: "name") as? String
                predicate = NSPredicate(format: "(name == %@)", argumentArray: [search as Any])
            } else {
                predicate = NSPredicate(format: "(patientUID BEGINSWITH[cd] %@)", argumentArray: [search as Any])
            }
            let found = db.objects(forEntity: db.studyEntity(), predicate: predicate) as NSArray?
            allStudies = found?.sortedArray(using: [NSSortDescriptor(key: "date", ascending: false)]) as NSArray?
        }

        let studyUIDs = (allStudies?.value(forKey: "studyInstanceUID") as? NSArray) ?? []
        let colors = ViewerController.studyColors() as NSArray? ?? []

        // A colour for each study.
        for study in studies {
            guard let uid = study.value(forKey: "studyInstanceUID") as? String, colorsStudy[uid] == nil else { continue }
            var color = studyUIDs.index(of: uid)
            if color != NSNotFound {
                if color >= colors.count { color = colors.count - 1 }
                colorsStudy[uid] = colors.object(at: color) as? NSColor
            }
        }

        if studyUIDs.count > 1 {
            for v in viewers {
                let uid = v.studyInstanceUID()
                let boxColor = uid.flatMap { colorsStudy[$0] }
                for case let view as DCMView in (v.imageViews() as NSArray?) ?? [] {
                    view.studyColorR = Float(boxColor?.redComponent ?? 0)
                    view.studyColorG = Float(boxColor?.greenComponent ?? 0)
                    view.studyColorB = Float(boxColor?.blueComponent ?? 0)
                    view.studyDateIndex = UInt(bitPattern: uid.map { studyUIDs.index(of: $0) } ?? NSNotFound)
                    view.needsDisplay = true
                }
            }
        }
    }
}
