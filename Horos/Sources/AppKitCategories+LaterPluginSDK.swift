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

// Selectors that later headers of the plugin SDK add to classes of AppKit, and
// to NSString for what it draws. A plugin built with those headers sends them
// by name, and an absent one raises «unrecognized selector» in the middle of
// the plugin's work. The headers give each a name and its types; what each
// answers follows its name and the conventions of Cocoa, and is said at each
// one. An argument that is nil or zero answers nil or nothing, never an
// exception. The pictures are drawn into bitmaps of their own, on the thread
// that asks; the view and the window are read on the main thread.

// MARK: - Bitmaps

/// The pixels a length in points takes at `scale`, at least 1; 0 for a length that is not a size.
private func pixels(_ points: CGFloat, scale: CGFloat = 1) -> Int {
    let length = points * scale
    guard length.isFinite, length > 0, length <= 65_536 else { return 0 }
    return max(1, Int(length.rounded()))
}

/// The pixels per point of the main display, 1 when it cannot be asked.
private func mainDisplayScale() -> CGFloat {
    guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()), mode.width > 0 else { return 1 }
    return max(1, CGFloat(mode.pixelWidth) / CGFloat(mode.width))
}

/// What `draw` draws in a rectangle of `size` points, in a new bitmap of 8
/// bits a sample, sRGB with alpha, of the pixels given: over `background`, or
/// over nothing. nil for a size that is none or too large to hold.
private func rendered(size: NSSize, pixelsWide: Int, pixelsHigh: Int, background: NSColor? = nil, _ draw: (NSRect) -> Void) -> NSBitmapImageRep? {
    guard pixelsWide > 0, pixelsHigh > 0, pixelsWide * pixelsHigh <= 1 << 28, size.width > 0, size.height > 0,
          let space = CGColorSpace(name: CGColorSpace.sRGB),
          let bitmap = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    bitmap.scaleBy(x: CGFloat(pixelsWide) / size.width, y: CGFloat(pixelsHigh) / size.height)
    bitmap.interpolationQuality = .high
    let bounds = NSRect(origin: .zero, size: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
    if let background {
        background.setFill()
        bounds.fill()
    }
    draw(bounds)
    NSGraphicsContext.restoreGraphicsState()
    guard let image = bitmap.makeImage() else { return nil }
    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = size
    return representation
}

/// An image of one bitmap, of the size the bitmap stands for.
private func image(of representation: NSBitmapImageRep?) -> NSImage? {
    guard let representation else { return nil }
    let image = NSImage(size: representation.size)
    image.addRepresentation(representation)
    return image
}

extension NSImage {
    /// The pixels of the representation of the image that has the most; the
    /// size of the image in points for one without pixels, as a PDF.
    private var laterSDKPixels: (wide: Int, high: Int) {
        var wide = 0, high = 0
        for representation in representations where representation.pixelsWide > wide && representation.pixelsHigh > 0 {
            wide = representation.pixelsWide
            high = representation.pixelsHigh
        }
        return wide > 0 ? (wide, high) : (pixels(size.width), pixels(size.height))
    }

    /// The image drawn whole into a new bitmap of the pixels given.
    private func laterSDKBitmap(pixelsWide: Int, pixelsHigh: Int, background: NSColor? = nil) -> NSBitmapImageRep? {
        rendered(size: size, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, background: background) {
            draw(in: $0, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    /// What `draw` draws in `canvas` points, at the pixels per point of the image.
    private func laterSDKImage(canvas: NSSize, _ draw: (NSRect) -> Void) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = (x: CGFloat(laterSDKPixels.wide) / size.width, y: CGFloat(laterSDKPixels.high) / size.height)
        return image(of: rendered(size: canvas, pixelsWide: pixels(canvas.width, scale: scale.x), pixelsHigh: pixels(canvas.height, scale: scale.y), draw))
    }

    // MARK: Representations

    /// The image as a bitmap of its own pixels: 8 bits a sample, sRGB with alpha.
    @objc(bitmapImageRepresentation) func laterSDKBitmapImageRepresentation() -> NSBitmapImageRep? {
        laterSDKBitmap(pixelsWide: laterSDKPixels.wide, pixelsHigh: laterSDKPixels.high)
    }

    /// The image as a bitmap of its own pixels with the samples asked for.
    @objc(bitmapImageRepresentationWithBitsPerSample:andBitsPerPixel:)
    func laterSDKBitmapImageRepresentation(bitsPerSample: Int32, bitsPerPixel: Int32) -> NSBitmapImageRep? {
        laterSDKBitmapImageRepresentation(bitsPerSample: bitsPerSample, bitsPerPixel: bitsPerPixel, scalingFactor: 1, alphaFirst: false)
    }

    /// The same with its pixels multiplied by `scalingFactor` in each direction.
    @objc(bitmapImageRepresentationWithBitsPerSample:andBitsPerPixel:scalingFactor:)
    func laterSDKBitmapImageRepresentation(bitsPerSample: Int32, bitsPerPixel: Int32, scalingFactor: Float) -> NSBitmapImageRep? {
        laterSDKBitmapImageRepresentation(bitsPerSample: bitsPerSample, bitsPerPixel: bitsPerPixel, scalingFactor: scalingFactor, alphaFirst: false)
    }

    /// The image as a bitmap of `bitsPerSample` bits a sample, 8 or 16, and
    /// `bitsPerPixel` bits a pixel, which make one sample for gray, two for
    /// gray and alpha, three for RGB and four for RGB and alpha, the alpha
    /// before the colours when `alphaFirst`: the pixels of the image
    /// multiplied by `scalingFactor`, 1 for a factor of 0 or less. The
    /// colours are those of sRGB multiplied by the alpha, and a bitmap
    /// without alpha shows the image over black. nil for other numbers of bits.
    @objc(bitmapImageRepresentationWithBitsPerSample:andBitsPerPixel:scalingFactor:alphaFirst:)
    func laterSDKBitmapImageRepresentation(bitsPerSample: Int32, bitsPerPixel: Int32, scalingFactor: Float, alphaFirst: Bool) -> NSBitmapImageRep? {
        guard bitsPerSample == 8 || bitsPerSample == 16, bitsPerPixel > 0, bitsPerPixel % bitsPerSample == 0, bitsPerPixel / bitsPerSample <= 4 else { return nil }
        let samples = Int(bitsPerPixel / bitsPerSample), wide16 = bitsPerSample == 16
        let hasAlpha = samples == 2 || samples == 4
        let factor = scalingFactor.isFinite && scalingFactor > 0 ? CGFloat(scalingFactor) : 1
        guard let source = laterSDKBitmap(pixelsWide: pixels(CGFloat(laterSDKPixels.wide), scale: factor), pixelsHigh: pixels(CGFloat(laterSDKPixels.high), scale: factor)),
              source.bitsPerPixel == 32, source.bitsPerSample == 8, !source.isPlanar, !source.bitmapFormat.contains(.alphaFirst),
              let from = source.bitmapData else { return nil }
        let format: NSBitmapImageRep.Format = alphaFirst && hasAlpha ? [.alphaFirst] : []
        guard let target = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: source.pixelsWide, pixelsHigh: source.pixelsHigh,
                                            bitsPerSample: Int(bitsPerSample), samplesPerPixel: samples, hasAlpha: hasAlpha, isPlanar: false,
                                            colorSpaceName: samples <= 2 ? .calibratedWhite : .calibratedRGB, bitmapFormat: format,
                                            bytesPerRow: 0, bitsPerPixel: Int(bitsPerPixel)),
              let to = target.bitmapData else { return nil }
        target.size = source.size
        for y in 0..<source.pixelsHigh {
            let fromRow = from + y * source.bytesPerRow, toRow = to + y * target.bytesPerRow
            for x in 0..<source.pixelsWide {
                let red = fromRow[x * 4], green = fromRow[x * 4 + 1], blue = fromRow[x * 4 + 2], alpha = fromRow[x * 4 + 3]
                let gray = UInt8((Int(red) * 77 + Int(green) * 150 + Int(blue) * 29) >> 8)
                var values: [UInt8] = samples <= 2 ? [gray] : [red, green, blue]
                if hasAlpha { values.insert(alpha, at: alphaFirst ? 0 : values.count) }
                for (sample, value) in values.enumerated() {
                    if wide16 {
                        // A sample of 16 bits is the one of 8 in both its bytes, whatever their order.
                        toRow[(x * samples + sample) * 2] = value
                        toRow[(x * samples + sample) * 2 + 1] = value
                    } else {
                        toRow[x * samples + sample] = value
                    }
                }
            }
        }
        // The samples are those of the sRGB bitmap they were read from, and its gray those of its gamma.
        return target.retagging(with: samples <= 2 ? .genericGamma22Gray : .sRGB) ?? target
    }

    /// The image as a bitmap of the pixels of `size`, one pixel a point,
    /// stretched to them; nil for a size that is none.
    @objc(resizedImageRepresentationToPixelDimensions:) func laterSDKResizedImageRepresentation(toPixelDimensions size: NSSize) -> NSBitmapImageRep? {
        let representation = laterSDKBitmap(pixelsWide: pixels(size.width), pixelsHigh: pixels(size.height))
        representation?.size = NSSize(width: representation?.pixelsWide ?? 0, height: representation?.pixelsHigh ?? 0)
        return representation
    }

    /// The image as a file of `type` (TIFF, BMP, GIF, JPEG, PNG or JPEG
    /// 2000), with `compressionFactor` from 0, the most compressed, to 1 for
    /// the types that take one; a type without alpha shows the image over white.
    @objc(getDataOfType:compressionFactor:) func laterSDKData(ofType type: UInt, compressionFactor: Float) -> Data? {
        guard let fileType = NSBitmapImageRep.FileType(rawValue: type), [.tiff, .bmp, .gif, .jpeg, .png, .jpeg2000].contains(fileType) else { return nil }
        let opaque = fileType == .jpeg || fileType == .bmp
        guard let bitmap = laterSDKBitmap(pixelsWide: laterSDKPixels.wide, pixelsHigh: laterSDKPixels.high, background: opaque ? .white : nil) else { return nil }
        let factor = compressionFactor.isFinite ? min(max(compressionFactor, 0), 1) : 1
        return bitmap.representation(using: fileType, properties: [.compressionFactor: NSNumber(value: factor)])
    }

    /// The image as a JPEG file, over white, at a compression factor of 0.9.
    @objc(JPEGRepresentation) func laterSDKJPEGRepresentation() -> Data? {
        laterSDKData(ofType: NSBitmapImageRep.FileType.jpeg.rawValue, compressionFactor: 0.9)
    }

    /// The image as a PDF file of one page of its size.
    @objc(PDFRepresentation) func laterSDKPDFRepresentation() -> Data? {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
        let data = NSMutableData()
        var page = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data), let pdf = CGContext(consumer: consumer, mediaBox: &page, nil) else { return nil }
        pdf.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
        draw(in: page, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        pdf.endPDFPage()
        pdf.closePDF()
        return data as Data
    }

    // MARK: Derived images

    /// The part of the image inside `rect`, in the points of the image from
    /// its bottom left corner, as an image of the size of the rectangle.
    @objc(crop:) func laterSDKCropped(to rect: NSRect) -> NSImage? {
        let part = rect.standardized
        guard part.width > 0, part.height > 0, part.origin.x.isFinite, part.origin.y.isFinite else { return nil }
        return laterSDKImage(canvas: part.size) { draw(in: $0, from: part, operation: .sourceOver, fraction: 1) }
    }

    /// The image mirrored from left to right when `flipX`, from top to bottom when `flipY`.
    @objc(flipImageX:Y:) func laterSDKFlipped(x flipX: Bool, y flipY: Bool) -> NSImage? {
        laterSDKImage(canvas: size) { bounds in
            let mirror = NSAffineTransform()
            mirror.translateX(by: flipX ? bounds.width : 0, yBy: flipY ? bounds.height : 0)
            mirror.scaleX(by: flipX ? -1 : 1, yBy: flipY ? -1 : 1)
            mirror.concat()
            draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    /// The image turned by `degrees` counterclockwise about its centre, in an
    /// image large enough to hold all of it.
    @objc(rotateBy:) func laterSDKRotated(by degrees: Float) -> NSImage? {
        let angle = degrees.isFinite ? CGFloat(degrees) : 0
        let sine = abs(sin(angle * .pi / 180)), cosine = abs(cos(angle * .pi / 180))
        let canvas = NSSize(width: size.width * cosine + size.height * sine, height: size.width * sine + size.height * cosine)
        return laterSDKImage(canvas: canvas) { bounds in
            let turn = NSAffineTransform()
            turn.translateX(by: bounds.midX, yBy: bounds.midY)
            turn.rotate(byDegrees: angle)
            turn.concat()
            draw(in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    /// The largest size of the proportions of the image that fits in `box`.
    private func laterSDKFitted(in box: NSSize) -> NSSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let ratio = min(box.width / size.width, box.height / size.height)
        return NSSize(width: size.width * ratio, height: size.height * ratio)
    }

    /// The image stretched to `size` points, or made the largest of its
    /// proportions that fits in it when `proportionally`: one pixel a point,
    /// or those of the main display when `retina`.
    @objc(imageByScalingToSize:retinaSupport:proportionally:)
    func laterSDKScaled(to size: NSSize, retinaSupport retina: Bool, proportionally: Bool) -> NSImage? {
        guard self.size.width > 0, self.size.height > 0 else { return nil }
        let canvas = proportionally ? laterSDKFitted(in: size) : size
        let scale = retina ? mainDisplayScale() : 1
        return image(of: rendered(size: canvas, pixelsWide: pixels(canvas.width, scale: scale), pixelsHigh: pixels(canvas.height, scale: scale)) {
            draw(in: $0, from: .zero, operation: .sourceOver, fraction: 1)
        })
    }

    /// The image made the largest of its proportions that fits in `size` points.
    @objc(imageByScalingProportionallyToSize:retinaSupport:) func laterSDKScaledProportionally(to size: NSSize, retinaSupport retina: Bool) -> NSImage? {
        laterSDKScaled(to: size, retinaSupport: retina, proportionally: true)
    }

    /// The image made small enough to fit in `size` points, with its
    /// proportions and its pixels per point; an image that fits already is not enlarged.
    @objc(imageByScalingProportionallyToMaxSizeUsingNSImage:) func laterSDKScaledProportionally(toMaxSize size: NSSize) -> NSImage? {
        let fitted = laterSDKFitted(in: size)
        let canvas = fitted.width < self.size.width ? fitted : self.size
        return laterSDKImage(canvas: canvas) { draw(in: $0, from: .zero, operation: .sourceOver, fraction: 1) }
    }

    /// The image over `color`, white without one, with nothing left transparent.
    @objc(imageWithOpaqueBackgroundColor:) func laterSDKImage(opaqueBackgroundColor color: NSColor?) -> NSImage? {
        laterSDKImage(canvas: size) { bounds in
            (color ?? .white).setFill()
            bounds.fill()
            draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    /// The image with a shadow of `color`, black at a third of its strength
    /// without one, moved by `offset` and blurred over `blur` points, in an
    /// image enlarged on every side by what the shadow can reach.
    @objc(imageWithShadowOffset:blur:color:) func laterSDKImage(shadowOffset offset: NSSize, blur: Float, color: NSColor?) -> NSImage? {
        guard offset.width.isFinite, offset.height.isFinite else { return nil }
        let radius = blur.isFinite && blur > 0 ? CGFloat(blur) : 0
        let margin = (x: (abs(offset.width) + radius).rounded(.up), y: (abs(offset.height) + radius).rounded(.up))
        return laterSDKImage(canvas: NSSize(width: size.width + 2 * margin.x, height: size.height + 2 * margin.y)) { bounds in
            let shadow = NSShadow()
            shadow.shadowOffset = offset
            shadow.shadowBlurRadius = radius
            shadow.shadowColor = color ?? NSColor.black.withAlphaComponent(1 / 3)
            shadow.set()
            draw(in: bounds.insetBy(dx: margin.x, dy: margin.y), from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    // MARK: Class methods

    /// The pixels per point of the main display, for which an image is drawn: 2 on a Retina display.
    @objc(backingScaleNSImage) class func laterSDKBackingScale() -> Float { Float(mainDisplayScale()) }

    /// A picture of the file at `path` that fits in `size` points: the file
    /// itself when it is an image, the icon the Finder gives it otherwise.
    /// nil when there is no such file.
    @objc(imageWithPreviewOfFileAtPath:ofSize:) class func laterSDKImage(previewOfFileAtPath path: String?, ofSize size: NSSize) -> NSImage? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        let picture = NSImage(contentsOfFile: path).flatMap { $0.isValid ? $0 : nil } ?? NSWorkspace.shared.icon(forFile: path)
        return picture.laterSDKScaled(to: size, retinaSupport: true, proportionally: true)
    }
}

// MARK: - NSColor

extension NSColor {
    /// The red, green, blue and alpha of the colour in sRGB, from 0 to 1; nil
    /// for a colour that has none, as a pattern.
    private var laterSDKComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)? {
        guard let color = usingColorSpace(.sRGB) else { return nil }
        return (color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
    }

    /// The colour as #RRGGBB in sRGB, without its alpha; nil for a colour that has no components.
    @objc(hexadecimalValue) func laterSDKHexadecimalValue() -> String? {
        guard let (red, green, blue, _) = laterSDKComponents else { return nil }
        return [red, green, blue].reduce("#") { text, component in
            let digits = String(Int((min(max(component, 0), 1) * 255).rounded()), radix: 16, uppercase: true)
            return text + (digits.count < 2 ? "0" : "") + digits
        }
    }

    /// The colour as CSS writes it in sRGB, rgba(255, 128, 0, 0.5); nil for a colour that has no components.
    @objc(rgbaCSSValue) func laterSDKRGBACSSValue() -> String? {
        guard let (red, green, blue, alpha) = laterSDKComponents else { return nil }
        let bytes = [red, green, blue].map { String(Int((min(max($0, 0), 1) * 255).rounded())) }
        let thousandths = Int((min(max(alpha, 0), 1) * 1000).rounded())
        var opacity = String(thousandths / 1000)
        if thousandths % 1000 != 0 {
            let decimals = String(thousandths % 1000)
            opacity += "." + String(repeating: "0", count: 3 - decimals.count) + decimals
            while opacity.hasSuffix("0") { opacity.removeLast() }
        }
        return "rgba(\(bytes[0]), \(bytes[1]), \(bytes[2]), \(opacity))"
    }

    /// The colour with each of red, green and blue taken from 1, and the same alpha: white for black.
    @objc(inverted) func laterSDKInverted() -> NSColor? {
        guard let (red, green, blue, alpha) = laterSDKComponents else { return nil }
        return NSColor(srgbRed: 1 - red, green: 1 - green, blue: 1 - blue, alpha: alpha)
    }

    /// The colour across the colour wheel, with the same saturation,
    /// brightness and alpha: cyan for red. A gray, which has no hue to turn,
    /// answers the gray of the opposite brightness.
    @objc(oppsite) func laterSDKOpposite() -> NSColor? {
        guard let color = usingColorSpace(.sRGB) else { return nil }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        guard saturation > 0 else { return NSColor(srgbRed: 1 - brightness, green: 1 - brightness, blue: 1 - brightness, alpha: alpha) }
        return NSColor(colorSpace: .sRGB, hue: (hue + 0.5).truncatingRemainder(dividingBy: 1), saturation: saturation, brightness: brightness, alpha: alpha)
    }

    /// The sRGB colour written as RGB, RGBA, RRGGBB or RRGGBBAA in
    /// hexadecimal, with or without a # or 0x before it; nil for anything else.
    @objc(colorFromHexString:) class func laterSDKColor(fromHexString text: String?) -> NSColor? {
        guard var digits = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if digits.hasPrefix("#") { digits.removeFirst() } else if digits.lowercased().hasPrefix("0x") { digits.removeFirst(2) }
        var values = digits.compactMap { $0.isASCII ? $0.hexDigitValue : nil }
        guard values.count == digits.count, [3, 4, 6, 8].contains(values.count) else { return nil }
        if values.count <= 4 { values = values.flatMap { [$0, $0] } }
        let components = stride(from: 0, to: values.count, by: 2).map { CGFloat(values[$0] * 16 + values[$0 + 1]) / 255 }
        return NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: components.count > 3 ? components[3] : 1)
    }
}

// MARK: - NSString

extension NSString {
    private func laterSDKAttributes(_ attributes: NSDictionary?) -> [NSAttributedString.Key: Any] {
        var typed: [NSAttributedString.Key: Any] = [:]
        for (key, value) in attributes ?? [:] {
            if let name = key as? String { typed[NSAttributedString.Key(name)] = value }
        }
        return typed
    }

    /// The size the string takes on one line in `font`, in the font of the system without one.
    @objc(sizeOfStringWithFont:) func laterSDKSize(font: NSFont?) -> NSSize {
        size(withAttributes: font.map { [.font: $0] })
    }

    /// Draws the string in `rect` of the current graphics context with
    /// `attributes`, its lines to the left for an alignment of 0, centred for
    /// 1 and to the right for 2. Nothing is drawn without a context.
    @objc(drawStringInRect:withAttributes:alignment:) func laterSDKDraw(in rect: CGRect, withAttributes attributes: NSDictionary?, alignment: Int) {
        guard NSGraphicsContext.current != nil, rect.width > 0, rect.height > 0 else { return }
        var typed = laterSDKAttributes(attributes)
        let paragraph = NSMutableParagraphStyle()
        if let given = typed[.paragraphStyle] as? NSParagraphStyle { paragraph.setParagraphStyle(given) }
        paragraph.alignment = alignment == 1 ? .center : alignment == 2 ? .right : .left
        typed[.paragraphStyle] = paragraph
        draw(in: rect, withAttributes: typed)
    }
}

// MARK: - NSView and NSWindow

/// What `body` answers on the main thread, where it runs at once when called
/// from it and which is waited for when called from another.
private func onMainThread<Answer: Sendable>(_ body: @MainActor @Sendable () -> Answer) -> Answer {
    if Thread.isMainThread { return MainActor.assumeIsolated(body) }
    return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
}

extension NSView {
    /// A picture of the view and of the views inside it as they draw
    /// themselves, of the size of the view; nil for a view without a size.
    /// The view draws on the main thread, which another thread waits for.
    @objc(screenCapture) nonisolated func laterSDKScreenCapture() -> NSImage? {
        onMainThread {
            let bounds = self.bounds
            guard bounds.width > 0, bounds.height > 0, let bitmap = self.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
            self.cacheDisplay(in: bounds, to: bitmap)
            return image(of: bitmap)
        }
    }
}

extension NSWindow {
    /// Whether the window is shown in the dark appearance. Read on the main
    /// thread, which another thread waits for.
    @objc(isDarkMode) nonisolated func laterSDKIsDarkMode() -> Bool {
        onMainThread { self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    }
}
