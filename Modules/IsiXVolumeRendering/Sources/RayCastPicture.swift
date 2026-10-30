//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Accelerate
import Foundation

/// The ray-cast image VTK's mapper keeps and the 3D view shows: premultiplied
/// RGBA words in VTK's 15-bit fixed-point range, its rows `memoryWidth` pixels
/// apart, the bottom row first; and the picture Metal renders into it.
public enum RayCastPicture {

    /// The image grid as the native comparison reads it: viewport width and
    /// height, the in-use rectangle's top-left origin, and its size, in ray
    /// pixels. VTK's origin is at the bottom left.
    public static func region(viewportWidth: Int, viewportHeight: Int, originX: Int, originY: Int,
                              usedWidth: Int, usedHeight: Int) -> [Int] {
        [viewportWidth, viewportHeight, originX, viewportHeight - originY - usedHeight, usedWidth, usedHeight]
    }

    /// The in-use rectangle's words, rows as VTK keeps them; nil when there is
    /// no image.
    public static func inUseWords(_ image: UnsafePointer<UInt16>?, memoryWidth: Int, usedWidth: Int, usedHeight: Int) -> Data? {
        guard let image, usedWidth > 0, usedHeight > 0 else { return nil }
        let row = usedWidth * 4
        var data = Data(count: row * usedHeight * MemoryLayout<UInt16>.size)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: UInt16.self).baseAddress!
            for y in 0..<usedHeight { memcpy(out + y * row, image + y * memoryWidth * 4, row * MemoryLayout<UInt16>.size) }
        }
        return data
    }

    /// Clears the whole image (memoryWidth × memoryHeight) and copies
    /// `picture`, `usedWidth` × `usedHeight` pixels with row 0 at the top,
    /// into its in-use rectangle, bottom row first as VTK keeps it.
    public static func replace(_ image: UnsafeMutablePointer<UInt16>, memoryWidth: Int, memoryHeight: Int,
                               with picture: UnsafePointer<UInt16>, usedWidth: Int, usedHeight: Int) {
        // ClearImage(), as one memset: its loop over the whole image memory
        // cost milliseconds in Debug, and so do the generic pointer copies,
        // which are not optimized there either.
        memset(image, 0, memoryWidth * memoryHeight * 4 * MemoryLayout<UInt16>.size)
        let row = usedWidth * 4, stride = memoryWidth * 4
        for y in 0..<usedHeight { memcpy(image + (usedHeight - 1 - y) * stride, picture + y * row, row * MemoryLayout<UInt16>.size) }
    }

    /// A projection's values into the fourth word of each pixel, as the
    /// volume stores them: (value + offset) × factor, rounded and clamped to 16
    /// bits; 0 for no value. `values` holds one float a pixel, top row first;
    /// the image is `stride` words a row, bottom row first.
    public static func writeFullDepthProjection(_ rgba: UnsafeMutablePointer<UInt16>, stride: Int, width: Int, height: Int,
                                                values: UnsafePointer<Float>, offset: Float, factor: Float) {
        for y in 0..<height {
            var out = rgba + (height - 1 - y) * stride + 3
            let row = values + y * width
            for x in 0..<width {
                let value = row[x]
                let word = value.isFinite ? ((Double(value) + Double(offset)) * Double(factor)).rounded() : 0
                out.pointee = UInt16(Swift.min(65535.0, Swift.max(0.0, word)))
                out += 4
            }
        }
    }

    /// A composite render as VTK displays it: Metal's premultiplied BGRA bytes
    /// and accumulated opacity (one float a pixel) become RGBA words. Each
    /// colour byte c becomes (c × 32767 + 127) / 255, and the opacity, clamped
    /// to [0, 1] with NaN as 0, becomes opacity × 32767 + 0.5 truncated.
    /// Accelerate does it a row of pixels at a time: a loop over a megapixel
    /// image cost 20 ms in Debug. Nil when the sizes do not match.
    public static func composite(bgra: Data, opacity scalar: Data) -> Data? {
        let count = scalar.count / MemoryLayout<Float>.size
        if count == 0 || bgra.count != count * 4 { return nil }
        var picture = Data(count: count * 4 * MemoryLayout<UInt16>.size)
        // The working planes in one uninitialized allocation, every byte of
        // which the conversions write before reading: the module is not
        // optimized in Debug, where filling Swift arrays element by element,
        // or a Swift loop over the pixels, cost tens of milliseconds a
        // megapixel.
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: count * (4 + 8 + 4), alignment: 16)
        defer { scratch.deallocate() }
        let w = scratch.bindMemory(to: UInt16.self, capacity: count * 4)
        let v = (scratch + count * 8).bindMemory(to: Float.self, capacity: count)
        let p = (scratch + count * 12).bindMemory(to: UInt8.self, capacity: count * 4)
        _ = scalar.copyBytes(to: UnsafeMutableBufferPointer(start: v, count: count))
        var table = [Pixel_16U](repeating: 0, count: 256)
        for c in 0..<256 { table[c] = Pixel_16U((UInt32(c) * 32767 + 127) / 255) }
        return bgra.withUnsafeBytes { source -> Data? in
            picture.withUnsafeMutableBytes { rgbaRaw -> Bool in
                var sourceBuffer = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.baseAddress!), height: 1,
                                                 width: vImagePixelCount(count), rowBytes: count * 4)
                func planar8(_ k: Int) -> vImage_Buffer {
                    vImage_Buffer(data: p + k * count, height: 1, width: vImagePixelCount(count), rowBytes: count)
                }
                func planar16(_ k: Int) -> vImage_Buffer {
                    vImage_Buffer(data: w + k * count, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                }
                var b8 = planar8(0), g8 = planar8(1), r8 = planar8(2), a8 = planar8(3)
                var r16 = planar16(0), g16 = planar16(1), b16 = planar16(2), a16 = planar16(3)
                var rgba = vImage_Buffer(data: rgbaRaw.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 8)
                guard vImageConvert_ARGB8888toPlanar8(&sourceBuffer, &b8, &g8, &r8, &a8, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
                      vImageLookupTable_Planar8toPlanar16(&r8, &r16, &table, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
                      vImageLookupTable_Planar8toPlanar16(&g8, &g16, &table, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
                      vImageLookupTable_Planar8toPlanar16(&b8, &b16, &table, vImage_Flags(kvImageNoFlags)) == kvImageNoError
                else { return false }
                var zero: Float = 0, one: Float = 1, scale: Float = 32767, half: Float = 0.5
                // NaN as 0: the threshold keeps a value only when it is at
                // least 0, which NaN never is.
                vDSP_vthr(v, 1, &zero, v, 1, vDSP_Length(count))
                vDSP_vclip(v, 1, &zero, &one, v, 1, vDSP_Length(count))
                vDSP_vsmsa(v, 1, &scale, &half, v, 1, vDSP_Length(count))
                vDSP_vfixu16(v, 1, w + 3 * count, 1, vDSP_Length(count))
                return vImageConvert_Planar16UtoARGB16U(&r16, &g16, &b16, &a16, &rgba, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            } ? picture : nil
        }
    }
}
