//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import simd

/// What the VR view shows over its volume, drawn without VTK (#731): the
/// strings its text actors hold and the orientation cube. The view's 2D lines
/// go on the overlay's canvas with the ROI calls; this places the rest.
@objc(HorosVROverlay)
public final class VROverlay: NSObject {

    /// A string where a vtkTextActor would put it: its anchor (x, y) in display
    /// pixels from the bottom left of a view `viewHeight` pixels high, and its
    /// justifications as VTK numbers them (0 left or bottom, 1 centred, 2 right
    /// or top). `fontSize` is in pixels, as VTK scales it by the window's DPI.
    @objc(addText:fontFamily:fontSize:bold:red:green:blue:opacity:x:y:justification:verticalJustification:viewHeight:scale:window:overlay:)
    @MainActor public static func addText(_ string: String, fontFamily: String, fontSize: CGFloat, bold: Bool,
                               red: CGFloat, green: CGFloat, blue: CGFloat, opacity: CGFloat,
                               x: CGFloat, y: CGFloat, justification: Int, verticalJustification: Int,
                               viewHeight: CGFloat, scale: CGFloat, window: NSWindow?, overlay: AnnotationOverlay) {
        let lines = string.components(separatedBy: "\n")
        guard lines.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), opacity > 0, fontSize > 0 else { return }
        let factor = scale > 0 ? scale : 1
        let font = font(family: fontFamily, size: fontSize / factor, bold: bold)
        let token = AnnotationPresentation.textureCacheToken(for: window)
        // VTK stacks the lines 1.1 font sizes apart and justifies each one.
        let lineHeight = (fontSize * 1.1).rounded()
        let blockHeight = CGFloat(lines.count - 1) * lineHeight + fontSize
        let blockTop: CGFloat
        switch verticalJustification {
        case 1: blockTop = viewHeight - y - blockHeight / 2
        case 2: blockTop = viewHeight - y
        default: blockTop = viewHeight - y - blockHeight
        }
        let colour = NSColor(deviceRed: red, green: green, blue: blue, alpha: opacity)
        let shadow = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: opacity)
        for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let text = AnnotationText.text(for: line, font: font, scale: factor, cacheToken: token)
            guard text.pixelWidth > 0 else { continue }
            // The string's own box within the picture: 4 × 2 points of margin.
            let width = text.stringWidth
            let height = CGFloat(text.pixelHeight) - 4 * factor
            let left: CGFloat
            switch justification {
            case 1: left = x - width / 2
            case 2: left = x - width
            default: left = x
            }
            let top = blockTop + CGFloat(index) * lineHeight + (fontSize - height) / 2
            overlay.add(text: text, x: (left - 4 * factor).rounded(), y: (top - 2 * factor).rounded(), textColor: colour, shadowColor: shadow)
        }
    }

    static func font(family: String, size: CGFloat, bold: Bool) -> NSFont {
        let base = NSFont(name: family, size: size) ?? NSFont(name: "Helvetica", size: size) ?? NSFont.systemFont(ofSize: size)
        return bold ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
    }

    // MARK: Orientation cube

    private struct Face {
        let normal: SIMD3<Double>, u: SIMD3<Double>, v: SIMD3<Double>
        let label: Int
        let colour: SIMD3<Double>
    }

    /// The faces of VTK's annotated cube, each with the directions its letter
    /// reads along seen from outside, as vtkAnnotatedCubeActor orients them.
    private static let faces: [Face] = [
        Face(normal: [1, 0, 0], u: [0, 1, 0], v: [0, 0, 1], label: 0, colour: [0, 0, 1]),
        Face(normal: [-1, 0, 0], u: [0, -1, 0], v: [0, 0, 1], label: 1, colour: [0, 0, 1]),
        Face(normal: [0, 1, 0], u: [-1, 0, 0], v: [0, 0, 1], label: 2, colour: [0, 1, 0]),
        Face(normal: [0, -1, 0], u: [1, 0, 0], v: [0, 0, 1], label: 3, colour: [0, 1, 0]),
        Face(normal: [0, 0, 1], u: [0, -1, 0], v: [1, 0, 0], label: 4, colour: [1, 0, 0]),
        Face(normal: [0, 0, -1], u: [0, 1, 0], v: [1, 0, 0], label: 5, colour: [1, 0, 0]),
    ]

    /// The orientation cube as vtkOrientationMarkerWidget showed it in the
    /// viewport `rect` (display pixels, bottom left origin): a unit cube seen
    /// along the main camera's direction, perspective with VTK's 30° view angle
    /// and reset to fit its bounding sphere, white faces lit by a headlight and
    /// the letters (+X, -X, +Y, -Y, +Z, -Z) in their colours with grey edges.
    /// `viewRotation` is the camera's view transform, row major 4 × 4.
    @objc(drawOrientationCubeIn:rect:viewRotation:labels:)
    public static func drawOrientationCube(in context: CGContext, rect: CGRect, viewRotation: [NSNumber], labels: [String]) {
        guard viewRotation.count >= 12, labels.count == 6, rect.width > 0, rect.height > 0 else { return }
        let m = viewRotation.map { $0.doubleValue }
        let row0 = SIMD3(m[0], m[1], m[2]), row1 = SIMD3(m[4], m[5], m[6]), row2 = SIMD3(m[8], m[9], m[10])
        func camera(_ p: SIMD3<Double>) -> SIMD3<Double> { SIMD3(simd_dot(row0, p), simd_dot(row1, p), simd_dot(row2, p)) }
        let halfAngle = 15.0 * Double.pi / 180
        let distance = sqrt(3.0) / 2 / sin(halfAngle)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let pixelsPerUnit = Double(rect.height) / 2 / tan(halfAngle)
        func project(_ p: SIMD3<Double>) -> CGPoint {
            let c = camera(p)
            let depth = distance - c.z
            return CGPoint(x: Double(centre.x) + c.x / depth * pixelsPerUnit, y: Double(centre.y) + c.y / depth * pixelsPerUnit)
        }
        context.saveGState()
        context.clip(to: rect)
        let visible = faces.map { ($0, camera($0.normal).z) }.filter { $0.1 > 1e-6 }.sorted { $0.1 < $1.1 }
        for (face, facing) in visible {
            let corners = [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)].map { (a, b) in
                face.normal * 0.5 + face.u * a + face.v * b
            }
            let points = corners.map(project)
            let shade = CGFloat(min(1, max(0, facing)))
            context.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
            context.beginPath()
            context.addLines(between: points)
            context.closePath()
            context.fillPath()

            // The letter, on the face's plane: an affine map from the letter's
            // unit square (u right, v up) to the projected face.
            let origin = project(face.normal * 0.5)
            let alongU = project(face.normal * 0.5 + face.u), alongV = project(face.normal * 0.5 + face.v)
            let transform = CGAffineTransform(a: alongU.x - origin.x, b: alongU.y - origin.y,
                                              c: alongV.x - origin.x, d: alongV.y - origin.y,
                                              tx: origin.x, ty: origin.y)
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 1, nil)
            let colour = face.colour * Double(shade)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: colour.x, green: colour.y, blue: colour.z, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: labels[face.label], attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            guard bounds.height > 0 else { continue }
            let letterScale = 0.67 / bounds.height
            context.saveGState()
            context.concatenate(transform)
            context.scaleBy(x: letterScale, y: letterScale)
            context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
            context.setTextDrawingMode(.fillStroke)
            context.setStrokeColor(CGColor(red: 0.5 * shade, green: 0.5 * shade, blue: 0.5 * shade, alpha: 1))
            context.setLineWidth(0.03 / letterScale)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        context.restoreGState()
    }
}
