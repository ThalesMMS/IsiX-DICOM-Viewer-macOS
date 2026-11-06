//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Foundation
import Testing
@testable import IsiXImaging

/// The display image's rules on their own. The comparison with the
/// Objective-C they replaced, bit for bit, is tests/test-dcmpix-display.py.
struct ShutterMaskTests {
    @Test func theRectangleIsHeldInsideAndRounded() {
        #expect(ShutterMask.heldRect(CGRect(x: -2.4, y: 3.5, width: 10.6, height: 100), width: 8, height: 20)
                == CGRect(x: 0, y: 4, width: 8, height: 17))
    }

    @Test func outsideTheRectangleIsBlack() {
        var picture = [UInt8](repeating: 9, count: 16)
        picture.withUnsafeMutableBufferPointer {
            ShutterMask.maskGrey($0.baseAddress!, width: 4, height: 4, rect: CGRect(x: 1, y: 1, width: 2, height: 2), black: 3,
                                 circleCentre: .zero, circleRadius: 0, polygon: nil, polygonCount: 0)
        }
        #expect(picture == [3, 3, 3, 3, 3, 9, 9, 3, 3, 9, 9, 3, 3, 3, 3, 3])
        var colour = [UInt8](repeating: 7, count: 4 * 4 * 4)
        colour.withUnsafeMutableBytes {
            ShutterMask.maskColour($0.baseAddress!, width: 4, height: 4, rect: CGRect(x: 3, y: 3, width: 1, height: 1))
        }
        #expect(colour.filter { $0 == 7 }.count == 4 && Array(colour[60..<64]) == [7, 7, 7, 7])
    }

    @Test func aPolygonHasItsLeftEdgeAndNotItsRight() {
        let square = [CGPoint(x: 1, y: 1), CGPoint(x: 3, y: 1), CGPoint(x: 3, y: 3), CGPoint(x: 1, y: 3)]
        square.withUnsafeBufferPointer { p in
            #expect(ShutterMask.contains(p.baseAddress!, count: 4, x: 1, y: 1))
            #expect(ShutterMask.contains(p.baseAddress!, count: 4, x: 2, y: 2))
            #expect(!ShutterMask.contains(p.baseAddress!, count: 4, x: 3, y: 2))
            #expect(!ShutterMask.contains(p.baseAddress!, count: 4, x: 2, y: 3))
        }
    }

    @Test func aCircleKeepsItsInside() {
        var picture = [UInt8](repeating: 1, count: 11 * 11)
        picture.withUnsafeMutableBufferPointer {
            ShutterMask.eraseOutsideCircle($0.baseAddress!, width: 11, height: 11, cx: 5, cy: 5, radius: 4, black: 0)
        }
        #expect(picture[5 * 11 + 5] == 1 && picture[0] == 0 && picture[5 * 11 + 10] == 0 && picture[1 * 11 + 1] == 0)
        var untouched = [UInt8](repeating: 1, count: 4)
        untouched.withUnsafeMutableBufferPointer {
            ShutterMask.eraseOutsideCircle($0.baseAddress!, width: 2, height: 2, cx: 5, cy: 0, radius: 1, black: 0)
        }
        #expect(untouched == [1, 1, 1, 1])
    }
}

struct ThumbnailIconTests {
    @Test func theLongestSideIsThePreviewSize() {
        #expect(ThumbnailIcon.size(width: 136, height: 68) == (68, 34))
        #expect(ThumbnailIcon.size(width: 30, height: 60) == (34, 68))
    }

    @Test func greyIsWindowedInIntegers() {
        let image: [Float] = [-10, 0, 50, 100, 200, 99.9]
        var icon = [UInt8](repeating: 0, count: 68 * 68)
        image.withUnsafeBytes { source in
            icon.withUnsafeMutableBufferPointer {
                ThumbnailIcon.draw(source.baseAddress!, into: $0.baseAddress!, width: 6, height: 1, iconWidth: 68, level: 50, window: 100,
                                   isRGB: false)
            }
        }
        // 6 pixels over 68: each is drawn about 11 times.
        #expect(icon[0] == 0 && icon[12] == 0 && icon[23] == 127 && icon[34] == 255 && icon[46] == 255 && icon[67] == 252)
        ThumbnailIcon.invert(&icon, count: 1)
        #expect(icon[0] == 255)
    }
}

struct ThickSlabReductionTests {
    @Test func slicesAreFoldedByMode() {
        let a: [Float] = [1, 5, 3], b: [Float] = [4, 2, 6]
        for (mode, expected) in [(ThickSlabReduction.maximum, [Float](arrayLiteral: 4, 5, 6)), (ThickSlabReduction.minimum, [1, 2, 3]),
                                 (ThickSlabReduction.mean, [2.5, 3.5, 4.5])] {
            var result: [Float] = [1, 5, 3]
            a.withUnsafeBufferPointer { _ in
                b.withUnsafeBufferPointer { other in
                    result.withUnsafeMutableBufferPointer {
                        ThickSlabReduction.fold(into: $0.baseAddress!, count: 3, slices: [other.baseAddress!], mode: mode, workers: 5)
                        if mode == ThickSlabReduction.mean { ThickSlabReduction.divide($0.baseAddress!, count: 3, by: 2) }
                    }
                }
            }
            #expect(result == expected)
        }
    }

    @Test func colourBytesAreFoldedOneByOne() {
        let a = [UInt8](0..<23).map { $0 * 3 }, b = [UInt8](0..<23).map { 60 - $0 * 2 }
        var r = [UInt8](repeating: 0, count: 24)
        a.withUnsafeBytes { x in b.withUnsafeBytes { y in r.withUnsafeMutableBytes {
            ThickSlabReduction.foldBytes(x.baseAddress!, y.baseAddress!, into: $0.baseAddress!, pixels: 5, keepLarger: true)
        } } }
        #expect(Array(r[0..<20]) == (0..<20).map { Swift.max(a[$0], b[$0]) } && r[20] == 0)
    }

    @Test func aValueIsReadThroughTheSlab() {
        let current: [Float] = [10, 20], next: [Float] = [30, 0]
        current.withUnsafeBufferPointer { c in next.withUnsafeBufferPointer { n in
            #expect(ThickSlabReduction.value(at: 0, current: c.baseAddress!, neighbours: [n.baseAddress!], mode: 1, isRGB: false) == 20)
            #expect(ThickSlabReduction.value(at: 1, current: c.baseAddress!, neighbours: [n.baseAddress!], mode: 3, isRGB: false) == 0)
            #expect(ThickSlabReduction.value(at: 1, current: c.baseAddress!, neighbours: nil, mode: 2, isRGB: false) == 20)
        } }
    }
}

struct ColourChannelsTests {
    @Test func greyAndColourChange() {
        let argb: [UInt8] = [255, 10, 20, 31, 0, 1, 2, 3]
        var grey = [Float](repeating: -1, count: 2)
        argb.withUnsafeBufferPointer { s in grey.withUnsafeMutableBufferPointer {
            ColourChannels.grey(fromARGB: s.baseAddress!, into: $0.baseAddress!, count: 2, mode: 3)
        } }
        #expect(grey == [Float(61.0 / 3.0), 2])
        var pixels: [Float] = [0, 100, 50, 200]
        pixels.withUnsafeMutableBufferPointer {
            ColourChannels.toARGB($0.baseAddress!, width: 2, height: 2, mode: 1, level: 100, window: 200)
            ColourChannels.fillAlpha(UnsafeMutableRawPointer($0.baseAddress!).assumingMemoryBound(to: UInt8.self), count: 4)
        }
        let bytes = pixels.withUnsafeBytes { Array($0) }
        #expect(bytes[1] == 0 && bytes[3] == 0 && bytes[6] == 128 && bytes[4] == 42)
    }
}

struct DisplayWindowRangeTests {
    @Test func storedBitsGiveTheLastResortWindow() {
        let unsigned = DisplayWindowRange.storedRange(bitsStored: 12, bitsAllocated: 16, isSigned: false, slope: 1, intercept: -1024)
        #expect(unsigned?.level == 1023.5 && unsigned?.width == 4095)
        let narrow = DisplayWindowRange.storedRange(bitsStored: 1, bitsAllocated: 8, isSigned: false, slope: 0.1, intercept: 0)
        #expect(narrow?.width == 1)
        #expect(DisplayWindowRange.storedRange(bitsStored: 12, bitsAllocated: 16, isSigned: true, slope: .nan, intercept: 0) == nil)
        #expect(!DisplayWindowRange.isUsableStoredWindow(level: 40, width: 0))
        #expect(!DisplayWindowRange.isUsableFrameRange(level: 40, width: -1))
    }

    @Test func largePicturesAreRedrawnSmaller() {
        #expect(DisplayWindowRange.resizedSize(CGSize(width: 512, height: 900), pixelWidth: 256, pixelHeight: 256) == nil)
        #expect(DisplayWindowRange.resizedSize(CGSize(width: 2000, height: 1500), pixelWidth: 256, pixelHeight: 200)
                == CGSize(width: 1333, height: 1000))
        #expect(DisplayWindowRange.resizedSize(CGSize(width: 600, height: 520), pixelWidth: 700, pixelHeight: 600) == nil)
    }
}
