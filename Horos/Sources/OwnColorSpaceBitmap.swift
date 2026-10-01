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

public extension NSImage {
    /// The image with something drawn over it, as a bitmap in the image's own
    /// colour space.
    ///
    /// An image made by a drawing handler is rendered in the space of the
    /// screen: a grey image comes out colour matched, its levels moved (102
    /// becomes 121 from generic grey to sRGB). That is wrong for an image
    /// whose levels are the window of a series. Here the pixels are drawn into
    /// a bitmap of the space they already have, so no level changes, and the
    /// overlay is drawn over them in the same context.
    @objc(horosBitmapInOwnColorSpaceWithOverlay:)
    func horosBitmapInOwnColorSpace(overlay: ((NSRect) -> Void)?) -> NSBitmapImageRep? {
        let size = self.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        var rect = NSRect(origin: .zero, size: size)
        // An identity transform asks for the representation's own pixels,
        // whatever screen the application happens to be on.
        guard let source = self.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: NSAffineTransform()]),
              source.width > 0, source.height > 0 else { return nil }

        let model = source.colorSpace?.model ?? .unknown
        let grey = model == .monochrome
        guard let space = (grey || model == .rgb) ? source.colorSpace : CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = grey ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo) else { return nil }

        // The overlay is laid out in the image's points, over all of its pixels.
        context.scaleBy(x: CGFloat(source.width) / size.width, y: CGFloat(source.height) / size.height)
        let bounds = NSRect(origin: .zero, size: size)
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(source, in: bounds)
        context.setBlendMode(.normal)
        if let overlay {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            overlay(bounds)
            NSGraphicsContext.restoreGraphicsState()
        }

        guard let composed = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: composed)
        bitmap.size = size
        return bitmap
    }
}
