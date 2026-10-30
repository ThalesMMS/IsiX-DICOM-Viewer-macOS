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
import IsiXROI

// A ROI's label: the lines it shows (its name, its measurement and the
// statistics of the pixels inside it), where it is laid out among the other
// labels of the view, and how it is written on the view's text layer.
extension ROI {

    // MARK: Pictures of text

    /// A picture of a string rasterized as the viewer's text is.
    @objc(textPicture:font:)
    @discardableResult
    func textPicture(_ str: String, font: NSFont) -> AnnotationText {
        return AnnotationText.text(for: str, font: font, scale: view?.roiWindow?.backingScaleFactor ?? 0, cacheToken: textureCacheToken)
    }

    /// A length in centimetres as the labels write it.
    @objc(formattedLength:)
    public class func formattedLength(_ lCm: Float) -> String! {
        LengthPresentation.string(centimetres: Double(lCm))
    }

    /// The size of a text ROI's string.
    @discardableResult
    @objc func textFrameSize() -> NSSize {
        guard let stringTex, let font = stanStringAttrib?[NSAttributedString.Key.font] as? NSFont else { return .zero }
        return textPicture(stringTex as String, font: font).frameSize
    }

    /// Puts a picture whose top left the canvas's current transform takes (x,
    /// y) to on the view's text layer, with its shadow a pixel right and down.
    static func overlayText(_ view: ROIDrawingView?, _ text: AnnotationText?, _ x: Float, _ y: Float, _ textColor: NSColor, _ shadowColor: NSColor, _ blendOnAlpha: Bool) {
        guard let canvas = ROICanvas.current, let view, let text else { return }
        let a = canvas.devicePoint(x: CGFloat(x), y: CGFloat(y))
        let b = canvas.devicePoint(x: CGFloat(x + Float(text.pixelWidth)), y: CGFloat(y + Float(text.pixelHeight)))
        ROI.textLayer(of: view).add(text: text, x: roiMin(a.x, b.x), y: roiMin(a.y, b.y), textColor: textColor, shadowColor: shadowColor,
                                    blendOnAlpha: blendOnAlpha)
    }

    /// The picture of a label line, in the label font. Each ROI keeps the
    /// pictures of its own labels, as it kept their textures.
    @objc(stringTextureForString:)
    @discardableResult
    func stringTexture(for str: String) -> AnnotationText {
        if stringTextureCache == nil {
            let cache = NSCache<NSArray, AnnotationText>()
            cache.countLimit = 50
            stringTextureCache = cache
        }
        let key: NSArray = [str, NSNumber(value: Double(view?.roiWindow?.backingScaleFactor ?? 0)), textureCacheToken]
        if let kept = stringTextureCache?.object(forKey: key) { return kept }

        // ROI layout reads the size before drawing, at the view's current scale.
        let defaults = UserDefaults.standard
        let size = CGFloat(defaults.float(forKey: "LabelFONTSIZE"))
        // A font saved on another Mac may no longer be installed.
        let font = defaults.string(forKey: "LabelFONTNAME").flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.userFixedPitchFont(ofSize: size) ?? NSFont.systemFont(ofSize: size)
        let kept = textPicture(str, font: font)
        stringTextureCache?.setObject(kept, forKey: key)
        return kept
    }

    @objc(maxStringWidth:max:)
    @discardableResult
    func maxStringWidth(_ str: String, max: Int) -> Int {
        if str.isEmpty { return max }
        let width = stringTexture(for: str).pixelWidth
        return width > max ? width : max
    }

    /// Writes a label line at (x, y), `line` lines down.
    @objc(glStr::::)
    public func writeLabelLine(_ str: String!, _ x: Float, _ y: Float, _ line: Float) {
        guard let str, !str.isEmpty else { return }
        let scale = view?.roiWindow?.backingScaleFactor ?? 0
        let lineOffset = Float(Double(line) * (Double(ROI.fontHeight) * Double(scale)))
        let xx = x, yy = y + lineOffset
        let sT = stringTexture(for: str)
        let xc = ROIBrushMask.int32(Double(xx) - 2 * Double(scale))
        let yc = ROIBrushMask.int32(Double(yy - Float(sT.pixelHeight)))

        // Over its box the text is opaque, in the ROI's colour lightened until
        // it reads over the box whatever is beneath.
        if let box = labelBoxColor() {
            ROI.overlayText(view, sT, Float(xc), Float(yc),
                            ROILabelContrast.textColor(for: NSColor(deviceRed: CGFloat(Double(color.red) / 65535.0), green: CGFloat(Double(color.green) / 65535.0),
                                                                    blue: CGFloat(Double(color.blue) / 65535.0), alpha: 1), overBox: box),
                            NSColor.black, false)
            return
        }
        // The picture is premultiplied, so the colour carries the opacity as
        // well as the alpha; premultiplied black is black, so the shadow needs
        // the alpha only.
        ROI.overlayText(view, sT, Float(xc), Float(yc),
                        NSColor(deviceRed: CGFloat(Double(_opacity * Float(color.red)) / 65535.0), green: CGFloat(Double(_opacity * Float(color.green)) / 65535.0),
                                blue: CGFloat(Double(_opacity * Float(color.blue)) / 65535.0), alpha: CGFloat(_opacity)),
                        NSColor(deviceRed: 0, green: 0, blue: 0, alpha: CGFloat(_opacity)), false)
    }

    /// The box behind this ROI's label, or nil when the labels have none.
    @discardableResult
    @objc func labelBoxColor() -> NSColor? {
        let boxOpacity = ROILabelContrast.backgroundOpacity
        if boxOpacity <= 0 { return nil }
        return ROILabelContrast.boxColor(selected: mode != ROI_sleep, opacity: boxOpacity)
    }

    // MARK: Layout

    /// The ROI's outline bounds in the view, which its label avoids.
    @discardableResult
    @objc public func textualDataContourRect() -> NSRect {
        guard let view else { return .zero }
        var vertices: [NSPoint] = []
        if _type == .tPlain {
            // The texture's bounds: no contour is extracted at every frame.
            for x in [mask.upLeftX, mask.downRightX] {
                for y in [mask.upLeftY, mask.downRightY] { vertices.append(NSPoint(x: CGFloat(x), y: CGFloat(y))) }
            }
        } else if _type == .tOval || _type == .tROI {
            let bounds = _type == .tOval
                ? NSRect(x: _rect.origin.x - _rect.size.width, y: _rect.origin.y - _rect.size.height, width: 2 * _rect.size.width, height: 2 * _rect.size.height)
                : _rect
            for x in [bounds.origin.x, bounds.origin.x + bounds.size.width] {
                for y in [bounds.origin.y, bounds.origin.y + bounds.size.height] { vertices.append(NSPoint(x: x, y: y)) }
            }
        } else {
            for case let point as MyPoint in _points { vertices.append(point.point) }
        }
        if vertices.isEmpty { return .zero }
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for vertex in vertices {
            let point = view.convertFromGL2View(vertex)
            if !point.x.isFinite || !point.y.isFinite { return .zero }
            minX = roiMin(minX, point.x)
            maxX = roiMax(maxX, point.x)
            minY = roiMin(minY, point.y)
            maxY = roiMax(maxY, point.y)
        }
        let padding = 3 * (view.roiWindow?.backingScaleFactor ?? 0)
        return NSRect(x: minX - padding, y: minY - padding, width: maxX - minX + 2 * padding, height: maxY - minY + 2 * padding)
    }

    /// The view's frame, from its centre.
    private var labelViewport: NSRect {
        var viewport = view?.drawingFrameRect ?? .zero
        viewport.origin = NSPoint(x: -viewport.size.width / 2, y: -viewport.size.height / 2)
        return viewport
    }

    private var labelPlacedByHand: Bool { offsetTextBox_x != 0 || offsetTextBox_y != 0 }

    /// Where the label goes: near `dRect`, where no other label of the frame
    /// is; recorded among them. `moved` tells whether it is not where it hangs.
    @objc(findAnEmptySpaceForMyRect::)
    @discardableResult
    func findAnEmptySpace(forMyRect dRect: NSRect, _ moved: UnsafeMutablePointer<ObjCBool>) -> NSRect {
        let rectArray = view?.rectArray
        let desired = NSRect(x: dRect.origin.x + 8, y: dRect.origin.y + 8, width: dRect.size.width, height: dRect.size.height)
        let placed = ROILabelPresentation.placeLabelRect(desired, inViewport: labelViewport, avoiding: (rectArray as? [NSValue]) ?? [],
                                                         roiBounds: textualDataContourRect(), manuallyPlaced: labelPlacedByHand)
        moved.pointee = ObjCBool(!ROI.equalRects(desired, placed) || labelPlacedByHand)
        rectArray?.add(NSValue(rect: placed))
        return placed
    }

    /// Whether the label is shown: not for a hidden ROI nor a calcium score,
    /// and, as the preferences say, only for a selected ROI or the one under
    /// the pointer; never for a polygon, pencil or brush being drawn.
    @objc public var isTextualDataDisplayed: Bool {
        if !_displayTextualData { return false }
        if _hidden { return false }
        // No text for a calcium score.
        if _displayCalciumScoring { return false }
        let s = ROI.settings
        var drawTextBox = false
        if !s.textIfSelected || mode == ROI_selected || mode == ROI_selectedModify || mode == ROI_drawing { drawTextBox = true }
        if s.textIfSelected && _mouseOverROI { drawTextBox = true }
        if mode == ROI_selectedModify || mode == ROI_drawing {
            if _type == .tOPolygon || _type == .tCPolygon || _type == .tPencil || _type == .tPlain { drawTextBox = false }
        }
        return drawTextBox
    }

    /// The lines the label shows, and its size: as many lines as there is room
    /// for, once the frame's fixed annotations have their rectangles.
    @discardableResult
    @objc func fitTextualDataToAvailableSpace() -> [String] {
        var drawingLines = renderedTextualLines()
        let viewportLines = drawingLines
        let lineCount = viewportLines.filter { !$0.isEmpty }.count
        let viewport = labelViewport
        let roiContourBounds = textualDataContourRect()
        let scale = Double(view?.roiWindow?.backingScaleFactor ?? 0)
        var budget = lineCount
        while budget >= 1 {
            drawingLines = ROILabelPresentation.fitLines(viewportLines, maximumLineCount: budget)
            var maxWidth = 0
            for text in drawingLines { maxWidth = maxStringWidth(text, max: maxWidth) }
            drawRect.size = NSSize(width: CGFloat(maxWidth + 8), height: CGFloat(Double(Float(budget) * ROI.fontHeight) * scale + 2))
            let candidate = NSRect(x: drawRect.origin.x + 8, y: drawRect.origin.y + 8, width: drawRect.size.width, height: drawRect.size.height)
            if ROILabelPresentation.hasUnoccupiedPlacement(forLabelRect: candidate, inViewport: viewport, avoiding: (view?.rectArray as? [NSValue]) ?? [],
                                                            roiBounds: roiContourBounds, manuallyPlaced: labelPlacedByHand) {
                break
            }
            budget -= 1
        }
        return drawingLines
    }

    /// Writes the label: its box and lines, with a curve from where it hangs
    /// when it was moved away.
    @objc public func drawTextualData() {
        if _hidden {
            drawRect = .zero
            return
        }
        let lines = [_textualBoxLine1, _textualBoxLine2, _textualBoxLine3, _textualBoxLine4, _textualBoxLine5, _textualBoxLine6]
        if lines.allSatisfy({ ($0?.length ?? 0) == 0 }) {
            drawRect = .zero
            return
        }
        if !_displayTextualData {
            drawRect = .zero
            return
        }
        guard let view else { return }
        let drawingLines = fitTextualDataToAvailableSpace()
        var movedFlag: ObjCBool = false
        drawRect = findAnEmptySpace(forMyRect: drawRect, &movedFlag)
        var moved = movedFlag.boolValue
        if _type == .tDynAngle || _type == .tTAGT || _type == .tAxis || _type == .tCPolygon || _type == .tOPolygon || _type == .tPencil { moved = true }

        let scale = view.roiWindow?.backingScaleFactor ?? 0
        let frame = view.drawingFrameRect
        if moved && !view.suppressLabels && self.isTextualDataDisplayed {
            // The curve from where the label hangs.
            var anchor = originAnchor
            if _type == .tPlain {
                anchor = view.convertFromGL2View(_textNameOnly ? textureLabelPoint()
                    : NSPoint(x: CGFloat(mask.downRightX - mask.width / 2), y: CGFloat(mask.downRightY - mask.height / 2)))
            }
            guard ROICanvas.current != nil else { return }
            ROIGL.loadIdentity()
            ROIGL.scalef(Float(2.0 / Double(frame.size.width)), Float(-2.0 / Double(frame.size.height)), 1)

            let endpoint = NSPoint(x: roiMin(roiMax(anchor.x, drawRect.origin.x), drawRect.origin.x + drawRect.size.width),
                                   y: roiMin(roiMax(anchor.y, drawRect.origin.y), drawRect.origin.y + drawRect.size.height))
            let control: [Float] = [Float(endpoint.x), Float(endpoint.y), 0,
                                    Float((endpoint.x + anchor.x) / 2), Float((endpoint.y + anchor.y) / 2), 0,
                                    Float(anchor.x), Float(anchor.y), 0]
            ROIGL.lineWidth(Float(3.0 * Double(scale)))
            if mode == ROI_sleep { ROIGL.color4f(0, 0, 0, 0) } else { ROIGL.color4f(0.3, 0, 0, 0) }
            ROIGL.map1f(control, order: 3)
            ROIGL.enable(ROIGL.map1Vertex3)
            ROIGL.begin(ROIGL.lineStrip)
            for i in 0...30 { ROIGL.evalCoord1f(Float(Double(Float(i)) / 30.0)) }
            ROIGL.end()
            ROIGL.disable(ROIGL.map1Vertex3)

            ROIGL.lineWidth(Float(1.0 * Double(scale)))
            ROIGL.color4f(1.0, 1.0, 1.0, 0.5)
            ROIGL.map1f(control, order: 3)
            ROIGL.enable(ROIGL.map1Vertex3)
            ROIGL.begin(ROIGL.lineStrip)
            for i in 0...30 { ROIGL.evalCoord1f(Float(Double(Float(i)) / 30.0)) }
            ROIGL.end()
            ROIGL.disable(ROIGL.map1Vertex3)
            view.applyImageTransformation()
        }

        if self.isTextualDataDisplayed {
            if _type != .tText {
                guard let canvas = ROICanvas.current else { return }
                ROIGL.loadIdentity()
                ROIGL.enable(ROIGL.blend)
                ROIGL.blendFunc(ROIGL.one, ROIGL.oneMinusSrcAlpha)
                let sf = Float(scale)
                ROIGL.scalef(Float(2.0 / Double(frame.size.width)), Float(-2.0 / Double(frame.size.height)), 1)

                // The box is added to what is beneath it through (ONE,
                // ONE_MINUS_SRC_ALPHA), premultiplied. It goes with the
                // label's text, above the graphics. Switched off, a selected
                // label's box is the colour with no alpha it always was.
                let a = canvas.devicePoint(x: drawRect.origin.x, y: drawRect.origin.y - 1)
                let b = canvas.devicePoint(x: drawRect.origin.x + drawRect.size.width, y: drawRect.origin.y + drawRect.size.height)
                let boxRect = NSRect(x: roiMin(a.x, b.x), y: roiMin(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                if let box = labelBoxColor() {
                    ROI.textLayer(of: view).addFill(red: box.redComponent * box.alphaComponent, green: box.greenComponent * box.alphaComponent,
                                                    blue: box.blueComponent * box.alphaComponent, alpha: box.alphaComponent, rect: boxRect)
                } else if mode != ROI_sleep {
                    ROI.textLayer(of: view).addFill(red: 0.3, green: 0, blue: 0, alpha: 0, rect: boxRect)
                }

                let tPt = NSPoint(x: Double(drawRect.origin.x) + Double(4 * sf), y: Double(drawRect.origin.y) + Double((2 * sf).addingProduct(ROI.fontHeight, sf)))
                var line: Int = 0
                for text in drawingLines {
                    writeLabelLine(text, Float(tPt.x), Float(tPt.y), Float(line))
                    if !text.isEmpty { line += 1 }
                }
                ROIGL.disable(ROIGL.blend)
                view.applyImageTransformation()
            }
        } else {
            drawRect = .zero
        }
    }

    // MARK: Lines

    /// The lines as the label shows them: wrapped to the view's width, and as
    /// many as its height holds. The lines themselves and the exports stay complete.
    @discardableResult
    @objc func renderedTextualLines() -> [String] {
        let defaults = UserDefaults.standard
        let size = CGFloat(defaults.float(forKey: "LabelFONTSIZE"))
        let font = defaults.string(forKey: "LabelFONTNAME").flatMap { NSFont(name: $0, size: size) }
            ?? NSFont.userFixedPitchFont(ofSize: size) ?? NSFont.systemFont(ofSize: size)
        let scale = view?.roiWindow?.backingScaleFactor ?? 0
        if scale <= 0 { return displayedTextualLines() }
        let frame = view?.drawingFrameRect ?? .zero
        // A picture carries 8 points of padding across, and the box an inset.
        let width = frame.size.width / scale - 20
        let wrapped = ROILabelPresentation.wrapLines(displayedTextualLines(), font: font, maximumWidth: width)
        // The height in backing pixels, the border included, as prepareTextualData counts it.
        let height = frame.size.height
        if ROI.fontHeight <= 0 || !height.isFinite { return wrapped }
        let lines = Swift.max(0, Int(((height - 2) / (CGFloat(ROI.fontHeight) * scale)).rounded(.down)))
        return ROILabelPresentation.fitLines(wrapped, maximumLineCount: lines)
    }

    /// A segment of a textual box line: see ROILabelPresentation.text(ofSegments:hiding:).
    static func labelSegment(_ kind: String, _ text: String?) -> [String] {
        [kind, text ?? ""]
    }

    /// Writes the complete line, and keeps its segments for
    /// displayedTextualLines(), which leaves out the statistics whose check is
    /// off in the Viewers pane.
    @objc(setTextualBoxLine:segments:)
    func setTextualBoxLine(_ line: Int32, segments: [[String]]) {
        let text = ROILabelPresentation.text(ofSegments: segments, hiding: []) as NSString
        switch line {
        case 2: _textualBoxLine2 = text
        case 3: _textualBoxLine3 = text
        case 4: _textualBoxLine4 = text
        case 5: _textualBoxLine5 = text
        case 6: _textualBoxLine6 = text
        default: return
        }
        let all = NSMutableDictionary(dictionary: textualBoxSegments ?? [:])
        all[NSNumber(value: line)] = segments
        textualBoxSegments = all.copy() as? NSDictionary
    }

    @objc(setTextualBoxLine:area:width:height:)
    func setTextualBoxLine(_ line: Int32, area: String, width: String, height: String) {
        setTextualBoxLine(line, segments: [ROI.labelSegment("Area", area),
                                           ROI.labelSegment("WH", String(format: NSLocalizedString("(W: %@ H: %@)", comment: "W = Width, H = Height"), width, height))])
    }

    /// The mean, standard deviation, sum and median line, then the minimum
    /// and maximum line, of the image or, with `fused`, of the fused image.
    @objc(setStatisticsLines:mean:sdev:sum:median:min:max:skewness:kurtosis:unit:fused:)
    func setStatisticsLines(_ line: Int32, mean: Float, sdev: Float, sum: Float, median: Double, min: Float, max: Float,
                            skewness: Float, kurtosis: Float, unit: String, fused: Bool) {
        var values: [[String]] = [], range: [[String]] = []
        if fused {
            let prefix = ROI.labelSegment(ROILabelPresentation.prefixKind, NSLocalizedString("Fused Image", comment: "Names the ROI label lines of the fused image's statistics"))
            values.append(prefix)
            range.append(prefix)
        }
        let medianText = median.isFinite ? String(format: "%0.3f", median) : NSLocalizedString("N/A", comment: "")
        values.append(ROI.labelSegment("Mean", String(format: NSLocalizedString("Mean: %0.3f%@", comment: "ROI label statistic"), Double(mean), unit)))
        values.append(ROI.labelSegment("SDev", String(format: NSLocalizedString("SDev: %0.3f%@", comment: "ROI label statistic"), Double(sdev), unit)))
        values.append(ROI.labelSegment("Sum", String(format: NSLocalizedString("Sum: %0.0f%@", comment: "ROI label statistic"), Double(sum), unit)))
        values.append(ROI.labelSegment("Median", String(format: NSLocalizedString("Median: %@%@", comment: "ROI label statistic"), medianText, unit)))
        range.append(ROI.labelSegment("Min", String(format: NSLocalizedString("Min: %0.3f%@", comment: "ROI label statistic"), Double(min), unit)))
        range.append(ROI.labelSegment("Max", String(format: NSLocalizedString("Max: %0.3f%@", comment: "ROI label statistic"), Double(max), unit)))
        if skewness != 0 || kurtosis != 0 {
            range.append(ROI.labelSegment("Shape", String(format: NSLocalizedString("Skewness: %0.3f Kurtosis: %0.3f", comment: ""), Double(skewness), Double(kurtosis))))
        }
        setTextualBoxLine(line, segments: values)
        setTextualBoxLine(line + 1, segments: range)
    }

    /// The lines without the statistics whose check is off. A line keeps its
    /// complete text when it was written otherwise since its segments were.
    @discardableResult
    @objc func linesWithoutHiddenStatistics(_ lines: [String]) -> [String] {
        let hidden = ROILabelPresentation.hiddenStatistics()
        guard let segmentsByLine = textualBoxSegments, !hidden.isEmpty, segmentsByLine.count > 0 else { return lines }
        var result = lines
        for case let (line as NSNumber, segments as [[String]]) in segmentsByLine {
            let index = line.intValue - 1
            if index < 0 || index >= result.count { continue }
            if !(result[index] as NSString).isEqual(to: ROILabelPresentation.text(ofSegments: segments, hiding: [])) { continue }
            result[index] = ROILabelPresentation.text(ofSegments: segments, hiding: hidden)
        }
        return result
    }

    /// The lines the label shows: the primary measurement only, when the
    /// preferences ask for it; the complete lines otherwise.
    @discardableResult
    @objc func displayedTextualLines() -> [String] {
        let full = [_textualBoxLine1, _textualBoxLine2, _textualBoxLine3, _textualBoxLine4, _textualBoxLine5, _textualBoxLine6]
            .map { ($0 ?? "") as String }
        if ROI.settings.textNameOnly || _textNameOnly { return full }
        if !UserDefaults.standard.bool(forKey: "ROIPRIMARYMEASUREMENTONLY") { return linesWithoutHiddenStatistics(full) }

        let primary: NSString?
        switch _type {
        case .tOPolygon:
            primary = _textualBoxLine5
        case .tMesure, .tAngle, .tOval, .tROI, .tCPolygon, .tPencil, .tPlain:
            primary = _textualBoxLine2
        default:
            return linesWithoutHiddenStatistics(full)
        }
        if let compact = ROILabelPresentation.compactMeasurement(primary as String?, primaryAngle: _type == .tAngle) {
            return [compact]
        }
        return linesWithoutHiddenStatistics(full)
    }

    /// The label's size, and where it hangs: at `tPt`, offset by hand, or at
    /// the lowest point of a polygon.
    @objc(prepareTextualData:)
    func prepareTextualData(_ point: NSPoint) {
        let view = self.view
        func toView(_ p: NSPoint) -> NSPoint { view?.convertFromGL2View(p) ?? .zero }
        var ctPt = point
        var tPt = toView(ctPt)
        originAnchor = tPt
        ctPt.x += CGFloat(offsetTextBox_x)
        ctPt.y += CGFloat(offsetTextBox_y)
        tPt = toView(ctPt)
        drawRect.origin = tPt

        var line = 0, maxWidth = 0
        for text in renderedTextualLines() {
            maxWidth = maxStringWidth(text, max: maxWidth)
            if !text.isEmpty { line += 1 }
        }
        let scale = Double(view?.roiWindow?.backingScaleFactor ?? 0)
        drawRect.size.height = CGFloat(Double(Float(line) * ROI.fontHeight) * scale + 2)
        drawRect.size.width = CGFloat(maxWidth + 8)

        if _type == .tDynAngle || _type == .tAxis || _type == .tTAGT || _type == .tCPolygon || _type == .tOPolygon || _type == .tPencil {
            if _points.count > 0 {
                var ymin = myPoint(0).y
                tPt = NSPoint(x: CGFloat(myPoint(0).x), y: CGFloat(myPoint(0).y))
                for i in 0..<_points.count where myPoint(i).y > ymin {
                    ymin = myPoint(i).y
                    tPt = NSPoint(x: CGFloat(myPoint(i).x), y: CGFloat(myPoint(i).y))
                }
                ctPt = tPt
                originAnchor = toView(ctPt)
                tPt = ctPt
                tPt.x += CGFloat(offsetTextBox_x)
                tPt.y += CGFloat(offsetTextBox_y)
                drawRect.origin = toView(tPt)
            }
        }
    }

    // MARK: What each kind of ROI says

    /// The first line: the name, unless the ROI is unnamed.
    var labelName: NSString? {
        guard let name = _name else { return nil }
        if name.isEqual(to: "Unnamed") || name.isEqual(to: NSLocalizedString("Unnamed", comment: "")) { return nil }
        return name
    }

    /// " HU ", " SUV ": the unit of an image's values in the label.
    static func pixelUnit(of pix: DCMPix?) -> String {
        if pix?.suvConverted == true {
            return String(format: " %@ ", NSLocalizedString("SUV", comment: "SUV = Standard Uptake Value"))
        }
        return String(format: " %@ ", (pix?.rescaleType ?? "(null)") as NSString)
    }

    /// Whether the ROI's image has ultrasound regions: not without an image.
    var hasUltrasoundRegions: Bool { (self.pix as DCMPix?)?.hasUSRegions() ?? false }

    /// The ultrasound regions of the ROI's image, read by message as the
    /// Objective-C ROI read them, whatever the class of the objects that answer.
    var ultrasoundRegions: [USRegion] {
        guard let regions = (self.pix as DCMPix?)?.usRegions else { return [] }
        return regions.map { unsafeBitCast($0 as AnyObject, to: USRegion.self) }
    }

    /// Whether the rectangle from `a` to `b` lies in a 2D region of the ROI's
    /// ultrasound image; its area is then in the region's units.
    func liesIn2DUltrasoundRegion(_ a: NSPoint, _ b: NSPoint) -> Bool {
        guard hasUltrasoundRegions else { return false }
        var inside = false
        for region in ultrasoundRegions where !inside && region.regionSpatialFormat == 1 {
            // A 2D spatial format.
            let ax = ROIBrushMask.int32(Double(a.x)), ay = ROIBrushMask.int32(Double(a.y))
            let bx = ROIBrushMask.int32(Double(b.x)), by = ROIBrushMask.int32(Double(b.y))
            inside = ax >= region.regionLocationMinX0 && ax <= region.regionLocationMaxX1 && ay >= region.regionLocationMinY0 && ay <= region.regionLocationMaxY1
                && bx >= region.regionLocationMinX0 && bx <= region.regionLocationMaxX1 && by >= region.regionLocationMinY0 && by <= region.regionLocationMaxY1
        }
        return inside
    }

    /// Whether the area is in mm2, from the pixel spacing or a 2D ultrasound region.
    func areaIsCalibrated(insideUltrasoundRegion inside: Bool) -> Bool {
        inside || (_pixelSpacingX != 0 && _pixelSpacingY != 0 && !hasUltrasoundRegions)
    }

    /// The area line, in µm2, mm2 or cm2 by size, of `area` square pixels.
    func areaText(_ area: Float) -> String {
        let a = Double(area) * _pixelSpacingX * _pixelSpacingY
        if a < 1.0 {
            return String(format: NSLocalizedString("Area: %0.1f %cm\u{00B2}", comment: ""), a * 1000000.0, Int32(0xB5))
        } else if a / 100.0 < 1.0 {
            return String(format: NSLocalizedString("Area: %0.3f mm\u{00B2}", comment: ""), a)
        }
        return String(format: NSLocalizedString("Area: %0.3f cm\u{00B2}", comment: ""), a / 100.0)
    }

    /// The fused image's statistics, for a ROI drawn on the view's blended image.
    func fusedStatistics(_ blendedROI: ROI, _ blendedPix: DCMPix) {
        blendedPix.computeROI(blendedROI, &Brmean, &Brtotal, &Brdev, &Brmin, &Brmax, &Brskewness, &Brkurtosis)
        Brmedian = blendedROI.median
    }

    /// The fused image's statistics of the polygon through the ROI's points,
    /// carried over to the blended view.
    func fusedPolygonStatistics(_ view: ROIDrawingView, _ blendingView: ROIDrawingView, _ blendedPix: DCMPix) {
        let blendedROI: ROI = ROI(type: .tCPolygon, Float(blendedPix.pixelSpacingX), Float(blendedPix.pixelSpacingY),
                                  DCMPix.originCorrected(accordingToOrientation: blendedPix))
        let pts = NSMutableArray(array: self.points.map { $0 as! [Any] } ?? [], copyItems: true)
        for case let p as MyPoint in pts { p.point = view.convertFromGL2GL(p.point, toView: blendingView) }
        blendedROI.points = pts
        fusedStatistics(blendedROI, blendedPix)
    }

    func labelLayer() {
        let tPt = lowerRightPoint()
        _textualBoxLine1 = labelName
        prepareTextualData(tPt)
    }

    func labelBrush() {
        let tPt = _textNameOnly ? textureLabelPoint() : lowerRightPoint()
        _textualBoxLine1 = labelName
        if _textNameOnly {
            // The name alone: no statistics, so nothing is computed.
            _textualBoxLine2 = nil; _textualBoxLine3 = nil; _textualBoxLine4 = nil; _textualBoxLine5 = nil; _textualBoxLine6 = nil
        } else if !ROI.settings.textNameOnly {
            if rtotal == -1 { computeStatistics(of: viewImage) }
            let area = plainArea()
            if !_displayCalciumScoring {
                let inside = liesIn2DUltrasoundRegion(NSPoint(x: CGFloat(mask.upLeftX), y: CGFloat(mask.upLeftY)),
                                                      NSPoint(x: CGFloat(mask.downRightX), y: CGFloat(mask.downRightY)))
                if areaIsCalibrated(insideUltrasoundRegion: inside) {
                    setTextualBoxLine(2, segments: [ROI.labelSegment("Area", areaText(area))])
                } else {
                    setTextualBoxLine(2, segments: [ROI.labelSegment("Area", String(format: NSLocalizedString("Area: %0.3f pix2", comment: ""), Double(area)))])
                }
                setStatisticsLines(3, mean: rmean, sdev: rdev, sum: rtotal, median: self.median, min: rmin, max: rmax, skewness: rskewness, kurtosis: rkurtosis,
                                   unit: ROI.pixelUnit(of: self.pix), fused: false)
            } else {
                _textualBoxLine2 = String(format: NSLocalizedString("Calcium Score: %0.1f", comment: ""), Double(calciumScore())) as NSString
                _textualBoxLine3 = String(format: NSLocalizedString("Calcium Volume: %0.1f", comment: ""), Double(calciumVolume())) as NSString
                _textualBoxLine4 = String(format: NSLocalizedString("Calcium Mass: %0.1f", comment: ""), Double(calciumMass())) as NSString
            }
            if let view, let blendingView = view.roiBlendingView, let blendedPix = blendingView.curDCM {
                if let blendedROI = copyROI(with: nil) {
                    blendedROI.pix = blendedPix
                    blendedROI.setOriginAndSpacing(Float(blendedPix.pixelSpacingX), Float(blendedPix.pixelSpacingY),
                                                   DCMPix.originCorrected(accordingToOrientation: blendedPix))
                    fusedStatistics(blendedROI, blendedPix)
                }
                setStatisticsLines(5, mean: Brmean, sdev: Brdev, sum: Brtotal, median: Brmedian, min: Brmin, max: Brmax, skewness: Brskewness,
                                   kurtosis: Brkurtosis, unit: ROI.pixelUnit(of: blendedPix), fused: true)
            }
        }
        prepareTextualData(tPt)
    }

    func labelPoint() {
        let tPt = lowerRightPoint()
        _textualBoxLine1 = labelName
        if !ROI.settings.textNameOnly {
            if rtotal == -1 { computeStatistics(of: viewImage) }
            if let view, let blendingView = view.roiBlendingView, let blendedPix = blendingView.curDCM {
                let blendedROI: ROI = ROI(type: _type, Float(blendedPix.pixelSpacingX), Float(blendedPix.pixelSpacingY),
                                          DCMPix.originCorrected(accordingToOrientation: blendedPix))
                var blendedRect = self.rect
                blendedRect.origin = view.convertFromGL2GL(blendedRect.origin, toView: blendingView)
                blendedROI.rect = blendedRect
                // The point's own skewness and kurtosis receive the fused image's, as they always did.
                blendedPix.computeROI(blendedROI, &Brmean, &Brtotal, &Brdev, &Brmin, &Brmax, &rskewness, &rkurtosis)
                Brmedian = blendedROI.median
            }

            // Ultrasound regions: an M-mode or spectral region gives the point its units.
            var roiPosXValue = 0.0, roiPosYValue = 0.0
            var unitsXCode: Int32 = 0, unitsYCode: Int32 = 0
            var inside = false
            var referenceX = false, referenceY = false
            if hasUltrasoundRegions {
                for region in ultrasoundRegions where !inside && (region.regionSpatialFormat == 2 || region.regionSpatialFormat == 3) {
                    let x = ROIBrushMask.int32(Double(_rect.origin.x)), y = ROIBrushMask.int32(Double(_rect.origin.y))
                    inside = x >= region.regionLocationMinX0 && x <= region.regionLocationMaxX1 && y >= region.regionLocationMinY0 && y <= region.regionLocationMaxY1
                    if inside {
                        unitsXCode = region.physicalUnitsXDirection
                        referenceX = region.isReferencePixelX0Present
                        if referenceX {
                            roiPosXValue = (Double(_rect.origin.x) - Double(region.regionLocationMinX0 &+ region.referencePixelX0) + region.refPixelPhysicalValueX)
                                * region.physicalDeltaX
                        }
                        unitsYCode = region.physicalUnitsYDirection
                        referenceY = region.isReferencePixelY0Present
                        if referenceY {
                            let fromReference = Double(region.regionLocationMinY0 &+ region.referencePixelY0) - Double(_rect.origin.y) + region.refPixelPhysicalValueY
                            // M-mode measures down, spectral up.
                            roiPosYValue = region.regionSpatialFormat == 2 ? -fromReference * abs(region.physicalDeltaY) : fromReference * abs(region.physicalDeltaY)
                        }
                    }
                }
            }

            _textualBoxLine2 = String(format: NSLocalizedString("Value: %0.3f%@", comment: ""), Double(rmean), ROI.pixelUnit(of: self.pix)) as NSString
            if Brtotal != -1 {
                let blendedPix = view?.roiBlendingView?.curDCM
                _textualBoxLine3 = String(format: NSLocalizedString("Fused Image Value: %0.3f%@", comment: ""), Double(Brmean), ROI.pixelUnit(of: blendedPix)) as NSString
            }

            if inside {
                // (0018,6024) and (0018,6026) are independent: each axis answers for itself.
                let unitsX = ROIUltrasoundUnits.name(of: unitsXCode), unitsY = ROIUltrasoundUnits.name(of: unitsYCode)
                let text: String
                if !referenceX && referenceY {
                    text = String(format: NSLocalizedString("2D Pos: X:n/a %@ Y:%0.3f %@", comment: ""), unitsX, roiPosYValue, unitsY)
                } else if referenceX && !referenceY {
                    text = String(format: NSLocalizedString("2D Pos: X:%0.3f %@ Y:n/a %@", comment: ""), roiPosXValue, unitsX, unitsY)
                } else if !referenceX && !referenceY {
                    text = String(format: NSLocalizedString("2D Pos: X:n/a %@ Y:n/a %@", comment: ""), unitsX, unitsY)
                } else {
                    text = String(format: NSLocalizedString("2D Pos: X:%0.3f %@ Y:%0.3f %@", comment: ""), roiPosXValue, unitsX, roiPosYValue, unitsY)
                }
                _textualBoxLine4 = text as NSString
            } else {
                _textualBoxLine4 = String(format: NSLocalizedString("2D Pos: X:%0.3f px Y:%0.3f px", comment: ""), Double(_rect.origin.x), Double(_rect.origin.y)) as NSString
            }

            var location: [Float] = [0, 0, 0]
            viewImage?.convertX(Float(_rect.origin.x), pixY: Float(_rect.origin.y), toDICOMCoords: &location, pixelCenter: true)
            _textualBoxLine5 = String(format: NSLocalizedString("3D Pos: X:%0.3f mm Y:%0.3f mm Z:%0.3f mm", comment: ""),
                                      Double(location[0]), Double(location[1]), Double(location[2])) as NSString
        }
        prepareTextualData(tPt)
    }

    func labelLength() {
        let tPt = lowerRightPoint()
        _textualBoxLine1 = labelName
        if _type == .tMesure && !ROI.settings.textNameOnly {
            let regions = hasUltrasoundRegions ? ultrasoundRegions : []
            // Ultrasound images with a single region whose spatial format is not 2D.
            if (_pixelSpacingX != 0 && _pixelSpacingY != 0) || (hasUltrasoundRegions && ultrasoundRegions.count == 1) {
                var lPix: Float = 0
                let lCm = mesureLength(&lPix)
                if _displayCMOrPixels {   // CPR
                    _textualBoxLine2 = LengthPresentation.string(centimetres: Double(lCm)) as NSString
                } else if hasUltrasoundRegions {
                    _textualBoxLine2 = ultrasoundLengthText(regions, lCm: lCm, lPix: lPix) as NSString
                } else {
                    _textualBoxLine2 = String(format: NSLocalizedString("Length: %@", comment: ""), LengthPresentation.string(centimetres: Double(lCm))) as NSString
                }
            } else {
                let pixels = Double(length(myPoint(0).point, myPoint(1).point))
                _textualBoxLine2 = String(format: NSLocalizedString("Length: %@", comment: ""), LengthPresentation.string(pixels: pixels)) as NSString
            }

            // With another length before it, the Cobb angle between the two.
            if let view, ROI.settings.displayCobbAngle, !_displayCMOrPixels, let roiList = view.curRoiList {
                let index = roiList.index(of: self)
                if index != NSNotFound && index > 0 {
                    for i in 0..<index {
                        guard let r = roiList.object(at: i) as? ROI, r.type == .tMesure else { continue }
                        let other = r.points!
                        let u1 = myPoint(0).point, u2 = myPoint(1).point
                        let v1 = (other.object(at: 0) as! MyPoint).point, v2 = (other.object(at: 1) as! MyPoint).point
                        var pX = Float(view.curDCM?.pixelSpacingX ?? 0), pY = Float(view.curDCM?.pixelSpacingY ?? 0)
                        if pX == 0 || pY == 0 { pX = 1; pY = 1 }
                        let a1 = NSPoint(x: u1.x * CGFloat(pX), y: u1.y * CGFloat(pY)), a2 = NSPoint(x: u2.x * CGFloat(pX), y: u2.y * CGFloat(pY))
                        let b1 = NSPoint(x: v1.x * CGFloat(pX), y: v1.y * CGFloat(pY)), b2 = NSPoint(x: v2.x * CGFloat(pX), y: v2.y * CGFloat(pY))
                        var angle = angleBetween2Lines(a1, a2, b1, b2)
                        if angle < -180 { angle = -180 - angle } else if angle < -90 { angle += 180 } else if angle < 0 { angle *= -1 }
                        if angle > 270 { angle = 360 - angle } else if angle > 180 { angle -= 180 } else if angle > 90 { angle = 180 - angle }
                        var rName = r._name
                        if rName?.isEqual(to: "Unnamed") == true || rName?.isEqual(to: NSLocalizedString("Unnamed", comment: "")) == true { rName = nil }
                        if let rName {
                            _textualBoxLine3 = String(format: NSLocalizedString("Angle: %0.2f%@ with: %@", comment: ""), angle, "\u{00B0}", rName) as NSString
                        } else {
                            _textualBoxLine3 = String(format: NSLocalizedString("Angle: %0.2f%@", comment: ""), angle, "\u{00B0}") as NSString
                        }
                        break
                    }
                }
            }
        }
        prepareTextualData(tPt)
    }

    /// A length on an ultrasound image: in its region's units when both ends
    /// lie in one, in pixels otherwise.
    private func ultrasoundLengthText(_ regions: [USRegion], lCm: Float, lPix: Float) -> String {
        let p1 = myPoint(0).point, p2 = myPoint(1).point
        var inside = false
        var format: Int32 = 0, unitsXCode: Int32 = 0, unitsYCode: Int32 = 0
        var deltaX = 0.0, deltaY = 0.0
        let x1 = ROIBrushMask.int32(Double(p1.x)), y1 = ROIBrushMask.int32(Double(p1.y))
        let x2 = ROIBrushMask.int32(Double(p2.x)), y2 = ROIBrushMask.int32(Double(p2.y))
        for region in regions where !inside {
            inside = x1 <= region.regionLocationMaxX1 && x1 >= region.regionLocationMinX0 && y1 <= region.regionLocationMaxY1 && y1 >= region.regionLocationMinY0
                && x2 <= region.regionLocationMaxX1 && x2 >= region.regionLocationMinX0 && y2 <= region.regionLocationMaxY1 && y2 >= region.regionLocationMinY0
            if inside {
                format = region.regionSpatialFormat
                unitsXCode = region.physicalUnitsXDirection
                unitsYCode = region.physicalUnitsYDirection
                deltaX = region.physicalDeltaX
                deltaY = region.physicalDeltaY
                // No spatial format and no units: not a region to measure in.
                if format == 0 && unitsXCode == 0 && unitsYCode == 0 { inside = false }
            }
        }
        guard inside else {
            return String(format: NSLocalizedString("Length: %@", comment: ""), LengthPresentation.string(pixels: Double(lPix)))
        }
        if format == 1 && unitsXCode == 3 && unitsYCode == 3 {   // 2D, in cm both ways
            return String(format: NSLocalizedString("Length: %@", comment: ""), LengthPresentation.string(centimetres: Double(lCm)))
        }
        let lengthX = abs(Double(p2.x - p1.x)) * abs(deltaX)
        var lengthY = abs(Double(p2.y - p1.y)) * abs(deltaY)
        // Independent axes, as for a point.
        let unitsX = ROIUltrasoundUnits.name(of: unitsXCode)
        var unitsY = ROIUltrasoundUnits.name(of: unitsYCode)
        if (unitsY as NSString).isEqual(to: NSLocalizedString("cm/sec", comment: "")) && lengthY >= 100.0 {
            unitsY = NSLocalizedString("m/sec", comment: "")
            lengthY = lengthY / 100.0
        }
        return String(format: NSLocalizedString("Length: X=%0.3f %@, Y=%0.3f %@", comment: ""), lengthX, unitsX, lengthY, unitsY)
    }

    func labelRectangle() {
        let tPt = lowerRightPoint()
        _textualBoxLine1 = labelName
        if !ROI.settings.textNameOnly {
            if rtotal == -1 { computeStatistics(of: viewImage) }
            let inside = liesIn2DUltrasoundRegion(_rect.origin, NSPoint(x: _rect.origin.x + _rect.size.width, y: _rect.origin.y + _rect.size.height))
            let w = Double(_rect.size.width), h = Double(_rect.size.height)
            if areaIsCalibrated(insideUltrasoundRegion: inside) {
                let area = abs(w * _pixelSpacingX * h * _pixelSpacingY)
                if area < 1.0 {
                    setTextualBoxLine(2, area: String(format: NSLocalizedString("Area: %0.1f %cm\u{00B2}", comment: ""), abs(w * _pixelSpacingX * h * _pixelSpacingY * 1000000.0), Int32(0xB5)),
                                      width: String(format: "%0.1f %cm", abs(w * _pixelSpacingX) * 1000.0, Int32(0xB5)),
                                      height: String(format: "%0.1f %cm", abs(h * _pixelSpacingY) * 1000.0, Int32(0xB5)))
                } else if area / 100.0 < 1.0 {
                    setTextualBoxLine(2, area: String(format: NSLocalizedString("Area: %0.3f mm\u{00B2}", comment: ""), area),
                                      width: String(format: "%0.3f mm", abs(w * _pixelSpacingX)), height: String(format: "%0.3f mm", abs(h * _pixelSpacingY)))
                } else {
                    setTextualBoxLine(2, area: String(format: NSLocalizedString("Area: %0.3f cm\u{00B2}", comment: ""), abs(w * _pixelSpacingX * h * _pixelSpacingY / 100.0)),
                                      width: String(format: "%0.3f cm", abs(w * _pixelSpacingX) / 10.0), height: String(format: "%0.3f cm", abs(h * _pixelSpacingY) / 10.0))
                }
            } else {
                setTextualBoxLine(2, area: String(format: NSLocalizedString("Area: %0.3f pix2", comment: ""), abs(w * h)),
                                  width: String(format: "%0.3f pix", abs(w)), height: String(format: "%0.3f pix", abs(h)))
            }
            setStatisticsLines(3, mean: rmean, sdev: rdev, sum: rtotal, median: self.median, min: rmin, max: rmax, skewness: rskewness, kurtosis: rkurtosis,
                               unit: ROI.pixelUnit(of: self.pix), fused: false)

            if let view, let blendingView = view.roiBlendingView, let blendedPix = blendingView.curDCM {
                let blendedROI: ROI = ROI(type: _type, Float(blendedPix.pixelSpacingX), Float(blendedPix.pixelSpacingY),
                                          DCMPix.originCorrected(accordingToOrientation: blendedPix))
                var blendedRect = self.rect
                var downRight = NSPoint(x: blendedRect.origin.x + blendedRect.size.width, y: blendedRect.origin.y + blendedRect.size.height)
                blendedRect.origin = view.convertFromGL2GL(blendedRect.origin, toView: blendingView)
                downRight = view.convertFromGL2GL(downRight, toView: blendingView)
                blendedRect.size.width = downRight.x - blendedRect.origin.x
                blendedRect.size.height = downRight.y - blendedRect.origin.y
                blendedROI.rect = blendedRect
                fusedStatistics(blendedROI, blendedPix)
                setStatisticsLines(5, mean: Brmean, sdev: Brdev, sum: Brtotal, median: Brmedian, min: Brmin, max: Brmax, skewness: Brskewness,
                                   kurtosis: Brkurtosis, unit: ROI.pixelUnit(of: blendedPix), fused: true)
            }
        }
        prepareTextualData(tPt)
    }

    func labelOval(_ rrect: NSRect) {
        let tPt = lowerRightPoint()
        _textualBoxLine1 = labelName
        if !ROI.settings.textNameOnly {
            if rtotal == -1 { computeStatistics(of: viewImage) }
            let inside = liesIn2DUltrasoundRegion(NSPoint(x: rrect.origin.x - rrect.size.width, y: rrect.origin.y - rrect.size.height),
                                                  NSPoint(x: rrect.origin.x + rrect.size.width, y: rrect.origin.y + rrect.size.height))
            let w = Double(_rect.size.width), h = Double(_rect.size.height)
            if areaIsCalibrated(insideUltrasoundRegion: inside) {
                let area = Double(ellipseArea()) * _pixelSpacingX * _pixelSpacingY
                if area < 1.0 {
                    setTextualBoxLine(2, area: String(format: NSLocalizedString("Area: %0.1f %cm\u{00B2}", comment: ""), area * 1000000.0, Int32(0xB5)),
                                      width: String(format: "%0.1f %cm", 2.0 * abs(w) * _pixelSpacingX * 1000.0, Int32(0xB5)),
                                      height: String(format: "%0.1f %cm", 2.0 * abs(h) * _pixelSpacingY * 1000.0, Int32(0xB5)))
                } else if area / 100.0 < 1.0 {
                    setTextualBoxLine(2, area: String(format: NSLocalizedString("Area: %0.3f mm\u{00B2}", comment: ""), area),
                                      width: String(format: "%0.3f mm", 2.0 * abs(w) * _pixelSpacingX), height: String(format: "%0.3f mm", 2.0 * abs(h) * _pixelSpacingY))
                } else {
                    setTextualBoxLine(2, area: String(format: NSLocalizedString("Area: %0.3f cm\u{00B2}", comment: ""), area / 100.0),
                                      width: String(format: "%0.3f cm", 2.0 * abs(w) * _pixelSpacingX / 10.0), height: String(format: "%0.3f cm", 2.0 * abs(h) * _pixelSpacingY / 10.0))
                }
            } else {
                setTextualBoxLine(2, area: String(format: NSLocalizedString("Area: %0.3f pix2", comment: ""), Double(ellipseArea())),
                                  width: String(format: "%0.3f pix", 2.0 * abs(w)), height: String(format: "%0.3f pix", 2.0 * abs(h)))
            }
            setStatisticsLines(3, mean: rmean, sdev: rdev, sum: rtotal, median: self.median, min: rmin, max: rmax, skewness: rskewness, kurtosis: rkurtosis,
                               unit: ROI.pixelUnit(of: self.pix), fused: false)
            if let view, let blendingView = view.roiBlendingView, let blendedPix = blendingView.curDCM {
                fusedPolygonStatistics(view, blendingView, blendedPix)
                setStatisticsLines(5, mean: Brmean, sdev: Brdev, sum: Brtotal, median: Brmedian, min: Brmin, max: Brmax, skewness: Brskewness,
                                   kurtosis: Brkurtosis, unit: ROI.pixelUnit(of: blendedPix), fused: true)
            }
        }
        prepareTextualData(tPt)
    }

    func labelNameOnly() {
        let tPt = lowerRightPoint()
        _textualBoxLine1 = labelName
        prepareTextualData(tPt)
    }

    func labelTAGT() {
        let tPt = lowerRightPoint()
        _textualBoxLine1 = labelName
        func length(_ a: Int, _ b: Int) -> String {
            LengthPresentation.string(centimetres: Double(mesureLength(nil, pointA: myPoint(a).point, pointB: myPoint(b).point)))
        }
        _textualBoxLine2 = String(format: NSLocalizedString("A: %@", comment: ""), length(4, 5)) as NSString
        _textualBoxLine3 = String(format: NSLocalizedString("B: %@", comment: ""), length(0, 1)) as NSString
        _textualBoxLine4 = String(format: NSLocalizedString("C: %@", comment: ""), length(2, 3)) as NSString
        _textualBoxLine5 = String(format: NSLocalizedString("B-C: %@", comment: ""), length(0, 2)) as NSString
        prepareTextualData(tPt)
    }

    func labelDynamicAngle(_ angle: Float) {
        let tPt = lowerRightPoint()
        _textualBoxLine1 = labelName
        _textualBoxLine2 = String(format: NSLocalizedString("Angle: %0.2f%@", comment: ""), Double(angle), "\u{00B0}") as NSString
        _textualBoxLine3 = String(format: NSLocalizedString("Angle 2: %0.2f%@", comment: ""), Double(360 - angle), "\u{00B0}") as NSString
        _textualBoxLine4 = nil
        _textualBoxLine5 = nil
        prepareTextualData(tPt)
    }

    /// The bounds of the outline through `splinePoints`, for the ultrasound regions.
    private func ultrasoundBounds(of splinePoints: NSMutableArray) -> (NSPoint, NSPoint) {
        let first = splinePoints.object(at: 0) as! MyPoint
        var xMin = first.x, xMax = first.x, yMin = first.y, yMax = first.y
        for case let p as MyPoint in splinePoints {
            let x = p.x, y = p.y
            if x < xMin { xMin = x }
            if x > xMax { xMax = x }
            if y < yMin { yMin = y }
            if y > yMax { yMax = y }
        }
        return (NSPoint(x: CGFloat(xMin), y: CGFloat(yMin)), NSPoint(x: CGFloat(xMax), y: CGFloat(yMax)))
    }

    func labelClosedPolygon(_ splinePoints: NSMutableArray) {
        let tPt = lowerRightPoint()
        _textualBoxLine1 = labelName
        if !ROI.settings.textNameOnly {
            if rtotal == -1 { computeStatistics(of: viewImage) }
            var inside = false
            if hasUltrasoundRegions {
                let (a, b) = ultrasoundBounds(of: splinePoints)
                inside = liesIn2DUltrasoundRegion(a, b)
            }
            if areaIsCalibrated(insideUltrasoundRegion: inside) {
                setTextualBoxLine(2, segments: [ROI.labelSegment("Area", areaText(area()))])
            } else {
                setTextualBoxLine(2, segments: [ROI.labelSegment("Area", String(format: NSLocalizedString("Area: %0.3f pix2", comment: ""), Double(area())))])
            }
            setStatisticsLines(3, mean: rmean, sdev: rdev, sum: rtotal, median: self.median, min: rmin, max: rmax, skewness: rskewness, kurtosis: rkurtosis,
                               unit: ROI.pixelUnit(of: self.pix), fused: false)
            var length: Float = 0
            if splinePoints.count < 2 {
                _textualBoxLine5 = String(format: NSLocalizedString("Length: %@", comment: ""), LengthPresentation.string(centimetres: Double(length))) as NSString
            } else if let view, let blendingView = view.roiBlendingView, let blendedPix = blendingView.curDCM {
                fusedPolygonStatistics(view, blendingView, blendedPix)
                setStatisticsLines(5, mean: Brmean, sdev: Brdev, sum: Brtotal, median: Brmedian, min: Brmin, max: Brmax, skewness: Brskewness,
                                   kurtosis: Brkurtosis, unit: ROI.pixelUnit(of: blendedPix), fused: true)
            } else {
                length = perimeter(ofPoints: splinePoints, closed: true)
                _textualBoxLine5 = String(format: NSLocalizedString("Length: %@", comment: ""), LengthPresentation.string(centimetres: Double(length))) as NSString
            }
        }
        prepareTextualData(tPt)
    }

    func labelOpenPolygon(_ splinePoints: NSMutableArray) {
        let tPt = lowerRightPoint()
        _textualBoxLine1 = labelName
        if !ROI.settings.textNameOnly {
            if rtotal == -1 { computeStatistics(of: viewImage) }
            var inside = false
            if hasUltrasoundRegions {
                let (a, b) = ultrasoundBounds(of: splinePoints)
                inside = liesIn2DUltrasoundRegion(a, b)
            }
            let length = perimeter(ofPoints: splinePoints, closed: false)
            // The first and the last point too far apart: no area.
            if Double(self.length((splinePoints.object(at: 0) as! MyPoint).point, (splinePoints.lastObject as! MyPoint).point)) > Double(length) / ROI.openPolygonAreaRatio {
                // No area.
            } else {
                if areaIsCalibrated(insideUltrasoundRegion: inside) {
                    setTextualBoxLine(2, segments: [ROI.labelSegment("Area", areaText(area()))])
                } else {
                    setTextualBoxLine(2, segments: [ROI.labelSegment("Area", String(format: NSLocalizedString("Area: %0.3f pix2", comment: ""), Double(area())))])
                }
                setStatisticsLines(3, mean: rmean, sdev: rdev, sum: rtotal, median: self.median, min: rmin, max: rmax, skewness: 0, kurtosis: 0,
                                   unit: ROI.pixelUnit(of: self.pix), fused: false)
            }
            if let view, let blendingView = view.roiBlendingView, let blendedPix = blendingView.curDCM {
                fusedPolygonStatistics(view, blendingView, blendedPix)
                setStatisticsLines(5, mean: Brmean, sdev: Brdev, sum: Brtotal, median: Brmedian, min: Brmin, max: Brmax, skewness: 0, kurtosis: 0,
                                   unit: ROI.pixelUnit(of: blendedPix), fused: true)
            }
            _textualBoxLine5 = String(format: NSLocalizedString("Length: %@", comment: ""), LengthPresentation.string(centimetres: Double(length))) as NSString

            // The length in 3D, when the points lie on more than one slice.
            if _curView != nil && _pixelSpacingX != 0 && _pixelSpacingY != 0 && !UserDefaults.standard.bool(forKey: "splineForROI") {
                let zPosArray = self.zPositions!
                if zPosArray.count > 0 {
                    let zPos = (zPosArray.object(at: 0) as! NSNumber).int32Value
                    for i in 1..<Swift.max(zPosArray.count, 1) where zPos != (zPosArray.object(at: i) as! NSNumber).int32Value {
                        if zPosArray.count != _points.count { NSLog("***** [zPosArray count] != [points count]") }
                        // The distance between each point and the next, along the slices they lie on.
                        let pts = ROI.points(of: _points)
                        let count = Swift.min(pts.count, zPosArray.count)
                        let slices = (0..<count).map { (zPosArray.object(at: $0) as! NSNumber).int32Value }
                        let distance3d = pts.withUnsafeBufferPointer { p in
                            slices.withUnsafeBufferPointer { s in
                                ROIPlanarGeometry.pathLength(of: p.baseAddress, slices: s.baseAddress, count: count, spacingX: _pixelSpacingX, spacingY: _pixelSpacingY,
                                                             sliceInterval: (self.pix as DCMPix?)?.sliceInterval ?? 0)
                            }
                        }
                        // In millimetres: the unit is chosen by it, not by the length projected on the image.
                        _textualBoxLine6 = String(format: NSLocalizedString("3D Length: %@", comment: ""), LengthPresentation.string(millimetres: distance3d)) as NSString
                        break
                    }
                }
            }
        }
        prepareTextualData(tPt)
    }

    func labelAngle() {
        let tPt = lowerRightPoint()
        _textualBoxLine1 = labelName
        let angle = self.angle(myPoint(0).point, myPoint(1).point, myPoint(2).point)
        _textualBoxLine2 = String(format: NSLocalizedString("Angle: %0.3f%@ / %0.3f%@", comment: ""), Double(angle), "\u{00B0}", Double(360 - angle), "\u{00B0}") as NSString
        prepareTextualData(tPt)
    }

    /// An open polygon shows an area when its ends are closer than its length over this.
    static let openPolygonAreaRatio = 3.0
}

/// MIN and MAX as the C macros: the first unless the second is smaller, or larger.
func roiMin<T: Comparable>(_ a: T, _ b: T) -> T { a < b ? a : b }
func roiMax<T: Comparable>(_ a: T, _ b: T) -> T { a > b ? a : b }

extension ROI {
    /// NSEqualRects: the same origin and size, not made standard.
    static func equalRects(_ a: NSRect, _ b: NSRect) -> Bool {
        a.origin.x == b.origin.x && a.origin.y == b.origin.y && a.size.width == b.size.width && a.size.height == b.size.height
    }
}
