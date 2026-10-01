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

extension CGRect {
    /// Whether origin and size are all finite, told from their bits: Release
    /// builds the app's Swift with -Xcc -ffast-math, under which LLVM folds
    /// isFinite and isNaN to constants.
    var hasFiniteGeometry: Bool {
        let exponent = CGFloat.infinity.bitPattern
        return origin.x.bitPattern & exponent != exponent && origin.y.bitPattern & exponent != exponent &&
            size.width.bitPattern & exponent != exponent && size.height.bitPattern & exponent != exponent
    }
}

/// The ROIs' drawing, in Core Graphics.
///
/// The ROI classes describe their graphics as OpenGL's immediate mode did -
/// vertices between a begin and an end, a current colour, line width and
/// point size, a model-view matrix - and this canvas draws them into a bitmap
/// the size of the view, in backing pixels from the top left, with OpenGL's
/// rules: lines are separate segments without joins, a point is a square or,
/// smoothed, a disc, polygons are filled as fans of triangles, blending is
/// source-over on the colour's alpha or, with (ONE, ONE_MINUS_SRC_ALPHA),
/// additive, and nothing blends when blending is off.
@objc(HorosROICanvas)
public final class ROICanvas: NSObject {
    /// The canvas of the view being drawn, if any.
    // nonisolated(unsafe): set and cleared around a view's drawing and read by
    // the ROI drawing inside it, on the main thread where AppKit draws views.
    // Remove when the drawing helpers, Objective-C today, are Swift isolated to
    // the main actor.
    @objc nonisolated(unsafe) public static var current: ROICanvas?

    // OpenGL enumerants the ROI code passes.
    static let points: UInt32 = 0x0000, lines: UInt32 = 0x0001, lineLoop: UInt32 = 0x0002, lineStrip: UInt32 = 0x0003
    static let triangles: UInt32 = 0x0004, triangleStrip: UInt32 = 0x0005, triangleFan: UInt32 = 0x0006
    static let quads: UInt32 = 0x0007, quadStrip: UInt32 = 0x0008, polygon: UInt32 = 0x0009
    static let blendCap: UInt32 = 0x0BE2, pointSmooth: UInt32 = 0x0B10, lineSmooth: UInt32 = 0x0B20, polygonSmooth: UInt32 = 0x0B41
    static let lineStipple: UInt32 = 0x0B24, map1Vertex3: UInt32 = 0x0D97, one: UInt32 = 1

    private(set) var width = 0
    private(set) var height = 0
    private var context: CGContext?
    private var space: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    /// What this frame drew, in device pixels.
    private(set) var dirty = CGRect.null

    // OpenGL-like state.
    /// Model coordinates to OpenGL's clip coordinates: the model-view and
    /// projection matrices, column-major.
    private var matrix = matrix_identity_double4x4
    private var stack: [simd_double4x4] = []
    private var viewport = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var color: (CGFloat, CGFloat, CGFloat, CGFloat) = (1, 1, 1, 1)
    private var lineWidthValue: CGFloat = 1
    private var pointSizeValue: CGFloat = 1
    private var blending = false
    private var additive = false
    private var smoothPoints = false, smoothLines = false, smoothPolygons = false
    private var stipple: (factor: Int, pattern: UInt16)? = nil
    private var stippleOn = false
    private var mapOn = false
    private var map: [CGPoint] = []
    private var mode: UInt32?
    /// Clip coordinates, before OpenGL clips them to the depth range.
    private var vertices: [SIMD4<Double>] = []
    /// Each vertex's colour: OpenGL interpolates it along lines.
    private var vertexColors: [Color] = []
    typealias Color = (CGFloat, CGFloat, CGFloat, CGFloat)

    // MARK: Frame

    /// Two bitmaps, a frame each in turn: the one a frame hands to Core
    /// Animation is not drawn into again before the next frame replaces it,
    /// so its pixels are never copied.
    private var contexts: [CGContext?] = [nil, nil]
    private var buffers: [UnsafeMutableRawPointer?] = [nil, nil]

    deinit {
        buffers.forEach { free($0) }
    }
    /// The tiles each bitmap drew in, to clear before it is drawn again: the
    /// pieces a frame draws overlap - labels over their ROIs, a disc at every
    /// vertex of a spline - and a tile is cleared once however many drew in it.
    private var drawnTiles: [[Bool]] = [[], []]
    private static let tile = 32
    private var tilesAcross = 0, tilesDown = 0
    private var current = 0

    /// Starts a frame of `width` × `height` backing pixels.
    @objc(beginFrameWidth:height:colorSpace:)
    public func beginFrame(width: Int, height: Int, colorSpace: CGColorSpace?) {
        closeModelContext()
        let space = colorSpace ?? CGColorSpaceCreateDeviceRGB()
        current ^= 1
        if width != self.width || height != self.height || contexts[current] == nil || space != self.space {
            self.width = max(0, width)
            self.height = max(0, height)
            self.space = space
            buffers.forEach { free($0) }
            buffers = (0..<2).map { _ in self.width > 0 && self.height > 0 ? calloc(self.width * self.height, 4) : nil }
            contexts = buffers.map { buffer in
                buffer.flatMap {
                    CGContext(data: $0, width: self.width, height: self.height, bitsPerComponent: 8, bytesPerRow: self.width * 4,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                }
            }
            tilesAcross = (self.width + ROICanvas.tile - 1) / ROICanvas.tile
            tilesDown = (self.height + ROICanvas.tile - 1) / ROICanvas.tile
            drawnTiles = [[Bool]](repeating: [Bool](repeating: false, count: tilesAcross * tilesDown), count: 2)
        } else if let data = buffers[current] {
            // What this bitmap drew two frames ago, a run of tiles at a time.
            let tile = ROICanvas.tile
            drawnTiles[current].withUnsafeMutableBufferPointer { drawn in
                for ty in 0..<tilesDown {
                    var tx = 0
                    while tx < tilesAcross {
                        guard drawn[ty * tilesAcross + tx] else { tx += 1; continue }
                        var end = tx
                        while end < tilesAcross && drawn[ty * tilesAcross + end] { drawn[ty * tilesAcross + end] = false; end += 1 }
                        let x0 = tx * tile, bytes = (min(end * tile, self.width) - x0) * 4
                        for y in ty * tile..<min((ty + 1) * tile, self.height) { memset(data + (y * self.width + x0) * 4, 0, bytes) }
                        tx = end
                    }
                }
            }
        }
        context = contexts[current]
        dirty = .null
        clipRect = nil
        mode = nil
        vertices.removeAll(keepingCapacity: true)
    }

    /// The frame's pixels where it drew, and where they are: nil when
    /// nothing was drawn.
    func finishFrame() -> (picture: AnnotationPicture, rect: CGRect)? {
        closeModelContext()
        let rect = dirty.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        dirty = .null
        // The image reads the bitmap where the frame drew, without a copy: the
        // bitmap is not drawn into again until the next frame has replaced it.
        guard let data = buffers[current], !rect.isNull, !rect.isEmpty else { return nil }
        let x0 = Int(rect.minX), y0 = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
        let rowBytes = width * 4
        guard let provider = CGDataProvider(dataInfo: nil, data: data + y0 * rowBytes + x0 * 4, size: rowBytes * (h - 1) + w * 4,
                                            releaseData: { _, _, _ in }),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return (AnnotationPicture(image: image), rect)
    }

    /// The bitmap: premultiplied RGBA, rows from the top.
    var bytes: UnsafeMutablePointer<UInt8>? { buffers[current]?.assumingMemoryBound(to: UInt8.self) }

    /// The bitmap for a host that composites it itself.
    @objc public var pixels: UnsafeMutableRawPointer? { buffers[current] }
    @objc public var pixelWidth: Int { width }
    @objc public var pixelHeight: Int { height }
    /// What the frame drew so far, in device pixels from the top left.
    @objc public var drawnRect: CGRect { dirty.isNull ? .zero : dirty.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height)) }

    /// Clips what follows to a rectangle of device pixels from the top left,
    /// as OpenGL's scissor; a null rectangle clips nothing.
    @objc(clipTo:) public func clip(to rect: CGRect) { clipRect = rect.isEmpty ? nil : rect }
    private var clipRect: CGRect?

    private func applyClip(_ context: CGContext) {
        if let clipRect { context.clip(to: flip(clipRect)) }
    }

    // MARK: Frame state

    /// Starts a frame's graphics: a stipple or a curve map the last frame left
    /// on is off, as the view's OpenGL state used to be reset at each frame.
    @objc public func resetFrameState() {
        if ownsTransform { stippleOn = false; mapOn = false }
    }

    /// Whether set(modelview:viewport:) has given the canvas its transform: the
    /// DCMView family (#728) and the NavigatorView (#730) draw only through the
    /// canvas, and no OpenGL context is left to read one from (#735).
    private var ownsTransform = false

    /// Sets the state directly: the model-view matrix as the affine part of an
    /// OpenGL-style matrix, and the viewport. From then on the canvas keeps its
    /// own transform and state.
    @objc(setModelview:viewport:)
    public func set(modelview: CGAffineTransform, viewport: CGRect) {
        ownsTransform = true
        matrix = simd_double4x4(columns: (SIMD4(Double(modelview.a), Double(modelview.b), 0, 0), SIMD4(Double(modelview.c), Double(modelview.d), 0, 0),
                                          SIMD4(0, 0, 1, 0), SIMD4(Double(modelview.tx), Double(modelview.ty), 0, 1)))
        self.viewport = viewport
        stack.removeAll()
    }

    // MARK: Immediate mode

    @objc(begin:) public func begin(_ mode: UInt32) {
        self.mode = mode
        vertices.removeAll(keepingCapacity: true)
        vertexColors.removeAll(keepingCapacity: true)
    }

    @objc(vertexX:y:) public func vertex(x: CGFloat, y: CGFloat) {
        guard mode != nil else { return }
        vertices.append(matrix * SIMD4(Double(x), Double(y), 0, 1))
        vertexColors.append(color)
    }

    @objc(vertexX:y:z:) public func vertex(x: Double, y: Double, z: Double) {
        guard mode != nil else { return }
        vertices.append(matrix * SIMD4(x, y, z, 1))
        vertexColors.append(color)
    }

    @objc(evalCoord:) public func evalCoord(_ u: CGFloat) {
        guard mapOn, map.count >= 2 else { return }
        // A Bézier curve of the control points, as OpenGL's evaluator.
        var points = map
        while points.count > 1 {
            points = zip(points, points.dropFirst()).map { CGPoint(x: $0.x + ($1.x - $0.x) * u, y: $0.y + ($1.y - $0.y) * u) }
        }
        vertex(x: points[0].x, y: points[0].y)
    }

    @objc(map1Points:count:) public func map1(points: UnsafePointer<Float>, count: Int) {
        map = (0..<count).map { CGPoint(x: CGFloat(points[3 * $0]), y: CGFloat(points[3 * $0 + 1])) }
    }

    @objc public func end() {
        closeModelContext()
        guard let mode, let context else { self.mode = nil; return }
        self.mode = nil
        let v = vertices
        guard !v.isEmpty else { return }
        context.saveGState()
        applyClip(context)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let current = color
        let c = vertexColors
        func mix(_ a: Color, _ b: Color, _ t: CGFloat) -> Color {
            (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t, a.3 + (b.3 - a.3) * t)
        }
        // OpenGL clips what lies outside the depth range, -w ≤ z ≤ w.
        func lines(_ pairs: [(Int, Int)]) -> [Segment] {
            pairs.compactMap { i, j -> Segment? in
                guard let (t0, t1) = ROICanvas.clipRange(v[i], v[j]) else { return nil }
                let a = v[i] + (v[j] - v[i]) * t0, b = v[i] + (v[j] - v[i]) * t1
                return Segment(a: project(a), b: project(b), ca: mix(c[i], c[j], CGFloat(t0)), cb: mix(c[i], c[j], CGFloat(t1)))
            }
        }
        // Each polygon is filled whole, in the mean of its vertices' colours.
        func fills(_ list: [[Int]]) -> [([CGPoint], Color)] {
            list.compactMap { t -> ([CGPoint], Color)? in
                let q = ROICanvas.clipPolygon(t.map { v[$0] }).map(project)
                let n = CGFloat(t.count)
                let average = t.reduce((0, 0, 0, 0) as Color) { ($0.0 + c[$1].0 / n, $0.1 + c[$1].1 / n, $0.2 + c[$1].2 / n, $0.3 + c[$1].3 / n) }
                return q.count < 3 ? nil : (q, average)
            }
        }
        let n = v.count
        switch mode {
        case ROICanvas.points:
            var start = 0
            while start < n {
                // One fill a run of points of one colour.
                var stop = start + 1
                while stop < n && c[stop] == c[start] { stop += 1 }
                color = c[start]
                let size = pointSizeValue
                let centres = v[start..<stop].filter({ abs($0.z) <= $0.w }).map(project)
                if smoothPoints {
                    // A smoothed point is a disc, laid straight into the bitmap.
                    discs(centres, diameter: size)
                } else {
                    fill(context, antialias: false) { path in
                        for q in centres { path.addRect(CGRect(x: q.x - size / 2, y: q.y - size / 2, width: size, height: size)) }
                    }
                }
                start = stop
            }
        case ROICanvas.lines:
            segments(context, lines(stride(from: 0, to: n - 1, by: 2).map { ($0, $0 + 1) }))
        case ROICanvas.lineStrip where polylineAllowed(c):
            polyline(context, v, closed: false)
        case ROICanvas.lineLoop where polylineAllowed(c):
            polyline(context, v, closed: true)
        case ROICanvas.lineStrip:
            segments(context, lines(n < 2 ? [] : (0..<(n - 1)).map { ($0, $0 + 1) }))
        case ROICanvas.lineLoop:
            segments(context, lines((0..<n).map { ($0, ($0 + 1) % n) }.filter { n > 1 && $0.0 != $0.1 }))
        case ROICanvas.triangles:
            triangles(context, fills(stride(from: 0, to: n - 2, by: 3).map { [$0, $0 + 1, $0 + 2] }))
        case ROICanvas.triangleStrip, ROICanvas.quadStrip:
            triangles(context, fills(n < 3 ? [] : (0..<(n - 2)).map { [$0, $0 + 1, $0 + 2] }))
        case ROICanvas.quads:
            triangles(context, fills(stride(from: 0, to: n - 3, by: 4).map { [$0, $0 + 1, $0 + 2, $0 + 3] }))
        case ROICanvas.polygon, ROICanvas.triangleFan:
            triangles(context, fills(n < 3 ? [] : [Array(0..<n)]))
        default:
            break
        }
        color = current
        context.restoreGState()
    }

    @objc(colorR:g:b:a:) public func color(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) { color = (r, g, b, a) }
    @objc(lineWidth:) public func lineWidth(_ w: CGFloat) { lineWidthValue = w }
    @objc(pointSize:) public func pointSize(_ s: CGFloat) { pointSizeValue = s }

    @objc(enable:) public func enable(_ cap: UInt32) { set(cap, true) }
    @objc(disable:) public func disable(_ cap: UInt32) { set(cap, false) }

    private func set(_ cap: UInt32, _ on: Bool) {
        switch cap {
        case ROICanvas.blendCap: blending = on
        case ROICanvas.pointSmooth: smoothPoints = on
        case ROICanvas.lineSmooth: smoothLines = on
        case ROICanvas.polygonSmooth: smoothPolygons = on
        case ROICanvas.lineStipple: stippleOn = on
        case ROICanvas.map1Vertex3: mapOn = on
        default: break
        }
    }

    @objc(blendSource:destination:) public func blend(source: UInt32, destination: UInt32) { additive = source == ROICanvas.one }
    @objc(lineStippleFactor:pattern:) public func lineStipple(factor: Int, pattern: UInt16) { stipple = (max(1, factor), pattern) }

    private var saved: [(color: (CGFloat, CGFloat, CGFloat, CGFloat), line: CGFloat, point: CGFloat, blending: Bool, additive: Bool,
                         smooth: (Bool, Bool, Bool), stipple: Bool)] = []

    /// Saves the drawing state, as glPushAttrib for the enables, line, point,
    /// current colour and blending.
    @objc public func pushAttributes() {
        saved.append((color, lineWidthValue, pointSizeValue, blending, additive, (smoothPoints, smoothLines, smoothPolygons), stippleOn))
    }

    @objc public func popAttributes() {
        guard let last = saved.popLast() else { return }
        color = last.color; lineWidthValue = last.line; pointSizeValue = last.point
        blending = last.blending; additive = last.additive
        (smoothPoints, smoothLines, smoothPolygons) = last.smooth
        stippleOn = last.stipple
    }

    // The projection is the identity wherever the ROIs draw, so these act on
    // the model-view part as OpenGL's did.
    @objc public func loadIdentity() { matrix = matrix_identity_double4x4 }
    @objc public func pushMatrix() { stack.append(matrix) }
    @objc public func popMatrix() { if let last = stack.popLast() { matrix = last } }
    @objc(scaleX:y:z:) public func scale(x: Double, y: Double, z: Double) {
        matrix = matrix * simd_double4x4(diagonal: SIMD4(x, y, z, 1))
    }
    @objc(translateX:y:z:) public func translate(x: Double, y: Double, z: Double) {
        var t = matrix_identity_double4x4
        t.columns.3 = SIMD4(x, y, z, 1)
        matrix = matrix * t
    }
    @objc(rotate:) public func rotate(_ degrees: Double) {
        let a = degrees * .pi / 180
        var r = matrix_identity_double4x4
        r.columns.0 = SIMD4(cos(a), sin(a), 0, 0)
        r.columns.1 = SIMD4(-sin(a), cos(a), 0, 0)
        matrix = matrix * r
    }
    /// glMultMatrixd: a column-major 4 × 4 matrix.
    @objc(multMatrix:) public func mult(_ m: UnsafePointer<Double>) { matrix = matrix * ROICanvas.matrix(Array(UnsafeBufferPointer(start: m, count: 16))) }

    static func matrix(_ m: [Double]) -> simd_double4x4 {
        simd_double4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                 SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
    }

    /// Where a model point lands, in backing pixels from the top left.
    @objc(devicePointX:y:) public func devicePoint(x: CGFloat, y: CGFloat) -> CGPoint { device(CGPoint(x: x, y: y)) }

    // MARK: Core Graphics

    /// The canvas's context with the current model-view transform, for
    /// drawing in the view's image coordinates as the ROIs are; the whole
    /// view is kept, as what is drawn there is not known. Nil outside a frame.
    @objc public func modelContext() -> CGContext? {
        guard let context else { return nil }
        closeModelContext()
        context.saveGState()
        modelContextOpen = true
        // OpenGL's window coordinates are Core Graphics' own: pixels up from
        // the bottom left.
        let window = CGAffineTransform(a: viewport.width / 2, b: 0, c: 0, d: viewport.height / 2,
                                       tx: viewport.minX + viewport.width / 2, ty: viewport.minY + viewport.height / 2)
        let affine = CGAffineTransform(a: matrix.columns.0.x, b: matrix.columns.0.y, c: matrix.columns.1.x, d: matrix.columns.1.y,
                                       tx: matrix.columns.3.x, ty: matrix.columns.3.y)
        context.concatenate(affine.concatenating(window))
        mark(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    private var modelContextOpen = false

    private func closeModelContext() {
        if modelContextOpen { context?.restoreGState(); modelContextOpen = false }
    }

    // MARK: Pictures

    /// An 8-bit intensity texture over the quad from (x0, y0) to (x1, y1), in
    /// the current colour, as OpenGL's intensity texture modulated by the
    /// colour and blended on its alpha.
    @objc(drawIntensity:width:height:rowBytes:x0:y0:x1:y1:interpolate:)
    public func drawIntensity(_ data: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int,
                              x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, interpolate: Bool) {
        closeModelContext()
        guard let context, width > 0, height > 0,
              let provider = CGDataProvider(data: Data(bytes: data, count: rowBytes * height) as CFData),
              let mask = CGImage(maskWidth: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: rowBytes,
                                 provider: provider, decode: [1, 0], shouldInterpolate: interpolate)
        else { return }
        picture(context, x0: x0, y0: y0, x1: x1, y1: y0, x2: x0, y2: y1, width: width, height: height) { context, rect in
            context.interpolationQuality = interpolate ? .default : .none
            context.clip(to: rect, mask: mask)
            context.setFillColor(self.cgColor(self.color.0, self.color.1, self.color.2, self.color.3))
            context.fill(rect)
        }
    }

    /// ARGB pixels with straight alpha on the parallelogram whose corners the
    /// image's (0, 0), (w, 0) and (0, h) land on, blended on their alpha.
    @objc(drawARGB:width:height:rowBytes:x0:y0:x1:y1:x2:y2:interpolate:)
    public func drawARGB(_ data: UnsafePointer<UInt8>, width: Int, height: Int, rowBytes: Int,
                         x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat, interpolate: Bool) {
        closeModelContext()
        guard let context, width > 0, height > 0,
              let provider = CGDataProvider(data: Data(bytes: data, count: rowBytes * height) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: interpolate, intent: .defaultIntent)
        else { return }
        picture(context, x0: x0, y0: y0, x1: x1, y1: y1, x2: x2, y2: y2, width: width, height: height) { context, rect in
            context.interpolationQuality = interpolate ? .default : .none
            context.draw(image, in: rect)
        }
    }

    // MARK: Drawing

    private func device(_ point: CGPoint, z: Double = 0) -> CGPoint {
        project(matrix * SIMD4(Double(point.x), Double(point.y), z, 1))
    }

    private func project(_ clip: SIMD4<Double>) -> CGPoint {
        let w = clip.w == 0 ? 1 : clip.w
        let x = viewport.minX + (clip.x / w + 1) * viewport.width / 2
        let y = viewport.minY + (clip.y / w + 1) * viewport.height / 2
        return CGPoint(x: x, y: CGFloat(height) - y)
    }

    /// The part of a segment inside -w ≤ z ≤ w, as parameters along it.
    static func clipRange(_ a: SIMD4<Double>, _ b: SIMD4<Double>) -> (Double, Double)? {
        var t0 = 0.0, t1 = 1.0
        for sign in [1.0, -1.0] {
            let da = a.w - sign * a.z, db = b.w - sign * b.z
            if da < 0 && db < 0 { return nil }
            if da < 0 { t0 = max(t0, da / (da - db)) }
            if db < 0 { t1 = min(t1, da / (da - db)) }
        }
        return t0 <= t1 ? (t0, t1) : nil
    }

    /// The part of a segment inside -w ≤ z ≤ w.
    static func clipSegment(_ a: SIMD4<Double>, _ b: SIMD4<Double>) -> (SIMD4<Double>, SIMD4<Double>)? {
        var t0 = 0.0, t1 = 1.0
        for sign in [1.0, -1.0] {
            // Inside where w - sign·z ≥ 0.
            let da = a.w - sign * a.z, db = b.w - sign * b.z
            if da < 0 && db < 0 { return nil }
            if da < 0 { t0 = max(t0, da / (da - db)) }
            if db < 0 { t1 = min(t1, da / (da - db)) }
        }
        guard t0 <= t1 else { return nil }
        return (a + (b - a) * t0, a + (b - a) * t1)
    }

    /// A convex polygon clipped to -w ≤ z ≤ w.
    static func clipPolygon(_ polygon: [SIMD4<Double>]) -> [SIMD4<Double>] {
        var out = polygon
        for sign in [1.0, -1.0] {
            let input = out
            out = []
            guard !input.isEmpty else { break }
            for (i, current) in input.enumerated() {
                let next = input[(i + 1) % input.count]
                let dc = current.w - sign * current.z, dn = next.w - sign * next.z
                if dc >= 0 { out.append(current) }
                if (dc >= 0) != (dn >= 0) { out.append(current + (next - current) * (dc / (dc - dn))) }
            }
        }
        return out
    }

    private func flip(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
    }

    private func cgColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        CGColor(colorSpace: space, components: [min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1), min(max(a, 0), 1)])
            ?? CGColor(gray: 1, alpha: 1)
    }

    /// Sets how the current colour lands: blended on its alpha, added, or
    /// written as it is with blending off. False when it leaves nothing.
    private func paint(_ context: CGContext, fill: Bool) -> Bool {
        var (r, g, b, a) = color
        if !blending {
            a = 1
        } else if additive {
            // (ONE, ONE_MINUS_SRC_ALPHA): the colour is added and the
            // destination kept by 1 - alpha, source-over of colour / alpha.
            // A colour with no alpha would be added to the image beneath,
            // which a layer over it cannot do: it leaves nothing.
            guard a > 0 else { return false }
            r = min(1, r / a); g = min(1, g / a); b = min(1, b / a)
        } else if a <= 0 {
            return false
        }
        let paint = cgColor(r, g, b, a)
        if fill { context.setFillColor(paint) } else { context.setStrokeColor(paint) }
        return true
    }

    private func mark(_ rect: CGRect) {
        guard !rect.isNull, rect.hasFiniteGeometry else { return }
        let r = rect.insetBy(dx: -2, dy: -2)
        dirty = dirty.union(r)
        let b = r.insetBy(dx: -1, dy: -1).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !b.isNull, !b.isEmpty, drawnTiles[current].count == tilesAcross * tilesDown else { return }
        let tile = ROICanvas.tile
        let tx0 = Int(b.minX) / tile, tx1 = (Int(b.maxX.rounded(.up)) - 1) / tile
        let ty0 = Int(b.minY) / tile, ty1 = (Int(b.maxY.rounded(.up)) - 1) / tile
        guard tx0 <= tx1, ty0 <= ty1 else { return }
        drawnTiles[current].withUnsafeMutableBufferPointer { drawn in
            for ty in ty0...ty1 { for tx in tx0...tx1 { drawn[ty * tilesAcross + tx] = true } }
        }
    }

    private func fill(_ context: CGContext, antialias: Bool, _ build: (CGMutablePath) -> Void) {
        let path = CGMutablePath()
        build(path)
        guard !path.isEmpty, paint(context, fill: true) else { return }
        context.setShouldAntialias(antialias)
        context.addPath(path)
        context.fillPath()
        mark(path.boundingBoxOfPath)
    }

    /// A strip of one colour, smooth and solid, is stroked as one polyline:
    /// the same pixels as its segments but for the joins, and one pass of
    /// the rasterizer instead of one a segment.
    private func polylineAllowed(_ colours: [Color]) -> Bool {
        smoothLines && !stippleOn && vertices.count > 2 && colours.allSatisfy { $0 == colours[0] }
            && vertices.allSatisfy { abs($0.z) <= $0.w }
    }

    private func polyline(_ context: CGContext, _ v: [SIMD4<Double>], closed: Bool) {
        guard paint(context, fill: false) else { return }
        let points = v.map(project)
        context.setShouldAntialias(true)
        context.setLineWidth(max(lineWidthValue, 0.5))
        context.setLineCap(.butt)
        context.setLineJoin(.bevel)
        context.addLines(between: points)
        if closed { context.closePath() }
        context.strokePath()
        // Segment by segment: the tiles a long curve crosses, not its box.
        for (a, b) in zip(points, points.dropFirst() + (closed ? [points[0]] : [])) {
            mark(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -lineWidthValue, dy: -lineWidthValue))
        }
    }

    /// Antialiased discs straight into the bitmap: coverage falls off over a
    /// pixel at the rim, and each disc blends over what is there.
    private func discs(_ centres: [CGPoint], diameter: CGFloat) {
        guard let data = bytes, !centres.isEmpty, let ink = ink() else { return }
        let radius = diameter / 2
        let outer = (radius + 0.5) * (radius + 0.5)
        // Wholly inside where the distance is at most radius - 0.5.
        let inner = radius >= 0.5 ? (radius - 0.5) * (radius - 0.5) : -1
        let limit = clipRect ?? CGRect(x: 0, y: 0, width: width, height: height)
        for c in centres {
            let x0 = max(Int(floor(max(limit.minX, c.x - radius - 1))), 0), x1 = min(Int(ceil(min(limit.maxX, c.x + radius + 1))), width)
            let y0 = max(Int(floor(max(limit.minY, c.y - radius - 1))), 0), y1 = min(Int(ceil(min(limit.maxY, c.y + radius + 1))), height)
            guard x0 < x1, y0 < y1 else { continue }
            for y in y0..<y1 {
                let dy = CGFloat(y) + 0.5 - c.y, dy2 = dy * dy
                guard dy2 < outer else { continue }
                // Only the pixels whose centres fall within the rim's reach.
                let reach = (outer - dy2).squareRoot()
                let s0 = max(x0, Int(floor(c.x - reach - 0.5))), s1 = min(x1, Int(ceil(c.x + reach - 0.5)) + 1)
                guard s0 < s1 else { continue }
                let row = data + y * width * 4
                for x in s0..<s1 {
                    let dx = CGFloat(x) + 0.5 - c.x, d2 = dx * dx + dy2
                    if d2 <= inner {
                        ink.lay(row + x * 4)
                    } else {
                        let coverage = min(1, max(0, radius + 0.5 - d2.squareRoot()))
                        if coverage > 0 { ink.lay(row + x * 4, coverage: coverage) }
                    }
                }
            }
            mark(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
        }
    }

    /// The current colour as it lands on the bitmap, as paint(_:fill:) sets
    /// it for Core Graphics; nil when it leaves nothing.
    private func ink() -> Ink? {
        var (r, g, b, a) = color
        if !blending { a = 1 } else if additive { guard a > 0 else { return nil }; r = min(1, r / a); g = min(1, g / a); b = min(1, b / a) }
        guard a > 0 else { return nil }
        return Ink(r: min(max(r, 0), 1), g: min(max(g, 0), 1), b: min(max(b, 0), 1), a: min(a, 1))
    }

    /// A colour blended over premultiplied RGBA pixels on its alpha times a
    /// coverage, as source-over.
    struct Ink {
        let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
        /// The pixel it leaves at full coverage when it is opaque.
        let solid: UInt32?

        init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
            self.r = r; self.g = g; self.b = b; self.a = a
            if a >= 1 {
                let bytes = [r, g, b, 1].map { UInt32(($0 * 255).rounded()) }
                solid = bytes[0] | bytes[1] << 8 | bytes[2] << 16 | bytes[3] << 24
            } else {
                solid = nil
            }
        }

        @inline(__always) func lay(_ p: UnsafeMutablePointer<UInt8>, coverage: CGFloat = 1) {
            if coverage >= 1, let solid {
                UnsafeMutableRawPointer(p).storeBytes(of: solid.littleEndian, as: UInt32.self)
                return
            }
            let alpha = a * coverage, keep = 1 - alpha
            p[0] = UInt8(min(255, (r * alpha * 255 + CGFloat(p[0]) * keep).rounded()))
            p[1] = UInt8(min(255, (g * alpha * 255 + CGFloat(p[1]) * keep).rounded()))
            p[2] = UInt8(min(255, (b * alpha * 255 + CGFloat(p[2]) * keep).rounded()))
            p[3] = UInt8(min(255, (alpha * 255 + CGFloat(p[3]) * keep).rounded()))
        }
    }

    struct Segment {
        let a: CGPoint, b: CGPoint
        let ca: Color, cb: Color
    }

    private func segments(_ context: CGContext, _ list: [Segment]) {
        guard !list.isEmpty else { return }
        context.setShouldAntialias(smoothLines)
        context.setLineWidth(max(lineWidthValue, 0.5))
        context.setLineCap(.butt)
        var phase: CGFloat = 0
        let dash: [CGFloat]? = stippleOn ? stipple.map { ROICanvas.dashes($0.pattern, factor: $0.factor) } : nil
        let period = dash?.reduce(0, +) ?? 0
        let width = max(lineWidthValue, 1)
        let current = color
        // Pieces of one colour go in one path, drawn at once: a separate
        // subpath each, without joins, as OpenGL's separate segments.
        var pathColor: Color?
        var batch = CGMutablePath()
        for segment in list {
            let a = segment.a, b = segment.b
            // A colour that changes along the segment, in steps.
            let same = segment.ca == segment.cb
            let steps = same ? 1 : max(2, min(32, Int(hypot(b.x - a.x, b.y - a.y) / 4)))
            for k in 0..<steps {
                let t0 = CGFloat(k) / CGFloat(steps), t1 = CGFloat(k + 1) / CGFloat(steps), tm = (t0 + t1) / 2
                let p = CGPoint(x: a.x + (b.x - a.x) * t0, y: a.y + (b.y - a.y) * t0)
                let q = CGPoint(x: a.x + (b.x - a.x) * t1, y: a.y + (b.y - a.y) * t1)
                let c: Color = (segment.ca.0 + (segment.cb.0 - segment.ca.0) * tm, segment.ca.1 + (segment.cb.1 - segment.ca.1) * tm,
                                segment.ca.2 + (segment.cb.2 - segment.ca.2) * tm, segment.ca.3 + (segment.cb.3 - segment.ca.3) * tm)
                if let dash, period > 0 {
                    // A dashed piece carries its own phase.
                    color = c
                    if paint(context, fill: false) {
                        context.setLineDash(phase: phase, lengths: dash)
                        context.move(to: p); context.addLine(to: q); context.strokePath()
                    }
                } else if !smoothLines {
                    // Runs of whole pixels need no rasterizer: they go straight
                    // into the bitmap, each segment on its own as OpenGL's.
                    color = c
                    if let ink = ink() { aliasedRuns(p, q, width: width, ink: ink) }
                } else {
                    if let pc = pathColor, pc != c {
                        context.addPath(batch); batch = CGMutablePath()
                        color = pc
                        if paint(context, fill: false) { context.strokePath() } else { context.beginPath() }
                    }
                    pathColor = c
                    batch.move(to: p); batch.addLine(to: q)
                }
                phase = (phase + hypot(q.x - p.x, q.y - p.y)).truncatingRemainder(dividingBy: max(period, 1))
            }
            mark(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -lineWidthValue, dy: -lineWidthValue))
        }
        if let pc = pathColor, !batch.isEmpty {
            context.addPath(batch)
            color = pc
            if paint(context, fill: false) { context.strokePath() } else { context.beginPath() }
        }
        color = current
    }

    /// An aliased line lights, at each pixel centre along its major axis, a
    /// run of `width` pixels across the minor one, the last pixel left to the
    /// next segment.
    private func aliasedRuns(_ a: CGPoint, _ b: CGPoint, width: CGFloat, ink: Ink) {
        guard let data = bytes else { return }
        let run = max(1, Int(width.rounded()))
        let xMajor = abs(b.x - a.x) >= abs(b.y - a.y)
        let (u0, u1, v0, v1) = xMajor ? (a.x, b.x, a.y, b.y) : (a.y, b.y, a.x, b.x)
        let du = u1 - u0
        guard du != 0 else { return }
        let first = Int(ceil(min(u0, u1) - 0.5)), last = Int(ceil(max(u0, u1) - 0.5)) - 1
        guard first <= last else { return }
        // Whole pixels inside the clip, as the scissor keeps them.
        let limit = clipRect ?? CGRect(x: 0, y: 0, width: self.width, height: self.height)
        let lx0 = max(0, Int(ceil(limit.minX - 0.5))), lx1 = min(self.width, Int(ceil(limit.maxX - 0.5)))
        let ly0 = max(0, Int(ceil(limit.minY - 0.5))), ly1 = min(self.height, Int(ceil(limit.maxY - 0.5)))
        for i in first...last {
            let c = CGFloat(i) + 0.5
            let v = v0 + (c - u0) * (v1 - v0) / du
            // A run starting exactly on a pixel border takes the pixel before it,
            // left across x and up across y, as OpenGL's rasterizer does. A
            // border within rounding of the arithmetic counts as one.
            var edge = v - CGFloat(run - 1) / 2
            if abs(edge - edge.rounded()) < 1e-4 { edge = edge.rounded() }
            let start = Int(ceil(edge)) - 1
            let (x0, x1, y0, y1) = xMajor ? (i, i + 1, start, start + run) : (start, start + run, i, i + 1)
            for y in max(y0, ly0)..<max(max(y0, ly0), min(y1, ly1)) {
                let row = data + y * self.width * 4
                for x in max(x0, lx0)..<max(max(x0, lx0), min(x1, lx1)) { ink.lay(row + x * 4) }
            }
        }
    }

    /// OpenGL's 16-bit stipple, lowest bit first, as dash lengths starting with a dash.
    static func dashes(_ pattern: UInt16, factor: Int) -> [CGFloat] {
        var runs: [CGFloat] = []
        var current = pattern & 1 != 0, run = 0
        for bit in 0..<16 {
            let on = (pattern >> bit) & 1 != 0
            if on == current { run += 1 } else { runs.append(CGFloat(run * factor)); current = on; run = 1 }
        }
        runs.append(CGFloat(run * factor))
        if pattern & 1 == 0 { runs.insert(0, at: 0) }
        if runs.count % 2 == 1 { runs.append(0) }
        return runs
    }

    private func triangles(_ context: CGContext, _ list: [([CGPoint], Color)]) {
        guard !list.isEmpty else { return }
        context.setShouldAntialias(smoothPolygons)
        let current = color
        var box = CGRect.null
        for (t, c) in list {
            color = c
            guard paint(context, fill: true) else { continue }
            // Each primitive blends on its own, as OpenGL fills them.
            context.move(to: t[0])
            for q in t.dropFirst() { context.addLine(to: q) }
            context.closePath()
            context.fillPath()
            for q in t { box = box.union(CGRect(origin: q, size: .zero)) }
        }
        color = current
        mark(box)
    }

    private func picture(_ context: CGContext, x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat,
                         width: Int, height: Int, draw: (CGContext, CGRect) -> Void) {
        // Image pixel (u, v), v down, to device pixels, v down.
        let o = device(CGPoint(x: x0, y: y0)), u = device(CGPoint(x: x1, y: y1)), v = device(CGPoint(x: x2, y: y2))
        let w = CGFloat(width), h = CGFloat(height)
        let toDevice = CGAffineTransform(a: (u.x - o.x) / w, b: (u.y - o.y) / w, c: (v.x - o.x) / h, d: (v.y - o.y) / h, tx: o.x, ty: o.y)
        context.saveGState()
        applyClip(context)
        context.translateBy(x: 0, y: CGFloat(self.height))
        context.scaleBy(x: 1, y: -1)
        context.concatenate(toDevice)
        // Core Graphics puts an image's first row at the top of its rectangle.
        context.translateBy(x: 0, y: h)
        context.scaleBy(x: 1, y: -1)
        draw(context, CGRect(x: 0, y: 0, width: w, height: h))
        context.restoreGState()
        let far = CGPoint(x: u.x + v.x - o.x, y: u.y + v.y - o.y)
        mark([o, u, v, far].reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) })
    }
}
