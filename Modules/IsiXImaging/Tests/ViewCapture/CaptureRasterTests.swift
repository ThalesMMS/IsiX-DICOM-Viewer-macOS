//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import Testing
@testable import IsiXImaging

@Suite struct CaptureRasterTests {

    @Test func sixteenBitEncodingFollowsTheSeriesMinimum() {
        #expect(CaptureRaster.SixteenBitEncoding(minimumOfSeries: -2048) == .init(minimumOfSeries: -1025))
        #expect(CaptureRaster.SixteenBitEncoding(minimumOfSeries: -2048).isSigned)
        #expect(CaptureRaster.SixteenBitEncoding(minimumOfSeries: -2048).offset == 0)
        #expect(!CaptureRaster.SixteenBitEncoding(minimumOfSeries: -1024).isSigned)
        #expect(CaptureRaster.SixteenBitEncoding(minimumOfSeries: -1024).offset == -1024)
        #expect(CaptureRaster.SixteenBitEncoding(minimumOfSeries: -0.5).offset == -1024)
        #expect(CaptureRaster.SixteenBitEncoding(minimumOfSeries: 0).offset == 0)
        #expect(!CaptureRaster.SixteenBitEncoding(minimumOfSeries: 0).isSigned)
    }

    @Test func floatSamplesBecomeShiftedOrSignedIntegers() {
        var samples: [Float] = [-1024, -1000, 0, 2000.4, 70000]
        var unsigned = [UInt16](repeating: 0, count: 5)
        samples.withUnsafeMutableBytes { src in
            unsigned.withUnsafeMutableBytes { dst in
                CaptureRaster.convertFloatSamples(src.baseAddress!, width: 5, height: 1, slope: 1,
                                                  encoding: .init(minimumOfSeries: -1024), into: dst.baseAddress!)
            }
        }
        #expect(unsigned == [0, 24, 1024, 3024, 65535])

        var signed = [Int16](repeating: 0, count: 5)
        samples = [-3000, -2, 0, 1.6, 80000]
        samples.withUnsafeMutableBytes { src in
            signed.withUnsafeMutableBytes { dst in
                CaptureRaster.convertFloatSamples(src.baseAddress!, width: 5, height: 1, slope: 2,
                                                  encoding: .init(minimumOfSeries: -3000), into: dst.baseAddress!)
            }
        }
        // vImage divides by the scale it is given.
        #expect(signed == [-1500, -1, 0, 1, 32767])
    }

    @Test func screenFrameRowsBecomeRGBWithClearOutside() {
        // 2 × 2 BGRA frame: (b, g, r, a) = (1, 2, 3, 0), (4, 5, 6, 0), ...
        let frame: [UInt8] = [1, 2, 3, 0, 4, 5, 6, 0, 7, 8, 9, 0, 10, 11, 12, 0]
        var out = [UInt8](repeating: 0, count: 2 * 2 * 3)
        frame.withUnsafeBytes { bytes in
            CaptureRaster.rgbFromBGRAFrame(bytes, frameWidth: 2, frameHeight: 2, originX: 1, originY: 0,
                                           width: 2, height: 2, clear: 255, into: &out)
        }
        #expect(out == [6, 5, 4, 255, 255, 255, 12, 11, 10, 255, 255, 255])

        CaptureRaster.rgbFromBGRAFrame(nil, frameWidth: 2, frameHeight: 2, originX: 0, originY: 0,
                                       width: 2, height: 2, clear: 0, into: &out)
        #expect(out.allSatisfy { $0 == 0 })
    }

    @Test func argbBecomesRGB() {
        let argb: [UInt8] = [255, 1, 2, 3, 0, 4, 5, 6]
        var rgb = [UInt8](repeating: 0, count: 6)
        CaptureRaster.rgbFromARGB(argb, pixelCount: 2, into: &rgb)
        #expect(rgb == [1, 2, 3, 4, 5, 6])
    }

    @Test func squarePixelsAndThumbnailsKeepTheFormerSizes() {
        #expect(CaptureRaster.squarePixelHeight(height: 72, spacingX: 1.0, spacingY: 0.5) == 36)
        #expect(CaptureRaster.squarePixelHeight(height: 7, spacingX: 3, spacingY: 1) == 2)
        #expect(CaptureRaster.centredSquare(width: 905, height: 841) == (32, 0, 841))
        #expect(CaptureRaster.centredSquare(width: 10, height: 15) == (0, 2, 10))
    }

    @Test func resamplingToTheSameSizeKeepsThePixels() {
        var rgb = (0..<(4 * 3 * 3)).map { UInt8($0 * 7 % 256) }
        var out = [UInt8](repeating: 0, count: rgb.count)
        rgb.withUnsafeMutableBytes { src in
            out.withUnsafeMutableBytes { dst in
                CaptureRaster.scaleRGB(src.baseAddress!, width: 4, height: 3, sourceRowBytes: 12,
                                       into: dst.baseAddress!, destinationWidth: 4, destinationHeight: 3)
            }
        }
        #expect(out == rgb)

        var gray: [UInt8] = [0, 0, 255, 255]
        var half = [UInt8](repeating: 9, count: 2)
        gray.withUnsafeMutableBytes { src in
            half.withUnsafeMutableBytes { dst in
                CaptureRaster.scalePlanar8(src.baseAddress!, width: 1, height: 4,
                                           into: dst.baseAddress!, destinationWidth: 1, destinationHeight: 2)
            }
        }
        #expect(half[0] < 64 && half[1] > 192)
    }

    @Test func tilesGoToTheirCellOfTheGrid() {
        var grid = [UInt16](repeating: 0, count: 2 * 2 * 2)
        let a: [UInt16] = [1, 2, 3, 4], b: [UInt16] = [5, 6, 7, 8]
        grid.withUnsafeMutableBytes { g in
            a.withUnsafeBytes { CaptureRaster.copyTile($0.baseAddress!, into: g.baseAddress!, column: 0, row: 0, gridWidth: 4,
                                                       width: 2, height: 2, samplesPerPixel: 1, bitsPerSample: 16) }
            b.withUnsafeBytes { CaptureRaster.copyTile($0.baseAddress!, into: g.baseAddress!, column: 1, row: 0, gridWidth: 4,
                                                       width: 2, height: 2, samplesPerPixel: 1, bitsPerSample: 16) }
        }
        #expect(grid == [1, 2, 5, 6, 3, 4, 7, 8])
    }

    @Test func viewersAreGatheredWithoutGaps() {
        let rects = [NSRect(x: 0, y: 0, width: 100, height: 50), NSRect(x: 130, y: 10, width: 40, height: 40)]
        let arranged = CaptureRaster.arrangeViewRects(rects)
        // The first steps one pixel past the left edge; the second comes left
        // until it overlaps the first, then steps back out of it.
        #expect(arranged.rects[0].origin.x == -1)
        #expect(arranged.rects[1].origin.x == 100)
        #expect(arranged.rects[0].origin.y == 1 && arranged.rects[1].origin.y == 11)
        #expect(arranged.union.width == 141)
        #expect(CaptureRaster.paddedWidth(arranged.union.width) == 144)
        #expect(CaptureRaster.paddedWidth(140.9) == 140)
        #expect(CaptureRaster.arrangeViewRects([]).rects.isEmpty)
    }

    @Test func aViewIsPlacedRowsFromTheTopAndKeptInsideTheBuffer() {
        var canvas = [UInt8](repeating: 0, count: 4 * 3)
        let view: [UInt8] = [1, 2, 3, 4]
        let skipped = canvas.withUnsafeMutableBytes { c in
            view.withUnsafeBytes { v in
                CaptureRaster.placeView(v.baseAddress!, width: 2, height: 2, samplesPerPixel: 1,
                                        bounds: NSRect(x: 1, y: 0, width: 2, height: 2), into: c.baseAddress!,
                                        canvasWidth: 4, canvasHeight: 3, canvasSamplesPerPixel: 1,
                                        bitsPerSample: 8, canvasSize: c.count)
            }
        }
        // Bottom-aligned: y = 0 is the bottom, rows are from the top.
        #expect(skipped == 0)
        #expect(canvas == [0, 0, 0, 0, 0, 1, 2, 0, 0, 3, 4, 0])

        // A row that would end exactly at the end of the buffer is refused,
        // as the former bound check did.
        let refused = canvas.withUnsafeMutableBytes { c in
            view.withUnsafeBytes { v in
                CaptureRaster.placeView(v.baseAddress!, width: 2, height: 2, samplesPerPixel: 1,
                                        bounds: NSRect(x: 2, y: 0, width: 2, height: 2), into: c.baseAddress!,
                                        canvasWidth: 4, canvasHeight: 3, canvasSamplesPerPixel: 1,
                                        bitsPerSample: 8, canvasSize: c.count)
            }
        }
        #expect(refused == 1)
    }

    @Test func smartCropKeepsTheUsefulPartOfAtLeast256Pixels() {
        let centred = CaptureRaster.smartCrop(usefulSize: NSSize(width: 100, height: 300), origin: .zero,
                                              frameSize: NSSize(width: 800, height: 600))
        #expect(centred.rect == NSRect(x: 272, y: 150, width: 256, height: 300))
        #expect(centred.shift == .zero && !centred.cut)

        let cut = CaptureRaster.smartCrop(usefulSize: NSSize(width: 400, height: 400), origin: NSPoint(x: 300, y: 0),
                                          frameSize: NSSize(width: 800, height: 600))
        #expect(cut.rect == NSRect(x: 500, y: 100, width: 300, height: 400))
        #expect(cut.shift == NSPoint(x: 50, y: 0) && cut.cut)

        let fractional = CaptureRaster.smartCrop(usefulSize: NSSize(width: 300.6, height: 300.6), origin: .zero,
                                                 frameSize: NSSize(width: 500, height: 500))
        #expect(fractional.rect == NSRect(x: 99, y: 99, width: 300, height: 300))
    }
}
