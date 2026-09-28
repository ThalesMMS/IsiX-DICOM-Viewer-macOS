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

import Accelerate
import AppKit
import CoreImage

// NSImage (N2) and N2Image are implemented in Swift since #709. The
// Objective-C names, the selectors and <Horos/NSImage+N2.h> are those of the
// former category and class.

/// N2LogException for an exception HorosObjCException caught.
fileprivate func logException(_ error: Error, _ function: StaticString) {
    guard let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException else { return }
    function.withUTF8Buffer { buffer in
        buffer.withMemoryRebound(to: CChar.self) { _N2LogExceptionImpl(exception, false, $0.baseAddress) }
    }
}

/// The C conversion of a coordinate to `int` as it behaves on arm64: NaN is
/// 0 and values past the range saturate.
fileprivate func cInt(_ value: CGFloat) -> Int {
    if value.isNaN { return 0 }
    if value >= CGFloat(Int32.max) { return Int(Int32.max) }
    if value <= CGFloat(Int32.min) { return Int(Int32.min) }
    return Int(value)
}

/// An image that knows its size in inches and which portion of an original
/// image it shows.
@objc(N2Image)
public final class N2Image: NSImage {
    /// Atomic in the former header. Swift does not declare atomic properties;
    /// nothing in the app or Nitrogen uses N2Image, from any thread.
    @objc public var inchSize = NSSize.zero
    /// Atomic in the former header, as inchSize.
    @objc public var portion = NSRect.zero

    public override init(size: NSSize) {
        super.init(size: size)
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    public required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        super.init(pasteboardPropertyList: propertyList, ofType: type)
    }

    /// Swift cannot call NSImage's -initWithContentsOfFile: from a subclass
    /// initializer, so the file is read by NSImage and its representations and
    /// size are taken, before the size in inches is derived at 72 dpi.
    @objc(initWithContentsOfFile:)
    public init?(contentsOfFile fileName: String) {
        guard let loaded = NSImage(contentsOfFile: fileName) else { return nil }
        super.init(size: .zero)
        addRepresentations(loaded.representations)
        super.size = loaded.size
        let size = self.size
        inchSize = NSSize(width: size.width / 72, height: size.height / 72)
        portion.size = NSSize(width: 1, height: 1)
    }

    @objc(initWithSize:inches:)
    public init(size: NSSize, inches: NSSize) {
        super.init(size: size)
        inchSize = inches
    }

    @objc(initWithSize:inches:portion:)
    public convenience init(size: NSSize, inches: NSSize, portion: NSRect) {
        self.init(size: size, inches: inches)
        self.portion = portion
    }

    @objc public func originalInchSize() -> NSSize {
        NSSize(width: inchSize.width * (1 / portion.size.width), height: inchSize.height * (1 / portion.size.height))
    }

    @objc(convertPointFromPageInches:)
    public func convertPointFromPageInches(_ p: NSPoint) -> NSPoint {
        let original = originalInchSize()
        let resolution = CGFloat(self.resolution())
        return NSPoint(x: (p.x - portion.origin.x * original.width) * resolution,
                       y: (p.y - portion.origin.y * original.height) * resolution)
    }

    public override var size: NSSize {
        get { super.size }
        set {
            let oldSize = self.size
            // -scalesWhenResized is unavailable to Swift; the message is sent
            // as the Objective-C sent it.
            let scalesWhenResized = NSSelectorFromString("scalesWhenResized")
            typealias Send = @convention(c) (NSObject, Selector) -> ObjCBool
            if !unsafeBitCast(method(for: scalesWhenResized), to: Send.self)(self, scalesWhenResized).boolValue {
                inchSize = NSSize(width: inchSize.width / oldSize.width * newValue.width,
                                  height: inchSize.height / oldSize.height * newValue.height)
            }
            super.size = newValue
        }
    }

    @objc(crop:)
    public func crop(_ cropRect: NSRect) -> N2Image {
        let size = self.size

        var cropped = NSRect.zero
        cropped.size = NSSize(width: portion.size.width * (cropRect.size.width * (1 / size.width)),
                              height: portion.size.height * (cropRect.size.height * (1 / size.height)))
        cropped.origin = NSPoint(x: portion.origin.x + portion.size.width * (cropRect.origin.x * (1 / size.width)),
                                 y: portion.origin.y + portion.size.height * (cropRect.origin.y * (1 / size.height)))

        let croppedImage = N2Image(size: cropRect.size,
                                   inches: NSSize(width: inchSize.width / size.width * cropRect.size.width,
                                                  height: inchSize.height / size.height * cropRect.size.height),
                                   portion: cropped)

        croppedImage.lockFocus()
        draw(at: .zero, from: cropRect, operation: .sourceOver, fraction: 0)
        croppedImage.unlockFocus()

        return croppedImage
    }

    @objc public func resolution() -> Float {
        let size = self.size
        return Float((size.width + size.height) / (inchSize.width + inchSize.height))
    }
}

// One Core Image context for every resize (#625): building it - Metal device,
// compiled kernels - is most of what the first conversion costs. Intermediates
// are not cached, so a long sequence of movie frames does not accumulate them,
// and colour management is off: the values that went in come out, in the colour
// space of the source.
fileprivate let scalingContext = CIContext(options: [.cacheIntermediates: false,
                                                    .workingColorSpace: NSNull(),
                                                    .outputColorSpace: NSNull()])

// The largest side produced: the Metal texture limit Core Image renders into.
fileprivate let maximumScaledSide: CGFloat = 16384

public extension NSImage {
    @objc(toolbarImageNamed:)
    class func toolbarImageNamed(_ name: String?) -> NSImage? {
        self.toolbarImageNamed(name, size: NSSize(width: 32, height: 32))
    }

    @objc(toolbarImageNamed:size:)
    class func toolbarImageNamed(_ name: String?, size: NSSize) -> NSImage? {
        // Forcing the requested size squashed non-square artwork such as the
        // 124x100 windows.tif used by the tiling items. Fit the longest edge into
        // the box instead, so the icon keeps its proportions and the toolbar keeps
        // its height.
        ToolbarImage.fitting(name.flatMap { NSImage(named: $0) }, size: min(size.width, size.height))
    }

    @objc func shadowImage() -> NSImage {
        let dark = NSImage(size: size)
        dark.lockFocus()
        draw(in: NSRect(x: 0, y: 0, width: size.width, height: size.height),
             from: NSRect(x: 0, y: 0, width: size.width, height: size.height),
             operation: .sourceOver, fraction: 1.0)
        NSColor(calibratedWhite: 0, alpha: 0.5).set()
        NSRect(x: 0, y: 0, width: size.width, height: size.height).fill(using: .sourceAtop)
        dark.unlockFocus()

        return dark
    }

    @objc func flipImageHorizontally() {
        // bitmap init
        let bitmap = tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }
        // flip
        if let bitmap {
            var source = vImage_Buffer(data: bitmap.bitmapData, height: vImagePixelCount(bitmap.pixelsHigh),
                                       width: vImagePixelCount(bitmap.pixelsWide), rowBytes: bitmap.bytesPerRow)
            var destination = source
            vImageHorizontalReflect_ARGB8888(&source, &destination, vImage_Flags(0))
        }
        // draw
        lockFocus()
        bitmap?.draw()
        unlockFocus()
    }

    @objc(boundingBoxSkippingColor:inRect:)
    func boundingBoxSkippingColor(_ color: NSColor?, inRect rect: NSRect) -> NSRect {
        var box = rect
        if box.size.width < 0 {
            box.origin.x += box.size.width
            box.size.width = -box.size.width
        }
        if box.size.height < 0 {
            box.origin.y += box.size.height
            box.size.height = -box.size.height
        }

        let size = self.size

        if box.origin.x < 0 {
            box.size.width += box.origin.x
            box.origin.x = 0
        }
        if box.origin.y < 0 {
            box.size.height += box.origin.y
            box.origin.y = 0
        }
        if box.origin.x + box.size.width > size.width {
            box.size.width = size.width - box.origin.x
        }
        if box.origin.y + box.size.height > size.height {
            box.size.height = size.height - box.origin.y
        }

//      if (![self isFlipped])
        box.origin.y = size.height - box.origin.y - box.size.height

        let bitmap = tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }
        let data = bitmap?.bitmapData

        var color = color
        if color?.colorSpaceName != .calibratedRGB {
            color = color?.usingColorSpaceName(.calibratedRGB)
        }
        // The Objective-C read three components from a variable-length array
        // that was empty when the colour did not convert; here they are zero.
        var components = [CGFloat](repeating: 0, count: max(color?.numberOfComponents ?? 0, 3))
        color?.getComponents(&components)

        let rowBytes = bitmap?.bytesPerRow ?? 0, pixelBytes = (bitmap?.bitsPerPixel ?? 0) / 8
        func matches(_ x: Int, _ y: Int) -> Bool {
            let p = y * rowBytes + x * pixelBytes
            let alpha = CGFloat(data![p + 3])
            return CGFloat(data![p]) == alpha * components[0]
                && CGFloat(data![p + 1]) == alpha * components[1]
                && CGFloat(data![p + 2]) == alpha * components[2]
        }

        var x = 0, y = 0

        // change origin.x
        x = cInt(box.origin.x)
        endOriginX: while CGFloat(x) < box.origin.x + box.size.width {
            y = cInt(box.origin.y)
            while CGFloat(y) <= box.origin.y + box.size.height {
                if !matches(x, y) { break endOriginX }
                y += 1
            }
            x += 1
        }
        if CGFloat(x) < box.origin.x + box.size.width {
            box.size.width -= CGFloat(x) - box.origin.x
            box.origin.x = CGFloat(x)
        }

        // change origin.y
        y = cInt(box.origin.y)
        endOriginY: while CGFloat(y) < box.origin.y + box.size.height {
            x = cInt(box.origin.x)
            while CGFloat(x) <= box.origin.x + box.size.width {
                if !matches(x, y) { break endOriginY }
                x += 1
            }
            y += 1
        }
        if CGFloat(y) < box.origin.y + box.size.height {
            box.size.height -= CGFloat(y) - box.origin.y
            box.origin.y = CGFloat(y)
        }

        // change size.width
        x = cInt(box.origin.x + box.size.width - 1)
        endSizeX: while CGFloat(x) >= box.origin.x {
            y = cInt(box.origin.y)
            while CGFloat(y) <= box.origin.y + box.size.height {
                if !matches(x, y) { break endSizeX }
                y += 1
            }
            x -= 1
        }
        if CGFloat(x) >= box.origin.x {
            box.size.width = CGFloat(x) - box.origin.x + 1
        }

        // change size.height
        y = cInt(box.origin.y + box.size.height - 1)
        endSizeY: while CGFloat(y) >= box.origin.y {
            x = cInt(box.origin.x)
            while CGFloat(x) <= box.origin.x + box.size.width {
                if !matches(x, y) { break endSizeY }
                x += 1
            }
            y -= 1
        }
        if CGFloat(y) >= box.origin.y {
            box.size.height = CGFloat(y) - box.origin.y + 1
        }

        //if (![self isFlipped])
        box.origin.y = size.height - box.origin.y - box.size.height

        return box
    }

    @objc(boundingBoxSkippingColor:)
    func boundingBoxSkippingColor(_ color: NSColor?) -> NSRect {
        let imageSize = self.size
        return boundingBoxSkippingColor(color, inRect: NSRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height))
    }

    @objc(imageWithHue:)
    func imageWithHue(_ hue: CGFloat) -> NSImage {
        // -filterWithName:keysAndValues: stopped at a nil input image.
        var parameters: [String: Any] = ["inputAngle": NSNumber(value: Float(hue * 2 * .pi))]
        if let input = tiffRepresentation.flatMap({ CIImage(data: $0) }) {
            parameters["inputImage"] = input
        }
        let output = CIFilter(name: "CIHueAdjust", parameters: parameters)?.value(forKey: "outputImage") as? CIImage
        let rep = output.map { NSCIImageRep(ciImage: $0) }
        let image = NSImage(size: rep?.size ?? .zero)
        if let rep { image.addRepresentation(rep) }
        return image
    }

    @objc func imageInverted() -> NSImage {
        let invert = CIFilter(name: "CIColorMatrix")

        invert?.setDefaults()
        invert?.setValue(tiffRepresentation.flatMap { CIImage(data: $0) }, forKey: kCIInputImageKey)
        invert?.setValue(CIVector(x: -1, y: 0, z: 0), forKey: "inputRVector")
        invert?.setValue(CIVector(x: 0, y: -1, z: 0), forKey: "inputGVector")
        invert?.setValue(CIVector(x: 0, y: 0, z: -1), forKey: "inputBVector")
        invert?.setValue(CIVector(x: 0.9, y: 0.9, z: 0.9), forKey: "inputBiasVector")

        let output = invert?.value(forKey: "outputImage") as? CIImage
        let rep = output.map { NSCIImageRep(ciImage: $0) }
        let image = NSImage(size: rep?.size ?? .zero)
        if let rep { image.addRepresentation(rep) }
        return image
    }

    @objc(sizeByScalingProportionallyToSize:)
    func sizeByScalingProportionally(toSize targetSize: NSSize) -> NSSize {
        N2ProportionallyScaleSize(size, targetSize)
    }

    @objc(sizeByScalingDownProportionallyToSize:)
    func sizeByScalingDownProportionally(toSize targetSize: NSSize) -> NSSize {
        let imageSize = size
        let outSize = sizeByScalingProportionally(toSize: targetSize)
        return outSize.width < imageSize.width ? outSize : imageSize
    }

    @objc(imageByScalingProportionallyUsingNSImage:)
    func imageByScalingProportionallyUsingNSImage(_ ratio: Float) -> NSImage {
        imageByScalingProportionallyToSizeUsingNSImage(NSSize(width: size.width * CGFloat(ratio),
                                                              height: size.height * CGFloat(ratio)))
    }

    @objc(imageByScalingProportionallyToSizeUsingNSImage:)
    func imageByScalingProportionallyToSizeUsingNSImage(_ targetSize: NSSize) -> NSImage {
        var scaled: NSImage?
        do {
            try HorosObjCException.perform {
                let newImage = NSImage(size: targetSize)

                if newImage.size.width > 0 && newImage.size.height > 0 {
                    newImage.lockFocus()

                    NSGraphicsContext.current?.imageInterpolation = .high

                    var thumbnailPoint = NSPoint.zero

                    // float, as in the Objective-C
                    let imageSize = self.size
                    let width = Float(imageSize.width)
                    let height = Float(imageSize.height)
                    let targetWidth = Float(targetSize.width)
                    let targetHeight = Float(targetSize.height)
                    var scaledWidth = targetWidth
                    var scaledHeight = targetHeight

                    if imageSize != targetSize {
                        let widthFactor = targetWidth / width
                        let heightFactor = targetHeight / height
                        var scaleFactor: Float = 0.0

                        if widthFactor < heightFactor {
                            scaleFactor = widthFactor
                        } else {
                            scaleFactor = heightFactor
                        }

                        scaledWidth = width * scaleFactor
                        scaledHeight = height * scaleFactor

                        if widthFactor < heightFactor {
                            thumbnailPoint.y = CGFloat((targetHeight - scaledHeight) * 0.5)
                        } else if widthFactor > heightFactor {
                            thumbnailPoint.x = CGFloat((targetWidth - scaledWidth) * 0.5)
                        }
                    }

                    var thumbnailRect = NSRect.zero
                    thumbnailRect.origin = thumbnailPoint
                    thumbnailRect.size.width = CGFloat(scaledWidth)
                    thumbnailRect.size.height = CGFloat(scaledHeight)

                    self.draw(in: thumbnailRect, from: .zero, operation: .copy, fraction: 1.0)

                    newImage.unlockFocus()

                    scaled = newImage
                }
            }
        } catch {
            logException(error, "-[NSImage(N2) imageByScalingProportionallyToSizeUsingNSImage:]")
        }
        return scaled ?? self
    }

    // Scales the image to fit `targetSize` without distortion, centred, the rest
    // transparent. The size is the output's size in pixels and in points alike -
    // every caller (movie frames, the web portal's WADO and previews) passes pixel
    // dimensions of the picture it will encode - so a fractional size is rounded up
    // in pixels and kept exactly in points.
    //
    // It used to draw through AppKit under a lock on the whole NSImage class, scale
    // by the main screen's backing factor (so a Retina display halved every export),
    // hand a scale of zero to the filter when the size was already right, and
    // round-trip the result through TIFF. Now the source is snapshotted as a
    // CGImage under a lock on that image alone, Core Image scales it with a
    // per-request filter and renders once into a bitmap that owns its pixels, grey
    // kept grey and 8 bits kept 8 bits (16 when the source has more).
    @objc(imageByScalingProportionallyToSize:)
    func imageByScalingProportionally(toSize targetSize: NSSize) -> NSImage? {
        if !targetSize.width.isFinite || !targetSize.height.isFinite ||
            targetSize.width <= 0 || targetSize.height <= 0 {
            return nil
        }
        let pixelsWide = ceil(targetSize.width), pixelsHigh = ceil(targetSize.height)
        if pixelsWide > maximumScaledSide || pixelsHigh > maximumScaledSide {
            return nil
        }

        let function: StaticString = "-[NSImage(N2) imageByScalingProportionallyToSize:]"
        var result: NSImage?
        autoreleasepool {
            var imageSize = NSSize.zero
            var source: CGImage?
            // @synchronized (self): the lock is left before an exception is
            // handled, as @synchronized left it.
            objc_sync_enter(self)
            var failure: Error?
            do {
                try HorosObjCException.perform {
                    if self.isValid {
                        imageSize = self.size
                        if imageSize.width.isFinite && imageSize.height.isFinite && imageSize.width > 0 && imageSize.height > 0 {
                            var rect = NSRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height)
                            // An identity transform asks for the representation's own
                            // pixels, whatever screen the app happens to be on.
                            source = self.cgImage(forProposedRect: &rect, context: nil,
                                                  hints: [.ctm: NSAffineTransform()])
                        }
                    }
                }
            } catch {
                failure = error
            }
            objc_sync_exit(self)
            if let failure {
                logException(failure, function)
                return
            }

            do {
                try HorosObjCException.perform {
                    let sourceWide = source?.width ?? 0, sourceHigh = source?.height ?? 0
                    guard let source, sourceWide != 0, sourceHigh != 0 else { return }
                    let fit = min(pixelsWide / imageSize.width, pixelsHigh / imageSize.height)
                    let contentWide = imageSize.width * fit, contentHigh = imageSize.height * fit
                    let scale = contentHigh / CGFloat(sourceHigh), aspect = (contentWide / CGFloat(sourceWide)) / scale
                    let sourceSpace = source.colorSpace
                    let model = sourceSpace?.model ?? .unknown
                    let grey = model == .monochrome
                    let colorSpace = (grey || model == .rgb) ? sourceSpace : CGColorSpace(name: CGColorSpace.sRGB)
                    let deep = source.bitsPerComponent > 8
                    let format: CIFormat = grey ? (deep ? .LA16 : .LA8) : (deep ? .RGBA16 : .RGBA8)
                    guard scale.isFinite && aspect.isFinite && scale > 0 && aspect > 0 else { return }
                    var image: CIImage? = CIImage(cgImage: source)
                    let content = CGRect(x: 0, y: 0, width: contentWide, height: contentHigh)
                    if sourceWide != Int(contentWide) || sourceHigh != Int(contentHigh) ||
                        contentWide != floor(contentWide) || contentHigh != floor(contentHigh) {
                        let filter = CIFilter(name: "CILanczosScaleTransform")
                        filter?.setValue(image?.clampedToExtent(), forKey: kCIInputImageKey)
                        filter?.setValue(NSNumber(value: Double(scale)), forKey: kCIInputScaleKey)
                        filter?.setValue(NSNumber(value: Double(aspect)), forKey: kCIInputAspectRatioKey)
                        image = filter?.outputImage?.cropped(to: content)
                    }
                    guard let placed = image?.transformed(by: CGAffineTransform(translationX: (pixelsWide - contentWide) * 0.5,
                                                                                 y: (pixelsHigh - contentHigh) * 0.5))
                    else { return }
                    let canvas = CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh)
                    let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: canvas)
                    if let output = scalingContext.createCGImage(placed.composited(over: clear), from: canvas,
                                                                 format: format, colorSpace: colorSpace, deferred: false) {
                        result = NSImage(cgImage: output, size: targetSize)
                    }
                }
            } catch {
                logException(error, function)
            }
        }
        return result
    }
}
