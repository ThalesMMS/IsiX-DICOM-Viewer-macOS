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
import Foundation

/// The 2D viewer's thick slab in volume-rendering mode (once ThickSlabVR, an
/// Objective-C++ view whose VTK ray cast had long been replaced by this
/// composite): every slice of the slab is windowed to bytes, and each pixel
/// adds, front to back, the opacity table's value of its byte, clipped to
/// what is left of 1, times the colour tables' values of the byte. A fused
/// series adds its own bytes, through its own colour tables and the same
/// opacity table. The sums become bytes again under an opaque alpha.
///
/// The buffers are the caller's: the source and fused slices must outlive
/// the composer's use of them, and `renderSlab()` hands back a malloc'ed
/// picture the caller frees. The arithmetic is the former class's, rounding
/// included (each product fused into the sum that uses it, as clang compiled
/// it).
public final class ThickSlabComposer: @unchecked Sendable {
    public private(set) var width = 0
    public private(set) var height = 0
    public private(set) var count = 0
    public private(set) var spaceX: Float = 0
    public private(set) var spaceY: Float = 0
    public private(set) var thickness: Float = 0
    public private(set) var windowLevel: Float = 0
    public private(set) var windowWidth: Float = 0
    /// NO (false) when setWLWW reverses the slices before they are composed.
    public var flipData = false
    public var lowQuality = false
    public private(set) var isRGB = false

    var imagePtr: UnsafeMutablePointer<Float>?
    var imageBlendingPtr: UnsafeMutablePointer<Float>?
    var srcf = vImage_Buffer()
    var dst8 = vImage_Buffer()
    var srcfBlending = vImage_Buffer()
    var dst8Blending = vImage_Buffer()

    /// The workers that share a composite: the processors, as
    /// -[ThickSlabVR renderSlab] used; tests fix it.
    var threadCount = ProcessInfo.processInfo.processorCount

    public private(set) var opacityTable = [Float](repeating: 0, count: 256)
    public private(set) var red = [Float](repeating: 0, count: 256)
    public private(set) var green = [Float](repeating: 0, count: 256)
    public private(set) var blue = [Float](repeating: 0, count: 256)
    var blendingRed = [Float](repeating: 0, count: 256)
    var blendingGreen = [Float](repeating: 0, count: 256)
    var blendingBlue = [Float](repeating: 0, count: 256)

    public init() {
        setCLUT(nil, nil, nil)
    }

    deinit {
        free(dst8.data)
        free(dst8Blending.data)
    }

    /// The slab's geometry: `c` slices of `w` × `h`. A change of size forgets
    /// the source and the window and allocates the windowed slices again;
    /// the same size only takes `flip`.
    public func setImageData(_ w: Int, _ h: Int, _ c: Int, _ sX: Float, _ sY: Float, _ t: Float, _ flip: Bool) {
        flipData = flip
        if width == w && height == h && count == c { return }

        imagePtr = nil
        width = w
        height = h
        count = c
        spaceX = sX
        spaceY = sY
        thickness = t
        windowLevel = 0
        windowWidth = 0
        NSLog("Count: %d", Int32(truncatingIfNeeded: count))

        srcf.height = vImagePixelCount(bitPattern: height &* count)
        srcf.width = vImagePixelCount(bitPattern: width)
        srcf.rowBytes = width &* MemoryLayout<Float>.size
        srcf.data = nil
        srcfBlending.height = vImagePixelCount(bitPattern: height &* count)
        srcfBlending.width = vImagePixelCount(bitPattern: width)
        srcfBlending.rowBytes = width &* MemoryLayout<Float>.size
        srcfBlending.data = nil
        dst8.height = vImagePixelCount(bitPattern: height &* count)
        dst8.width = vImagePixelCount(bitPattern: width)
        dst8.rowBytes = width
        dst8Blending.height = vImagePixelCount(bitPattern: height &* count)
        dst8Blending.width = vImagePixelCount(bitPattern: width)
        dst8Blending.rowBytes = width

        free(dst8.data)
        dst8.data = malloc(Int(dst8.height) &* Int(dst8.width))
    }

    /// The source slices: `c` slices from `i`.
    public func setImageSource(_ i: UnsafeMutablePointer<Float>?, _ c: Int) {
        imagePtr = i
        srcf.height = vImagePixelCount(bitPattern: height &* c)
        dst8.height = vImagePixelCount(bitPattern: height &* c)
        if count != c {
            count = c
            free(dst8.data)
            dst8.data = malloc(Int(dst8.height) &* Int(dst8.width))
        }
        srcf.data = imagePtr.map { UnsafeMutableRawPointer($0) }
    }

    /// The fused series' slices, as many as the source's.
    public func setImageBlendingSource(_ i: UnsafeMutablePointer<Float>?) {
        imageBlendingPtr = i
        srcfBlending.height = vImagePixelCount(bitPattern: height &* count)
        dst8Blending.height = vImagePixelCount(bitPattern: height &* count)
        srcfBlending.data = imageBlendingPtr.map { UnsafeMutableRawPointer($0) }
        free(dst8Blending.data)
        dst8Blending.data = malloc(Int(dst8Blending.height) &* Int(dst8Blending.width))
    }

    /// The source windowed to bytes, level `l` and width `w`; the slices are
    /// then reversed unless `flipData`.
    public func setWLWW(_ l: Float, _ w: Float) {
        windowLevel = l
        windowWidth = w
        vImageConvert_PlanarFtoPlanar8(&srcf, &dst8, windowLevel + windowWidth / 2, windowLevel - windowWidth / 2,
                                       vImage_Flags(kvImageNoFlags))
        if !flipData { dst8.data = reversedSlices(dst8.data) }
    }

    /// The fused slices windowed to bytes, reversed as the source's are.
    public func setBlendingWLWW(_ l: Float, _ w: Float) {
        guard imageBlendingPtr != nil else { return }
        vImageConvert_PlanarFtoPlanar8(&srcfBlending, &dst8Blending, l + w / 2, l - w / 2, vImage_Flags(kvImageNoFlags))
        if !flipData { dst8Blending.data = reversedSlices(dst8Blending.data) }
    }

    /// A new buffer with the slices of `bytes` in reverse order; `bytes` is freed.
    private func reversedSlices(_ bytes: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
        let size = height &* width
        let reversed = malloc(height &* width &* count)
        if let reversed, let bytes {
            for i in 0..<max(count, 0) {
                memcpy(reversed + (count - i - 1) * size, bytes + i * size, size)
            }
        }
        free(bytes)
        return reversed
    }

    /// The colour tables from 256 entries each, or the grey ramp without them.
    public func setCLUT(_ r: UnsafePointer<UInt8>?, _ g: UnsafePointer<UInt8>?, _ b: UnsafePointer<UInt8>?) {
        NSLog("CLUT Table")
        if let r, let g, let b {
            isRGB = true
            for i in 0..<256 {
                red[i] = Float(r[i]); green[i] = Float(g[i]); blue[i] = Float(b[i])
            }
        } else {
            isRGB = false
            for i in 0..<256 {
                red[i] = Float(i); green[i] = Float(i); blue[i] = Float(i)
            }
        }
    }

    /// The fused series' colour tables, or the grey ramp.
    public func setBlendingCLUT(_ r: UnsafePointer<UInt8>?, _ g: UnsafePointer<UInt8>?, _ b: UnsafePointer<UInt8>?) {
        NSLog("CLUT Table")
        if let r, let g, let b {
            for i in 0..<256 {
                blendingRed[i] = Float(r[i]); blendingGreen[i] = Float(g[i]); blendingBlue[i] = Float(b[i])
            }
        } else {
            for i in 0..<256 {
                blendingRed[i] = Float(i); blendingGreen[i] = Float(i); blendingBlue[i] = Float(i)
            }
        }
    }

    /// The opacity of each byte, 256 values.
    public func setOpacityTable(_ table: [Float]) {
        for i in 0..<256 { opacityTable[i] = i < table.count ? table[i] : 0 }
    }

    /// The opacity, red, green and blue tables, 256 floats each, in that order.
    public var compositeTables: Data {
        var data = Data(capacity: 4 * 256 * MemoryLayout<Float>.size)
        for table in [opacityTable, red, green, blue] {
            table.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        return data
    }

    /// The composite, `width` × `height` ARGB bytes the caller frees.
    public func renderSlab() -> UnsafeMutablePointer<UInt8>? {
        let size = height &* width
        guard let dst = malloc(size &* 4), let dstPlan = malloc(size &* 4),
              let dstR = malloc(size &* 4)?.assumingMemoryBound(to: Float.self),
              let dstG = malloc(size &* 4)?.assumingMemoryBound(to: Float.self),
              let dstB = malloc(size &* 4)?.assumingMemoryBound(to: Float.self),
              let dstA = malloc(size) else { return nil }
        memset(dstA, 255, size)
        let planes = ThickSlabPlanes(red: dstR, green: dstG, blue: dstB)
        let slices = UnsafePointer<UInt8>(dst8.data?.assumingMemoryBound(to: UInt8.self))

        opacityTable.withUnsafeBufferPointer { opacity in
            red.withUnsafeBufferPointer { r in
                green.withUnsafeBufferPointer { g in
                    blue.withUnsafeBufferPointer { b in
                        let tables = ThickSlabTables(opacity: opacity.baseAddress!, red: r.baseAddress!,
                                                     green: g.baseAddress!, blue: b.baseAddress!)
                        if imageBlendingPtr != nil {
                            blendingRed.withUnsafeBufferPointer { br in
                                blendingGreen.withUnsafeBufferPointer { bg in
                                    blendingBlue.withUnsafeBufferPointer { bb in
                                        let fused = ThickSlabTables(opacity: opacity.baseAddress!, red: br.baseAddress!,
                                                                    green: bg.baseAddress!, blue: bb.baseAddress!)
                                        let fusedSlices = UnsafePointer<UInt8>(dst8Blending.data?.assumingMemoryBound(to: UInt8.self))
                                        Self.composeFused(slices, fusedSlices, count: count, size: size, tables: tables,
                                                          fused: fused, into: planes)
                                    }
                                }
                            }
                        } else {
                            let threads = threadCount
                            let source = ThickSlabSource(slices: slices)
                            let count = self.count
                            DispatchQueue.concurrentPerform(iterations: threads) { position in
                                Self.compose(source.slices, count: count, size: size, position: position,
                                             threads: threads, tables: tables, into: planes)
                            }
                        }
                    }
                }
            }
        }

        var src = vImage_Buffer(data: dstR, height: vImagePixelCount(bitPattern: height),
                                width: vImagePixelCount(bitPattern: width), rowBytes: width &* 4)
        var destR = vImage_Buffer(data: dstPlan, height: vImagePixelCount(bitPattern: height),
                                  width: vImagePixelCount(bitPattern: width), rowBytes: width)
        vImageConvert_PlanarFtoPlanar8(&src, &destR, 255, 0, vImage_Flags(kvImageNoFlags))
        src.data = UnsafeMutableRawPointer(dstG)
        var destG = destR
        destG.data = dstPlan + size
        vImageConvert_PlanarFtoPlanar8(&src, &destG, 255, 0, vImage_Flags(kvImageNoFlags))
        src.data = UnsafeMutableRawPointer(dstB)
        var destB = destR
        destB.data = dstPlan + size &* 2
        vImageConvert_PlanarFtoPlanar8(&src, &destB, 255, 0, vImage_Flags(kvImageNoFlags))
        var srcA = vImage_Buffer(data: dstA, height: vImagePixelCount(bitPattern: height),
                                 width: vImagePixelCount(bitPattern: width), rowBytes: width)
        var dstARGB = vImage_Buffer(data: dst, height: vImagePixelCount(bitPattern: height),
                                    width: vImagePixelCount(bitPattern: width), rowBytes: width &* 4)
        vImageConvert_Planar8toARGB8888(&srcA, &destR, &destG, &destB, &dstARGB, vImage_Flags(kvImageNoFlags))

        free(dstPlan)
        free(dstR)
        free(dstG)
        free(dstB)
        free(dstA)
        return dst.assumingMemoryBound(to: UInt8.self)
    }

    /// One worker's share of the composite, `position` of `threads`: pixels
    /// from a multiple of four, four at a time, then one at a time up to the
    /// end of the share (the last ends at the image's end). Four pixels stop
    /// together when the slice that clips their opacity is the same for all
    /// four; a pixel on its own goes through every slice.
    static func compose(_ slices: UnsafePointer<UInt8>?, count: Int, size slicesize: Int, position: Int, threads: Int,
                        tables: ThickSlabTables, into planes: ThickSlabPlanes) {
        guard let slices else { return }
        let from = ((position &* slicesize) / threads) & ~3
        let to = position == threads - 1 ? slicesize : (((position + 1) &* slicesize) / threads) & ~3
        let opacityTable = tables.opacity, tableR = tables.red, tableG = tables.green, tableB = tables.blue
        var outR = planes.red + from, outG = planes.green + from, outB = planes.blue + from

        var i = from
        while i + 4 <= to {
            var r1: Float = 0, g1: Float = 0, b1: Float = 0
            var r2: Float = 0, g2: Float = 0, b2: Float = 0
            var r3: Float = 0, g3: Float = 0, b3: Float = 0
            var r4: Float = 0, g4: Float = 0, b4: Float = 0
            var tot1: Float = 1, tot2: Float = 1, tot3: Float = 1, tot4: Float = 1
            var pixels = slices + i
            var x = count
            while x > 0 {
                x -= 1
                var clipped = 0
                let v1 = Int(pixels[0]), v2 = Int(pixels[1]), v3 = Int(pixels[2]), v4 = Int(pixels[3])
                var o1 = opacityTable[v1]
                if o1 > tot1 { o1 = tot1; clipped += 1 }
                tot1 -= o1
                var o2 = opacityTable[v2]
                if o2 > tot2 { o2 = tot2; clipped += 1 }
                tot2 -= o2
                var o3 = opacityTable[v3]
                if o3 > tot3 { o3 = tot3; clipped += 1 }
                tot3 -= o3
                var o4 = opacityTable[v4]
                if o4 > tot4 { o4 = tot4; clipped += 1 }
                tot4 -= o4
                if clipped == 4 { x = 0 }
                pixels += slicesize

                r1 = r1.addingProduct(o1, tableR[v1]); g1 = g1.addingProduct(o1, tableG[v1]); b1 = b1.addingProduct(o1, tableB[v1])
                r2 = r2.addingProduct(o2, tableR[v2]); g2 = g2.addingProduct(o2, tableG[v2]); b2 = b2.addingProduct(o2, tableB[v2])
                r3 = r3.addingProduct(o3, tableR[v3]); g3 = g3.addingProduct(o3, tableG[v3]); b3 = b3.addingProduct(o3, tableB[v3])
                r4 = r4.addingProduct(o4, tableR[v4]); g4 = g4.addingProduct(o4, tableG[v4]); b4 = b4.addingProduct(o4, tableB[v4])
            }
            outR[0] = r1; outG[0] = g1; outB[0] = b1
            outR[1] = r2; outG[1] = g2; outB[1] = b2
            outR[2] = r3; outG[2] = g3; outB[2] = b3
            outR[3] = r4; outG[3] = g4; outB[3] = b4
            outR += 4; outG += 4; outB += 4
            i += 4
        }

        while i < to {
            var r: Float = 0, g: Float = 0, b: Float = 0
            var total: Float = 1
            var pixels = slices + i
            var x = count
            while x > 0 {
                x -= 1
                let value = Int(pixels[0])
                var opacity = opacityTable[value]
                if opacity > total { opacity = total }
                total -= opacity
                pixels += slicesize
                r = r.addingProduct(opacity, tableR[value])
                g = g.addingProduct(opacity, tableG[value])
                b = b.addingProduct(opacity, tableB[value])
            }
            outR[0] = r; outG[0] = g; outB[0] = b
            outR += 1; outG += 1; outB += 1
            i += 1
        }
    }

    /// The composite with a fused series, on this thread: the two opacities of
    /// a slice share what is left of 1 in proportion when together they
    /// exceed it, and the pixel stops there.
    static func composeFused(_ slices: UnsafePointer<UInt8>?, _ fusedSlices: UnsafePointer<UInt8>?, count: Int, size: Int,
                             tables: ThickSlabTables, fused: ThickSlabTables, into planes: ThickSlabPlanes) {
        guard let slices, let fusedSlices else { return }
        var i = size
        while i > 0 {
            i -= 1
            var total: Float = 1
            var r: Float = 0, g: Float = 0, b: Float = 0
            var pixels = slices + i
            var fusedPixels = fusedSlices + i
            var x = count
            while x > 0 {
                x -= 1
                let value = Int(pixels[0])
                let fusedValue = Int(fusedPixels[0])
                pixels += size
                fusedPixels += size
                var opacityBlending = tables.opacity[fusedValue]
                var opacity = tables.opacity[value]
                let opacityAdd = opacity + opacityBlending
                if opacityAdd > total {
                    opacityBlending *= total / opacityAdd
                    opacity *= total / opacityAdd
                    x = 0
                } else {
                    total -= opacityAdd
                }
                r += (fused.red[fusedValue] * opacityBlending).addingProduct(tables.red[value], opacity)
                g += (fused.green[fusedValue] * opacityBlending).addingProduct(tables.green[value], opacity)
                b += (fused.blue[fusedValue] * opacityBlending).addingProduct(tables.blue[value], opacity)
            }
            planes.red[i] = r
            planes.green[i] = g
            planes.blue[i] = b
        }
    }
}

/// The 256-entry tables a composite reads.
struct ThickSlabTables: @unchecked Sendable {
    let opacity: UnsafePointer<Float>
    let red: UnsafePointer<Float>
    let green: UnsafePointer<Float>
    let blue: UnsafePointer<Float>
}

/// The composite's red, green and blue sums, one float per pixel each; the
/// workers write disjoint ranges.
struct ThickSlabPlanes: @unchecked Sendable {
    let red: UnsafeMutablePointer<Float>
    let green: UnsafeMutablePointer<Float>
    let blue: UnsafeMutablePointer<Float>
}

/// The windowed slices the workers read.
struct ThickSlabSource: @unchecked Sendable {
    let slices: UnsafePointer<UInt8>?
}
