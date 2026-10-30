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
import Metal
import QuartzCore

// The drawing of DCMView is implemented in Swift: an extension of DCMView, with the same selectors. -drawRect: and the Metal layer the picture is
// drawn in, -drawFrame: and the graphics drawn over the picture (CLUT bars,
// reference lines, ROI labels, the 2D point marker, the repulsor and the ROI
// selector), the annotations' text on the overlay, the description in large,
// the magnifier and the lens, and the fonts. The reference lines'
// -drawCrossLines:..., whose float[2][3] parameter has no @objc spelling, stay
// in Objective-C, in DCMView+CAPI.m, as calls to -horosDrawCrossLines:... here. The arithmetic is in
// IsiXImaging (DrawingGeometry).

// The OpenGL enumerants ROICanvasGL.h names, which Swift cannot import: that
// header imports Horos-Swift.h.
private let GL_POINTS: UInt32 = 0x0000
private let GL_LINES: UInt32 = 0x0001
private let GL_LINE_LOOP: UInt32 = 0x0002
private let GL_POLYGON: UInt32 = 0x0009
private let GL_POINT_SMOOTH: UInt32 = 0x0B10
private let GL_LINE_SMOOTH: UInt32 = 0x0B20
private let GL_POLYGON_SMOOTH: UInt32 = 0x0B41
private let GL_BLEND: UInt32 = 0x0BE2
private let GL_ONE: UInt32 = 1
private let GL_SRC_ALPHA: UInt32 = 0x0302
private let GL_ONE_MINUS_SRC_ALPHA: UInt32 = 0x0303

// The static inline functions of ROICanvasGL.h, with the same parameter types.
private func roiBegin(_ mode: UInt32) { ROICanvas.current?.begin(mode) }
private func roiEnd() { ROICanvas.current?.end() }
private func roiVertex2f(_ x: Float, _ y: Float) { ROICanvas.current?.vertex(x: CGFloat(x), y: CGFloat(y)) }
private func roiColor3f(_ r: Float, _ g: Float, _ b: Float) {
    ROICanvas.current?.color(r: CGFloat(r), g: CGFloat(g), b: CGFloat(b), a: 1)
}
private func roiColor4f(_ r: Float, _ g: Float, _ b: Float, _ a: Float) {
    ROICanvas.current?.color(r: CGFloat(r), g: CGFloat(g), b: CGFloat(b), a: CGFloat(a))
}
private func roiLineWidth(_ w: Float) { ROICanvas.current?.lineWidth(CGFloat(w)) }
private func roiPointSize(_ s: Float) { ROICanvas.current?.pointSize(CGFloat(s)) }
private func roiEnable(_ cap: UInt32) { ROICanvas.current?.enable(cap) }
private func roiDisable(_ cap: UInt32) { ROICanvas.current?.disable(cap) }
private func roiBlendFunc(_ source: UInt32, _ destination: UInt32) { ROICanvas.current?.blend(source: source, destination: destination) }
private func roiLoadIdentity() { ROICanvas.current?.loadIdentity() }
private func roiScalef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.scale(x: Double(x), y: Double(y), z: Double(z)) }
private func roiTranslatef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.translate(x: Double(x), y: Double(y), z: Double(z)) }

/// The canvas in backing pixels from the top left of a frame `size`.
private func roiEnterPixelGrid(_ size: NSSize) {
    let grid = DrawingGeometry.pixelGrid(width: size.width, height: size.height)
    roiScalef(grid.scaleX, grid.scaleY, 1.0)
    roiTranslatef(grid.translateX, grid.translateY, 0.0)
}

/// Runs `body` as an @try block: the NSException it raises is returned.
private func drawingTry(_ body: () -> Void) -> NSException? {
    do {
        try HorosObjCException.perform(body)
    } catch {
        return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
    }
    return nil
}

/// N2LogExceptionWithStackTrace(e) in `function`.
private func logDrawingException(_ exception: NSException, _ function: StaticString) {
    function.withUTF8Buffer { buffer in
        buffer.withMemoryRebound(to: CChar.self) { _N2LogExceptionImpl(exception, true, $0.baseAddress) }
    }
}

/// Where the canvas's current transform puts a point, in backing pixels from the
/// view's top left: the annotation overlay draws text where the graphics are.
private func annotationPixel(_ x: Double, _ y: Double) -> NSPoint? {
    guard let canvas = ROICanvas.current else { return nil }
    let window = canvas.devicePoint(x: CGFloat(x), y: CGFloat(y))
    return NSPoint(x: DrawingGeometry.overlayPixel(window.x), y: DrawingGeometry.overlayPixel(window.y))
}

extension DCMView {

    // MARK: - Text on the annotation overlay

    @objc(purgeStringTextureCache)
    public dynamic class func purgeStringTextureCache() {
        AnnotationText.purgeCache()
    }

    @objc(horosAnnotationRect:pixels:)
    public dynamic func horosAnnotationRect(_ r: NSRect, pixels: UnsafeMutablePointer<NSRect>!) -> Bool {
        guard let a = annotationPixel(Double(NSMinX(r)), Double(NSMinY(r))),
              let b = annotationPixel(Double(NSMaxX(r)), Double(NSMaxY(r))) else { return false }
        pixels.pointee = DrawingGeometry.overlayRect(a, b)
        return true
    }

    @objc(horosDrawAnnotationBox:bounds:)
    public dynamic func horosDraw(_ box: AnnotationBox!, bounds r: NSRect) {
        var pixels = NSRect.zero
        if let box, self.horosAnnotationRect(r, pixels: &pixels) {
            AnnotationOverlay.overlay(for: self).add(box: box, rect: pixels)
        }
    }

    @objc(horosLabelText:font:)
    public dynamic func horosLabelText(_ label: String!, font: NSFont!) -> AnnotationText! {
        return AnnotationText.text(for: label, font: font, scale: self.window?.backingScaleFactor ?? 0,
                                   cacheToken: AnnotationPresentation.textureCacheToken(for: self.window))
    }

    @objc(horosDrawLabel:at:textColor:shadowColor:)
    public dynamic func horosDrawLabel(_ text: AnnotationText!, at origin: NSPoint, textColor: NSColor!, shadowColor: NSColor!) {
        var pixels = NSRect.zero
        if let text, self.horosAnnotationRect(NSMakeRect(origin.x, origin.y, CGFloat(text.pixelWidth), CGFloat(text.pixelHeight)), pixels: &pixels) {
            AnnotationOverlay.overlay(for: self).add(text: text, x: NSMinX(pixels), y: NSMinY(pixels), textColor: textColor, shadowColor: shadowColor)
        }
    }

    @objc(DrawNSStringGL::::align:useStringTexture:)
    public dynamic func drawNSStringGL(_ str: String!, _ fontL: DCMViewFontKind, _ x: Int, _ y: Int, align: DCMViewTextAlign, useStringTexture stringTex: Bool) {
        guard let str else { return }

        let sf = Float(self.window?.backingScaleFactor ?? 0)
        guard let textureFont = fontL == DCMViewLabelFont ? self.horos_labelFont : self.horos_fontGL else { return }
        let text = AnnotationText.text(for: str, font: textureFont, scale: CGFloat(sf),
                                       cacheToken: AnnotationPresentation.textureCacheToken(for: self.window))
        let light = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1), dark = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1)
        let textColor = self.whiteBackground ? dark : light
        var shadowColor = self.whiteBackground ? light : dark
        let alignment = DrawingGeometry.TextAlignment(rawValue: Int(align.rawValue)) ?? .left
        let left: Double, top: Double

        if stringTex {
            let frame = self.horos_drawingFrameRect.size
            let placed = DrawingGeometry.texturedText(x: x, y: y, align: alignment, pixelWidth: text.pixelWidth,
                                                      pixelHeight: text.pixelHeight, scale: sf, frame: frame)
            if self.horos_recordAnnotationRects {
                self.rectArray?.add(NSValue(rect: placed.occupied))
            }
            left = placed.left
            top = placed.top
        } else {
            // These strings were glyph bitmaps whose line started at x and sat
            // on y; the picture's line lands there instead, aligned by its own
            // width.
            let placed = DrawingGeometry.glyphText(x: x, y: y, align: alignment, labelFont: fontL == DCMViewLabelFont,
                                                   stringWidth: text.stringWidth, lineBottom: text.lineBottom,
                                                   pixelHeight: text.pixelHeight, scale: sf)
            if let fontColor = self.horos_fontColor { shadowColor = fontColor }
            left = placed.left
            top = placed.top
        }

        var pixels = NSRect.zero
        if self.horosAnnotationRect(NSMakeRect(CGFloat(left), CGFloat(top), CGFloat(text.pixelWidth), CGFloat(text.pixelHeight)), pixels: &pixels) {
            AnnotationOverlay.overlay(for: self).add(text: text, x: NSMinX(pixels), y: NSMinY(pixels), textColor: textColor, shadowColor: shadowColor)
        }
    }

    @objc(DrawNSStringGL::::rightAlignment:useStringTexture:)
    public dynamic func drawNSStringGL(_ str: String!, _ fontL: DCMViewFontKind, _ x: Int, _ y: Int, rightAlignment right: Bool, useStringTexture stringTex: Bool) {
        self.drawNSStringGL(str, fontL, x, y, align: right ? DCMViewTextAlignRight : DCMViewTextAlignLeft, useStringTexture: stringTex)
    }

    @objc(DrawNSStringGL::::)
    public dynamic func drawNSStringGL(_ cstrOut: String!, _ fontL: DCMViewFontKind, _ x: Int, _ y: Int) {
        self.drawNSStringGL(cstrOut, fontL, x, y, rightAlignment: false, useStringTexture: false)
    }

    @objc(DrawCStringGL::::align:useStringTexture:)
    public dynamic func drawCStringGL(_ cstrOut: UnsafeMutablePointer<CChar>!, _ fontL: DCMViewFontKind, _ x: Int, _ y: Int, align: DCMViewTextAlign, useStringTexture stringTex: Bool) {
        self.drawNSStringGL(NSString(utf8String: cstrOut) as String?, fontL, x, y, align: align, useStringTexture: stringTex)
    }

    @objc(DrawCStringGL::::rightAlignment:useStringTexture:)
    public dynamic func drawCStringGL(_ cstrOut: UnsafeMutablePointer<CChar>!, _ fontL: DCMViewFontKind, _ x: Int, _ y: Int, rightAlignment right: Bool, useStringTexture stringTex: Bool) {
        self.drawCStringGL(cstrOut, fontL, x, y, align: right ? DCMViewTextAlignRight : DCMViewTextAlignLeft, useStringTexture: stringTex)
    }

    @objc(DrawCStringGL::::)
    public dynamic func drawCStringGL(_ cstrOut: UnsafeMutablePointer<CChar>!, _ fontL: DCMViewFontKind, _ x: Int, _ y: Int) {
        self.drawCStringGL(cstrOut, fontL, x, y, rightAlignment: false, useStringTexture: false)
    }

    @objc(lengthOfString:forFont:)
    public dynamic class func length(ofString cstr: UnsafeMutablePointer<CChar>!, forFont fontSizeArray: UnsafeMutablePointer<Int>!) -> Int {
        var i = 0, temp = 0
        while cstr[i] != 0 {
            temp += fontSizeArray[Int(cstr[i])]
            i += 1
        }
        return temp
    }

    @objc(sizeOfString:forFont:)
    public dynamic class func size(ofString string: String!, forFont font: NSFont!) -> NSSize {
        let attributes: [NSAttributedString.Key: Any] = [.font: font as Any]
        return NSAttributedString(string: string ?? "", attributes: attributes).size()
    }

    // MARK: - Description in large

    @objc(allIdenticalValues:inArray:)
    public dynamic func allIdenticalValues(_ v: String!, inArray a: [Any]!) -> Bool {
        let array = (a ?? []) as NSArray
        if array.count > 0 {
            // -isEqualToString: sent to nil, or with nil, answered NO.
            guard let s = (array.object(at: 0) as AnyObject).value(forKey: v) as? NSString else { return false }
            for i in array {
                guard let value = (i as AnyObject).value(forKey: v) as? String, s.isEqual(to: value) else { return false }
            }
            return true
        }
        return false
    }

    @objc(computeDescriptionInLarge)
    public dynamic func computeDescriptionInLarge() {
        let drawLock = DCMView.horos_static_drawLock
        drawLock?.lock()

        if let exception = drawingTry({
            let curSeries = self.seriesObj() as NSObject?
            let curStudy = curSeries?.value(forKey: "study") as AnyObject?

            let viewers = dcmViewersByStudyDate(ViewerController.getDisplayed2DViewers() as NSArray? ?? [])

            let studiesArray = NSMutableArray()
            let seriesArray = NSMutableArray()

            for v in viewers {
                if let study = v.currentStudy(), let series = v.currentSeries() {
                    studiesArray.add(study)
                    seriesArray.add(series)
                }
            }

            let description = NSMutableString(string: "")
            // same patients?
            if !self.allIdenticalValues("name", inArray: studiesArray as? [Any]) {
                if let name = curStudy?.value(forKey: "name") as? String {
                    if description.length > 0 { description.append("\r") }
                    description.append(name)
                }
            }

            if description.length > 0 { description.append("\r") }

            if let date = UserDefaults.formatDateTime(curSeries?.value(forKey: "date") as? Date) {
                description.append(date)
            }

            if !self.allIdenticalValues("studyName", inArray: studiesArray as? [Any]) {
                if let studyName = curStudy?.value(forKey: "studyName") as? String {
                    if description.length > 0 { description.append("\r") }
                    description.append(studyName)
                }
            }

            if let name = curSeries?.value(forKey: "name") as? String {
                if description.length > 0 { description.append("\r") }
                description.append(name)
            }

            let stanStringAttrib = NSMutableDictionary()
            stanStringAttrib.setObject(NSFont(name: "Helvetica-Bold", size: 30) as Any, forKey: NSAttributedString.Key.font as NSCopying)

            let text = NSAttributedString(string: description as String, attributes: stanStringAttrib as? [NSAttributedString.Key: Any])

            self.computeColor()

            var boxColor = (ViewerController.studyColors() as NSArray?)?.object(at: 0) as? NSColor ?? NSColor.clear
            if self.studyColorR != 0 || self.studyColorG != 0 || self.studyColorB != 0 {
                boxColor = NSColor(calibratedRed: CGFloat(self.studyColorR), green: CGFloat(self.studyColorG), blue: CGFloat(self.studyColorB), alpha: 0.7)
            }
            let frameColor = NSColor(deviceRed: boxColor.redComponent, green: boxColor.greenComponent, blue: boxColor.blueComponent, alpha: 1)

            if let box = self.horos_showDescriptionInLargeText {
                box.set(attributedString: text, boxColor: boxColor, borderColor: frameColor)
            } else {
                self.horos_showDescriptionInLargeText = AnnotationBox(attributedString: text, boxColor: boxColor, borderColor: frameColor)
            }
        }) {
            logDrawingException(exception, "-[DCMView computeDescriptionInLarge]")
        }

        drawLock?.unlock()
    }

    @objc(switchShowDescriptionInLarge)
    public dynamic func switchShowDescriptionInLarge() {
        let show = self.showDescriptionInLarge
        for case let v as ViewerController in (ViewerController.getDisplayed2DViewers() as NSArray?) ?? [] {
            for case let m as DCMView in (v.imageViews() as NSArray?) ?? [] {
                m.showDescriptionInLarge = show

                if show {
                    m.computeDescriptionInLarge()
                }
                m.needsDisplay = true
            }
        }
    }

    // MARK: - 2D point, repulsor, selector

    @objc(erase2DPointMarker)
    public dynamic func erase2DPointMarker() {
        self.horos_display2DPoint = NSMakePoint(0, 0)
    }

    @objc(draw2DPointMarker)
    public dynamic func draw2DPointMarker() {
        let point = self.horos_display2DPoint
        if point.x != 0 || point.y != 0 {
            if Int(self.horos_display2DPointIndex) == Int(self.horos_curImage) {
                roiColor3f(0.0, 0.5, 1.0)
                roiLineWidth(Float(2.0 * (self.window?.backingScaleFactor ?? 0)))
                roiBegin(GL_LINES)

                let pix = self.curDCM
                for (x, y) in DrawingGeometry.pointMarker(point, width: pix?.pwidth ?? 0, height: pix?.pheight ?? 0, scale: self.horos_scaleValue) {
                    roiVertex2f(x, y)
                }
                roiEnd()
            } else {
                self.horos_display2DPoint = NSMakePoint(0, 0)
            }
        }
    }

    @objc(drawRepulsorToolArea)
    public dynamic func drawRepulsorToolArea() {
        roiEnable(GL_BLEND)
        roiDisable(GL_POLYGON_SMOOTH)
        roiDisable(GL_POINT_SMOOTH)
        roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

        roiColor4f(1.0, 1.0, 0.0, self.horos_repulsorAlpha)

        var pt = self.horos_repulsorPosition
        pt = self.convertToBacking(pt)

        pt.y = self.drawingFrameRect.size.height - pt.y // inverse Y scaling system

        roiBegin(GL_POLYGON)
        for (x, y) in DrawingGeometry.repulsorCircle(center: pt, radius: Int(self.horos_repulsorRadius), scale: self.horos_scaleValue) {
            roiVertex2f(x, y)
        }
        roiEnd()
        roiDisable(GL_BLEND)
    }

    @objc(setAlphaRepulsor:)
    public dynamic func setAlphaRepulsor(_ theTimer: Timer!) {
        let step = DrawingGeometry.repulsorAlphaStep(alpha: self.horos_repulsorAlpha, sign: self.horos_repulsorAlphaSign)
        self.horos_repulsorAlphaSign = step.sign
        self.horos_repulsorAlpha = step.alpha

        self.needsDisplay = true
    }

    @objc(drawROISelectorRegion)
    public dynamic func drawROISelectorRegion() {
        roiEnable(GL_BLEND)
        roiDisable(GL_POLYGON_SMOOTH)
        roiDisable(GL_POINT_SMOOTH)
        roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)

        roiLineWidth(Float(1 * (self.window?.backingScaleFactor ?? 0)))

        let r: Float = 0.8, g: Float = 0.8, b: Float = 1.0

        let startPt = self.convertToBacking(self.horos_ROISelectorStartPoint)
        let endPt = self.convertToBacking(self.horos_ROISelectorEndPoint)

        // inside: fill
        roiColor4f(r, g, b, 0.3)
        roiBegin(GL_POLYGON)
        roiVertex2f(Float(startPt.x), Float(startPt.y))
        roiVertex2f(Float(startPt.x), Float(endPt.y))
        roiVertex2f(Float(endPt.x), Float(endPt.y))
        roiVertex2f(Float(endPt.x), Float(startPt.y))
        roiEnd()

        // border
        roiColor4f(r, g, b, 0.75)
        roiBegin(GL_LINE_LOOP)
        roiVertex2f(Float(startPt.x), Float(startPt.y))
        roiVertex2f(Float(startPt.x), Float(endPt.y))
        roiVertex2f(Float(endPt.x), Float(endPt.y))
        roiVertex2f(Float(endPt.x), Float(startPt.y))
        roiEnd()

        roiDisable(GL_BLEND)
    }

    // MARK: - Lens and magnifier

    @objc(deleteLens)
    public dynamic func deleteLens() {
        if self.horos_lensActive {
            self.horos_lensActive = false
            self.needsDisplay = true

            if self.horos_cursorhidden {
                NSCursor.unhide()
                self.horos_cursorhidden = false
            }
        }
    }

    @objc(computeMagnifyLens:)
    public dynamic func computeMagnifyLens(_ p: NSPoint) {
        if p.x == 0 && p.y == 0 {
            return
        }

        if !UserDefaults.standard.bool(forKey: "magnifyingLens") {
            return
        }

        if !self.horos_isKeyView {
            self.window?.makeFirstResponder(self)
        }

        self.horos_lensSize = DrawingGeometry.cInt(Float(100) / self.horos_scaleValue)
        self.horos_LENSRATIO = 1
        self.horosLoadMagnifierFactors()

        self.deleteLens()

        let lensActualSize = DrawingGeometry.cInt(Float(self.horos_lensSize) * self.horos_lensSizeFactor)

        // The lens is drawn with each frame, from the picture Metal draws.
        if lensActualSize > 0 && Int(lensActualSize) < (self.curDCM?.pwidth ?? 0) {
            self.horos_lensActive = true

            // In the corner the lens is away from the pointer, which stays to aim with.
            if !self.horos_cursorhidden && !UserDefaults.standard.bool(forKey: MagnifierPresentation.cornerDefaultsKey) {
                self.horos_cursorhidden = true
                NSCursor.hide()
            }
        }

        self.needsDisplay = true
    }

    /// The magnifier's zoom and size, as the keys last set them in any view.
    @objc(horosLoadMagnifierFactors)
    public dynamic func horosLoadMagnifierFactors() {
        let defaults = UserDefaults.standard
        self.horos_lensZoomFactor = MagnifierPresentation.storedZoomFactor(in: defaults)
        self.horos_lensSizeFactor = MagnifierPresentation.storedSizeFactor(in: defaults)
    }

    /// A point of a ROI is being placed under the pointer: a ROI still being drawn,
    /// a handle the mouse holds, or the second click of a two-click length. A
    /// handle's mode outlives its drag for some types, hence the button. The brush
    /// and the pencil trace areas and a text ROI has no point to aim.
    @objc(horosPlacingROIPoint)
    public dynamic func horosPlacingROIPoint() -> Bool {
        if self.horos_lengthFirstEndpoint != nil {
            return true
        }

        let mouseDown = (NSEvent.pressedMouseButtons & 1) != 0
        for case let r as ROI in self.horos_curRoiList ?? [] {
            if r.type == .tPlain || r.type == .tPencil || r.type == .tText {
                continue
            }
            if r.roImode == Int(ROI_drawing) || (r.roImode == Int(ROI_selectedModify) && mouseDown) {
                return true
            }
        }
        return false
    }

    /// Shift alone asks for the lens of a ROI tool at any moment of a measurement:
    /// before the click, over a ROI, during the drag that draws a ROI or moves a
    /// handle, and between the two clicks of a length. It draws the ROIs' outlines,
    /// so it is useful over them. Command, Option and Control keep their meanings.
    @objc(horosShiftLensWantedWithFlags:)
    public dynamic func horosShiftLensWanted(with flags: NSEvent.ModifierFlags) -> Bool {
        return self.roiTool(self.currentTool)
            && flags.intersection([.shift, .command, .control, .option]) == .shift
            && UserDefaults.standard.bool(forKey: "magnifyingLens")
            && !self.horosShiftHidesMeasurementMagnifier(with: flags)
    }

    /// With the measurement magnifier on, Shift alone hides it while a point is
    /// placed, instead of showing the lens in its place: the way to aim without it.
    /// Shift with Option still constrains the shape and keeps the magnifier.
    @objc(horosShiftHidesMeasurementMagnifierWithFlags:)
    public dynamic func horosShiftHidesMeasurementMagnifier(with flags: NSEvent.ModifierFlags) -> Bool {
        return flags.intersection([.shift, .command, .control, .option]) == .shift
            && UserDefaults.standard.bool(forKey: MagnifierPresentation.measurementDefaultsKey)
            && self.roiTool(self.currentTool)
            && self.horosPlacingROIPoint()
    }

    /// The magnifier is up for a point the mouse is holding: the keys are its own.
    @objc(horosMeasurementMagnifierHoldsKeys)
    public dynamic func horosMeasurementMagnifierHoldsKeys() -> Bool {
        return (NSEvent.pressedMouseButtons & 1) != 0 && UserDefaults.standard.bool(forKey: MagnifierPresentation.measurementDefaultsKey)
            && self.horosPlacingROIPoint()
            && !self.horosShiftHidesMeasurementMagnifier(with: NSEvent.modifierFlags)
    }

    /// The ROIs' outlines as the magnifier draws them: segments in the pixels of a
    /// picture `side` wide that shows the view around `cursor`, `magnification`
    /// times larger. The brush and text have no outline to follow.
    @objc(horosROISegmentsForMagnifierSide:cursor:magnification:)
    public dynamic func horosROISegments(forMagnifierSide side: Int, cursor: NSPoint, magnification: Float) -> [Any]! {
        let sf = Float(self.window?.backingScaleFactor ?? 0)
        var segments: [Any] = []
        for case let r as ROI in self.horos_curRoiList ?? [] {
            if r.type == .tPlain || r.type == .tText || r.type == .tLayerROI || r.hidden {
                continue
            }
            let points = (r.splinePoints(self.horos_scaleValue) as NSArray?) ?? []
            if points.count < 2 {
                continue
            }
            let closed = r.roImode != Int(ROI_drawing) && (r.type == .tROI || r.type == .tOval || r.type == .tCPolygon || r.type == .tPencil)
            let color = r.rgbcolor
            let red = NSNumber(value: Int32(color.red >> 8)), green = NSNumber(value: Int32(color.green >> 8)), blue = NSNumber(value: Int32(color.blue >> 8))
            let thickness = r.thickness
            let width = NSNumber(value: (1.0 < thickness ? thickness : 1.0) * sf)

            var vertices: [NSPoint] = []
            vertices.reserveCapacity(points.count + 1)
            for case let p as MyPoint in points {
                let v = self.convert(fromGL2NSView: p.point)
                vertices.append(DrawingGeometry.magnifierPoint(v, cursor: cursor, side: side, magnification: magnification, scale: sf))
            }
            if closed, let first = vertices.first {
                vertices.append(first)
            }
            for i in stride(from: 1, to: vertices.count, by: 1) {
                let a = vertices[i - 1], b = vertices[i]
                segments.append([NSNumber(value: Double(a.x)), NSNumber(value: Double(a.y)), NSNumber(value: Double(b.x)), NSNumber(value: Double(b.y)),
                                 red, green, blue, width])
            }
        }
        return segments
    }

    @objc(horosHideCursorForMagnifier:)
    public dynamic func horosHideCursor(forMagnifier hide: Bool) {
        if hide == self.horos_cursorhidden {
            return
        }
        self.horos_cursorhidden = hide
        if hide { NSCursor.hide() } else { NSCursor.unhide() }
    }

    /// The square magnifier: the picture under the pointer drawn again by Metal,
    /// magnified, framed and sighted, around the pointer or in the view's corner,
    /// with the ROIs' outlines over it: around the pointer it covers the very line
    /// being measured. It takes the lens's magnification and size factor, so the
    /// keys that adjust the lens adjust it too.
    @objc(horosDrawSquareMagnifierInCorner:)
    @discardableResult
    public dynamic func horosDrawSquareMagnifier(inCorner corner: Bool) -> Bool {
        guard let canvas = ROICanvas.current, let window = self.window else {
            return false
        }

        let sf = Float(window.backingScaleFactor)
        let mlr = NSRect(origin: NSEvent.mouseLocation, size: .zero)
        let cursor = self.convert(window.convertFromScreen(mlr).origin, from: nil)
        if !NSPointInRect(cursor, self.bounds) {
            return false
        }

        self.horosLoadMagnifierFactors()
        let frame = MagnifierPresentation.frame(inBounds: self.bounds, cursor: cursor,
                                                side: MagnifierPresentation.side * CGFloat(self.horos_lensSizeFactor),
                                                inCorner: corner, flipped: self.isFlipped)
        let side = DrawingGeometry.cLong((Double(frame.size.width) * Double(sf)).rounded(.toNearestOrAwayFromZero))
        if side < 2 || side > 4096 {
            return false
        }

        let magnification = DrawingGeometry.magnification(zoomFactor: self.horos_lensZoomFactor)
        let half = Float(Double(frame.size.width) / 2.0 / Double(magnification))
        let bgra = self.horosPlanarPixelsSide(side,
                                              topLeft: NSMakePoint(cursor.x - CGFloat(half), cursor.y + CGFloat(half)),
                                              topRight: NSMakePoint(cursor.x + CGFloat(half), cursor.y + CGFloat(half)),
                                              bottomLeft: NSMakePoint(cursor.x - CGFloat(half), cursor.y - CGFloat(half)), inverted: false)
        let roundedScale = DrawingGeometry.cLong(Double(sf).rounded(.toNearestOrAwayFromZero))
        guard let bgra,
              let argb = MagnifierPresentation.squareARGB(fromBGRA: bgra, side: side, scale: 1 < roundedScale ? roundedScale : 1,
                                                          segments: (self.horosROISegments(forMagnifierSide: side, cursor: cursor,
                                                                                           magnification: magnification) as? [[NSNumber]]) ?? []) else {
            return false
        }

        let topLeft = self.convertToBacking(NSMakePoint(NSMinX(frame), NSMaxY(frame)))
        let drawingFrameRect = self.horos_drawingFrameRect
        let x0 = Float(topLeft.x), y0 = Float(drawingFrameRect.size.height - topLeft.y)

        roiLoadIdentity()
        roiEnterPixelGrid(drawingFrameRect.size)
        canvas.drawARGB(argb.mutableBytes.assumingMemoryBound(to: UInt8.self), width: side, height: side, rowBytes: side * 4,
                        x0: CGFloat(x0), y0: CGFloat(y0), x1: CGFloat(x0 + Float(side)), y1: CGFloat(y0),
                        x2: CGFloat(x0), y2: CGFloat(y0 + Float(side)), interpolate: false)
        return true
    }

    /// The magnifier of a measurement: there while a point is placed, without a key,
    /// when its own preference is on. Around the pointer it takes the cursor's
    /// place, as the lens does; off, the cursor stays.
    @objc(horosDrawMeasurementMagnifier)
    public dynamic func horosDrawMeasurementMagnifier() {
        let defaults = UserDefaults.standard
        let corner = defaults.bool(forKey: MagnifierPresentation.cornerDefaultsKey)
        let shown = defaults.bool(forKey: MagnifierPresentation.measurementDefaultsKey) && self.horosPlacingROIPoint()
            && !self.horosShiftHidesMeasurementMagnifier(with: NSEvent.modifierFlags)
            && self.horosDrawSquareMagnifier(inCorner: corner)
        self.horosHideCursor(forMagnifier: shown && !corner)
    }

    /// The lens of the Shift key: the same square magnifier, where the preference puts it.
    @objc(drawMagnifyingLens)
    public dynamic func drawMagnifyingLens() {
        self.horosDrawSquareMagnifier(inCorner: UserDefaults.standard.bool(forKey: MagnifierPresentation.cornerDefaultsKey))
    }

    // MARK: - Pending length

    @objc(drawPendingLength)
    public dynamic func drawPendingLength() {
        guard let first = self.horos_lengthFirstEndpoint as NSDictionary? else { return }
        let pix = self.curDCM
        let point: NSPoint
        if let patientPoint = first.object(forKey: "point") {
            if !HorosVolumeLengthROI.validGeometry(pix) { return }
            point = HorosVolumeLengthROI.projectPoint(patientPoint as? [Any], pix: pix, depth: nil)
        } else {
            // Without patient geometry the point exists on its own image only.
            let sameImage = (first.object(forKey: "imageIndex") as? NSObject)?.isEqual(NSNumber(value: self.curImage)) ?? false
            let sameReference = (first.object(forKey: "reference") as? NSObject)?.isEqual(HorosVolumeLengthROI.reference(for: pix)) ?? false
            if !sameImage || !sameReference { return }
            point = (first.object(forKey: "imagePoint") as? NSValue)?.pointValue ?? .zero
        }
        guard let marker = self.horos_lengthPendingMarker else { return }
        marker.curView = self
        marker.pix = pix
        marker.rect = NSMakeRect(point.x, point.y, 0, 0)
        marker.name = (pix?.stack ?? 0) > 1 ?
            NSLocalizedString("Length: return to thin slices to place the second point", comment: "") :
            NSLocalizedString("Length: select the second point (Esc to cancel)", comment: "")
        marker.draw(self.horos_scaleValue, Float(Double(pix?.pwidth ?? 0) / 2.0), Float(Double(pix?.pheight ?? 0) / 2.0),
                       Float(pix?.pixelSpacingX ?? 0), Float(pix?.pixelSpacingY ?? 0))
        marker.textualBoxLine6 = nil
        marker.textualBoxLine5 = nil
        marker.textualBoxLine4 = nil
        marker.textualBoxLine3 = nil
        marker.textualBoxLine2 = nil
    }

    @objc(showCompleteROILabels:)
    @IBAction public dynamic func showCompleteROILabels(_ sender: Any!) {
        guard let window = self.window else { return }
        var labels: [[String]] = []
        // Snapshot complete fields, independently of compact or overflow rendering.
        for case let roi as ROI in self.horos_curRoiList ?? [] {
            labels.append([roi.textualBoxLine1 ?? "", roi.textualBoxLine2 ?? "", roi.textualBoxLine3 ?? "",
                           roi.textualBoxLine4 ?? "", roi.textualBoxLine5 ?? "", roi.textualBoxLine6 ?? ""])
        }
        ROILabelPresentation.showLabels(labels, inWindow: window)
    }

    // MARK: - The view and its layers

    open override func draw(_ r: NSRect) {
        if !self.drawing { return }

        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        let backingBounds = self.convertToBacking(self.frame) // Retina
        let factor = Double(self.window?.backingScaleFactor ?? 0)

        if Double(self.horos_previousScalingFactor) != factor && factor != 0 {
            let previous = Double(self.horos_previousScalingFactor)
            if previous != 0 {
                self.horos_scaleValue = Float(Double(self.horos_scaleValue) * (factor / previous))
                var origin = self.horos_origin
                origin.x *= CGFloat(factor / previous)
                origin.y *= CGFloat(factor / previous)
                self.horos_origin = origin
            }
            self.horos_previousScalingFactor = Float(factor)

            DCMView.purgeStringTextureCache()

            NotificationCenter.default.post(name: NSNotification.Name.OsirixLabelGLFontChange, object: self)
            NotificationCenter.default.post(name: NSNotification.Name.OsirixGLFontChange, object: self)

            for case let roi as ROI in self.horos_curRoiList ?? [] {
                roi.curView = self
            }
        }

        self.horosUpdateDrawableSize()
        self.drawFrame(backingBounds)
    }

    /// The picture is drawn by Metal into a layer of its own, the first of the
    /// view's layer: the annotation overlay's graphics and text are above it.
    @objc(horosPictureLayer)
    public dynamic func horosPictureLayer() -> CAMetalLayer! {
        let host = self.layer
        var picture = host?.sublayers?.first as? CAMetalLayer
        if picture == nil {
            for sublayer in host?.sublayers ?? [] {
                if let metal = sublayer as? CAMetalLayer {
                    picture = metal
                    metal.removeFromSuperlayer()
                    break
                }
            }
            if picture == nil {
                let layer = CAMetalLayer()
                layer.device = PlanarHostRenderer.device
                layer.pixelFormat = .bgra8Unorm
                layer.framebufferOnly = true
                // The picture is shown with the transaction that shows its graphics
                // and text, so the three never show different frames.
                layer.presentsWithTransaction = true
                layer.isOpaque = true
                layer.anchorPoint = .zero
                layer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
                picture = layer
            }
            host?.insertSublayer(picture!, at: 0)
        }
        return picture
    }

    open override var wantsUpdateLayer: Bool {
        return true
    }

    open override var isOpaque: Bool {
        return true
    }

    open override func updateLayer() {
        self.draw(self.bounds)
    }

    @objc(horosUpdateDrawableSize)
    public dynamic func horosUpdateDrawableSize() {
        if self.layer == nil {
            return
        }
        guard let picture = self.horosPictureLayer() else { return }
        let backingScale = self.window?.backingScaleFactor ?? 0
        let scale = backingScale > 0 ? backingScale : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contentsScale = scale
        picture.frame = self.bounds
        // OpenGL put its bytes on the screen untouched, which is what a layer in the
        // screen's own colour space does, as the overlay's are.
        if let space = self.window?.colorSpace?.cgColorSpace, picture.colorspace !== space {
            picture.colorspace = space
        }
        CATransaction.commit()
        let size = self.convertToBacking(self.bounds.size)
        let width = size.width.rounded(.toNearestOrAwayFromZero), height = size.height.rounded(.toNearestOrAwayFromZero)
        let drawable = CGSize(width: 1 < width ? width : 1, height: 1 < height ? height : 1)
        if !picture.drawableSize.equalTo(drawable) {
            picture.drawableSize = drawable
        }
    }

    // What NSOpenGLView's reshape was called for: a new size.
    open override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        self.horosUpdateDrawableSize()
        // -reshape, which subclasses override.
        self.reshape()
    }

    open override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        self.horosUpdateDrawableSize()
        self.needsDisplay = true
    }

    @objc(subDrawRect:)
    public dynamic func subDraw(_ aRect: NSRect) { // Subclassable, default does nothing.
    }

    @objc(drawRectAnyway:)
    public dynamic func drawRectAnyway(_ aRect: NSRect) { // Subclassable, default does nothing.
    }

    // MARK: - Reference lines

    /// -drawCrossLines:perpendicular:withShift:half:showPoint:, which DCMView+CAPI.m
    /// keeps for its float[2][3] parameter: the line `sft` (6 values).
    @objc(horosDrawCrossLines:perpendicular:withShift:half:showPoint:)
    public dynamic func horosDrawCrossLines(_ sft: UnsafeMutablePointer<Float>!, perpendicular: Bool, withShift shift: Double,
                                            half: Bool, showPoint: Bool) {
        let shifted = DrawingGeometry.shiftedCrossLine(Array(UnsafeBufferPointer(start: sft, count: 6)),
                                                      perpendicular: perpendicular, shift: shift)
        let c = shifted.line, a0 = shifted.a0, a1 = shifted.a1

        let viewPoint = { (sx: Float, sy: Float) -> NSPoint in
            let pix = self.curDCM
            return ViewerReferenceLines.renderedPoint(sliceX: Double(sx), sliceY: Double(sy),
                                                      pixelSpacingX: pix?.pixelSpacingX ?? 0, pixelSpacingY: pix?.pixelSpacingY ?? 0,
                                                      width: Double(pix?.pwidth ?? 0), height: Double(pix?.pheight ?? 0),
                                                      scale: Double(self.horos_scaleValue))
        }

        if showPoint {
            roiEnable(GL_POINT_SMOOTH)
            roiPointSize(Float(12 * (self.window?.backingScaleFactor ?? 0)))

            roiBegin(GL_POINTS)
            let middle = DrawingGeometry.crossLineMiddle(c)
            let mid = viewPoint(middle.x, middle.y)
            roiVertex2f(Float(mid.x), Float(mid.y))
            roiEnd()
        } else {
            roiEnable(GL_LINE_SMOOTH)
            roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
            roiEnable(GL_BLEND)
            roiBegin(GL_LINES)
            let start = viewPoint(c[0], c[1])
            roiVertex2f(Float(start.x), Float(start.y))

            if half {
                roiVertex2f(0, 0)
            } else {
                let end = viewPoint(c[3], c[4])
                roiVertex2f(Float(end.x), Float(end.y))
            }
            roiEnd()
        }

        if perpendicular {
            let thickness = self.horos_sliceFromToThickness
            roiLineWidth(Float(1.0 * (self.window?.backingScaleFactor ?? 0)))
            let p0 = DrawingGeometry.slabEdge(x: c[0], y: c[1], a0: a0, a1: a1, thickness: thickness, sign: 1)
            let p1 = DrawingGeometry.slabEdge(x: c[3], y: c[4], a0: a0, a1: a1, thickness: thickness, sign: 1)
            let plus0 = viewPoint(p0.x, p0.y)
            let plus1 = viewPoint(p1.x, p1.y)
            roiBegin(GL_LINES)
            roiVertex2f(Float(plus0.x), Float(plus0.y))
            roiVertex2f(Float(plus1.x), Float(plus1.y))
            roiEnd()

            let m0 = DrawingGeometry.slabEdge(x: c[0], y: c[1], a0: a0, a1: a1, thickness: thickness, sign: -1)
            let m1 = DrawingGeometry.slabEdge(x: c[3], y: c[4], a0: a0, a1: a1, thickness: thickness, sign: -1)
            let minus0 = viewPoint(m0.x, m0.y)
            let minus1 = viewPoint(m1.x, m1.y)
            roiBegin(GL_LINES)
            roiVertex2f(Float(minus0.x), Float(minus0.y))
            roiVertex2f(Float(minus1.x), Float(minus1.y))
            roiEnd()
        }
    }

    /// -drawCrossLines:perpendicular: on a float[2][3] line, which subclasses
    /// can override.
    private func drawCrossLinesHook(_ line: UnsafeMutablePointer<Float>, perpendicular: Bool) {
        self.arrayMessages.drawCrossLines(line, perpendicular: perpendicular)
    }

    /// The lines where the other viewers' slices cut this one, and the 3D point
    /// they show, in the image's grid; -drawCrossLines: stays the subclasses' hook.
    @objc(horosDrawReferenceLinesScale:)
    public dynamic func horosDrawReferenceLines(scale sf: Float) {
        roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
        roiEnable(GL_BLEND)
        roiEnable(GL_POINT_SMOOTH)
        roiEnable(GL_LINE_SMOOTH)
        roiEnable(GL_POLYGON_SMOOTH)

        let sliceFromTo = self.horos_sliceFromTo!, sliceFromToS = self.horos_sliceFromToS!
        let sliceFromToE = self.horos_sliceFromToE!, sliceFromTo2 = self.horos_sliceFromTo2!

        if DISPLAYCROSSREFERENCELINES != 0 && sliceFromTo[0] != Float.infinity {
            if sliceFromToS[0] != Float.infinity {
                roiColor3f(1.0, 0.6, 0.0)

                roiLineWidth(Float(2.0 * Double(sf)))
                self.drawCrossLinesHook(sliceFromToS, perpendicular: false)

                roiLineWidth(Float(2.0 * Double(sf)))
                self.drawCrossLinesHook(sliceFromToE, perpendicular: false)
            }

            roiColor3f(0.0, 0.6, 0.0)
            roiLineWidth(Float(2.0 * Double(sf)))
            self.drawCrossLinesHook(sliceFromTo, perpendicular: true)

            if sliceFromTo2[0] != Float.infinity {
                roiLineWidth(Float(2.0 * Double(sf)))
                self.drawCrossLinesHook(sliceFromTo2, perpendicular: true)
            }
        }

        let slicePoint3D = self.horos_slicePoint3D!
        if slicePoint3D[0] != Float.infinity {
            let pix = self.curDCM
            let point = DrawingGeometry.slicePoint((slicePoint3D[0], slicePoint3D[1]),
                                                   pixelSpacingX: pix?.pixelSpacingX ?? 0, pixelSpacingY: pix?.pixelSpacingY ?? 0,
                                                   width: pix?.pwidth ?? 0, height: pix?.pheight ?? 0)

            // Across the reference line, when there is one: its unit normal.
            let sliceVector = self.horos_sliceVector!
            let hasLine = sliceFromTo[0] != Float.infinity && (sliceVector[0] != 0 || sliceVector[1] != 0 || sliceVector[2] != 0)
            var a: (Float, Float) = (0, 0)
            if hasLine {
                let normal = DrawingGeometry.crossLineNormal(x0: sliceFromTo[0], y0: sliceFromTo[1], x1: sliceFromTo[3], y1: sliceFromTo[4])
                a = (normal.a0, normal.a1)
            }
            PlanarFrameGraphics.drawSlicePoint(NSMakePoint(CGFloat(point.x), CGFloat(point.y)), across: NSMakePoint(CGFloat(a.0), CGFloat(a.1)),
                                               hasLine: hasLine, pixelSpacingX: pix?.pixelSpacingX ?? 0, pixelSpacingY: pix?.pixelSpacingY ?? 0,
                                               zoom: self.horos_scaleValue, scale: CGFloat(sf))
        }

        roiDisable(GL_LINE_SMOOTH)
        roiDisable(GL_POLYGON_SMOOTH)
        roiDisable(GL_POINT_SMOOTH)
        roiDisable(GL_BLEND)
    }

    // MARK: - The frame

    /// The CLUT bars of a 2D viewer's frame: the image's, and the fused series'
    /// with its own table (the PET one in B/W Inverse mode) and window.
    @objc(horosDrawCLUTBars:scale:)
    public dynamic func horosDrawCLUTBars(_ clutBars: Int, scale sf: Float) {
        let size = self.horos_drawingFrameRect.size
        let curWW = self.horos_curWW
        PlanarFrameGraphics.beginCLUTBars(size: size)
        if clutBars == Int(barOrigin) || clutBars == Int(barBoth) {
            PlanarFrameGraphics.drawCLUTBar(red: self.horos_redTable, green: self.horos_greenTable, blue: self.horos_blueTable, fused: false,
                                            level: self.horos_curWL, width: (self.curDCM?.displayInverted ?? false) ? -curWW : curWW,
                                            precise: curWW < 50, size: size, scale: CGFloat(sf), in: self)
        }

        if let blending = self.horos_blending, clutBars == Int(barFused) || clutBars == Int(barBoth) {
            var bred: UnsafeMutablePointer<UInt8>? = nil, bgreen: UnsafeMutablePointer<UInt8>? = nil, bblue: UnsafeMutablePointer<UInt8>? = nil
            var bwl: Float = 0, bww: Float = 0

            if UserDefaults.standard.string(forKey: "PET Clut Mode") == "B/W Inverse" {
                if DCMView.horos_static_PETredTable == nil {
                    DCMView.computePETBlendingCLUT()
                }

                bred = DCMView.horos_static_PETredTable
                bgreen = DCMView.horos_static_PETgreenTable
                bblue = DCMView.horos_static_PETblueTable
            } else {
                blending.getCLUT(&bred, &bgreen, &bblue)
            }

            blending.getWLWW(&bwl, &bww)
            if blending.curDCM?.displayInverted ?? false { bww = -bww }

            // The labels take the image's window width to choose their decimals.
            PlanarFrameGraphics.drawCLUTBar(red: bred, green: bgreen, blue: bblue, fused: true, level: bwl, width: bww, precise: curWW < 50,
                                            size: size, scale: CGFloat(sf), in: self)
        }
    }

    /// The ROIs' labels, after the view's own text has claimed its place: newest
    /// first, none while a ROI is being drawn or the labels are suppressed. Ends
    /// the frame's record of label rectangles.
    @objc(horosDrawROILabels:)
    public dynamic func horosDrawROILabels(_ is2DViewer: Bool) {
        let roiLock = is2DViewer ? (self.windowController() as? ViewerController)?.roiLock() : nil
        let labelLock = !is2DViewer || (roiLock?.try() ?? false)
        if labelLock {
            let roiSorting = NSSortDescriptor(key: "uniqueID", ascending: false)
            if !self.horos_suppress_labels {
                let labelROIs = NSMutableArray(array: (self.horos_curRoiList as NSArray?) ?? [])
                if let marker = self.horos_lengthPendingMarker { labelROIs.add(marker) }
                let sortedROIs = labelROIs.sortedArray(using: [roiSorting]) as NSArray

                var drawingRoiMode = false
                for case let r as ROI in sortedROIs where r.roImode == Int(ROI_drawing) {
                    drawingRoiMode = true
                }

                if !drawingRoiMode {
                    var i = sortedROIs.count - 1
                    while i >= 0 {
                        if let r = sortedROIs.object(at: i) as? ROI,
                           let exception = drawingTry({ r.drawTextualData() }) {
                            NSLog("drawTextualData ROI Exception : %@", exception)
                        }
                        i -= 1
                    }
                }
            }

            if is2DViewer { roiLock?.unlock() }
        }
        self.horos_rectArray = nil
    }

    @objc(drawFrame:)
    public dynamic func drawFrame(_ aRect: NSRect) {
        let clutBars = Int(CLUTBARS), annotations = Int(self.horos_annotationType)
        var preparedROILabels = false
        var frontMost = false
        let is2DViewer = self.is2DViewer()
        let sf = Float(self.window?.backingScaleFactor ?? 0)

        if is2DViewer {
            frontMost = self.window?.isKeyWindow ?? false
        }

        if !self.horos_firstTimeDisplay && is2DViewer {
            self.horos_firstTimeDisplay = true
            self.updatePresentationStateFromSeries()
        }

        DCMView.horos_static_drawLock = nil

        // The frame's presentation cycle: the overlay and its canvas, the
        // picture in the Metal layer, the notice and the commit that shows them
        // together. The graphics and the subclass hooks below are drawn between.
        let frame = PlanarFrameCycle.begin(in: self, size: aRect.size, scale: CGFloat(sf),
                                           inverted: DCMView.horos_static_gInvertColors && self.stringID != "export")

        if let exception = drawingTry({
            if self.horos_noScale {
                self.scaleValue = 1.0
                self.setOriginX(0, y: 0)
            }

            self.horos_drawingFrameRect = aRect

            let hasImage = self.horos_dcmPixList != nil && self.horos_curImage > -1
            _ = frame.presentPicture(in: self, layer: self.horosPictureLayer(), index: Int(self.horos_curImage),
                                     hasImage: hasImage, whiteBackground: self.whiteBackground)

            if hasImage {
                let noBlending = is2DViewer && !self.horos_isKeyView
                let viewer = self.windowController() as? ViewerController

                frame.imageDrawn()
                // The graphics start from the blending the image left, as they did
                // in OpenGL: off, with the fusion's function when one was drawn.
                roiDisable(GL_BLEND)
                if self.horos_blending != nil && !self.horos_syncOnLocationImpossible && !noBlending {
                    roiBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA)
                } else {
                    roiBlendFunc(GL_ONE, GL_ONE)
                }
                if is2DViewer, let viewer, viewer.highLighted() > 0 {
                    PlanarFrameGraphics.drawHighlight(viewer.highLighted(), inverted: DCMView.horos_static_gInvertColors,
                                                      size: self.horos_drawingFrameRect.size, scale: CGFloat(sf))
                }

                if is2DViewer && AnnotationLevel.shows(.colorBar, level: annotations) {
                    self.horosDrawCLUTBars(clutBars, scale: sf)
                }

                if annotations != Int(annotNone) {
                    let drawingFrameRect = self.horos_drawingFrameRect
                    PlanarFrameGraphics.beginBorders(size: drawingFrameRect.size, xFlipped: self.horos_xFlipped, yFlipped: self.horos_yFlipped)

                    // More than one window: each has a frame in its own colour, the
                    // colour of its series' thumbnails, thick on the key view of the
                    // frontmost one.
                    if ViewerController.numberOf2DViewer() > 1 && is2DViewer && self.stringID == nil &&
                        SeriesListIdentification.showsColors(in: UserDefaults.standard),
                       let viewer, !viewer.fullScreenON() {
                        PlanarFrameGraphics.drawWindowBorder(size: drawingFrameRect.size, scale: CGFloat(sf),
                                                             color: ViewerWindowColors.color(for: viewer),
                                                             active: self.horos_isKeyView && (frontMost || ViewerController.frontMostDisplayed2DViewer(for: self.window?.screen) === viewer))
                    }

                    // A dotted line where the image overflows the view.
                    if DCMView.horos_static_OVERFLOWLINES && is2DViewer && self.stringID == nil {
                        let rotation = self.horos_rotation
                        var dstRect = self.curDCM?.usefulRect(withRotation: rotation, scale: self.horos_scaleValue, xFlipped: self.horos_xFlipped, yFlipped: self.horos_yFlipped) ?? .zero
                        let oo = DCMPix.rotatePoint(self.origin, aroundPoint: NSMakePoint(0, 0), angle: Float(Double(-rotation) * DCMView.horos_static_deg2rad))
                        dstRect.origin = NSMakePoint(drawingFrameRect.size.width / 2 + oo.x - dstRect.size.width / 2,
                                                     drawingFrameRect.size.height / 2 - oo.y - dstRect.size.height / 2)
                        PlanarFrameGraphics.drawOverflow(image: dstRect, size: drawingFrameRect.size, scale: CGFloat(sf))
                    }

                    if (self.horos_imageColumns > 1 || self.horos_imageRows > 1) && is2DViewer && self.stringID == nil {
                        PlanarFrameGraphics.drawTileBorder(size: drawingFrameRect.size, scale: CGFloat(sf),
                                                           key: self.horos_isKeyView && (frontMost || ViewerController.frontMostDisplayed2DViewer(for: self.window?.screen) === viewer))
                    }

                    PlanarFrameGraphics.enterImage(rotation: self.horos_rotation, origin: self.horos_origin, pixelRatio: Float(self.curDCM?.pixelRatio ?? 0))

                    // Draw ROIs
                    var drawROI = false

                    if is2DViewer { drawROI = viewer?.roiLock()?.try() ?? false } else { drawROI = true }

                    if drawROI && AnnotationLevel.shows(.rois, level: annotations) {
                        let resetData = self.horos_imageColumns > 1 || self.horos_imageRows > 1 // For alias ROIs

                        self.horos_rectArray = NSMutableArray(capacity: self.horos_curRoiList?.count ?? 0)

                        // The ROIs are drawn by the canvas, from this state.
                        ROICanvas.current?.resetFrameState()

                        let list = self.horos_curRoiList
                        var i = (list?.count ?? 0) - 1
                        while i >= 0 {
                            // If we are not in the main thread (iChat), we want to be sure to keep our ROIs
                            if let r = list?.object(at: i) as? ROI {
                                if resetData { r.recompute() }
                                r.curView = self
                                let pix = self.curDCM
                                r.draw(self.horos_scaleValue, Float(Double(pix?.pwidth ?? 0) / 2.0), Float(Double(pix?.pheight ?? 0) / 2.0),
                                          Float(pix?.pixelSpacingX ?? 0), Float(pix?.pixelSpacingY ?? 0))
                            }
                            i -= 1
                        }

                        self.drawPendingLength()

                        // let the pluginSDK draw anything it needs to draw, we use a notification for now, but that is nasty style, we really should be calling a method
                        OSIEnvironment.shared()?.drawDCMView(self)

                        // Place text after this frame's fixed annotation bounds are known.
                        preparedROILabels = true
                    }

                    if drawROI && is2DViewer { viewer?.roiLock()?.unlock() }

                    // Draw 2D point cross (used when double-click in 3D panel)
                    // BLUE CROSS
                    if is2DViewer {
                        self.draw2DPointMarker()
                        self.horos_blending?.draw2DPointMarker()
                    }

                    // Draw any Plugin objects. OsirixDrawObjectsNotification handed
                    // plugins the OpenGL context; there is none now, and only
                    // the canvas notification is posted.
                    if let objectsCanvas = ROICanvas.current {
                        let pix = self.curDCM
                        let canvasInfo: [AnyHashable: Any] = [
                            "scaleValue": NSNumber(value: self.horos_scaleValue),
                            "offsetx": NSNumber(value: Float(Double(pix?.pwidth ?? 0) / 2.0)),
                            "offsety": NSNumber(value: Float(Double(pix?.pheight ?? 0) / 2.0)),
                            "spacingX": NSNumber(value: Float(pix?.pixelSpacingX ?? 0)),
                            "spacingY": NSNumber(value: Float(pix?.pixelSpacingY ?? 0)),
                            "canvas": objectsCanvas]
                        NotificationCenter.default.post(name: NSNotification.Name.HorosDrawObjectsCanvas, object: self, userInfo: canvasInfo)
                    }

                    self.subDraw(aRect)
                    self.scaleValue = self.horos_scaleValue

                    // Patient-space marker in both active and inactive viewers. The
                    // surrounding host transform already accounts for pan/zoom/flip/rotation.
                    var patientCross: [Float] = [0, 0, 0]
                    if self.stringID == nil && self.getPatientCrosshairSliceCoordinates(&patientCross), let pix = self.curDCM {
                        PlanarFrameGraphics.drawPatientCrosshair(
                            x: DrawingGeometry.patientCrosshair(slice: patientCross[0], pixelSpacing: pix.pixelSpacingX, size: pix.pwidth, zoom: self.horos_scaleValue),
                            y: DrawingGeometry.patientCrosshair(slice: patientCross[1], pixelSpacing: pix.pixelSpacingY, size: pix.pheight, zoom: self.horos_scaleValue),
                            pixelRatio: Float(pix.pixelRatio), scale: CGFloat(sf))
                    }

                    //** SLICE CUT BETWEEN SERIES - CROSS REFERENCES LINES
                    if is2DViewer && (self.stringID == nil || self.stringID == "export") && !frontMost &&
                        AnnotationLevel.shows(.referenceLines, level: annotations) {
                        self.horosDrawReferenceLines(scale: sf)
                    }

                    // The text's grid, and the ruler in it.
                    let textFrame = self.horos_drawingFrameRect
                    PlanarFrameGraphics.beginText(size: textFrame.size)
                    if AnnotationLevel.shows(.scaleRuler, level: annotations) {
                        var rr = textFrame
                        let screenCaptureRect = self.horos_screenCaptureRect
                        if !NSIsEmptyRect(screenCaptureRect) {
                            rr = screenCaptureRect

                            // We didn't used glTranslate, after glScalef...
                            rr.origin.x -= textFrame.size.width / 2.0
                            rr.origin.y -= textFrame.size.height / 2.0

                            rr.origin.x += rr.size.width / 2.0
                            rr.origin.y += rr.size.height / 2.0
                        } else {
                            rr.origin = NSMakePoint(0, 0)
                        }

                        let pix = self.curDCM
                        PlanarFrameGraphics.drawRuler(rect: rr, size: textFrame.size, pixelSpacingX: pix?.pixelSpacingX ?? 0, pixelSpacingY: pix?.pixelSpacingY ?? 0,
                                                      pixelRatio: pix?.pixelRatio ?? 0, zoom: self.horos_scaleValue, scale: CGFloat(sf))
                    }
                } // Annotation != None

                self.horos_recordAnnotationRects = preparedROILabels
                if let exception = drawingTry({ self.drawTextualData(self.horos_drawingFrameRect, annotations) }) {
                    NSLog("drawTextualData Annotations Exception : %@", exception)
                }

                self.horos_recordAnnotationRects = false
                if preparedROILabels {
                    self.horosDrawROILabels(is2DViewer)
                }

                let drawingFrameRect = self.horos_drawingFrameRect
                if self.horos_repulsorRadius != 0 {
                    roiLoadIdentity() // reset model view matrix to identity (eliminates rotation basically)
                    roiEnterPixelGrid(drawingFrameRect.size) // scale to port per pixel scale, centre to upper left

                    self.drawRepulsorToolArea()
                }

                let start = self.horos_ROISelectorStartPoint, end = self.horos_ROISelectorEndPoint
                if start.x != end.x || start.y != end.y {
                    roiLoadIdentity() // reset model view matrix to identity (eliminates rotation basically)
                    roiEnterPixelGrid(drawingFrameRect.size) // scale to port per pixel scale, centre to upper left

                    self.drawROISelectorRegion()
                }

                if self.showDescriptionInLarge, let box = self.horos_showDescriptionInLargeText {
                    let boxSize = self.convertToBacking(box.frameSize)
                    let r = NSMakeRect(drawingFrameRect.size.width / 2 - boxSize.width / 2, drawingFrameRect.size.height / 2 - boxSize.height / 2,
                                       boxSize.width, boxSize.height)

                    AnnotationOverlay.overlay(for: self).add(box: box, rect: r)
                }
            }

            if self.horos_lensActive {
                self.drawMagnifyingLens()
            } else {
                self.horosDrawMeasurementMagnifier()
            }

            self.drawRectAnyway(aRect)
            frame.drawNotice(in: self, hasImage: self.horos_dcmPixList != nil && self.horos_curImage > -1)
        }) {
            logDrawingException(exception, "-[DCMView drawFrame:]")
        }

        frame.commit(index: Int(self.horos_curImage))

        self.horos_drawingFrameRect = self.convertToBacking(self.frame)

        _ = self._checkHasChanged(true)
    }

    // MARK: - Fonts

    @objc(labelFontSizeMenuItemIsEnabled:)
    public dynamic class func labelFontSizeMenuItemIsEnabled(_ item: NSMenuItem!) -> Bool {
        let size = UserDefaults.standard.float(forKey: "LabelFONTSIZE")
        if item.action == NSSelectorFromString("increaseFontSize:") {
            return size < 60
        }
        if item.action == NSSelectorFromString("decreaseFontSize:") {
            return size > 6
        }
        return true
    }

    @objc(increaseFontSize:)
    public dynamic func increaseFontSize(_ sender: Any!) {
        let defaults = UserDefaults.standard
        if defaults.float(forKey: "LabelFONTSIZE") < 60 {
            defaults.set(defaults.float(forKey: "LabelFONTSIZE") + 1, forKey: "LabelFONTSIZE")
            NotificationCenter.default.post(name: NSNotification.Name.OsirixLabelGLFontChange, object: sender)
        }
    }

    @objc(decreaseFontSize:)
    public dynamic func decreaseFontSize(_ sender: Any!) {
        let defaults = UserDefaults.standard
        if defaults.float(forKey: "LabelFONTSIZE") > 6 {
            defaults.set(defaults.float(forKey: "LabelFONTSIZE") - 1, forKey: "LabelFONTSIZE")
            NotificationCenter.default.post(name: NSNotification.Name.OsirixLabelGLFontChange, object: sender)
        }
    }

    @objc(changeLabelGLFontNotification:)
    public dynamic func changeLabelGLFontNotification(_ note: Notification!) {
        if (self.window?.backingScaleFactor ?? 0) != 0 {
            let defaults = UserDefaults.standard
            var font = NSFont(name: defaults.string(forKey: "LabelFONTNAME") ?? "", size: CGFloat(defaults.float(forKey: "LabelFONTSIZE")))
            if font == nil { font = NSFont.userFixedPitchFont(ofSize: CGFloat(defaults.float(forKey: "LabelFONTSIZE"))) }
            self.horos_labelFont = font

            ROI.setFontHeight(Float(DCMView.size(ofString: "B", forFont: font).height))

            self.needsDisplay = true
        }
    }

    @objc(changeGLFontNotification:)
    public dynamic func changeGLFontNotification(_ note: Notification!) {
        if (self.window?.backingScaleFactor ?? 0) != 0 {
            let defaults = UserDefaults.standard
            var font = NSFont(name: defaults.string(forKey: "FONTNAME") ?? "", size: CGFloat(defaults.float(forKey: "FONTSIZE")))
            if font == nil { font = NSFont(name: "Geneva", size: 14) }
            self.horos_fontGL = font

            self.horos_stringSize = self.convertToBacking(DCMView.size(ofString: "B", forFont: font))

            self.needsDisplay = true
        }
    }

    @objc(changeFont:)
    public dynamic func changeFont(_ sender: Any!) {
        let oldFont = self.horos_fontGL
        let newFont = (sender as AnyObject?)?.perform(NSSelectorFromString("convertFont:"), with: oldFont)?.takeUnretainedValue() as? NSFont

        UserDefaults.standard.set(newFont?.fontName, forKey: "FONTNAME")
        UserDefaults.standard.set(Float(newFont?.pointSize ?? 0), forKey: "FONTSIZE")

        NotificationCenter.default.post(name: NSNotification.Name.OsirixGLFontChange, object: sender)
    }

    // The picture is uploaded when it is drawn: nothing is kept to load.
    @objc(loadTextures)
    public dynamic func loadTextures() {
    }
}
