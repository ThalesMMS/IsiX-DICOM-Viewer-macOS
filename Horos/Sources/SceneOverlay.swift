//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// The 2D layer of a VTK scene without VTK drawing it. The VTK adapter reads
/// what VTK's text actors and 2D actors hold after a render
/// (IsiXVTKOverlayFrame); this draws them, with the orientation cube, the crop
/// box and a picked prop's outline, on the view's annotation overlay, as VTK
/// drew them over the 3D picture.
@objc(HorosSceneOverlay)
@MainActor
final class HorosSceneOverlay: NSObject {
    // OpenGL's numbers, which the overlay's canvas takes.
    private static let blend: UInt32 = 0x0BE2
    private static let sourceAlpha: UInt32 = 0x0302, oneMinusSourceAlpha: UInt32 = 0x0303
    private static let points: UInt32 = 0x0000, lines: UInt32 = 0x0001, lineStrip: UInt32 = 0x0003, polygon: UInt32 = 0x0009

    /// Draws `frame` on the overlay of `view`, in the renderer's display pixels.
    /// Nothing when there is no frame, or when it has nothing to draw and the
    /// view has no overlay to clear.
    @objc(drawFrame:onView:)
    static func draw(_ frame: IsiXVTKOverlayFrame?, on view: NSView) {
        guard let frame else { return }
        let width = frame.width, height = frame.height
        if frame.isEmpty && !(view.subviews.last is AnnotationOverlay) { return }

        let scale = (view.window?.backingScaleFactor ?? 0) > 0 ? view.window!.backingScaleFactor : 1
        let overlay = AnnotationOverlay.overlay(for: view)
        overlay.beginFrame(width: width, height: height)
        // Display pixels, from the bottom left, as VTK's 2D actors hold them.
        overlay.canvas.set(modelview: CGAffineTransform(a: 2.0 / CGFloat(width), b: 0, c: 0, d: 2.0 / CGFloat(height), tx: -1, ty: -1),
                           viewport: NSRect(x: 0, y: 0, width: width, height: height))

        if let rotation = frame.cubeRotation, let context = overlay.canvas.modelContext() {
            VROverlay.drawOrientationCube(in: context,
                                          rect: CGRect(x: 0.9 * CGFloat(width), y: 0.9 * CGFloat(height),
                                                       width: 0.1 * CGFloat(width), height: 0.1 * CGFloat(height)),
                                          viewRotation: rotation,
                                          labels: [NSLocalizedString("L", comment: "L: Left"), NSLocalizedString("R", comment: "R: Right"),
                                                   NSLocalizedString("P", comment: "P: Posterior"), NSLocalizedString("A", comment: "A: Anterior"),
                                                   NSLocalizedString("S", comment: "S: Superior"), NSLocalizedString("I", comment: "I: Inferior")])
        }

        // The canvas the frame made current, as the ROI calls drew on it.
        let canvas = ROICanvas.current ?? overlay.canvas

        // The crop box, which VTK drew as 3D geometry.
        if frame.hasBox { frame.drawBox(on: canvas as AnyObject as! IsiXVTKLineCanvas) }

        // The picked point's bounds, in red, as vtkInteractorStyle outlined it.
        if let corners = frame.pickedCorners {
            corners.withUnsafeBytes { raw in
                let corner = raw.bindMemory(to: Double.self)
                canvas.disable(blend)
                canvas.color(r: 1, g: 0, b: 0, a: 1)
                canvas.lineWidth(1)
                canvas.begin(lines)
                for i in 0..<8 {
                    for axis in 0..<3 where i & (1 << axis) == 0 {
                        let j = i | (1 << axis)
                        canvas.vertex(x: singlePrecision(corner[3 * i]), y: singlePrecision(corner[3 * i + 1]))
                        canvas.vertex(x: singlePrecision(corner[3 * j]), y: singlePrecision(corner[3 * j + 1]))
                    }
                }
                canvas.end()
            }
        }

        let dpi = frame.dpi > 0 ? frame.dpi : 72.0 * Double(scale)
        for item in frame.items {
            if let text = item as? IsiXVTKOverlayText {
                VROverlay.addText(text.text, fontFamily: text.fontFamily, fontSize: CGFloat(text.fontSize * dpi / 72.0),
                                  bold: text.bold, red: CGFloat(text.red), green: CGFloat(text.green), blue: CGFloat(text.blue),
                                  opacity: CGFloat(text.opacity), x: CGFloat(text.anchorX), y: CGFloat(text.anchorY),
                                  justification: text.justification, verticalJustification: text.verticalJustification,
                                  viewHeight: CGFloat(height), scale: scale, window: view.window, overlay: overlay)
                continue
            }
            guard let shape = item as? IsiXVTKOverlayShape else { continue }
            if shape.opacity < 1 {
                canvas.enable(blend)
                canvas.blend(source: sourceAlpha, destination: oneMinusSourceAlpha)
            } else {
                canvas.disable(blend)
            }
            canvas.color(r: singlePrecision(shape.red), g: singlePrecision(shape.green), b: singlePrecision(shape.blue), a: singlePrecision(shape.opacity))
            canvas.lineWidth(singlePrecision(shape.lineWidth))
            canvas.pointSize(singlePrecision(shape.pointSize))
            drawCells(shape.polygons, mode: polygon, on: canvas)
            drawCells(shape.lines, mode: lineStrip, on: canvas)
            drawCells(shape.vertices, mode: points, on: canvas)
        }
        canvas.disable(blend)

        overlay.commit(inverted: false, scale: scale)
    }

    /// Each cell as a figure of `mode`, its points two doubles each.
    private static func drawCells(_ cells: [Data], mode: UInt32, on canvas: ROICanvas) {
        for cell in cells {
            canvas.begin(mode)
            cell.withUnsafeBytes { raw in
                let point = raw.bindMemory(to: Double.self)
                var index = 0
                while index + 1 < point.count {
                    canvas.vertex(x: singlePrecision(point[index]), y: singlePrecision(point[index + 1]))
                    index += 2
                }
            }
            canvas.end()
        }
    }

    /// A number as the GLfloat the canvas's C calls took it.
    private static func singlePrecision(_ value: Double) -> CGFloat { CGFloat(Float(value)) }
}
