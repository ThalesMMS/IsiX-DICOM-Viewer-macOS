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

import Foundation
import IsiXImaging

/// The rules of the DICOM export of an image (DICOMExport): which pixels it
/// accepts, how it squares and turns them, and what it writes over the
/// source's attributes. The pixels are the caller's; the dataset is DCMTK's,
/// in the app's adapter, which applies the edits these rules list.
///
/// The arithmetic is single precision, as the Objective-C++ it comes from was
/// compiled: a product added to or taken from a sum was one fused operation
/// there (the compiler contracts them), and is written so here.
public enum SecondaryCaptureExport {

    // MARK: - Pixel formats

    /// Why pixels of `samplesPerPixel` and `bitsPerSample` cannot be written,
    /// as the export logs it; nil when they can.
    public static func refusal(samplesPerPixel: Int, bitsPerSample: Int) -> String? {
        if samplesPerPixel != 1 && samplesPerPixel != 3 {
            return "**** DICOM Export: sample per pixel not supported: \(samplesPerPixel)"
        }
        if samplesPerPixel == 3 && bitsPerSample != 8 {
            return "**** DICOM Export: for RGB images, only 8 bits per sample is supported: \(bitsPerSample)"
        }
        if bitsPerSample != 8 && bitsPerSample != 16 && bitsPerSample != 32 {
            return "**** DICOM Export: unknown bits per sample: \(bitsPerSample)"
        }
        return nil
    }

    /// High Bit and Bits Allocated (and Stored) for `bitsPerSample`.
    public static func bitLayout(bitsPerSample: Int) -> (highBit: Int, bitsAllocated: Int)? {
        switch bitsPerSample {
        case 8: return (7, 8)
        case 16: return (15, 16)
        case 32: return (31, 32)
        default: return nil
        }
    }

    /// RGBA pixels made RGB, each colour multiplied by its alpha.
    public static func premultipliedRGB(rgba: UnsafePointer<UInt8>, rgb: UnsafeMutablePointer<UInt8>,
                                        width: Int, height: Int) {
        for y in 0..<height {
            for x in 0..<width {
                let source = x * 4 + y * width * 4, target = x * 3 + y * width * 3
                // (float)alpha / 255. divides in double, and is stored as a float.
                let alpha = Float(Double(Float(rgba[3 + source])) / 255.0)
                rgb[target] = UInt8(Float(rgba[source]) * alpha)
                rgb[target + 1] = UInt8(Float(rgba[source + 1]) * alpha)
                rgb[target + 2] = UInt8(Float(rgba[source + 2]) * alpha)
            }
        }
    }

    // MARK: - Square pixels

    /// The height of 16-bit pixels resampled to square pixels: the height in
    /// the X spacing, made even.
    public static func squarePixelHeight(height: Int, spacingX: Float, spacingY: Float) -> Int {
        let scaled = Int((Float(height) * spacingY) / spacingX)
        return (scaled / 2) * 2
    }

    // MARK: - A quarter turn

    /// The plane of an image turned a quarter turn, given with its spacing
    /// and size already exchanged: the new origin and orientation.
    public struct Plane: Equatable, Sendable {
        public var orientation: [Float]
        public var position: [Float]

        public init(orientation: [Float], position: [Float]) {
            self.orientation = orientation
            self.position = position
        }
    }

    /// -90 degrees, as the export computed it: the float constant
    /// M_PI / 180.0f times -90 in single precision.
    static let quarterTurn = Double(Float(-90) * Float(Double.pi / 180.0))

    /// The plane turned for an image now `width` wide with `spacingX` and
    /// `spacingY`; unchanged when it has no orientation.
    public static func turnedPlane(_ plane: Plane, width: Int, spacingX: Float, spacingY: Float) -> Plane {
        let o = plane.orientation, p = plane.position
        guard o[0] != 0 || o[1] != 0 || o[2] != 0 else { return plane }
        let x: Float = 0, y = Float(width)
        var origin = [Float](repeating: 0, count: 3)
        for i in 0..<3 {
            if spacingX != 0 && spacingY != 0 {
                origin[i] = p[i].addingProduct(y * o[3 + i], spacingY).addingProduct(x * o[i], spacingX)
            } else {
                origin[i] = p[i].addingProduct(y, o[3 + i]).addingProduct(x, o[i])
            }
        }
        let normal = SIMD3<Double>(Double((-(o[2] * o[4])).addingProduct(o[1], o[5])),
                                   Double((-(o[0] * o[5])).addingProduct(o[2], o[3])),
                                   Double((-(o[1] * o[3])).addingProduct(o[0], o[4])))
        let row = PlaneGeometry.arbitraryRotate(SIMD3(Double(o[0]), Double(o[1]), Double(o[2])),
                                                theta: quarterTurn, axis: normal)
        let column = PlaneGeometry.arbitraryRotate(SIMD3(Double(o[3]), Double(o[4]), Double(o[5])),
                                                   theta: quarterTurn, axis: normal)
        return Plane(orientation: [Float(row.x), Float(row.y), Float(row.z),
                                   Float(column.x), Float(column.y), Float(column.z)],
                     position: origin)
    }

    /// The pixels turned a quarter turn in place, for an image now `width`
    /// wide and `height` high. The three-sample loop is the one the export
    /// always had: it steps the column by one byte, not one pixel, and
    /// copies back the whole scratch buffer, written or not.
    public static func turnPixels(_ data: UnsafeMutableRawPointer, width: Int, height: Int,
                                  bitsPerSample: Int, samplesPerPixel: Int) -> Bool {
        switch bitsPerSample {
        case 8:
            let old = data.assumingMemoryBound(to: UInt8.self)
            if samplesPerPixel == 3 {
                let count = height * width * bitsPerSample * samplesPerPixel / 8
                guard let new = malloc(count)?.assumingMemoryBound(to: UInt8.self) else { return true }
                for x in 0..<width {
                    for y in 0..<height {
                        new[y * width * 3 + x] = old[(width - x - 1) * height * 3 + y]
                        new[y * width * 3 + x + 1] = old[(width - x - 1) * height * 3 + y + 1]
                        new[y * width * 3 + x + 2] = old[(width - x - 1) * height * 3 + y + 2]
                    }
                }
                memcpy(old, new, count)
                free(new)
            } else {
                turn(old, width: width, height: height)
            }
        case 16:
            turn(data.assumingMemoryBound(to: UInt16.self), width: width, height: height)
        case 32:
            turn(data.assumingMemoryBound(to: Float.self), width: width, height: height)
        default:
            return false
        }
        return true
    }

    private static func turn<T>(_ old: UnsafeMutablePointer<T>, width: Int, height: Int) {
        let count = height * width
        guard let new = malloc(count * MemoryLayout<T>.stride)?.assumingMemoryBound(to: T.self) else { return }
        for x in 0..<width {
            for y in 0..<height {
                new[y * width + x] = old[(width - x - 1) * height + y]
            }
        }
        memcpy(old, new, count * MemoryLayout<T>.stride)
        free(new)
    }

    // MARK: - The attributes

    /// One change to the dataset or to the file meta.
    public enum Edit: Equatable, Sendable {
        case put(UInt32, String)
        case putMeta(UInt32, String)
        case remove(UInt32)
    }

    public static let secondaryCaptureStorage = "1.2.840.10008.5.1.4.1.1.7"

    /// What an image is written with.
    public struct Image: Sendable {
        public var width: Int
        public var height: Int
        public var samplesPerPixel: Int
        public var bitsPerSample: Int
        public var isSigned: Bool
        public var offset: Int32
        public var slope: Float
        public var windowWidth: Int
        public var windowLevel: Int
        public var spacingX: Float
        public var spacingY: Float
        public var sliceThickness: Float
        public var orientation: [Float]
        public var position: [Float]?
        public var slicePosition: Float?

        public init(width: Int, height: Int, samplesPerPixel: Int, bitsPerSample: Int, isSigned: Bool, offset: Int32,
                    slope: Float, windowWidth: Int, windowLevel: Int, spacingX: Float, spacingY: Float,
                    sliceThickness: Float, orientation: [Float], position: [Float]?, slicePosition: Float?) {
            self.width = width
            self.height = height
            self.samplesPerPixel = samplesPerPixel
            self.bitsPerSample = bitsPerSample
            self.isSigned = isSigned
            self.offset = offset
            self.slope = slope
            self.windowWidth = windowWidth
            self.windowLevel = windowLevel
            self.spacingX = spacingX
            self.spacingY = spacingY
            self.sliceThickness = sliceThickness
            self.orientation = orientation
            self.position = position
            self.slicePosition = slicePosition
        }
    }

    /// Whether the image is written as a secondary capture (modality SC)
    /// rather than keeping the source's class and modality.
    public static func writesSecondaryCapture(modalityAsSource: Bool, samplesPerPixel: Int) -> Bool {
        !modalityAsSource || samplesPerPixel == 3
    }

    /// The edits after the series, in the order the export makes them, for
    /// `image` numbered `instanceNumber`, over a dataset whose modality is
    /// `sourceModality`. The pixel data itself is not among them.
    public static func imageEdits(_ image: Image, instanceNumber: Int32, modalityAsSource: Bool,
                                  sourceModality: String?) -> [Edit] {
        var edits: [Edit] = []
        let secondaryCapture = writesSecondaryCapture(modalityAsSource: modalityAsSource,
                                                      samplesPerPixel: image.samplesPerPixel)
        if secondaryCapture {
            edits += [.put(0x0008_0060, "SC"), .putMeta(0x0002_0002, secondaryCaptureStorage),
                      .put(0x0008_0016, secondaryCaptureStorage)]
        } else {
            edits.append(.remove(0x0002_0002))
        }
        let layout = bitLayout(bitsPerSample: image.bitsPerSample) ?? (0, 0)
        edits += [
            .put(0x0008_1090, "IsiX DICOM Viewer"),
            .put(0x0020_0013, String(format: "%d", instanceNumber)),
            .put(0x0020_0012, "1"),
            .put(0x0028_0010, String(format: "%d", Int32(truncatingIfNeeded: image.height))),
            .put(0x0028_0011, String(format: "%d", Int32(truncatingIfNeeded: image.width))),
            .put(0x0028_0002, String(format: "%d", Int32(truncatingIfNeeded: image.samplesPerPixel))),
            .put(0x0028_0004, image.samplesPerPixel == 3 ? "RGB" : "MONOCHROME2"),
            .put(0x0028_0103, image.isSigned ? "1" : "0"),
            .put(0x0028_0102, String(format: "%d", layout.highBit)),
            .put(0x0028_0100, String(format: "%d", layout.bitsAllocated)),
            .put(0x0028_0101, String(format: "%d", layout.bitsAllocated)),
            .remove(0x0018_1164), // Imager Pixel Spacing
            .remove(0x0018_1114), // Estimated Radiographic Magnification Factor
        ]
        if image.spacingX != 0 && image.spacingY != 0 {
            edits.append(.put(0x0028_0030, String(format: "%f\\%f", image.spacingY, image.spacingX)))
        }
        edits.append(.remove(0x0018_0050))
        if image.sliceThickness != 0 {
            edits.append(.put(0x0018_0050, String(format: "%f", image.sliceThickness)))
        }
        edits.append(.remove(0x0020_0037))
        let o = image.orientation
        if o[0] != 0 || o[1] != 0 || o[2] != 0 {
            edits.append(.put(0x0020_0037, String(format: "%f\\%f\\%f\\%f\\%f\\%f", o[0], o[1], o[2], o[3], o[4], o[5])))
        }
        edits.append(.remove(0x0020_0032))
        if let p = image.position {
            edits.append(.put(0x0020_0032, String(format: "%f\\%f\\%f", p[0], p[1], p[2])))
        }
        edits.append(.remove(0x0020_1041))
        if let slice = image.slicePosition {
            edits.append(.put(0x0020_1041, String(format: "%f", slice)))
        }
        edits.append(.remove(0x0028_0006))
        if image.samplesPerPixel == 3 {
            edits.append(.put(0x0028_0006, "0"))
        }
        edits += [.remove(0x7fe0_0010), .remove(0x0009_1110)] // GEIIS: a private, always JPEG, pixel data
        let modality = secondaryCapture ? "SC" : sourceModality
        let rescaleType = modality == "CT" ? "HU" : "US"
        let window = image.windowWidth != -1
            ? [Edit.put(0x0028_1050, String(format: "%d", Int32(truncatingIfNeeded: image.windowLevel))),
               .put(0x0028_1051, String(format: "%d", Int32(truncatingIfNeeded: image.windowWidth)))] : []
        switch image.bitsPerSample {
        case 32:
            edits += [.put(0x0028_1052, "0"), .put(0x0028_1053, "1"), .put(0x0028_1054, rescaleType)] + window
        case 16:
            edits += [.put(0x0028_1052, image.isSigned ? "0" : String(format: "%d", image.offset)),
                      .put(0x0028_1053, String(format: "%f", image.slope)), .put(0x0028_1054, rescaleType)] + window
        default:
            edits += [.remove(0x0028_1051), .remove(0x0028_1050)]
            if image.samplesPerPixel != 3 {
                edits += [.put(0x0028_1052, "0"), .put(0x0028_1053, "1"), .put(0x0028_1054, "US")]
            } else {
                edits += [.remove(0x0028_1052), .remove(0x0028_1053), .remove(0x0028_1055)]
            }
        }
        return edits
    }

    /// The edits after the pixel data, before the new identity.
    public static let closingRemovals: [UInt32] = [
        0x0028_0106, // Smallest Image Pixel Value
        0x0028_0107, // Largest Image Pixel Value
        0x0002_0003, // Media Storage SOP Instance UID, in the dataset
        0x5200_9230, // Per-Frame Functional Groups Sequence
        0x0088_0200, // Icon Image Sequence, which some GE files carry wrongly
    ]

    /// The number of bytes of pixel data written, and whether they go as
    /// 16-bit words.
    public static func pixelDataLength(_ image: Image) -> (count: Int, words: Bool) {
        switch image.bitsPerSample {
        case 32: return (image.height * image.width * 4, false)
        case 16: return (image.height * image.width * image.samplesPerPixel, true)
        default: return (image.height * image.width * image.samplesPerPixel, false)
        }
    }
}
