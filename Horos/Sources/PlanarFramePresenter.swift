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
import QuartzCore

/// One frame of a DCMView, from its start to its presentation.
///
/// `-[DCMView drawFrame:]` makes one per frame and lets it go at the end: it
/// keeps nothing between frames, and the picture's renderer, the overlay and
/// the trace stay the view's own. The frame starts the view's annotation
/// overlay and its canvas, draws the picture into the view's Metal layer
/// through the planar bridge (the typed `PlanarFrame` snapshot stays the
/// boundary) or clears the layer, says why when the picture could not be
/// drawn, and commits the overlay with the picture, inverted with the view.
/// What the view draws between the start and the commit - ROIs, text, the
/// subclass hooks - stays in the view, in the order it has always had.
@MainActor
@objc(HorosPlanarFrameCycle)
public final class PlanarFrameCycle: NSObject {
    /// The drawable, in backing pixels.
    @objc public let size: NSSize
    /// Backing pixels per point.
    @objc public let scale: CGFloat
    /// Whether the picture and the overlay are inverted (the view's colours, not an export).
    @objc public let inverted: Bool
    /// Whether this frame's picture came from Metal.
    @objc public private(set) var pictureDrawn = false

    private let overlay: AnnotationOverlay
    private let trace: PlanarPerformanceTrace?
    private var span: UInt64 = 0

    private init(overlay: AnnotationOverlay, trace: PlanarPerformanceTrace?, size: NSSize, scale: CGFloat, inverted: Bool) {
        self.overlay = overlay; self.trace = trace
        self.size = size; self.scale = scale; self.inverted = inverted
        super.init()
    }

    /// Starts the frame: the overlay and the canvas every graphic of the view
    /// is drawn by, with the viewport in backing pixels and the identity, as
    /// glViewport and a reset model-view matrix left OpenGL (#728).
    @objc(beginInView:size:scale:inverted:)
    public static func begin(in view: DCMView, size: NSSize, scale: CGFloat, inverted: Bool) -> PlanarFrameCycle {
        let overlay = AnnotationOverlay.overlay(for: view)
        overlay.beginFrame(width: Int(size.width), height: Int(size.height))
        overlay.canvas.set(modelview: .identity, viewport: NSRect(origin: .zero, size: size))
        return PlanarFrameCycle(overlay: overlay, trace: view.horosPlanarPerformanceTrace(),
                                size: size, scale: scale, inverted: inverted)
    }

    /// Draws the picture of image `index` into `layer`, presented with this
    /// frame's graphics and text, or clears it - white only when an image
    /// asked for a white background. Returns whether Metal drew it.
    @objc(presentPictureInView:layer:index:hasImage:whiteBackground:)
    @discardableResult
    public func presentPicture(in view: DCMView, layer: CAMetalLayer, index: Int, hasImage: Bool, whiteBackground: Bool) -> Bool {
        span = trace?.beginDraw(index: index) ?? 0
        pictureDrawn = hasImage && view.horosDrawPlanar(in: layer, inverted: inverted)
        if !pictureDrawn { view.horosClearLayer(layer, white: whiteBackground && hasImage, inverted: inverted) }
        trace?.prepared(span, metal: pictureDrawn, loadedLegacyTexture: false,
                        gpuMilliseconds: pictureDrawn ? view.horosPlanarLastCommandMilliseconds() : -1)
        return pictureDrawn
    }

    /// The image is on screen; its graphics follow.
    @objc public func imageDrawn() { trace?.imageDrawn(span) }

    /// The notice over a picture that could not be drawn, and over a plane the
    /// MPR computed on the CPU because Metal declined it (#735): the reason the
    /// bridge recorded, centred near the bottom, in the main font.
    @objc(drawNoticeInView:hasImage:)
    public func drawNotice(in view: DCMView, hasImage: Bool) {
        guard hasImage, !pictureDrawn || view.horosEngineNotice() != nil,
              let message = view.horosPlanarFallbackReason(), let canvas = ROICanvas.current else { return }
        let sf = Float(scale)
        canvas.loadIdentity()
        canvas.scale(x: floatNarrowed(2 / Double(size.width)), y: floatNarrowed(-2 / Double(size.height)), z: 1)
        canvas.color(r: 1, g: CGFloat(Float(0.8)), b: CGFloat(Float(0.2)), a: 1)
        view.drawNSStringGL(message, DCMViewMainFont, 0, longTruncated(Double(size.height) / 2 - Double(24 * sf)),
                            align: DCMViewTextAlignCenter, useStringTexture: true)
    }

    /// Presents the frame: the overlay's graphics and text over the picture,
    /// in the same Core Animation transaction, and ends the trace of image `index`.
    @objc(commitIndex:)
    public func commit(index: Int) {
        overlay.commit(inverted: inverted, scale: scale)
        trace?.endDraw(span, index: index)
    }
}

/// The graphics a DCMView frame draws around its image that depend only on
/// what they are given: the viewer highlight, the CLUT bars, the view and tile
/// borders, the overflow marks, the patient crosshair, the 3D point and the
/// ruler. Each draws on the current canvas, in the frame's backing pixels
/// (`size`, `scale`), with OpenGL's single-precision arithmetic, as the
/// Objective-C that drew them did.
@MainActor
@objc(HorosPlanarFrameGraphics)
public final class PlanarFrameGraphics: NSObject {
    private static let quads: UInt32 = 0x0007, lines: UInt32 = 0x0001, lineLoop: UInt32 = 0x0002
    private static let blendCap: UInt32 = 0x0BE2, stipple: UInt32 = 0x0B24
    private static let srcAlpha: UInt32 = 0x0302, oneMinusSrcAlpha: UInt32 = 0x0303

    private static func vertex(_ canvas: ROICanvas, _ x: Float, _ y: Float) { canvas.vertex(x: CGFloat(x), y: CGFloat(y)) }
    private static func loop(_ canvas: ROICanvas, halfWidth w: Float, halfHeight h: Float) {
        canvas.begin(lineLoop)
        vertex(canvas, -w, -h); vertex(canvas, -w, h); vertex(canvas, w, h); vertex(canvas, w, -h)
        canvas.end()
    }
    /// The frame's pixel grid centred on the view, y down: glScalef(2/w, -2/h).
    private static func screen(_ canvas: ROICanvas, _ size: NSSize, xFlipped: Bool = false, yFlipped: Bool = false) {
        canvas.loadIdentity()
        canvas.scale(x: floatNarrowed(2 / Double(xFlipped ? -size.width : size.width)),
                     y: floatNarrowed(-2 / Double(yFlipped ? -size.height : size.height)), z: 1)
    }

    /// The 2D viewer's highlight: a translucent fill over the whole frame,
    /// yellow, or black when the colours are inverted.
    @objc(drawHighlight:inverted:size:scale:)
    public static func drawHighlight(_ alpha: Float, inverted: Bool, size: NSSize, scale: CGFloat) {
        guard let canvas = ROICanvas.current else { return }
        let w = Float(size.width), h = Float(size.height)
        canvas.loadIdentity()
        canvas.scale(x: floatNarrowed(2 / Double(size.width)), y: floatNarrowed(-2 / Double(size.height)), z: 1)
        canvas.translate(x: floatNarrowed(-Double(size.width) / 2), y: floatNarrowed(-Double(size.height) / 2), z: 0)
        canvas.blend(source: srcAlpha, destination: oneMinusSrcAlpha)
        canvas.enable(blendCap)
        if inverted { canvas.color(r: 0, g: 0, b: 0, a: CGFloat(alpha)) }
        else { canvas.color(r: CGFloat(Float(249.0 / 255.0)), g: CGFloat(Float(240.0 / 255.0)), b: CGFloat(Float(140.0 / 255.0)), a: CGFloat(alpha)) }
        canvas.lineWidth(CGFloat(1 * Float(scale)))
        canvas.begin(quads)
        vertex(canvas, 0, 0); vertex(canvas, 0, h); vertex(canvas, w, h); vertex(canvas, w, 0)
        canvas.end()
        canvas.disable(blendCap)
    }

    /// Enters the frame's screen grid for the CLUT bars.
    @objc(beginCLUTBarsSize:)
    public static func beginCLUTBars(size: NSSize) {
        guard let canvas = ROICanvas.current else { return }
        screen(canvas, size)
    }

    /// One CLUT bar with its three window labels: the image's on the right
    /// (`fused` NO, labels right-aligned before the bar), the fused series' on
    /// the left (labels after it). `red`, `green` and `blue` are 256 entries;
    /// without them only the frame is drawn. `precise` gives four decimals.
    @objc(drawCLUTBarRed:green:blue:fused:level:width:precise:size:scale:inView:)
    public static func drawCLUTBar(red: UnsafePointer<UInt8>?, green: UnsafePointer<UInt8>?, blue: UnsafePointer<UInt8>?,
                                   fused: Bool, level: Float, width: Float, precise: Bool,
                                   size: NSSize, scale: CGFloat, in view: DCMView) {
        guard let canvas = ROICanvas.current else { return }
        let sf = Float(scale)
        let widthhalf = Float(Double(size.width) / 2 - 1), heighthalf: Float = 0
        // The image's bar: 62 to 32 points from the right; the fused one: 55 to 25 from the left.
        let x1 = fused ? -widthhalf + 55 * sf : widthhalf - 62 * sf
        let x2 = fused ? -widthhalf + 25 * sf : widthhalf - 32 * sf
        canvas.lineWidth(CGFloat(1 * sf))
        canvas.begin(lines)
        if let red, let green, let blue {
            for i in 0..<256 {
                canvas.color(r: CGFloat(red[i]) / 255, g: CGFloat(green[i]) / 255, b: CGFloat(blue[i]) / 255, a: 1)
                let y = heighthalf - (-128 * sf + Float(i) * sf)
                vertex(canvas, x1, y); vertex(canvas, x2, y)
            }
        } else {
            NSLog("bred == nil")
        }
        canvas.color(r: CGFloat(128) / 255, g: CGFloat(128) / 255, b: CGFloat(128) / 255, a: 1)
        vertex(canvas, x1, heighthalf - -128 * sf); vertex(canvas, x2, heighthalf - -128 * sf)
        vertex(canvas, x1, heighthalf - 127 * sf); vertex(canvas, x2, heighthalf - 127 * sf)
        vertex(canvas, x1, heighthalf - -128 * sf); vertex(canvas, x1, heighthalf - 127 * sf)
        vertex(canvas, x2, heighthalf - -128 * sf); vertex(canvas, x2, heighthalf - 127 * sf)
        canvas.end()

        let format = precise ? "%0.4f" : "%0.0f"
        let labels: [(Float, Float)] = [(level - width / 2, heighthalf - -133 * sf), (level, heighthalf - 0),
                                        (level + width / 2, heighthalf - 120 * sf)]
        for (value, y) in labels {
            let text = String(format: format, Double(value))
            if fused {
                view.drawNSStringGL(text, DCMViewMainFont, longTruncated(Double(-widthhalf + 55 * sf + 4 * sf)), longTruncated(Double(y)))
            } else {
                view.drawNSStringGL(text, DCMViewMainFont, longTruncated(Double(widthhalf - 62 * sf)), longTruncated(Double(y)),
                                    rightAlignment: true, useStringTexture: false)
            }
        }
    }

    /// Enters the screen grid, flipped with the image, for the borders.
    @objc(beginBordersSize:xFlipped:yFlipped:)
    public static func beginBorders(size: NSSize, xFlipped: Bool, yFlipped: Bool) {
        guard let canvas = ROICanvas.current else { return }
        screen(canvas, size, xFlipped: xFlipped, yFlipped: yFlipped)
    }

    /// The red border of the key view of the frontmost viewer, when more than one is open.
    @objc(drawKeyViewBorderSize:scale:)
    public static func drawKeyViewBorder(size: NSSize, scale: CGFloat) {
        guard let canvas = ROICanvas.current else { return }
        let sf = Float(scale)
        canvas.color(r: 1, g: 0, b: 0, a: CGFloat(Float(0.8)))
        canvas.lineWidth(CGFloat(8 * sf))
        loop(canvas, halfWidth: Float(Double(size.width) / 2), halfHeight: Float(Double(size.height) / 2))
        canvas.lineWidth(CGFloat(1 * sf))
    }

    /// Dotted green marks on the sides past which the image overflows the view.
    /// `image` is the image's rectangle in the frame's pixels.
    @objc(drawOverflowImageRect:size:scale:)
    public static func drawOverflow(image: NSRect, size: NSSize, scale: CGFloat) {
        guard let canvas = ROICanvas.current else { return }
        let sf = Float(scale)
        let heighthalf = Float(Double(size.height) / 2), widthhalf = Float(Double(size.width) / 2)
        let offset = 4 * sf
        // The rectangle is in doubles; the half sizes and the offset in floats.
        let ox = Double(image.origin.x), oy = Double(image.origin.y), iw = Double(image.size.width), ih = Double(image.size.height)
        let hh = Double(heighthalf), wh = Double(widthhalf)
        func v(_ x: Double, _ y: Double) { vertex(canvas, Float(x), Float(y)) }
        canvas.color(r: 0, g: 1, b: 0, a: CGFloat(Float(0.8)))
        canvas.lineWidth(CGFloat(3 * sf))
        canvas.pushAttributes()
        canvas.lineStipple(factor: Int(Int32(4 * sf)), pattern: 0xAAAA)
        canvas.enable(stipple)
        if image.origin.x <= -5 {
            canvas.begin(lines); v(Double(-widthhalf + offset), oy - hh); v(Double(-widthhalf + offset), oy + ih - hh); canvas.end()
        }
        if image.origin.y <= -5 {
            canvas.begin(lines); v(ox - wh, Double(-heighthalf + offset)); v(ox + iw - wh, Double(-heighthalf + offset)); canvas.end()
        }
        if image.origin.x + image.size.width >= size.width + 5 {
            canvas.begin(lines); v(Double(widthhalf - offset), oy - hh); v(Double(widthhalf - offset), oy + ih - hh); canvas.end()
        }
        if image.origin.y + image.size.height >= size.height + 5 {
            canvas.begin(lines); v(ox - wh, Double(heighthalf - offset)); v(ox + iw - wh, Double(heighthalf - offset)); canvas.end()
        }
        canvas.lineWidth(CGFloat(1 * sf))
        canvas.popAttributes()
    }

    /// A tile's grey border in a mosaic of images, and the red one of the key tile.
    @objc(drawTileBorderSize:scale:key:)
    public static func drawTileBorder(size: NSSize, scale: CGFloat, key: Bool) {
        guard let canvas = ROICanvas.current else { return }
        let sf = Float(scale)
        let heighthalf = Float(Double(size.height) / 2 - 1), widthhalf = Float(Double(size.width) / 2 - 1)
        canvas.color(r: CGFloat(Float(0.5)), g: CGFloat(Float(0.5)), b: CGFloat(Float(0.5)), a: 1)
        canvas.lineWidth(CGFloat(1 * sf))
        loop(canvas, halfWidth: widthhalf, halfHeight: heighthalf)
        canvas.lineWidth(CGFloat(1 * sf))
        guard key else { return }
        canvas.color(r: 1, g: 0, b: 0, a: 1)
        canvas.lineWidth(CGFloat(2 * sf))
        loop(canvas, halfWidth: widthhalf, halfHeight: heighthalf)
        canvas.lineWidth(CGFloat(1 * sf))
    }

    /// Enters the image's own grid, from the flipped screen grid: the view's
    /// rotation, pan and pixel ratio, where the ROIs are drawn.
    @objc(enterImageRotation:origin:pixelRatio:)
    public static func enterImage(rotation: Float, origin: NSPoint, pixelRatio: Float) {
        guard let canvas = ROICanvas.current else { return }
        canvas.rotate(Double(rotation))
        canvas.translate(x: CGFloat(Float(origin.x)), y: CGFloat(Float(-origin.y)), z: 0)
        canvas.scale(x: 1, y: CGFloat(pixelRatio), z: 1)
    }

    /// The patient-space marker, in the image's grid: a green cross open at its
    /// centre, at (`x`, `y`), its vertical arms divided by the pixel ratio.
    @objc(drawPatientCrosshairX:y:pixelRatio:scale:)
    public static func drawPatientCrosshair(x: Float, y: Float, pixelRatio ratio: Float, scale: CGFloat) {
        guard let canvas = ROICanvas.current, ratio > 0 else { return }
        let sf = Float(scale)
        canvas.pushAttributes()
        canvas.enable(blendCap)
        canvas.blend(source: srcAlpha, destination: oneMinusSrcAlpha)
        canvas.color(r: 0, g: CGFloat(Float(0.8)), b: CGFloat(Float(0.2)), a: 1)
        canvas.lineWidth(CGFloat(2 * sf))
        canvas.begin(lines)
        vertex(canvas, x - 12 * sf, y); vertex(canvas, x - 4 * sf, y)
        vertex(canvas, x + 4 * sf, y); vertex(canvas, x + 12 * sf, y)
        vertex(canvas, x, y - 12 * sf / ratio); vertex(canvas, x, y - 4 * sf / ratio)
        vertex(canvas, x, y + 4 * sf / ratio); vertex(canvas, x, y + 12 * sf / ratio)
        canvas.end()
        canvas.popAttributes()
    }

    /// The 3D point another view points at, in the image's grid: a 15 mm
    /// stroke across the reference line when there is one, else an open cross.
    /// `point` is in pixels from the image centre; `across` the line's unit
    /// normal, or nil.
    @objc(drawSlicePoint:across:hasLine:pixelSpacingX:pixelSpacingY:zoom:scale:)
    public static func drawSlicePoint(_ point: NSPoint, across: NSPoint, hasLine: Bool,
                                      pixelSpacingX sx: Double, pixelSpacingY sy: Double, zoom: Float, scale: CGFloat) {
        guard let canvas = ROICanvas.current else { return }
        let sf = Float(scale)
        let px = Float(point.x), py = Float(point.y)
        let length: Float = 15
        canvas.lineWidth(CGFloat(2 * sf))
        canvas.color(r: 0, g: CGFloat(Float(0.6)), b: 0, a: 1)
        canvas.lineWidth(CGFloat(2 * sf))
        canvas.begin(lines)
        if hasLine {
            let a0 = Float(across.x), a1 = Float(across.y)
            vertex(canvas, Float(Double(zoom) * (Double(px) - Double(length) / sx * Double(a0))), Float(Double(zoom) * (Double(py) + Double(length) / sy * Double(a1))))
            vertex(canvas, Float(Double(zoom) * (Double(px) + Double(length) / sx * Double(a0))), Float(Double(zoom) * (Double(py) - Double(length) / sy * Double(a1))))
        } else {
            func h(_ d: Double) -> Float { Float(Double(zoom) * (Double(px) + d / sx)) }
            func v(_ d: Double) -> Float { Float(Double(zoom) * (Double(py) + d / sx)) }
            let cy = zoom * py, cx = zoom * px
            vertex(canvas, h(-Double(length)), cy); vertex(canvas, h(-5), cy)
            vertex(canvas, h(Double(length)), cy); vertex(canvas, h(5), cy)
            vertex(canvas, cx, v(-Double(length))); vertex(canvas, cx, v(-5))
            vertex(canvas, cx, v(5)); vertex(canvas, cx, v(Double(length)))
        }
        canvas.end()
        canvas.lineWidth(CGFloat(1 * sf))
    }

    /// Enters the screen grid of the text and the ruler, in green.
    @objc(beginTextSize:)
    public static func beginText(size: NSSize) {
        guard let canvas = ROICanvas.current else { return }
        screen(canvas, size)
        canvas.color(r: 0, g: 1, b: 0, a: 1)
    }

    /// The ruler: a 10 cm scale (or 0.04 mm on a microscopic image) along the
    /// bottom and the left of `rect`, a grid centred on the frame, with ticks.
    /// Drawn in green in the screen grid, as the text over it.
    @objc(drawRulerRect:size:pixelSpacingX:pixelSpacingY:pixelRatio:zoom:scale:)
    public static func drawRuler(rect: NSRect, size: NSSize, pixelSpacingX sx: Double, pixelSpacingY sy: Double,
                                 pixelRatio ratio: Double, zoom: Float, scale: CGFloat) {
        guard let canvas = ROICanvas.current else { return }
        let sf = Float(scale)
        let yOffset = 24 * sf, xOffset = 32 * sf
        let z = Double(zoom)
        let ox = Double(rect.origin.x), oy = Double(rect.origin.y), rw = Double(rect.size.width), rh = Double(rect.size.height)
        canvas.lineWidth(CGFloat(1 * sf))
        canvas.begin(lines)
        func v(_ x: Double, _ y: Double) { vertex(canvas, Float(x), Float(y)) }
        let bottom = oy + rh / 2 - Double(yOffset), left = ox + -rw / 2 + Double(xOffset)
        // As the Objective-C evaluated them: `i * zoom` (and `* 10`) in floats,
        // the rest in doubles, each vertex handed over as a float.
        if sx != 0 && sx * 1000.0 < 1 {
            v(ox + z * (-0.02 / sx), bottom); v(ox + z * (0.02 / sx), bottom)
            v(left, oy + z * (-0.02 / sy * ratio)); v(left, oy + z * (0.02 / sy * ratio))
            for i in -20...20 {
                let length = Double(Int16(truncatingIfNeeded: Int(Float(i % 10 == 0 ? 10 : 5) * sf)))
                let step = Double(Float(i) * zoom) * 0.001
                v(ox + step / sx, bottom); v(ox + step / sx, bottom - length)
                v(left + length, oy + step / sy * ratio); v(left, oy + step / sy * ratio)
            }
        } else if sx != 0 && sy != 0 {
            v(ox + z * (-50 / sx), bottom); v(ox + z * (50 / sx), bottom)
            v(left, oy + z * (-50 / sy * ratio)); v(left, oy + z * (50 / sy * ratio))
            for i in -5...5 {
                let length = Double(Int16(truncatingIfNeeded: Int(Float(i % 5 == 0 ? 10 : 5) * sf)))
                let step = Double(Float(i) * zoom * 10)
                v(ox + step / sx, bottom); v(ox + step / sx, bottom - length)
                v(left + length, oy + step / sy * ratio); v(left, oy + step / sy * ratio)
            }
        }
        canvas.end()
    }
}

/// A double expression handed to a GLfloat parameter, as the canvas received it.
private func floatNarrowed(_ value: Double) -> CGFloat { CGFloat(Float(value)) }
/// A coordinate handed to DrawNSStringGL's `long` parameters: truncated toward zero.
private func longTruncated(_ value: Double) -> Int { value.isFinite ? Int(value.rounded(.towardZero)) : 0 }

/// One frame of the 3D view (`-[VRView drawRect:]`, #977): its preparation,
/// the render's outcome and its completion, with nothing kept between frames.
///
/// The first frame of a view prepares the 3D data, under a progress panel
/// that closes when the frame is done; that frame's completion also tells the
/// view to restore what the preparation borrowed (a 4D volume's two marker
/// pixels). A render that failed - VTK threw, which only the Objective-C++ can
/// catch - is reported once, by the view's error, after the frame.
@MainActor
@objc(HorosVRFrameCycle)
public final class VRFrameCycle: NSObject {
    /// What the view does once the frame is over.
    @objc(HorosVRFrameCompletion)
    public enum Completion: Int {
        /// Nothing more.
        case done = 0
        /// The first frame is over: restore what its preparation borrowed.
        case firstFrameDone = 1
    }

    @objc public let isFirstFrame: Bool
    /// Whether the render failed, which the view reports with its error.
    @objc public private(set) var failed = false
    private var progress: WaitRendering?

    private init(firstFrame: Bool) {
        isFirstFrame = firstFrame
        super.init()
    }

    /// Starts a frame; the first one shows its preparation's progress.
    @objc(beginFirstFrame:)
    public static func begin(firstFrame: Bool) -> VRFrameCycle {
        let frame = VRFrameCycle(firstFrame: firstFrame)
        if firstFrame {
            let progress: WaitRendering? = WaitRendering(NSLocalizedString("Preparing 3D data...", comment: ""))
            progress?.start()
            frame.progress = progress
        }
        return frame
    }

    /// Records the render's outcome. Returns whether the view shows its error:
    /// on a failure, unless it already has.
    @objc(renderSucceeded:errorShown:)
    public func render(succeeded: Bool, errorShown: Bool) -> Bool {
        failed = !succeeded
        return failed && !errorShown
    }

    /// Ends the frame: closes the first frame's progress.
    @objc public func finish() -> Completion {
        guard let progress else { return .done }
        progress.end()
        progress.close()
        self.progress = nil
        return .firstFrameDone
    }
}
