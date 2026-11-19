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

// Selectors the plug-in SDK of Horos and OsiriX added to classes of AppKit and
// that the application itself no longer sends. A plug-in built for that SDK
// sends them without being rebuilt.

extension NSBezierPath {
    @objc(bezierPathWithRoundedRect:cornerRadius:) class func legacyBezierPath(roundedRect rect: NSRect, cornerRadius radius: Float) -> NSBezierPath {
        let path = NSBezierPath()
        path.legacyAppendRoundedRect(rect, cornerRadius: radius)
        return path
    }

    /// A rectangle with its corners rounded by `radius`, at most half its
    /// smaller side; a plain rectangle for a radius of 0, nothing for an empty one.
    @objc(appendBezierPathWithRoundedRect:cornerRadius:) func legacyAppendRoundedRect(_ rect: NSRect, cornerRadius radius: Float) {
        guard !rect.isEmpty else { return }
        guard radius > 0 else {
            appendRect(rect)
            return
        }
        let clamped = CGFloat(min(Double(radius), 0.5 * Double(min(rect.width, rect.height))))
        let topLeft = NSPoint(x: rect.minX, y: rect.maxY), topRight = NSPoint(x: rect.maxX, y: rect.maxY)
        let bottomRight = NSPoint(x: rect.maxX, y: rect.minY)
        move(to: NSPoint(x: rect.midX, y: rect.maxY))
        appendArc(from: topLeft, to: rect.origin, radius: clamped)
        appendArc(from: rect.origin, to: bottomRight, radius: clamped)
        appendArc(from: bottomRight, to: topRight, radius: clamped)
        appendArc(from: topRight, to: topLeft, radius: clamped)
        close()
    }
}

extension NSBitmapImageRep {
    /// Raises the alpha of the pixels the transparent border does not reach
    /// to at least `level` (0 to 255), in the upper half of the bitmap, as it
    /// did: the border is every pixel connected to an edge through pixels of
    /// alpha 0. Only a bitmap of four interleaved bytes a pixel has such an alpha.
    @objc(ATMask:) func legacyAlphaThresholdMask(_ level: Float) {
        let width = Int(size.width), height = Int(size.height), rowBytes = bytesPerRow
        guard let pixels = bitmapData, !isPlanar, bitsPerPixel == 32, width > 0, height > 0,
              width <= pixelsWide, height <= pixelsHigh else { return }
        func alpha(_ x: Int, _ y: Int) -> UnsafeMutablePointer<UInt8> { pixels + y * rowBytes + x * 4 + 3 }

        var outside = [Bool](repeating: false, count: width * height)
        var visited = [Bool](repeating: false, count: width * height)
        var pending: [(Int, Int)] = []
        for x in 0..<width { pending += [(x, 0), (x, height - 1)] }
        for y in stride(from: 1, to: height - 1, by: 1) { pending += [(0, y), (width - 1, y)] }
        while let (x, y) = pending.popLast() {
            if visited[y * width + x] { continue }
            visited[y * width + x] = true
            guard alpha(x, y).pointee == 0 else { continue }
            outside[y * width + x] = true
            if x > 0 && !visited[y * width + x - 1] { pending.append((x - 1, y)) }
            if y > 0 && !visited[(y - 1) * width + x] { pending.append((x, y - 1)) }
            if x < width - 1 && !visited[y * width + x + 1] { pending.append((x + 1, y)) }
            if y < height - 1 && !visited[(y + 1) * width + x] { pending.append((x, y + 1)) }
        }
        let floor = UInt8(max(0, min(255, level.isNaN ? 0 : level)))
        for y in 0..<(height / 2) {
            for x in 0..<width where !outside[y * width + x] {
                alpha(x, y).pointee = max(alpha(x, y).pointee, floor)
            }
        }
    }

    /// The same picture in the colour space `name`, 8 bits a sample; the
    /// receiver when it is already in it. A colour space that is not white,
    /// black, RGB or CMYK raises, as it did.
    @objc(repUsingColorSpaceName:) func legacyRep(usingColorSpaceName name: NSColorSpaceName) -> NSBitmapImageRep? {
        if colorSpaceName == name { return self }
        var samples = hasAlpha ? 1 : 0
        switch colorSpaceName {
        case .calibratedWhite, .deviceWhite, NSColorSpaceName(rawValue: "NSCalibratedBlackColorSpace"), NSColorSpaceName(rawValue: "NSDeviceBlackColorSpace"): samples += 1
        case .calibratedRGB, .deviceRGB: samples += 3
        case .deviceCMYK: samples += 4
        default: NSException(name: .invalidArgumentException, reason: "invalid color space", userInfo: nil).raise()
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
                                         samplesPerPixel: samples, hasAlpha: hasAlpha, isPlanar: false, colorSpaceName: name,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        for y in stride(from: pixelsHigh - 1, through: 0, by: -1) {
            for x in stride(from: pixelsWide - 1, through: 0, by: -1) {
                if let color = colorAt(x: x, y: y)?.usingColorSpace(rep.colorSpace) { rep.setColor(color, atX: x, y: y) }
            }
        }
        return rep
    }

    /// It answered the receiver before doing anything, and still does.
    @objc(smoothen:) func legacySmoothen(_ kernelSize: UInt) -> NSBitmapImageRep { self }
}
