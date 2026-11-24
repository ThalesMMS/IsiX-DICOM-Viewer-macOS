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

extension NSImage {
    /// The pixels a point of an image that has no pixels of its own, as a PDF
    /// page: at one a point the text of a page cannot be read when zoomed.
    static let displayedPixelsAPoint: CGFloat = 2

    /// The image as the pixels the application shows: a bitmap as it is, a
    /// page drawn at `displayedPixelsAPoint`. nil when there is nothing to draw.
    ///
    /// The import sizes the image's row in the database by this and the viewer
    /// draws it: the volume of a series lends each image a place of the size
    /// its row says, so a size measured by another rule either cuts the image
    /// or squeezes it into a smaller place.
    func displayedPixels() -> CGImage? {
        var rect = NSRect(origin: .zero, size: size)
        var scale = AffineTransform.identity
        scale.scale(Self.displayedPixelsAPoint)
        guard let pixels = cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: NSAffineTransform(transform: scale)]),
              pixels.width != 0, pixels.height != 0 else { return nil }
        return pixels
    }
}
