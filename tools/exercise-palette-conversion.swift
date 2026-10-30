//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Drives -[DCMPixelDataAttribute convertPaletteToRGB:] - the real one, compiled
// with the IsiXDICOMDataset module by tests/test-palette-conversion-safety.py -
// against palettes that are extreme, truncated, contradictory or absent, under
// AddressSanitizer.
//
// The objects are real DCMObjects. The tag dictionary below stands in for the
// one the host's DCMTK adapter gives the model, reduced to the attributes the
// conversion names.

import Foundation
import IsiXDICOMFile

@objc(HorosDICOMDictionaries)
final class PaletteDictionaries: NSObject {
    private static let entries: [(String, String, String)] = [
        ("0028,0004", "PhotometricInterpretation", "CS"),
        ("0028,1101", "RedPaletteColorLookupTableDescriptor", "US"),
        ("0028,1102", "GreenPaletteColorLookupTableDescriptor", "US"),
        ("0028,1103", "BluePaletteColorLookupTableDescriptor", "US"),
        ("0028,1201", "RedPaletteColorLookupTableData", "OW"),
        ("0028,1202", "GreenPaletteColorLookupTableData", "OW"),
        ("0028,1203", "BluePaletteColorLookupTableData", "OW"),
        ("0028,1221", "SegmentedRedPaletteColorLookupTableData", "OW"),
        ("0028,1222", "SegmentedGreenPaletteColorLookupTableData", "OW"),
        ("0028,1223", "SegmentedBluePaletteColorLookupTableData", "OW"),
    ]

    @objc static func tagDictionary() -> NSDictionary {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.0, ["Description": $0.1, "VR": $0.2, "VM": "1"]) })
            as NSDictionary
    }

    @objc static func tagForNameDictionary() -> NSDictionary {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.1, $0.0) }) as NSDictionary
    }
}

/// An attribute value: one value, or several (a descriptor).
enum Value {
    case scalar(Any)
    case list([Any])
}

func descriptor(_ entries: Int, _ first: Int, _ bits: Int) -> Value { .list([entries, first, bits]) }

func table8(_ entries: Int, _ value: Int) -> Value {
    .scalar(Data((0..<entries).map { UInt8(truncatingIfNeeded: value < 0 ? $0 & 0xff : value) }))
}

func table16(_ entries: Int, _ value: Int, wide: Bool) -> Value {
    var data = Data()
    for index in 0..<entries {
        let level = value < 0 ? index & 0xff : value
        withUnsafeBytes(of: UInt16(truncatingIfNeeded: wide ? level * 257 : level).littleEndian) { data.append(contentsOf: $0) }
    }
    return .scalar(data)
}

func words(_ values: [UInt16]) -> Value {
    .scalar(values.withUnsafeBytes { Data($0) })
}

func rampPixels8(_ rows: Int, _ columns: Int) -> Data {
    Data((0..<(rows * columns)).map { UInt8($0 % 256) })
}

func extremePixels16(_ rows: Int, _ columns: Int) -> Data {
    (0..<(rows * columns)).map { (index: Int) -> UInt16 in
        index % 3 == 0 ? 0 : (index % 3 == 1 ? 65535 : UInt16(index % 4096))
    }.withUnsafeBytes { Data($0) }
}

nonisolated(unsafe) var failures = 0

func run(_ what: String, _ rows: Int, _ columns: Int, _ depth: Int, _ attributes: [String: Value],
         _ pixels: Data, _ expected: Int) {
    autoreleasepool {
        let object = DCMObject()
        for (name, value) in attributes {
            switch value {
            case .scalar(let one): object.setAttributeValues(NSMutableArray(object: one), forName: name)
            case .list(let several): object.setAttributeValues(NSMutableArray(array: several), forName: name)
            }
        }
        let attribute = DCMPixelDataAttribute(attributeTag: nil, vr: "OW", values: NSMutableArray(), object: object,
                                              transferSyntax: nil, frameSource: nil)
        attribute.rows = Int32(rows)
        attribute.columns = Int32(columns)
        attribute.pixelDepth = Int32(depth)
        let rgb = attribute.convertPaletteToRGB(pixels as NSData)
        let got = rgb.map { $0.length } ?? -1
        var verdict = "ok"
        if expected >= 0 && got != expected {
            verdict = "WRONG SIZE"
            failures += 1
        }
        print(what.padding(toLength: 46, withPad: " ", startingAt: 0),
              String(format: "%8ld bytes  (expected %ld)  %@", got, expected, verdict))
    }
}

let rows = 24, columns = 32
let common: [String: Value] = ["PhotometricInterpretation": .scalar("PALETTE COLOR")]

var eight = common
eight["RedPaletteColorLookupTableDescriptor"] = descriptor(256, 0, 8)
eight["GreenPaletteColorLookupTableDescriptor"] = descriptor(256, 0, 8)
eight["BluePaletteColorLookupTableDescriptor"] = descriptor(256, 0, 8)
eight["RedPaletteColorLookupTableData"] = table8(256, -1)
eight["GreenPaletteColorLookupTableData"] = table8(256, -1)
eight["BluePaletteColorLookupTableData"] = table8(256, 96)
run("8-bit palette, 8-bit pixels", rows, columns, 8, eight, rampPixels8(rows, columns), rows * columns * 3)

// A table that stops early, while the descriptor still claims 256 entries.
var truncated = eight
truncated["RedPaletteColorLookupTableData"] = table8(8, -1)
truncated["GreenPaletteColorLookupTableData"] = table8(3, -1)
truncated["BluePaletteColorLookupTableData"] = table8(1, 96)
run("truncated 8-bit tables", rows, columns, 8, truncated, rampPixels8(rows, columns), rows * columns * 3)

// Blue present, green absent: the blue table used to be read from green.
var noGreen = eight
noGreen["GreenPaletteColorLookupTableData"] = nil
run("green table missing, blue present", rows, columns, 8, noGreen, rampPixels8(rows, columns), rows * columns * 3)

// No table data at all, only descriptors.
var bare = common
bare["RedPaletteColorLookupTableDescriptor"] = descriptor(256, 0, 8)
bare["GreenPaletteColorLookupTableDescriptor"] = descriptor(256, 0, 8)
bare["BluePaletteColorLookupTableDescriptor"] = descriptor(256, 0, 8)
run("descriptors with no tables", rows, columns, 8, bare, rampPixels8(rows, columns), -1)

// A descriptor with fewer than three values.
var shortDescriptor = eight
shortDescriptor["RedPaletteColorLookupTableDescriptor"] = .list([256])
run("descriptor with one value", rows, columns, 8, shortDescriptor, rampPixels8(rows, columns), -1)

// 16-bit tables and 16-bit pixels, including 0 and 65535.
var sixteen = common
sixteen["RedPaletteColorLookupTableDescriptor"] = descriptor(256, 0, 16)
sixteen["GreenPaletteColorLookupTableDescriptor"] = descriptor(256, 0, 16)
sixteen["BluePaletteColorLookupTableDescriptor"] = descriptor(256, 0, 16)
sixteen["RedPaletteColorLookupTableData"] = table16(256, -1, wide: true)
sixteen["GreenPaletteColorLookupTableData"] = table16(256, -1, wide: true)
sixteen["BluePaletteColorLookupTableData"] = table16(256, 96, wide: true)
run("16-bit palette, extreme 16-bit pixels", rows, columns, 16, sixteen, extremePixels16(rows, columns),
    rows * columns * 3)

// Entry count zero, which the standard reads as 65536.
var full = sixteen
for colour in ["Red", "Green", "Blue"] { full["\(colour)PaletteColorLookupTableDescriptor"] = descriptor(0, 0, 16) }
run("entry count 0, 65536 entries implied", rows, columns, 16, full, extremePixels16(rows, columns), rows * columns * 3)

// A first mapped value well above the pixels.
var offsetHigh = sixteen
for colour in ["Red", "Green", "Blue"] {
    offsetHigh["\(colour)PaletteColorLookupTableDescriptor"] = descriptor(256, 60000, 16)
}
run("first mapped value 60000", rows, columns, 16, offsetHigh, extremePixels16(rows, columns), rows * columns * 3)

// Pixel data shorter than the picture it is supposed to fill.
run("pixel data half as long as the picture", rows, columns, 8, eight,
    rampPixels8(rows, columns).prefix(rows * columns / 2), -1)
run("16-bit pixel data half as long", rows, columns, 16, sixteen,
    extremePixels16(rows, columns).prefix(rows * columns), -1)

// A segmented table whose stream stops in the middle of a segment.
var segmented = common
for colour in ["Red", "Green", "Blue"] {
    segmented["\(colour)PaletteColorLookupTableDescriptor"] = descriptor(256, 0, 16)
    segmented["Segmented\(colour)PaletteColorLookupTableData"] = words([0, 4, 10, 20, 30, 40, 1, 8])
}
run("segmented table truncated mid-segment", rows, columns, 16, segmented, extremePixels16(rows, columns), -1)

// A discrete segment that says it holds far more than the stream does, and
// far more than the table can take.
var lying = segmented
for colour in ["Red", "Green", "Blue"] {
    lying["Segmented\(colour)PaletteColorLookupTableData"] = words([0, 60000, 1, 2, 3])
}
run("segment longer than the stream and the table", rows, columns, 16, lying, extremePixels16(rows, columns), -1)

// A linear segment first, with no earlier entry to interpolate from.
var linearFirst = segmented
for colour in ["Red", "Green", "Blue"] {
    linearFirst["Segmented\(colour)PaletteColorLookupTableData"] =
        words([1, 200, 4095, 0, 8, 100, 200, 300, 400, 500, 600, 700, 800])
}
run("linear segment with nothing before it", rows, columns, 16, linearFirst, extremePixels16(rows, columns), -1)

print("\(failures) case(s) produced the wrong size")
exit(failures != 0 ? 1 : 0)
