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
import IsiXROI

/// The ROIs' immediate-mode drawing on the view's canvas (ROICanvas), with
/// the arguments of the OpenGL functions it replaced: each value is rounded
/// to a float where OpenGL took one, so that a ROI draws the same pixels.
/// With no canvas current, nothing is drawn.
enum ROIGL {
    static let points: UInt32 = 0x0000, lines: UInt32 = 0x0001, lineLoop: UInt32 = 0x0002, lineStrip: UInt32 = 0x0003
    static let triangles: UInt32 = 0x0004, polygon: UInt32 = 0x0009
    static let pointSmooth: UInt32 = 0x0B10, lineSmooth: UInt32 = 0x0B20, polygonSmooth: UInt32 = 0x0B41
    static let blend: UInt32 = 0x0BE2, map1Vertex3: UInt32 = 0x0D97
    static let one: UInt32 = 1, srcAlpha: UInt32 = 0x0302, oneMinusSrcAlpha: UInt32 = 0x0303

    static func begin(_ mode: UInt32) { ROICanvas.current?.begin(mode) }
    static func end() { ROICanvas.current?.end() }
    static func vertex2f(_ x: Float, _ y: Float) { ROICanvas.current?.vertex(x: CGFloat(x), y: CGFloat(y)) }
    static func vertex2d(_ x: Double, _ y: Double) { ROICanvas.current?.vertex(x: CGFloat(x), y: CGFloat(y)) }
    static func vertex3f(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.vertex(x: Double(x), y: Double(y), z: Double(z)) }
    static func color3f(_ r: Float, _ g: Float, _ b: Float) { ROICanvas.current?.color(r: CGFloat(r), g: CGFloat(g), b: CGFloat(b), a: 1) }
    static func color4f(_ r: Float, _ g: Float, _ b: Float, _ a: Float) {
        ROICanvas.current?.color(r: CGFloat(r), g: CGFloat(g), b: CGFloat(b), a: CGFloat(a))
    }
    static func lineWidth(_ w: Float) { ROICanvas.current?.lineWidth(CGFloat(w)) }
    static func pointSize(_ s: Float) { ROICanvas.current?.pointSize(CGFloat(s)) }
    static func enable(_ cap: UInt32) { ROICanvas.current?.enable(cap) }
    static func disable(_ cap: UInt32) { ROICanvas.current?.disable(cap) }
    static func blendFunc(_ source: UInt32, _ destination: UInt32) { ROICanvas.current?.blend(source: source, destination: destination) }
    static func loadIdentity() { ROICanvas.current?.loadIdentity() }
    static func pushMatrix() { ROICanvas.current?.pushMatrix() }
    static func popMatrix() { ROICanvas.current?.popMatrix() }
    static func scalef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.scale(x: Double(x), y: Double(y), z: Double(z)) }
    static func translatef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.translate(x: Double(x), y: Double(y), z: Double(z)) }
    static func map1f(_ points: [Float], order: Int) {
        points.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress { ROICanvas.current?.map1(points: base, count: order) }
        }
    }
    static func evalCoord1f(_ u: Float) { ROICanvas.current?.evalCoord(CGFloat(u)) }
}

// How each kind of ROI draws itself on the view's canvas, and writes its label.
extension ROI {

    @objc(drawROI:::::)
    public func draw(_ scaleValue: Float, _ offsetx: Float, _ offsety: Float, _ spacingX: Float, _ spacingY: Float) {
        draw(withScaleValue: scaleValue, offsetX: offsetx, offsetY: offsety, pixelSpacingX: spacingX, pixelSpacingY: spacingY,
             highlightIfSelected: true, thickness: _thickness, prepareTextualData: true)
    }

    /// Draws the ROI with the view's scale and offset; with
    /// `prepareTextualData`, writes its label lines and lays the label out.
    @objc(drawROIWithScaleValue:offsetX:offsetY:pixelSpacingX:pixelSpacingY:highlightIfSelected:thickness:prepareTextualData:)
    public func draw(withScaleValue scaleValue: Float, offsetX offsetx: Float, offsetY offsety: Float, pixelSpacingX spacingX: Float,
                     pixelSpacingY spacingY: Float, highlightIfSelected: Bool, thickness thick: Float, prepareTextualData: Bool) {
        if _hidden { return }
        if roiLock == nil { roiLock = NSRecursiveLock() }
        if _curView == nil && prepareTextualData {
            NSLog("curView == nil! We will not draw this ROI...")
            return
        }
        let lock = roiLock
        lock?.lock()
        defer { lock?.unlock() }

        _textualBoxLine1 = nil; _textualBoxLine2 = nil; _textualBoxLine3 = nil
        _textualBoxLine4 = nil; _textualBoxLine5 = nil; _textualBoxLine6 = nil

        if let e = ROI.objcTry({
            drawShape(scaleValue, offsetx, offsety, spacingX, spacingY, highlightIfSelected, thick, prepareTextualData)
        }) {
            NSLog("drawROIWithScaleValue exception : %@", e)
        }
    }

    /// The colour of the ROI with `alpha`.
    private func setROIColor(_ alpha: Float) {
        ROIGL.color4f(Float(Double(color.red) / 65535.0), Float(Double(color.green) / 65535.0), Float(Double(color.blue) / 65535.0), alpha)
    }

    /// The handles of a selected ROI: red under the pointer or being moved,
    /// magenta near the pointer while drawing, blue otherwise.
    private func drawHandles(_ scaleValue: Float, _ offsetx: Float, _ offsety: Float, _ thick: Float, _ bsf: Float, skipping skip: Set<Int> = [],
                             size: Float) {
        let tempPt = mouseInImage
        ROIGL.color3f(0.5, 0.5, 1.0)
        ROIGL.pointSize(size)
        ROIGL.begin(ROIGL.points)
        for i in 0..<_points.count {
            if skip.contains(i) { continue }
            if mode >= ROI_selected && (i == selectedModifyPoint || i == Int(PointUnderMouse)) {
                ROIGL.color3f(1.0, 0.2, 0.2)
            } else if mode == ROI_drawing && myPoint(i).isNear(to: tempPt, scaleValue / (thick * bsf), viewPixelRatio) {
                ROIGL.color3f(1.0, 0.0, 1.0)
            } else {
                ROIGL.color3f(0.5, 0.5, 1.0)
            }
            ROIGL.vertex2f((myPoint(i).x - offsetx) * scaleValue, (myPoint(i).y - offsety) * scaleValue)
        }
        ROIGL.end()
    }

    /// `(1 * backingScaleFactor + sqrt(thick)) * 3.5 * backingScaleFactor`: the size of a handle.
    private static func handleSize(_ thick: Float, _ bsf: Float) -> Float {
        Float((Double(1 * bsf) + Double(thick).squareRoot()) * 3.5 * Double(bsf))
    }

    private var isSelectedOrDrawing: Bool { mode == ROI_selected || mode == ROI_selectedModify || mode == ROI_drawing }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func drawShape(_ scaleValue: Float, _ offsetx: Float, _ offsety: Float, _ spacingX: Float, _ spacingY: Float,
                           _ highlightIfSelected: Bool, _ thickness: Float, _ prepareTextualData: Bool) {
        var thick = thickness
        let bsf = backingScaleFactor
        if !_selectable { mode = ROI_sleep }
        _pixelSpacingX = Double(spacingX)
        _pixelSpacingY = Double(spacingY)

        guard ROICanvas.current != nil else { return }

        ROIGL.color3f(1.0, 1.0, 1.0)
        ROIGL.enable(ROIGL.pointSmooth)
        ROIGL.enable(ROIGL.lineSmooth)
        ROIGL.enable(ROIGL.polygonSmooth)
        ROIGL.enable(ROIGL.blend)
        ROIGL.blendFunc(ROIGL.srcAlpha, ROIGL.oneMinusSrcAlpha)

        let labelled = { self.isTextualDataDisplayed && prepareTextualData }
        let interpolate = !UserDefaults.standard.bool(forKey: "NOINTERPOLATION")

        switch _type {
        case .tLayerROI:
            if _layerImage != nil {
                autoreleasepool {
                    drawLayer(scaleValue, offsetx, offsety, highlightIfSelected, bsf, interpolate)
                    if labelled() { labelLayer() }
                }
            }

        case .tPlain:
            drawBrush(scaleValue, offsetx, offsety, highlightIfSelected, bsf, interpolate)
            ROIGL.lineWidth(1.0 * bsf)
            ROIGL.color3f(1.0, 1.0, 1.0)
            if labelled() { labelBrush() }

        case .t2DPoint:
            setROIColor(_opacity)
            ROIGL.begin(ROIGL.lineLoop)
            let ox = Double(_rect.origin.x) - Double(offsetx), oy = Double(_rect.origin.y) - Double(offsety)
            for i in 0..<ROI.circleResolution {
                let angle = Float(Double(i * 2) * Double.pi / Double(ROI.circleResolution))
                let x = (8 * cos(Double(angle))).addingProduct(ox, Double(scaleValue))
                if _pixelSpacingX != 0 && _pixelSpacingY != 0 {
                    ROIGL.vertex2f(Float(x), Float((8 * sin(Double(angle)) * _pixelSpacingX / _pixelSpacingY).addingProduct(oy, Double(scaleValue))))
                } else {
                    ROIGL.vertex2f(Float(x), Float((8 * sin(Double(angle))).addingProduct(oy, Double(scaleValue))))
                }
            }
            ROIGL.end()

            if isSelectedOrDrawing && highlightIfSelected {
                ROIGL.color4f(0.5, 0.5, 1.0, _opacity)
            } else {
                setROIColor(_opacity)
            }
            ROIGL.pointSize(Float((1 + Double(thick).squareRoot()) * 3.5 * Double(bsf)))
            ROIGL.begin(ROIGL.points)
            ROIGL.vertex2f(Float(ox * Double(scaleValue)), Float(oy * Double(scaleValue)))
            ROIGL.end()

            ROIGL.lineWidth(1.0 * bsf)
            ROIGL.color3f(1.0, 1.0, 1.0)
            if labelled() { labelPoint() }

        case .tText:
            drawText(scaleValue, offsetx, offsety, highlightIfSelected, bsf)

        case .tMesure, .tArrow:
            if _points.count > 2 { _type = .tOPolygon }
            setROIColor(_opacity)
            ROIGL.lineWidth(thick * bsf)

            if _type == .tArrow {
                thick *= 0.5
                if thick > 5 { thick = 5 }
                drawArrow(scaleValue, offsetx, offsety, thick, bsf)
            } else {
                drawCobbHighlight(scaleValue, offsetx, offsety, thick, bsf)
                ROIGL.begin(ROIGL.lineStrip)
                for case let pt as MyPoint in _points { ROIGL.vertex2f((pt.x - offsetx) * scaleValue, (pt.y - offsety) * scaleValue) }
                ROIGL.end()
                ROIGL.pointSize(thick * bsf)
                ROIGL.begin(ROIGL.points)
                for case let pt as MyPoint in _points { ROIGL.vertex2f((pt.x - offsetx) * scaleValue, (pt.y - offsety) * scaleValue) }
                ROIGL.end()
            }

            if highlightIfSelected {
                ROIGL.color3f(0.5, 0.5, 1.0)
                ROIGL.pointSize(Float(Double(thick).squareRoot() * 3.0 * Double(bsf)))
                ROIGL.begin(ROIGL.points)
                for i in 0..<_points.count {
                    if i == selectedModifyPoint || i == Int(PointUnderMouse) {
                        ROIGL.color3f(1.0, 0.2, 0.2)
                        ROIGL.vertex2f((myPoint(i).x - offsetx) * scaleValue, (myPoint(i).y - offsety) * scaleValue)
                    } else if mode >= ROI_selected {
                        ROIGL.color3f(0.5, 0.5, 1.0)
                        ROIGL.vertex2f((myPoint(i).x - offsetx) * scaleValue, (myPoint(i).y - offsety) * scaleValue)
                    }
                }
                ROIGL.end()
            }

            if _mousePosMeasure != -1 { drawMeasureCursor(scaleValue, offsetx, offsety, thick, bsf) }

            ROIGL.lineWidth(1.0 * bsf)
            ROIGL.color3f(1.0, 1.0, 1.0)
            if labelled() { labelLength() }

        case .tROI:
            setROIColor(_opacity)
            ROIGL.lineWidth(thick * bsf)
            let corners: [(Float, Float)] = {
                let o = _rect.origin, s = _rect.size
                let x0 = Float((Double(o.x) - Double(offsetx)) * Double(scaleValue))
                let y0 = Float((Double(o.y) - Double(offsety)) * Double(scaleValue))
                let x1 = Float((Double(o.x + s.width) - Double(offsetx)) * Double(scaleValue))
                let y1 = Float((Double(o.y + s.height) - Double(offsety)) * Double(scaleValue))
                return [(x0, y0), (x0, y1), (x1, y1), (x1, y0)]
            }()
            ROIGL.begin(ROIGL.lineLoop)
            for (x, y) in corners { ROIGL.vertex2f(x, y) }
            ROIGL.end()
            ROIGL.pointSize(thick * bsf)
            ROIGL.begin(ROIGL.points)
            for (x, y) in corners { ROIGL.vertex2f(x, y) }
            ROIGL.end()
            if isSelectedOrDrawing && highlightIfSelected {
                ROIGL.color3f(0.5, 0.5, 1.0)
                ROIGL.pointSize(ROI.handleSize(thick, bsf))
                ROIGL.begin(ROIGL.points)
                for (x, y) in corners { ROIGL.vertex2f(x, y) }
                ROIGL.end()
            }
            ROIGL.lineWidth(1.0 * bsf)
            ROIGL.color3f(1.0, 1.0, 1.0)
            if labelled() { labelRectangle() }

        case .tOval:
            drawOval(scaleValue, offsetx, offsety, highlightIfSelected, thick, bsf, labelled)

        case .tAxis:
            drawAxis(scaleValue, offsetx, offsety, highlightIfSelected, thick, bsf, labelled)

        case .tTAGT:
            if _points.count == 6 { drawTAGT(scaleValue, offsetx, offsety, highlightIfSelected, thick, bsf, labelled) }

        case .tDynAngle:
            drawDynamicAngle(scaleValue, offsetx, offsety, highlightIfSelected, thick, bsf, labelled)

        case .tCPolygon, .tOPolygon, .tAngle, .tPencil:
            drawPolygon(scaleValue, offsetx, offsety, highlightIfSelected, thick, bsf, labelled)

        default:
            break
        }

        ROIGL.pointSize(1.0 * bsf)
        ROIGL.disable(ROIGL.lineSmooth)
        ROIGL.disable(ROIGL.polygonSmooth)
        ROIGL.disable(ROIGL.pointSmooth)
        ROIGL.disable(ROIGL.blend)
    }

    // MARK: Layer and brush

    private func drawLayer(_ scaleValue: Float, _ offsetx: Float, _ offsety: Float, _ highlightIfSelected: Bool, _ bsf: Float, _ interpolate: Bool) {
        ROIGL.disable(ROIGL.polygonSmooth)
        // The layer's ARGB pixels are kept until something invalidates them.
        if (ctxArray?.count ?? 0) == 0 || mask.buffer == nil { computeLayerPixels() }
        ROIGL.blendFunc(ROIGL.srcAlpha, ROIGL.oneMinusSrcAlpha)

        func onScreen(_ i: Int) -> NSPoint {
            let p = myPoint(i).point
            return NSPoint(x: (Double(p.x) - Double(offsetx)) * Double(scaleValue), y: (Double(p.y) - Double(offsety)) * Double(scaleValue))
        }
        let p1 = onScreen(0), p2 = onScreen(1), p3 = onScreen(2), p4 = onScreen(3)

        if let pixels = mask.buffer, layerPixelsWidth > 0 {
            ROICanvas.current?.drawARGB(pixels, width: Int(layerPixelsWidth), height: Int(layerPixelsHeight), rowBytes: Int(layerPixelsRowBytes),
                                        x0: p1.x, y0: p1.y, x1: p2.x, y1: p2.y, x2: p4.x, y2: p4.y, interpolate: interpolate)
        }
        ROIGL.disable(ROIGL.blend)
        ROIGL.enable(ROIGL.polygonSmooth)

        // The four points of the bounding box.
        if mode == ROI_selected && highlightIfSelected {
            ROIGL.color3f(0.5, 0.5, 1.0)
            ROIGL.pointSize(Float(8.0 * Double(bsf)))
            ROIGL.begin(ROIGL.points)
            for p in [p1, p2, p3, p4] { ROIGL.vertex3f(Float(p.x), Float(p.y), 0) }
            ROIGL.end()
            ROIGL.color3f(1.0, 1.0, 1.0)
        }
    }

    private func drawBrush(_ scaleValue: Float, _ offsetx: Float, _ offsety: Float, _ highlightIfSelected: Bool, _ bsf: Float, _ interpolate: Bool) {
        ROIGL.disable(ROIGL.polygonSmooth)

        // The outline of a selected brush, around its painted pixels.
        if highlightIfSelected && ROI.settings.drawPlainEdge && isSelectedOrDrawing {
            let margin: Int32 = 1
            let newWidth = mask.width + 2 * margin, newHeight = mask.height + 2 * margin
            if textureBufferSelected == nil {
                textureBufferSelected = ROIBrushMask.selectionOutline(of: mask.buffer, width: mask.width, height: mask.height)
            }
            if let outline = textureBufferSelected {
                ROIGL.blendFunc(ROIGL.srcAlpha, ROIGL.oneMinusSrcAlpha)
                ROIGL.color4f(0, 0, 0, 1.0)
                let x0 = Float(mask.upLeftX - margin) - offsetx, y0 = Float(mask.upLeftY - margin) - offsety
                let screenXUpL = x0 * scaleValue, screenYUpL = y0 * scaleValue
                let screenXDr = screenXUpL.addingProduct(Float(newWidth), scaleValue)
                let screenYDr = screenYUpL.addingProduct(Float(newHeight), scaleValue)
                ROICanvas.current?.drawIntensity(outline, width: Int(newWidth), height: Int(newHeight), rowBytes: Int(newWidth),
                                                 x0: CGFloat(screenXUpL), y0: CGFloat(screenYUpL), x1: CGFloat(screenXDr), y1: CGFloat(screenYDr),
                                                 interpolate: interpolate)
            }
        }

        ROIGL.blendFunc(ROIGL.srcAlpha, ROIGL.oneMinusSrcAlpha)
        setROIColor(_opacity)
        let screenXUpL = (Float(mask.upLeftX) - offsetx) * scaleValue
        let screenYUpL = (Float(mask.upLeftY) - offsety) * scaleValue
        let screenXDr = screenXUpL.addingProduct(Float(mask.width), scaleValue)
        let screenYDr = screenYUpL.addingProduct(Float(mask.height), scaleValue)
        if let buffer = mask.buffer {
            ROICanvas.current?.drawIntensity(buffer, width: Int(mask.width), height: Int(mask.height), rowBytes: Int(mask.width),
                                             x0: CGFloat(screenXUpL), y0: CGFloat(screenYUpL), x1: CGFloat(screenXDr), y1: CGFloat(screenYDr),
                                             interpolate: interpolate)
        }
        ROIGL.enable(ROIGL.polygonSmooth)

        if isSelectedOrDrawing && highlightIfSelected && !ROI.settings.drawPlainEdge {
            ROIGL.color3f(0.5, 0.5, 1.0)
            // Smaller points for calcium scoring.
            ROIGL.pointSize(Float((_displayCalciumScoring ? 3.0 : 8.0) * Double(bsf)))
            ROIGL.begin(ROIGL.points)
            ROIGL.vertex3f(screenXUpL, screenYUpL, 0)
            ROIGL.vertex3f(screenXDr, screenYUpL, 0)
            ROIGL.vertex3f(screenXUpL, screenYDr, 0)
            ROIGL.vertex3f(screenXDr, screenYDr, 0)
            ROIGL.end()
        }
    }

    // MARK: Text

    /// A text ROI: its string upright whatever the view's rotation and flips,
    /// at its point.
    private func drawText(_ scaleValue: Float, _ offsetx: Float, _ offsety: Float, _ highlightIfSelected: Bool, _ bsf: Float) {
        let view = self.view
        ROIGL.pushMatrix()
        var ratio: Float = 1
        if _pixelSpacingX != 0 && _pixelSpacingY != 0 { ratio = Float(_pixelSpacingX / _pixelSpacingY) }

        // The identity, which leaves the rotation out; a unit is a backing pixel.
        ROIGL.loadIdentity()
        let frame = view?.drawingFrameRect ?? .zero
        let xFlipped = view?.xFlipped ?? false, yFlipped = view?.yFlipped ?? false
        ROIGL.scalef(Float(2.0 / Double(xFlipped ? -frame.size.width : frame.size.width)),
                     Float(-2.0 / Double(yFlipped ? -frame.size.height : frame.size.height)), 1)
        let origin = view?.origin ?? .zero
        ROIGL.translatef(Float(origin.x), Float(-origin.y), 0)

        let r = Double(ratio), s = Double(scaleValue)
        var centered = _rect, unrotated = _rect
        centered.origin.y -= CGFloat(Double(offsety) + Double(origin.y) * r / s)
        centered.origin.x -= CGFloat(Double(offsetx) - Double(origin.x) / s)

        let turn = Double(-(view?.rotation ?? 0) * ROI.deg2rad)
        let cx = Double(centered.origin.x), cy = Double(centered.origin.y)
        unrotated.origin.x = CGFloat((cy * sin(turn) / r).addingProduct(cx, cos(turn)))
        unrotated.origin.y = CGFloat((cy * cos(turn) / r).addingProduct(-cx, sin(turn)))
        unrotated.origin.y = CGFloat(Double(unrotated.origin.y) * r)
        unrotated.origin.y += CGFloat(Double(offsety) + Double(origin.y) * r / s)
        unrotated.origin.x += CGFloat(Double(offsetx) - Double(origin.x) / s)

        let ux = Double(unrotated.origin.x), uy = Double(unrotated.origin.y)
        let halfWidth = Double(unrotated.size.width) / 2, halfHeight = Double(unrotated.size.height) / 2 / r
        let left = (-halfWidth).addingProduct(ux - Double(offsetx), s)
        let right = halfWidth.addingProduct(ux - Double(offsetx), s)
        let bottom = (-halfHeight).addingProduct((uy - Double(offsety)) / r, s)
        let top = halfHeight.addingProduct((uy - Double(offsety)) / r, s)

        if isSelectedOrDrawing && highlightIfSelected {
            ROIGL.color3f(0.5, 0.5, 1.0)
            ROIGL.pointSize(Float(2.0 * 3 * Double(bsf)))
            ROIGL.begin(ROIGL.points)
            ROIGL.vertex2f(Float(left), Float(bottom))
            ROIGL.vertex2f(Float(left), Float(top))
            ROIGL.vertex2f(Float(right), Float(top))
            ROIGL.vertex2f(Float(right), Float(bottom))
            ROIGL.end()
        }
        ROIGL.lineWidth(1.0 * bsf)

        let tPt = NSPoint(x: left, y: bottom)
        ROIGL.enable(ROIGL.blend)
        ROIGL.blendFunc(ROIGL.srcAlpha, ROIGL.oneMinusSrcAlpha)

        if stringTex == nil { self.name = self.name }

        // Blended on the colour's alpha, as the texture was. The picture is
        // upright however the view is flipped, as the flipped texture was.
        let textFont = stanStringAttrib?[NSAttributedString.Key.font] as? NSFont
        let box = labelBoxColor()
        if let stringTex, let textFont, let box {
            // A text ROI gets the labels' box and lightened colour too.
            let picture = textPicture(stringTex as String, font: textFont)
            if let canvas = ROICanvas.current, let view {
                let a = canvas.devicePoint(x: tPt.x, y: tPt.y)
                let b = canvas.devicePoint(x: tPt.x + CGFloat(picture.pixelWidth), y: tPt.y + CGFloat(picture.pixelHeight))
                let fill = NSRect(x: roiMin(a.x, b.x) - 2, y: roiMin(a.y, b.y) - 2, width: abs(b.x - a.x) + 4, height: abs(b.y - a.y) + 4)
                ROI.textLayer(of: view).addFill(red: box.redComponent * box.alphaComponent, green: box.greenComponent * box.alphaComponent,
                                                blue: box.blueComponent * box.alphaComponent, alpha: box.alphaComponent, rect: fill)
            }
            ROI.overlayText(view, picture, Float(tPt.x), Float(tPt.y),
                            ROILabelContrast.textColor(for: NSColor(deviceRed: CGFloat(Double(color.red) / 65535.0), green: CGFloat(Double(color.green) / 65535.0),
                                                                    blue: CGFloat(Double(color.blue) / 65535.0), alpha: 1), overBox: box),
                            NSColor.black, true)
        } else if let stringTex, let textFont {
            ROI.overlayText(view, textPicture(stringTex as String, font: textFont), Float(tPt.x), Float(tPt.y),
                            NSColor(deviceRed: CGFloat(Double(color.red) / 65535.0), green: CGFloat(Double(color.green) / 65535.0),
                                    blue: CGFloat(Double(color.blue) / 65535.0), alpha: CGFloat(_opacity)),
                            NSColor(deviceRed: 0, green: 0, blue: 0, alpha: CGFloat(_opacity)), true)
        }
        ROIGL.color3f(1.0, 1.0, 1.0)
        ROIGL.popMatrix()
    }

    // MARK: Length and arrow

    private func drawArrow(_ scaleValue: Float, _ offsetx: Float, _ offsety: Float, _ thick: Float, _ bsf: Float) {
        let a = NSPoint(x: CGFloat((myPoint(0).x - offsetx) * scaleValue), y: CGFloat((myPoint(0).y - offsety) * scaleValue))
        let b = NSPoint(x: CGFloat((myPoint(1).x - offsetx) * scaleValue), y: CGFloat((myPoint(1).y - offsety) * scaleValue))
        let spaced = _pixelSpacingX != 0 && _pixelSpacingY != 0

        let slide: Float
        if b.y - a.y == 0 {
            slide = Float(Double(b.x - a.x) / -0.001)
        } else if spaced {
            slide = Float(Double(b.x - a.x) / (Double(b.y - a.y) * (_pixelSpacingY / _pixelSpacingX)))
        } else {
            slide = Float(Double(b.x - a.x) / Double(b.y - a.y))
        }
        let arrowSize = Float(25.0 * (Double(thick * bsf) / 3.0))
        let slope = Float(atan(Double(slide)) / Double(ROI.deg2rad))
        let rising = b.y - a.y > 0

        /// The point from `a` at `angle` degrees, `factor` thicknesses beyond
        /// the head's size, its height stretched as the pixels are; `sign` -1
        /// takes it the other way.
        func point(_ sign: Double, _ angle: Float, _ factor: Float) -> NSPoint {
            let length = arrowSize.addingProduct(thick * bsf, factor)
            let adj = Float(Double(length) * cos(Double(angle * ROI.deg2rad)))
            let op = Float(Double(length) * sin(Double(angle * ROI.deg2rad)))
            let dy = spaced ? Double(op) * _pixelSpacingX / _pixelSpacingY : Double(op)
            return NSPoint(x: Double(a.x) + sign * Double(adj), y: Double(a.y) + sign * dy)
        }

        // The line, from the head's base to the tail.
        ROIGL.lineWidth(thick * 2 * bsf)
        let start = point(rising ? 1 : -1, Float(90 - atan(Double(slide)) / Double(ROI.deg2rad)), 13)
        ROIGL.begin(ROIGL.lineStrip)
        ROIGL.vertex2f(Float(start.x), Float(start.y))
        ROIGL.vertex2f(Float(b.x), Float(b.y))
        ROIGL.end()

        ROIGL.pointSize(thick * 2 * bsf)
        ROIGL.begin(ROIGL.points)
        ROIGL.vertex2f(Float(start.x), Float(start.y))
        ROIGL.vertex2f(Float(b.x), Float(b.y))
        ROIGL.end()

        // The head.
        let aa1: NSPoint, aa2: NSPoint
        if rising {
            aa1 = point(1, (80 - slope).addingProduct(-thick, bsf), 15)
            aa2 = point(1, (100 - slope).addingProduct(thick, bsf), 15)
        } else {
            aa1 = point(1, (260 - slope).addingProduct(-thick, bsf), 15)
            aa2 = point(1, (280 - slope).addingProduct(thick, bsf), 15)
        }
        ROIGL.lineWidth(1.0 * bsf)
        ROIGL.begin(ROIGL.triangles)
        setROIColor(_opacity)
        ROIGL.vertex2f(Float(aa1.x), Float(aa1.y))
        ROIGL.vertex2f(Float(aa2.x), Float(aa2.y))
        ROIGL.vertex2f(Float(a.x), Float(a.y))
        ROIGL.end()
    }

    /// The first of two or more lengths is underlined in yellow when the view
    /// shows the Cobb angle between them.
    private func drawCobbHighlight(_ scaleValue: Float, _ offsetx: Float, _ offsety: Float, _ thick: Float, _ bsf: Float) {
        guard let view, ROI.settings.displayCobbAngle, !_displayCMOrPixels, let roiList = view.curRoiList else { return }
        let index = roiList.index(of: self)
        if index == NSNotFound { return }
        var lengths = 0
        for case let r as ROI in roiList where r.type == .tMesure {
            lengths += 1
            if lengths >= 2 { break }
        }
        if lengths < 2 { return }
        for i in 0..<index where (roiList.object(at: i) as! ROI).type == .tMesure { return }

        ROIGL.color4f(1.0, 1.0, 0.0, 0.5)
        ROIGL.lineWidth(Float(Double(thick) * 3.0 * Double(bsf)))
        ROIGL.begin(ROIGL.lineStrip)
        for case let pt as MyPoint in _points { ROIGL.vertex2f((pt.x - offsetx) * scaleValue, (pt.y - offsety) * scaleValue) }
        ROIGL.end()
        setROIColor(_opacity)
        ROIGL.lineWidth(thick * bsf)
    }

    /// The point a length's cursor in a curved MPR shows on it.
    private func drawMeasureCursor(_ scaleValue: Float, _ offsetx: Float, _ offsety: Float, _ thick: Float, _ bsf: Float) {
        let p0 = myPoint(0), p1 = myPoint(1)
        var pt = NSPoint(x: CGFloat(p0.x), y: CGFloat(p0.y))
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        let theta = Float(atan(Double(dy / dx)))
        var pyth = (dx * dx).addingProduct(dy, dy)
        pyth = Float(Double(pyth).squareRoot())
        let reach = Double(_mousePosMeasure * pyth)
        if dx < 0 {
            pt.x = CGFloat(Double(pt.x).addingProduct(-reach, cos(Double(theta))))
            pt.y = CGFloat(Double(pt.y).addingProduct(-reach, sin(Double(theta))))
        } else {
            pt.x = CGFloat(Double(pt.x).addingProduct(reach, cos(Double(theta))))
            pt.y = CGFloat(Double(pt.y).addingProduct(reach, sin(Double(theta))))
        }
        ROIGL.color3f(1.0, 0.0, 0.0)
        ROIGL.pointSize(ROI.handleSize(thick, bsf))
        ROIGL.begin(ROIGL.points)
        ROIGL.vertex2f(Float((Double(pt.x) - Double(offsetx)) * Double(scaleValue)), Float((Double(pt.y) - Double(offsety)) * Double(scaleValue)))
        ROIGL.end()
    }

    // MARK: Oval

    private func drawOval(_ scaleValue: Float, _ offsetx: Float, _ offsety: Float, _ highlightIfSelected: Bool, _ thick: Float, _ bsf: Float,
                          _ labelled: () -> Bool) {
        setROIColor(_opacity)
        ROIGL.lineWidth(thick * bsf)
        var rrect = _rect
        if rrect.size.height < 0 { rrect.size.height = -rrect.size.height }
        if rrect.size.width < 0 { rrect.size.width = -rrect.size.width }
        let ox = Double(rrect.origin.x), oy = Double(rrect.origin.y), w = Double(rrect.size.width), h = Double(rrect.size.height)
        let s = Double(scaleValue)
        let resol = Int(ROIBrushMask.int32((h + w) * 1.5 * s))

        func outline() {
            for i in 0..<Swift.max(resol, 0) {
                let angle = Float(Double(i * 2) * Double.pi / Double(resol))
                ROIGL.vertex2f(Float((ox.addingProduct(w, cos(Double(angle))) - Double(offsetx)) * s),
                               Float((oy.addingProduct(h, sin(Double(angle))) - Double(offsety)) * s))
            }
        }
        ROIGL.begin(ROIGL.lineLoop)
        outline()
        ROIGL.end()

        ROIGL.pointSize(thick * bsf)
        ROIGL.begin(ROIGL.points)
        outline()
        if UserDefaults.standard.bool(forKey: "drawROICircleCenter") {
            ROIGL.vertex2f(Float((ox - Double(offsetx)) * s), Float((oy - Double(offsety)) * s))
        }
        ROIGL.end()

        if isSelectedOrDrawing && highlightIfSelected {
            ROIGL.color3f(0.5, 0.5, 1.0)
            ROIGL.pointSize(ROI.handleSize(thick, bsf))
            ROIGL.begin(ROIGL.points)
            ROIGL.vertex2f(Float((ox - Double(offsetx) - w) * s), Float((oy - h - Double(offsety)) * s))
            ROIGL.vertex2f(Float((ox - Double(offsetx) - w) * s), Float((oy + h - Double(offsety)) * s))
            ROIGL.vertex2f(Float((ox + w - Double(offsetx)) * s), Float((oy + h - Double(offsety)) * s))
            ROIGL.vertex2f(Float((ox + w - Double(offsetx)) * s), Float((oy - h - Double(offsety)) * s))
            // The centre.
            ROIGL.vertex2f(Float((ox - Double(offsetx)) * s), Float((oy - Double(offsety)) * s))
            ROIGL.end()
        }
        ROIGL.lineWidth(1.0 * bsf)
        ROIGL.color3f(1.0, 1.0, 1.0)
        if labelled() { labelOval(rrect) }
    }

    // MARK: Axis, TAGT and dynamic angle

    /// Removes the points after the fourth as the loop always did: every
    /// other one, as the indices shift.
    private func dropPointsAfterFourth() {
        if _points.count > 3 {
            var i = 4
            while i < _points.count {
                _points.removeObject(at: i)
                i += 1
            }
        }
    }

    private func drawAxis(_ scaleValue: Float, _ offsetx: Float, _ offsety: Float, _ highlightIfSelected: Bool, _ thick: Float, _ bsf: Float,
                          _ labelled: () -> Bool) {
        setROIColor(_opacity)
        ROIGL.lineWidth(mode == ROI_drawing ? thick * 2 * bsf : thick * bsf)
        ROIGL.begin(ROIGL.lineLoop)
        for i in 0..<_points.count {
            ROIGL.vertex2f((myPoint(i).x - offsetx) * scaleValue, (myPoint(i).y - offsety) * scaleValue)
            if i > 2 { break }
        }
        ROIGL.end()
        dropPointsAfterFourth()

        if labelled() { labelNameOnly() }
        if isSelectedOrDrawing && highlightIfSelected {
            drawHandles(scaleValue, offsetx, offsety, thick, bsf, size: ROI.handleSize(thick, bsf))
        }

        // The two axes through the middles of the opposite sides.
        var plot = false
        var t0 = NSPoint.zero, t1 = NSPoint.zero, t2 = NSPoint.zero, t3 = NSPoint.zero
        func onScreen(_ i: Int) -> NSPoint {
            NSPoint(x: CGFloat((myPoint(i).x - offsetx) * scaleValue), y: CGFloat((myPoint(i).y - offsety) * scaleValue))
        }
        if _points.count > 3 {
            t0 = onScreen(0); t1 = onScreen(1); t2 = onScreen(2); t3 = onScreen(3)
            plot = true
        }
        let t01 = NSPoint(x: (t1.x + t0.x) / 2, y: (t1.y + t0.y) / 2)
        let t23 = NSPoint(x: (t3.x + t2.x) / 2, y: (t3.y + t2.y) / 2)
        let a1 = Float(Double(t23.y - t01.y) / Double(t23.x - t01.x))
        let b1 = Float(Double(t01.y).addingProduct(-Double(a1), Double(t01.x)))
        let y1 = Float(Double(t01.y) - 125), y2 = Float(Double(t23.y) + 125)
        let x1 = (y1 - b1) / a1, x2 = (y2 - b1) / a1
        let t03 = NSPoint(x: (t3.x + t0.x) / 2, y: (t3.y + t0.y) / 2)
        let t21 = NSPoint(x: (t1.x + t2.x) / 2, y: (t1.y + t2.y) / 2)
        let a2 = Float(Double(t21.y - t03.y) / Double(t21.x - t03.x))
        let b2 = Float(Double(t03.y).addingProduct(-Double(a2), Double(t03.x)))
        let x3 = Float(Double(t03.x) - 125), x4 = Float(Double(t21.x) + 125)
        let y3 = b2.addingProduct(a2, x3), y4 = b2.addingProduct(a2, x4)
        if plot {
            ROIGL.begin(ROIGL.lineStrip)
            ROIGL.color3f(0.0, 0.0, 1.0)
            ROIGL.vertex2f(x1, y1)
            ROIGL.vertex2f(x2, y2)
            ROIGL.end()
            ROIGL.begin(ROIGL.lineStrip)
            ROIGL.color3f(1.0, 0.0, 0.0)
            ROIGL.vertex2f(x3, y3)
            ROIGL.vertex2f(x4, y4)
            ROIGL.end()

            // The inside, filled, with no border.
            func doubleOnScreen(_ i: Int) -> NSPoint {
                let p = myPoint(i).point
                return NSPoint(x: (Double(p.x) - Double(offsetx)) * Double(scaleValue), y: (Double(p.y) - Double(offsety)) * Double(scaleValue))
            }
            let p1 = doubleOnScreen(0), p2 = doubleOnScreen(1), p3 = doubleOnScreen(2), p4 = doubleOnScreen(3)
            ROIGL.enable(ROIGL.blend)
            ROIGL.disable(ROIGL.polygonSmooth)
            ROIGL.disable(ROIGL.pointSmooth)
            ROIGL.blendFunc(ROIGL.srcAlpha, ROIGL.oneMinusSrcAlpha)
            setROIColor(0.25)
            ROIGL.begin(ROIGL.polygon)
            for p in [p1, p2, p3, p4] { ROIGL.vertex2f(Float(p.x), Float(p.y)) }
            ROIGL.end()
            ROIGL.disable(ROIGL.blend)
        }
        ROIGL.lineWidth(1.0 * bsf)
        ROIGL.color3f(1.0, 1.0, 1.0)
    }

    private func drawTAGT(_ scaleValue: Float, _ offsetx: Float, _ offsety: Float, _ highlightIfSelected: Bool, _ thick: Float, _ bsf: Float,
                          _ labelled: () -> Bool) {
        _ = valid()
        setROIColor(_opacity)
        ROIGL.lineWidth(thick * bsf)
        // B, C, then A, the main line.
        for (from, to) in [(0, 1), (2, 3), (4, 5)] {
            ROIGL.begin(ROIGL.lineStrip)
            ROIGL.vertex2f((myPoint(from).x - offsetx) * scaleValue, (myPoint(from).y - offsety) * scaleValue)
            ROIGL.vertex2f((myPoint(to).x - offsetx) * scaleValue, (myPoint(to).y - offsety) * scaleValue)
            ROIGL.end()
        }
        if labelled() { labelTAGT() }
        if isSelectedOrDrawing && highlightIfSelected {
            drawHandles(scaleValue, offsetx, offsety, thick, bsf, skipping: [0, 2], size: thick * 2 * bsf)
        }
        ROIGL.lineWidth(1.0 * bsf)
        ROIGL.color3f(1.0, 1.0, 1.0)

        // The letters.
        if stanStringAttrib == nil {
            let attributes = NSMutableDictionary()
            if let font = NSFont(name: "Helvetica", size: 14.0) { attributes[NSAttributedString.Key.font] = font }
            attributes[NSAttributedString.Key.foregroundColor] = NSColor.white
            stanStringAttrib = attributes
        }
        guard let letterFont = stanStringAttrib?[NSAttributedString.Key.font] as? NSFont else { return }
        var i = 0
        while i < _points.count {
            let letter: String? = i == 0 ? "B" : i == 2 ? "C" : i == 4 ? "A" : nil
            if let letter {
                let tPt = myPoint(i + 1).point
                ROI.overlayText(view, textPicture(letter, font: letterFont),
                                Float((Double(tPt.x) - Double(offsetx)) * Double(scaleValue)), Float((Double(tPt.y) - Double(offsety)) * Double(scaleValue)),
                                NSColor(deviceRed: 1, green: 1, blue: 0, alpha: 1), NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 1), false)
            }
            i += 2
        }
    }

    private func drawDynamicAngle(_ scaleValue: Float, _ offsetx: Float, _ offsety: Float, _ highlightIfSelected: Bool, _ thick: Float, _ bsf: Float,
                                  _ labelled: () -> Bool) {
        setROIColor(_opacity)
        ROIGL.lineWidth(mode == ROI_drawing ? thick * 2 * bsf : thick * bsf)
        ROIGL.begin(ROIGL.lineStrip)
        for i in 0..<_points.count {
            setROIColor(i == 1 || i == 2 ? 0.1 : _opacity)
            ROIGL.vertex2f((myPoint(i).x - offsetx) * scaleValue, (myPoint(i).y - offsety) * scaleValue)
            if i > 2 { break }
        }
        ROIGL.end()
        dropPointsAfterFourth()

        var angle: Float = 0
        if _points.count > 3 {
            angle = ROIPlanarGeometry.acuteAngle(betweenLine: myPoint(0).point, myPoint(1).point, andLine: myPoint(2).point, myPoint(3).point,
                                                 spacingX: _pixelSpacingX, spacingY: _pixelSpacingY)
        }
        if labelled() { labelDynamicAngle(angle) }
        if isSelectedOrDrawing && highlightIfSelected {
            drawHandles(scaleValue, offsetx, offsety, thick, bsf, size: ROI.handleSize(thick, bsf))
        }
        ROIGL.lineWidth(1.0 * bsf)
        ROIGL.color3f(1.0, 1.0, 1.0)
    }

    // MARK: Polygons, angle and pencil

    private func drawPolygon(_ scaleValue: Float, _ offsetx: Float, _ offsety: Float, _ highlightIfSelected: Bool, _ thick: Float, _ bsf: Float,
                             _ labelled: () -> Bool) {
        setROIColor(_opacity)
        ROIGL.lineWidth(mode == ROI_drawing ? thick * 2 * bsf : thick * bsf)

        guard var splinePoints = self.splinePoints(scaleValue), splinePoints.count >= 1 else { return }
        let ox = Double(offsetx), oy = Double(offsety), s = Double(scaleValue)
        func vertex(_ p: MyPoint) {
            ROIGL.vertex2d((Double(p.x) - ox) * s, (Double(p.y) - oy) * s)
        }
        func vertices() {
            for i in 0..<splinePoints.count { vertex(ROI.point(splinePoints, i)) }
        }

        ROIGL.begin((_type == .tCPolygon || _type == .tPencil) && mode != ROI_drawing ? ROIGL.lineLoop : ROIGL.lineStrip)
        vertices()
        ROIGL.end()

        if _type == .tOPolygon {
            let length = perimeter(ofPoints: splinePoints, closed: false)
            // The first and the last point too far apart: no area, so no closing line either.
            if Double(self.length((splinePoints.object(at: 0) as! MyPoint).point, (splinePoints.lastObject as! MyPoint).point)) < Double(length) / ROI.openPolygonAreaRatio {
                setROIColor(Float(Double(_opacity) / 4.0))
                ROIGL.begin(ROIGL.lineStrip)
                vertex(ROI.point(splinePoints, 0))
                vertex(ROI.point(splinePoints, splinePoints.count - 1))
                ROIGL.end()
                setROIColor(_opacity)
            }
        }

        ROIGL.pointSize(mode == ROI_drawing ? thick * 2 * bsf : thick * bsf)
        ROIGL.begin(ROIGL.points)
        vertices()
        ROIGL.end()

        // The measurements use the sampling of Area, whatever the zoom.
        if labelled() { splinePoints = self.splinePoints() }
        if _type == .tCPolygon || _type == .tPencil {
            if labelled() { labelClosedPolygon(splinePoints) }
        } else if _type == .tOPolygon {
            if labelled() { labelOpenPolygon(splinePoints) }
        } else if _type == .tAngle {
            if _points.count == 3 {
                _displayTextualData = true
                if labelled() { labelAngle() }
            } else {
                _displayTextualData = false
            }
        }

        if isSelectedOrDrawing && highlightIfSelected {
            drawHandles(scaleValue, offsetx, offsety, thick, bsf, size: ROI.handleSize(thick, bsf))
        }
        if PointUnderMouse != -1 && Int(PointUnderMouse) < _points.count {
            ROIGL.color3f(1.0, 0.0, 1.0)
            ROIGL.pointSize(ROI.handleSize(thick, bsf))
            ROIGL.begin(ROIGL.points)
            let p = myPoint(Int(PointUnderMouse))
            ROIGL.vertex2f((p.x - offsetx) * scaleValue, (p.y - offsety) * scaleValue)
            ROIGL.end()
        }
        ROIGL.lineWidth(1.0 * bsf)
        ROIGL.color3f(1.0, 1.0, 1.0)
    }
}
