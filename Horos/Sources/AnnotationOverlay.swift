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

/// Premultiplied RGBA8 pixels, rows from the top.
final class AnnotationPicture {
    let width: Int
    let height: Int
    private var storedBytes: [UInt8]?
    private var cachedImage: CGImage?

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        storedBytes = bytes
    }

    /// An image already in the screen's colour space, read only if a
    /// capture needs its bytes.
    init(image: CGImage) {
        width = image.width
        height = image.height
        cachedImage = image
    }

    var bytes: [UInt8] {
        if let storedBytes { return storedBytes }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        if let image = cachedImage, let space = image.colorSpace {
            out.withUnsafeMutableBytes { buffer in
                if let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                           space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    context.setBlendMode(.copy)
                    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
            }
        }
        storedBytes = out
        return out
    }

    /// The bytes as an image in `space`. OpenGL put the texture's bytes on
    /// the screen untouched, which is what an image in the screen's own
    /// colour space does.
    func image(in space: CGColorSpace) -> CGImage? {
        if let cachedImage, cachedImage.colorSpace == space || storedBytes == nil { return cachedImage }
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: Data(bytes) as CFData)
        else { return nil }
        cachedImage = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        return cachedImage
    }

    /// The picture as it looks once the whole frame is inverted: straight
    /// colour c becomes 1 - c, which on premultiplied bytes is alpha - c.
    func inverted() -> AnnotationPicture {
        var out = bytes
        for i in stride(from: 0, to: out.count, by: 4) {
            let a = out[i + 3]
            out[i] = a &- min(a, out[i]); out[i + 1] = a &- min(a, out[i + 1]); out[i + 2] = a &- min(a, out[i + 2])
        }
        return AnnotationPicture(width: width, height: height, bytes: out)
    }
}

/// An RGBA colour as OpenGL's glColor4f took it: the components as given.
struct AnnotationTint: Hashable {
    let r: Float, g: Float, b: Float, a: Float

    init(_ color: NSColor) {
        let rgb = color.colorSpace.colorSpaceModel == .rgb ? color : (color.usingColorSpace(.deviceRGB) ?? .white)
        r = Float(rgb.redComponent); g = Float(rgb.greenComponent); b = Float(rgb.blueComponent); a = Float(rgb.alphaComponent)
    }

    init(r: Float, g: Float, b: Float, a: Float) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    static let white = AnnotationTint(r: 1, g: 1, b: 1, a: 1)
    static let black = AnnotationTint(r: 0, g: 0, b: 0, a: 1)
}

/// A string rasterized the way the viewer's annotation textures always were:
/// white antialiased glyphs drawn at 4 × 2 points of margin in a calibrated
/// RGB bitmap of ceil(frame × scale) pixels, one texel to a backing pixel.
@objc(HorosAnnotationText)
public final class AnnotationText: NSObject {
    @objc public let pixelWidth: Int
    @objc public let pixelHeight: Int
    /// The bitmap's size in points: the string's size and its margins, rounded up.
    @objc public let frameSize: NSSize
    /// The width of the string itself, without the margins, in pixels.
    @objc public let stringWidth: CGFloat
    /// Where the string's line ends at the bottom, in pixels from the bottom
    /// of the bitmap: its margin.
    @objc public let lineBottom: CGFloat
    let glyphs: AnnotationPicture
    private var shadowed: [[AnnotationTint]: AnnotationPicture] = [:]
    private var shadowedOnAlpha: [[AnnotationTint]: AnnotationPicture] = [:]

    private static let cache: NSCache<NSArray, AnnotationText> = {
        let cache = NSCache<NSArray, AnnotationText>()
        cache.countLimit = 800
        return cache
    }()

    @objc(textForString:font:scale:cacheToken:)
    public static func text(for string: String, font: NSFont, scale: CGFloat, cacheToken: String) -> AnnotationText {
        let key = [string, font, scale, cacheToken] as NSArray
        if let cached = cache.object(forKey: key) { return cached }
        let text = AnnotationText(string: string, font: font, scale: scale)
        cache.setObject(text, forKey: key)
        return text
    }

    @objc public static func purgeCache() {
        cache.removeAllObjects()
    }

    init(string: String, font: NSFont, scale requested: CGFloat) {
        let scale = requested == 1 || requested == 2 ? requested : (NSScreen.main?.backingScaleFactor ?? 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let attributed = NSAttributedString(string: string, attributes: attributes)
        let size = attributed.size()
        let frame = NSSize(width: ceil(size.width + 8), height: ceil(size.height + 4))
        let wide = Int(ceil(frame.width * scale)), high = Int(ceil(frame.height * scale))
        var bytes = [UInt8]()
        if wide > 0, high > 0,
           let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                                         bitmapFormat: [], bytesPerRow: 0, bitsPerPixel: 32),
           let data = bitmap.bitmapData {
            memset(data, 0, bitmap.bytesPerRow * high)
            bitmap.size = frame
            if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.shouldAntialias = true
                NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1).set()
                attributed.draw(at: NSPoint(x: 4, y: 2))
                NSGraphicsContext.restoreGraphicsState()
            }
            bytes.reserveCapacity(wide * high * 4)
            for row in 0..<high {
                bytes.append(contentsOf: UnsafeBufferPointer(start: data + row * bitmap.bytesPerRow, count: wide * 4))
            }
        }
        pixelWidth = bytes.isEmpty ? 0 : wide
        pixelHeight = bytes.isEmpty ? 0 : high
        stringWidth = size.width * scale
        frameSize = frame
        lineBottom = 2 * scale
        glyphs = AnnotationPicture(width: pixelWidth, height: pixelHeight, bytes: bytes)
    }

    /// The glyphs in `text` over their own copy in `shadow` one pixel right
    /// and down, which is what drawing the texture twice through GL_MODULATE
    /// and (ONE, ONE_MINUS_SRC_ALPHA) left on the screen; `blendOnAlpha`,
    /// through (SRC_ALPHA, ONE_MINUS_SRC_ALPHA), which weighs the modulated
    /// colour by its alpha once more.
    func picture(text: AnnotationTint, shadow: AnnotationTint, blendOnAlpha: Bool = false) -> AnnotationPicture {
        if let done = (blendOnAlpha ? shadowedOnAlpha : shadowed)[[text, shadow]] { return done }
        let w = pixelWidth + 1, h = pixelHeight + 1
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let source = glyphs.bytes
        let tints = [text.r, text.g, text.b, text.a], shades = [shadow.r, shadow.g, shadow.b, shadow.a]
        if pixelWidth > 0 {
            for y in 0..<h {
                for x in 0..<w {
                    var t: (Float, Float, Float, Float) = (0, 0, 0, 0), s: (Float, Float, Float, Float) = (0, 0, 0, 0)
                    if x < pixelWidth, y < pixelHeight {
                        let i = (y * pixelWidth + x) * 4
                        t = (Float(source[i]) * tints[0], Float(source[i + 1]) * tints[1], Float(source[i + 2]) * tints[2], Float(source[i + 3]) * tints[3])
                    }
                    if x > 0, y > 0 {
                        let i = ((y - 1) * pixelWidth + x - 1) * 4
                        s = (Float(source[i]) * shades[0], Float(source[i + 1]) * shades[1], Float(source[i + 2]) * shades[2], Float(source[i + 3]) * shades[3])
                    }
                    if blendOnAlpha {
                        t = (t.0 * t.3 / 255, t.1 * t.3 / 255, t.2 * t.3 / 255, t.3)
                        s = (s.0 * s.3 / 255, s.1 * s.3 / 255, s.2 * s.3 / 255, s.3)
                    }
                    let keep = 1 - t.3 / 255
                    let o = (y * w + x) * 4
                    out[o] = UInt8(min(255, t.0 + s.0 * keep).rounded())
                    out[o + 1] = UInt8(min(255, t.1 + s.1 * keep).rounded())
                    out[o + 2] = UInt8(min(255, t.2 + s.2 * keep).rounded())
                    out[o + 3] = UInt8(min(255, t.3 + s.3 * keep).rounded())
                }
            }
        }
        let picture = AnnotationPicture(width: w, height: h, bytes: out)
        if blendOnAlpha { shadowedOnAlpha[[text, shadow]] = picture } else { shadowed[[text, shadow]] = picture }
        return picture
    }
}

/// A string on a rounded box, rasterized as the viewer's boxed labels were:
/// at one pixel to the point, the frame the string's truncated size plus 4 × 2
/// points of margin, drawn stretched to the backing size.
@objc(HorosAnnotationBox)
public final class AnnotationBox: NSObject {
    @objc public private(set) var frameSize: NSSize = .zero
    private var attributed: NSAttributedString
    private var boxColor: NSColor
    private var borderColor: NSColor
    private var cached: AnnotationPicture?

    @objc(initWithAttributedString:boxColor:borderColor:)
    public init(attributedString: NSAttributedString, boxColor: NSColor, borderColor: NSColor) {
        attributed = attributedString
        self.boxColor = boxColor
        self.borderColor = borderColor
        super.init()
        measure()
    }

    @objc(setAttributedString:boxColor:borderColor:)
    public func set(attributedString: NSAttributedString, boxColor: NSColor, borderColor: NSColor) {
        attributed = attributedString
        self.boxColor = boxColor
        self.borderColor = borderColor
        cached = nil
        measure()
    }

    private func measure() {
        let size = attributed.size()
        frameSize = NSSize(width: CGFloat(Int(size.width)) + 8, height: CGFloat(Int(size.height)) + 4)
    }

    var picture: AnnotationPicture {
        if let cached { return cached }
        let wide = Int(frameSize.width), high = Int(frameSize.height)
        var bytes = [UInt8]()
        if wide > 0, high > 0,
           let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                                         bytesPerRow: wide * 4, bitsPerPixel: 32),
           let data = bitmap.bitmapData,
           let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.shouldAntialias = true
            let edge = NSRect(x: 0, y: 0, width: frameSize.width - 1, height: frameSize.height - 1).insetBy(dx: 0.5, dy: 0.5)
            if boxColor.alphaComponent != 0 {
                boxColor.set()
                AnnotationBox.roundedRect(edge, radius: 4).fill()
            }
            if borderColor.alphaComponent != 0 {
                borderColor.set()
                let path = AnnotationBox.roundedRect(edge, radius: 4)
                path.lineWidth = 1
                path.stroke()
            }
            attributed.draw(at: NSPoint(x: 4, y: 2))
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            bytes = Array(UnsafeBufferPointer(start: data, count: wide * high * 4))
        }
        let picture = AnnotationPicture(width: bytes.isEmpty ? 0 : wide, height: bytes.isEmpty ? 0 : high, bytes: bytes)
        cached = picture
        return picture
    }

    /// The same four tangent arcs the boxed labels were outlined with.
    static func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        guard !rect.isEmpty else { return path }
        guard radius > 0 else { path.appendRect(rect); return path }
        let r = min(radius, 0.5 * min(rect.width, rect.height))
        let topLeft = NSPoint(x: rect.minX, y: rect.maxY), topRight = NSPoint(x: rect.maxX, y: rect.maxY)
        let bottomRight = NSPoint(x: rect.maxX, y: rect.minY)
        path.move(to: NSPoint(x: rect.midX, y: rect.maxY))
        path.appendArc(from: topLeft, to: rect.origin, radius: r)
        path.appendArc(from: rect.origin, to: bottomRight, radius: r)
        path.appendArc(from: bottomRight, to: topRight, radius: r)
        path.appendArc(from: topRight, to: topLeft, radius: r)
        path.close()
        return path
    }
}

/// The viewer's text, drawn above its OpenGL content by Core Animation.
///
/// The view records each string of a frame where OpenGL would have drawn it,
/// in backing pixels from the top left, and commits the frame when it has
/// drawn; captures read the OpenGL pixels and composite the same frame onto
/// them with OpenGL's arithmetic.
@objc(HorosAnnotationOverlay)
public final class AnnotationOverlay: NSView {
    private struct Item {
        let picture: AnnotationPicture
        /// Where the picture lands, in backing pixels from the top left.
        let rect: CGRect
    }

    private var pending: [Item] = []
    private var drawn: [Item] = []
    private var drawnInverted = false
    private var layers: [CALayer] = []
    /// Where the frame's ROIs and other graphics are drawn; its pixels go
    /// beneath the text.
    @objc public let canvas = ROICanvas()

    @objc(overlayForView:)
    public static func overlay(for host: NSView) -> AnnotationOverlay {
        if let existing = host.subviews.last(where: { $0 is AnnotationOverlay }) as? AnnotationOverlay { return existing }
        let overlay = AnnotationOverlay(frame: host.bounds)
        overlay.autoresizingMask = [.width, .height]
        host.addSubview(overlay)
        return overlay
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() {}
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override var acceptsFirstResponder: Bool { false }

    @objc public func beginFrame() {
        pending.removeAll(keepingCapacity: true)
    }

    /// Starts a frame of the view's `width` × `height` backing pixels; the
    /// canvas becomes the current one until the frame is committed.
    @objc(beginFrameWidth:height:)
    public func beginFrame(width: Int, height: Int) {
        beginFrame()
        canvas.beginFrame(width: width, height: height, colorSpace: window?.colorSpace?.cgColorSpace)
        ROICanvas.current = canvas
    }

    /// A rectangle of one premultiplied colour, which may carry no alpha and
    /// then adds to what is beneath, as (ONE, ONE_MINUS_SRC_ALPHA) did.
    @objc(addFillRed:green:blue:alpha:rect:)
    public func addFill(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat, rect: CGRect) {
        guard rect.width > 0, rect.height > 0 else { return }
        func byte(_ v: CGFloat) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        pending.append(Item(picture: AnnotationPicture(width: 1, height: 1, bytes: [byte(red), byte(green), byte(blue), byte(alpha)]), rect: rect))
    }

    /// A string whose glyphs' top left lands at (x, y), with its shadow a
    /// pixel right and down.
    @objc(addText:x:y:textColor:shadowColor:)
    public func add(text: AnnotationText, x: CGFloat, y: CGFloat, textColor: NSColor, shadowColor: NSColor) {
        add(text: text, x: x, y: y, textColor: textColor, shadowColor: shadowColor, blendOnAlpha: false)
    }

    @objc(addText:x:y:textColor:shadowColor:blendOnAlpha:)
    public func add(text: AnnotationText, x: CGFloat, y: CGFloat, textColor: NSColor, shadowColor: NSColor, blendOnAlpha: Bool) {
        guard text.pixelWidth > 0 else { return }
        let picture = text.picture(text: AnnotationTint(textColor), shadow: AnnotationTint(shadowColor), blendOnAlpha: blendOnAlpha)
        pending.append(Item(picture: picture, rect: CGRect(x: x, y: y, width: CGFloat(picture.width), height: CGFloat(picture.height))))
    }

    @objc(addBox:rect:)
    public func add(box: AnnotationBox, rect: CGRect) {
        let picture = box.picture
        guard picture.width > 0, rect.width > 0, rect.height > 0 else { return }
        pending.append(Item(picture: picture, rect: rect))
    }

    /// Shows the recorded frame. `inverted` when the frame beneath is
    /// inverted after its text was drawn.
    @objc(commitInverted:scale:)
    public func commit(inverted: Bool, scale: CGFloat) {
        if ROICanvas.current === canvas { ROICanvas.current = nil }
        if let graphics = canvas.finishFrame() {
            pending.insert(Item(picture: graphics.picture, rect: graphics.rect), at: 0)
        }
        // A view drawn at no size maps its graphics through a degenerate
        // transform, to no place: Core Animation rejects such a frame.
        pending.removeAll { !($0.rect.minX.isFinite && $0.rect.minY.isFinite && $0.rect.width.isFinite && $0.rect.height.isFinite) }
        drawn = inverted ? pending.map { Item(picture: $0.picture.inverted(), rect: $0.rect) } : pending
        drawnInverted = inverted
        guard let root = layer else { return }
        let factor = scale > 0 ? scale : 1
        let space = window?.colorSpace?.cgColorSpace ?? CGColorSpaceCreateDeviceRGB()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while layers.count < drawn.count {
            let sublayer = CALayer()
            sublayer.anchorPoint = .zero
            root.addSublayer(sublayer)
            layers.append(sublayer)
        }
        for (index, sublayer) in layers.enumerated() {
            guard index < drawn.count else {
                sublayer.isHidden = true
                sublayer.contents = nil
                continue
            }
            let item = drawn[index]
            let image = item.picture.image(in: space)
            if (sublayer.contents as AnyObject?) !== image { sublayer.contents = image }
            sublayer.contentsScale = item.rect.width == CGFloat(item.picture.width) ? factor : CGFloat(item.picture.width) * factor / item.rect.width
            sublayer.frame = CGRect(x: item.rect.minX / factor, y: item.rect.minY / factor,
                                    width: item.rect.width / factor, height: item.rect.height / factor)
            sublayer.isHidden = false
        }
        CATransaction.commit()
    }

    @objc public var itemCount: Int { drawn.count }

    /// Composites the shown frame onto 8-bit RGB pixels read from the view,
    /// `width` × `height` from the view's backing pixel (originX, originY),
    /// rows from the top, sampling each picture as OpenGL's linear filter did.
    @objc(compositeOntoRGB:width:height:originX:originY:)
    public func composite(onto rgb: UnsafeMutablePointer<UInt8>, width: Int, height: Int, originX: Int, originY: Int) {
        AnnotationOverlay.composite(drawn.map { ($0.picture, $0.rect) }, onto: rgb, width: width, height: height,
                                    originX: originX, originY: originY)
    }

    static func composite(_ items: [(AnnotationPicture, CGRect)], onto rgb: UnsafeMutablePointer<UInt8>, width: Int, height: Int,
                          originX: Int, originY: Int) {
        for (picture, rect) in items where picture.width > 0 {
            let sx = CGFloat(picture.width) / rect.width, sy = CGFloat(picture.height) / rect.height
            let x0 = max(0, Int(ceil(rect.minX - 0.5)) - originX), x1 = min(width, Int(ceil(rect.maxX - 0.5)) - originX)
            let y0 = max(0, Int(ceil(rect.minY - 0.5)) - originY), y1 = min(height, Int(ceil(rect.maxY - 0.5)) - originY)
            guard x0 < x1, y0 < y1 else { continue }
            let bytes = picture.bytes, pw = picture.width, ph = picture.height
            for y in y0..<y1 {
                let v = (CGFloat(y + originY) + 0.5 - rect.minY) * sy - 0.5
                let vy = max(0, min(CGFloat(ph - 1), v))
                let r0 = Int(vy), r1 = min(ph - 1, r0 + 1), fy = Float(vy - CGFloat(r0))
                for x in x0..<x1 {
                    let u = (CGFloat(x + originX) + 0.5 - rect.minX) * sx - 0.5
                    let ux = max(0, min(CGFloat(pw - 1), u))
                    let c0 = Int(ux), c1 = min(pw - 1, c0 + 1), fx = Float(ux - CGFloat(c0))
                    let i00 = (r0 * pw + c0) * 4, i01 = (r0 * pw + c1) * 4, i10 = (r1 * pw + c0) * 4, i11 = (r1 * pw + c1) * 4
                    func sample(_ k: Int) -> Float {
                        (Float(bytes[i00 + k]) * (1 - fx) + Float(bytes[i01 + k]) * fx) * (1 - fy)
                            + (Float(bytes[i10 + k]) * (1 - fx) + Float(bytes[i11 + k]) * fx) * fy
                    }
                    let alpha = sample(3), red = sample(0), green = sample(1), blue = sample(2)
                    guard alpha > 0 || red > 0 || green > 0 || blue > 0 else { continue }
                    let keep = 1 - alpha / 255
                    let o = (y * width + x) * 3
                    rgb[o] = UInt8(min(255, max(0, red + Float(rgb[o]) * keep)).rounded())
                    rgb[o + 1] = UInt8(min(255, max(0, green + Float(rgb[o + 1]) * keep)).rounded())
                    rgb[o + 2] = UInt8(min(255, max(0, blue + Float(rgb[o + 2]) * keep)).rounded())
                }
            }
        }
    }
}
