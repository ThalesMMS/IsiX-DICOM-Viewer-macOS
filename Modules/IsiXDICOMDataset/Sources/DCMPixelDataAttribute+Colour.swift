/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// YBR and palette colour to interleaved 8-bit RGB.
extension DCMPixelDataAttribute {

    /// The frame as RGB when it is YBR or palette colour, unchanged otherwise.
    @objc(convertDataToRGBColorSpace:)
    public func convertDataToRGBColorSpace(_ data: NSData) -> NSData? {
        let object = dcmObject
        let colorspace = object?.attributeValue(withName: "PhotometricInterpretation") as? String
        let isPlanar = Self.int(object?.attributeValue(withName: "PlanarConfiguration")) != 0
        if colorspace?.hasPrefix("YBR") == true {
            return convertYBrToRGB(data, kind: colorspace!, isPlanar: isPlanar)
        }
        if colorspace?.hasPrefix("PALETTE") == true {
            return convertPaletteToRGB(data)
        }
        return data
    }

    // MARK: YBR

    /// One place where a luminance and two chrominance samples become a colour.
    /// PS 3.3 C.7.6.3.1.2: YBR_FULL uses the whole 0-255 range for luminance, and
    /// YBR_PARTIAL reserves 16-235 for it, which is the same matrix with the range
    /// scaled. Fixed point, fifteen fractional bits.
    static func ybrToRGB(luminance: Int, blueDifference: Int, redDifference: Int,
                            partialRange: Bool) -> (UInt8, UInt8, UInt8) {
        let blue = blueDifference - 128
        let red = redDifference - 128
        var r: Int, g: Int, b: Int
        if partialRange {
            let y = luminance - 16
            r = 38142 * y + 52298 * red
            g = 38142 * y - 26640 * red - 12845 * blue
            b = 38142 * y + 66093 * blue
        } else {
            r = 32768 * luminance + 45941 * red
            g = 32768 * luminance - 23401 * red - 11277 * blue
            b = 32768 * luminance + 58065 * blue
        }
        func clamp(_ value: Int) -> UInt8 { UInt8(min(max((value + 16384) >> 15, 0), 255)) }
        return (clamp(r), clamp(g), clamp(b))
    }

    /// YBR_FULL, YBR_PARTIAL and their 4:2:2 forms (a pair of luminances, then
    /// the two chrominances they share) as RGB; planar only for the full-sampled kinds.
    @objc(convertYBrToRGB:kind:isPlanar:)
    public func convertYBrToRGB(_ ybrData: NSData?, kind: String, isPlanar: Bool) -> NSData? {
        // The planar configuration should be 0 whenever YBR_FULL_422 or
        // YBR_PARTIAL_422 is used.
        if kind != "YBR_FULL" && isPlanar { return nil }
        guard let ybrData else { return nil }
        let length = Int(Int32(truncatingIfNeeded: rows &* columns &* 3))
        guard length >= 0, let rgbData = NSMutableData(length: length) else { return nil }
        let size = Int(rows) * Int(columns)
        let partialRange = kind.hasPrefix("YBR_PARTIAL")
        let subsampled = kind.hasSuffix("_422") || kind.hasSuffix("_420")
        let ybr = ybrData.bytes.assumingMemoryBound(to: UInt8.self)
        let rgb = rgbData.mutableBytes.assumingMemoryBound(to: UInt8.self)
        func put(_ at: Int, _ y: UInt8, _ cb: UInt8, _ cr: UInt8) {
            guard at + 2 < length else { return }
            let colour = Self.ybrToRGB(luminance: Int(y), blueDifference: Int(cb), redDifference: Int(cr),
                                  partialRange: partialRange)
            rgb[at] = colour.0
            rgb[at + 1] = colour.1
            rgb[at + 2] = colour.2
        }

        if isPlanar {
            // Three planes, one after the other.
            guard ybrData.length >= size * 3 else {
                NSLog("YBR planar data holds %ld of the %ld bytes the object declares", ybrData.length, size * 3)
                return nil
            }
            for index in 0..<max(size, 0) {
                put(index * 3, ybr[index], ybr[size + index], ybr[2 * size + index])
            }
        } else if subsampled {
            var pairs = size / 2
            if ybrData.length < pairs * 4 {
                pairs = ybrData.length / 4
                NSLog("YBR_422 data holds %ld of the %ld pixel pairs the object declares", pairs, size / 2)
            }
            for pair in 0..<max(pairs, 0) {
                let cb = ybr[pair * 4 + 2], cr = ybr[pair * 4 + 3]
                put(pair * 6, ybr[pair * 4], cb, cr)
                put(pair * 6 + 3, ybr[pair * 4 + 1], cb, cr)
            }
        } else {
            var count = size
            if ybrData.length < size * 3 {
                count = ybrData.length / 3
                NSLog("YBR data holds %ld of the %ld pixels the object declares", count, size)
            }
            for index in 0..<max(count, 0) {
                put(index * 3, ybr[index * 3], ybr[index * 3 + 1], ybr[index * 3 + 2])
            }
        }
        return rgbData
    }

    // MARK: Palette

    /// What the Objective-C original raised, and caught, on a descriptor or
    /// table it could not read.
    private struct PaletteException: Error {
        let name: String
    }

    private static func element(_ array: [Any]?, _ index: Int) throws -> Any? {
        guard let array else { return nil }
        guard index < array.count else { throw PaletteException(name: "NSRangeException") }
        return array[index]
    }

    private static func intValue(_ value: Any?) throws -> Int32 {
        guard let value else { return 0 }
        if let number = value as? NSNumber { return number.int32Value }
        if let string = value as? NSString { return string.intValue }
        throw PaletteException(name: "NSInvalidArgumentException")
    }

    private static func dataValue(_ value: Any?) throws -> NSData? {
        guard let value else { return nil }
        guard let data = value as? NSData else { throw PaletteException(name: "NSInvalidArgumentException") }
        return data
    }

    /// A pixel value below the first one the table maps takes the first entry,
    /// one above the last takes the last: PS 3.3 C.7.6.3.1.5.
    static func paletteEntry(for value: Int, first: Int, entries: Int) -> Int {
        guard entries > 0 else { return 0 }
        if value - first < 0 { return 0 }
        if value - first >= entries { return entries - 1 }
        return value - first
    }

    /// Expands one segmented palette lookup table (PS 3.3 C.7.9.2): a stream of
    /// segments, each a type and a length, then whatever that type needs. Nothing in
    /// the stream is trusted - not the length to stay inside the stream, not the
    /// total to stay inside the table.
    private static func expandSegmentedPalette(_ segmented: NSData?, into table: inout [UInt16]) -> Int {
        guard let segmented, !table.isEmpty else { return 0 }
        let count = segmented.length / 2
        let stream = segmented.bytes
        func word(_ at: Int) -> Int {
            Int(UInt16(littleEndian: stream.loadUnaligned(fromByteOffset: at * 2, as: UInt16.self)))
        }
        let entries = table.count
        var filled = 0
        var at = 0
        while at + 1 < count && filled < entries {
            let type = word(at)
            var length = word(at + 1)
            at += 2
            if type == 0 {
                // Discrete: one value per entry.
                if at + length > count { length = count - at }
                var index = 0
                while index < length && filled < entries {
                    table[filled] = UInt16(word(at + index))
                    filled += 1
                    index += 1
                }
                at += length
            } else if type == 1 {
                // Linear: interpolate from the last entry to one value.
                if at >= count { break }
                let from = filled > 0 ? Int(table[filled - 1]) : 0
                let to = word(at)
                var index = 1
                while index <= length && filled < entries {
                    table[filled] = UInt16(truncatingIfNeeded: from + ((to - from) * index) / (length > 0 ? length : 1))
                    filled += 1
                    index += 1
                }
                at += 1
            } else {
                // Indirect, and anything else: expanding it is not implemented, and
                // carrying on would put every following segment at the wrong index.
                NSLog("Palette segment type %d is not expanded; %ld entries were read", type, filled)
                break
            }
        }
        return filled
    }

    /// A palette colour frame as RGB, through its three lookup tables, 8- or
    /// 16-bit, plain or segmented. Nil when the tables cannot be read.
    @objc(convertPaletteToRGB:)
    public func convertPaletteToRGB(_ data: NSData) -> NSData? {
        do {
            return try paletteToRGB(data)
        } catch let exception as PaletteException {
            NSLog("Exception converting Palette to RGB: %@", exception.name)
        } catch {
            NSLog("Exception converting Palette to RGB: %@", "\(error)")
        }
        return nil
    }

    private func paletteToRGB(_ data: NSData) throws -> NSData? {
        let object = dcmObject
        let height = Int(rows), width = Int(columns)
        // A missing Photometric Interpretation reads as a palette, as it did.
        let photometric = object?.attributeValue(withName: "PhotometricInterpretation") as? String
        guard photometric?.contains("PALETTE") ?? true else { return nil }

        var clutRed = [UInt8](repeating: 0, count: 65536)
        var clutGreen = [UInt8](repeating: 0, count: 65536)
        var clutBlue = [UInt8](repeating: 0, count: 65536)
        var counts = [0, 0, 0]
        var firsts = [0, 0, 0]
        var depths = [0, 0, 0]
        for (colour, name) in ["Red", "Green", "Blue"].enumerated() {
            let descriptor = object?.attributeArray(withName: "\(name)PaletteColorLookupTableDescriptor")
            counts[colour] = Int(UInt16(truncatingIfNeeded: try Self.intValue(try Self.element(descriptor, 0))))
            firsts[colour] = Int(try Self.intValue(try Self.element(descriptor, 1)))
            depths[colour] = Int(UInt16(truncatingIfNeeded: try Self.intValue(try Self.element(descriptor, 2))))
        }
        for (colour, name) in ["R", "G", "B"].enumerated() where counts[colour] > 256 {
            NSLog("%@-Palette > 256", name)
        }

        var found = false, found16 = false
        var shortTables: [[UInt16]] = []
        let segmentedRed = object?.attributeValue(withName: "SegmentedRedPaletteColorLookupTableData")
        if segmentedRed != nil {
            // Segmented: 16 bits.
            if depths == [16, 16, 16] {
                // A 16-bit pixel can be 65535, which is one past the end of 65535
                // entries, and a segmented table fills only as far as its segments
                // go: the rest is zero.
                var red = [UInt16](repeating: 0, count: 65536)
                var green = red, blue = red
                let filled = Self.expandSegmentedPalette(try Self.dataValue(segmentedRed), into: &red)
                _ = Self.expandSegmentedPalette(
                    try Self.dataValue(object?.attributeValue(withName: "SegmentedGreenPaletteColorLookupTableData")),
                    into: &green)
                _ = Self.expandSegmentedPalette(
                    try Self.dataValue(object?.attributeValue(withName: "SegmentedBluePaletteColorLookupTableData")),
                    into: &blue)
                shortTables = [red, green, blue]
                found16 = filled > 0
            } else if depths == [8, 8, 8] {
                NSLog("Segmented palettes for 8 bits ??")
            } else {
                NSLog("Dont know this kind of DICOM CLUT...")
            }
        } else if depths == [16, 16, 16] || depths == [8, 8, 8] {
            // Three tables, read the same way. An entry is narrowed to 8 bits by
            // what the tables contain, not by the descriptor: a nuclear medicine
            // palette that stores 0-255 in 16-bit words is common.
            var raw = [[UInt16]](repeating: [], count: 3)
            var largest: UInt16 = 0
            for (colour, name) in ["Red", "Green", "Blue"].enumerated() {
                guard let table = object?.attribute(withName: "\(name)PaletteColorLookupTableData") else { continue }
                if table.valueMultiplicity > 1 {
                    // Some objects arrive parsed into numbers rather than bytes.
                    let values = table.values ?? NSMutableArray()
                    var wanted = counts[colour] > 0 ? counts[colour] : values.count
                    wanted = min(wanted, values.count, 65536)
                    for index in 0..<max(wanted, 0) {
                        raw[colour].append(UInt16(truncatingIfNeeded: try Self.intValue(values.object(at: index))))
                    }
                } else {
                    guard let bytes = try Self.dataValue(table.value()) else { continue }
                    if depths[colour] == 16 {
                        let available = bytes.length / 2
                        let wanted = min(counts[colour] > 0 ? counts[colour] : available, available, 65536)
                        for index in 0..<max(wanted, 0) {
                            raw[colour].append(UInt16(littleEndian: bytes.bytes.loadUnaligned(fromByteOffset: index * 2,
                                                                                              as: UInt16.self)))
                        }
                    } else {
                        let available = bytes.length
                        let wanted = min(counts[colour] > 0 ? counts[colour] : available, available, 65536)
                        let entries = bytes.bytes.assumingMemoryBound(to: UInt8.self)
                        for index in 0..<max(wanted, 0) {
                            raw[colour].append(UInt16(entries[index]))
                        }
                    }
                }
                largest = max(largest, raw[colour].max() ?? 0)
            }
            let eightBitValues = largest <= 255
            for colour in 0..<3 {
                for (index, value) in raw[colour].enumerated() {
                    let narrowed = eightBitValues ? UInt8(truncatingIfNeeded: value) : UInt8(value >> 8)
                    switch colour {
                    case 0: clutRed[index] = narrowed
                    case 1: clutGreen[index] = narrowed
                    default: clutBlue[index] = narrowed
                    }
                }
                if !raw[colour].isEmpty {
                    counts[colour] = raw[colour].count
                    found = true
                }
            }
        } else {
            NSLog("Palette color lookup tables of %d/%d/%d bits are not read", depths[0], depths[1], depths[2])
        }

        var rgbData: NSMutableData?
        if found {
            let total = height * width * 3
            guard let output = NSMutableData(length: max(total, 0)) else { return nil }
            rgbData = output
            let image = output.mutableBytes.assumingMemoryBound(to: UInt8.self)
            // An object can declare a picture larger than the pixels it carries.
            let available = data.length / (pixelDepth == 16 ? 2 : 1)
            var pixels = height * width
            if available < pixels {
                NSLog("Palette pixel data holds %ld of the %ld pixels the object declares", available, pixels)
                pixels = available
            }
            func put(_ index: Int, _ value: Int) {
                image[index * 3] = clutRed[Self.paletteEntry(for: value, first: firsts[0], entries: counts[0])]
                image[index * 3 + 1] = clutGreen[Self.paletteEntry(for: value, first: firsts[1], entries: counts[1])]
                image[index * 3 + 2] = clutBlue[Self.paletteEntry(for: value, first: firsts[2], entries: counts[2])]
            }
            switch pixelDepth {
            case 8:
                let samples = data.bytes.assumingMemoryBound(to: UInt8.self)
                for index in 0..<max(pixels, 0) { put(index, Int(samples[index])) }
            case 16:
                // The pixels arrive in host order, like every other image here.
                for index in 0..<max(pixels, 0) {
                    put(index, Int(data.bytes.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self)))
                }
            default:
                break
            }
        }

        if found16 {
            if pixelDepth != 16 { NSLog("Segmented Palette with a non-16 bit image???") }
            // Three bytes per pixel, like the other palette: the display path
            // reads eight bits per sample.
            let total = Int(rows) * Int(columns) * 3
            guard let output = NSMutableData(length: max(total, 0)) else { return nil }
            rgbData = output
            let image = output.mutableBytes.assumingMemoryBound(to: UInt8.self)
            let available = data.length / 2
            var pixels = height * width
            if available < pixels {
                NSLog("Segmented palette pixel data holds %ld of the %ld pixels the object declares", available, pixels)
                pixels = available
            }
            let largest = shortTables.map { $0.max() ?? 0 }.max() ?? 0
            let eightBitValues = largest <= 255
            for index in 0..<max(pixels, 0) {
                let value = Int(data.bytes.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self))
                for colour in 0..<3 {
                    let entry = shortTables[colour][Self.paletteEntry(for: value, first: firsts[colour], entries: counts[colour])]
                    image[index * 3 + colour] = eightBitValues ? UInt8(truncatingIfNeeded: entry) : UInt8(entry >> 8)
                }
            }
        }
        return rgbData
    }
}
