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

// The rules of a viewer's capture, against the code the view ran before
// ViewCaptureRequest: each `former…` function below is that code, copied from
// the view's capture methods (-getRawPixels::::::, the -getRawPixelsWidth:…
// variants with the tiles and with several views, -getRawPixelsViewWidth:…,
// -exportNSImageCurrentImageWithSize:, -exportDCMCurrentImage:…, -nsimage:allViewers:)
// with the view's state turned into arguments. Values are compared exactly.

private let bools = [false, true]

/// The flags -getRawPixels::::::, the secondary captures and the copy passed.
private struct FormerFlags: Equatable {
    var screenCapture, force8bits, removeGraphical, squarePixels, allTiles, allowSmartCropping: Bool
}

private func flags(_ request: ViewCaptureRequest) -> FormerFlags {
    FormerFlags(screenCapture: request.screenCapture, force8bits: request.force8bits,
                removeGraphical: request.removeGraphical, squarePixels: request.squarePixels,
                allTiles: request.allTiles, allowSmartCropping: request.allowSmartCropping)
}

/// -getRawPixelsViewWidth:…: what spp and bpp a capture got, and what it allocated.
private func formerForm(screenCapture: Bool, force8bits: Bool, isRGB: Bool, blending: Bool, thickSlabVR: Bool,
                        stackMode: Int, width: Int, height: Int) -> (spp: Int, bpp: Int, bytes: Int) {
    if screenCapture {
        if force8bits || isRGB || blending {
            let spp = 3, bpp = 8
            return (spp, bpp, 10 + width * height * 4 * bpp / 8)
        }
        let spp = 1, bpp = 16
        return (spp, bpp, width * height * spp * bpp / 8)
    }
    var isRGB = isRGB
    var force8bits = force8bits
    if thickSlabVR {
        force8bits = true
        if stackMode == 4 || stackMode == 5 { isRGB = true }
    }
    if isRGB {
        return (3, 8, width * height * 3 * 8 / 8)
    } else if force8bits {
        return (1, 8, width * height * 1 * 8 / 8)
    }
    return (1, 16, width * height * 1 * 16 / 8)
}

/// The order -nsimage:allViewers: took the windows in, removing each from `cWindows`.
private func formerReadingOrder(_ frames: [NSRect]) -> [NSRect] {
    var cWindows = frames
    var viewers: [NSRect] = []
    for _ in 0..<cWindows.count {
        var index = 0
        var minY = Float(cWindows[0].origin.y)
        for x in 0..<cWindows.count where cWindows[x].origin.y > CGFloat(minY) {
            minY = Float(cWindows[x].origin.y)
            index = x
        }
        var minX = Float(cWindows[index].origin.x)
        for x in 0..<cWindows.count {
            let f = cWindows[x]
            if f.origin.x < CGFloat(minX) && f.origin.y >= CGFloat(minY) {
                minX = Float(f.origin.x)
                index = x
            }
        }
        viewers.append(cWindows.remove(at: index))
    }
    return viewers
}

/// The rectangle -nsimage:allViewers: gave a viewer's view.
private func formerCapturedRect(bounds: NSRect, screenOrigin: NSPoint, includeAllTiledViews: Bool,
                                columns: Int, rows: Int, scale: CGFloat) -> NSRect {
    var bounds = bounds
    if includeAllTiledViews {
        bounds.size.width *= CGFloat(columns)
        bounds.size.height *= CGFloat(rows)
    }
    bounds.origin = screenOrigin
    bounds = NSIntegralRect(bounds)
    bounds.origin.x *= scale
    bounds.origin.y *= scale
    bounds.size.width *= scale
    bounds.size.height *= scale
    return bounds
}

@Suite struct ViewCaptureRequestTests {

    @Test func theRequestsOfTheViewAreTheFlagsItPassed() {
        for screen in bools {
            for force8 in bools {
                for tiled in bools {
                    // -getRawPixels::::::
                    #expect(flags(.rawPixels(screenCapture: screen, force8bits: force8, includeAllTiledViews: tiled))
                            == FormerFlags(screenCapture: screen, force8bits: force8, removeGraphical: true,
                                           squarePixels: false, allTiles: tiled, allowSmartCropping: false))
                }
            }
        }
        // -exportNSImageCurrentImageWithSize: and -exportDCMCurrentImage:…, one view or several.
        #expect(flags(.secondaryCapture) == FormerFlags(screenCapture: true, force8bits: true, removeGraphical: true,
                                                        squarePixels: true, allTiles: false, allowSmartCropping: false))
        // -nsimage:allViewers:, every viewer or this one.
        for originalSize in bools {
            for tiled in bools {
                for crop in bools {
                    #expect(flags(.copy(originalSize: originalSize, allViewers: true, includeAllTiledViews: tiled,
                                        allowSmartCropping: crop))
                            == FormerFlags(screenCapture: true, force8bits: true, removeGraphical: false,
                                           squarePixels: true, allTiles: tiled, allowSmartCropping: false))
                    #expect(flags(.copy(originalSize: originalSize, allViewers: false, includeAllTiledViews: tiled,
                                        allowSmartCropping: crop))
                            == FormerFlags(screenCapture: !originalSize, force8bits: true, removeGraphical: false,
                                           squarePixels: true, allTiles: tiled, allowSmartCropping: crop))
                }
            }
        }
    }

    @Test func tilesAreAssembledOnlyInATiledTwoDViewer() {
        for allTiles in bools {
            for twoD in bools {
                for rows in 0...3 {
                    for columns in 0...3 {
                        let request = ViewCaptureRequest(screenCapture: true, force8bits: true, removeGraphical: true,
                                                         squarePixels: false, allTiles: allTiles, allowSmartCropping: true)
                        let former = allTiles && twoD && (rows != 1 || columns != 1)
                        #expect(request.capturesTiles(twoDViewer: twoD, rows: rows, columns: columns) == former)
                        #expect(ViewCaptureRequest.isTiled(twoDViewer: twoD, rows: rows, columns: columns)
                                == (twoD && (columns != 1 || rows != 1)))
                        #expect(request.forTile.allowSmartCropping == false)
                        #expect(request.forTile.allTiles == allTiles)
                    }
                }
            }
        }
    }

    @Test func theGridOfTilesHasTheFormerSizes() {
        for (columns, rows) in [(1, 2), (2, 1), (2, 2), (3, 4), (4, 4)] {
            let grid = ViewCaptureRequest.TileGrid(columns: columns, rows: rows)
            for (width, height, spp, bpp) in [(512, 512, 3, 8), (511, 300, 1, 16), (257, 1, 1, 8), (0, 0, 3, 8)] {
                let viewSize = bpp * spp * (width + 4) * (height + 4) / 8
                #expect(grid.byteCount(tileWidth: width, tileHeight: height, samplesPerPixel: spp, bitsPerSample: bpp)
                        == viewSize * columns * rows)
                let size = grid.size(tileWidth: width, tileHeight: height)
                #expect(size.width == width * columns && size.height == height * rows)
            }
            for x in 0..<columns {
                for y in 0..<rows { #expect(grid.index(column: x, row: y) == x + y * columns) }
            }
        }
    }

    @Test func smartCroppingNeedsTheRequestThePreferenceAndNoOrthogonalMPR() {
        for allow in bools {
            for mpr in bools {
                for preference in bools {
                    var allowSmartCropping = allow
                    if mpr { allowSmartCropping = false }
                    let former = allowSmartCropping && preference
                    let request = ViewCaptureRequest(screenCapture: true, force8bits: true, removeGraphical: false,
                                                     squarePixels: false, allTiles: false, allowSmartCropping: allow)
                    #expect(request.cropsSmartly(orthogonalMPR: mpr, screenCaptureSmartCropping: preference) == former)
                }
            }
        }
    }

    @Test func theFormOfTheSamplesIsTheFormerOne() {
        for screen in bools {
            for force8 in bools {
                for rgb in bools {
                    for blending in bools {
                        for thick in bools {
                            for stackMode in 0...6 {
                                let request = ViewCaptureRequest(screenCapture: screen, force8bits: force8,
                                                                 removeGraphical: true, squarePixels: true,
                                                                 allTiles: false, allowSmartCropping: false)
                                // A fusion only matters to the screen capture.
                                let form = request.form(isRGB: rgb, fused: blending && screen, thickSlabVR: thick,
                                                        stackMode: stackMode)
                                let former = formerForm(screenCapture: screen, force8bits: force8, isRGB: rgb,
                                                        blending: blending && screen, thickSlabVR: thick,
                                                        stackMode: stackMode, width: 301, height: 207)
                                #expect(form.samplesPerPixel == former.spp)
                                #expect(form.bitsPerSample == former.bpp)
                                #expect(form.byteCount(width: 301, height: 207) == former.bytes)
                                #expect((form == .screenColour || form == .screenGrey16) == screen)
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func onlyEightBitImagesInMemoryGetSquarePixels() {
        let spacings: [(Double, Double)] = [(0.5, 0.5), (0.5, 0.7), (0.7, 0.5), (0, 0), (1, 1.0000001)]
        for screen in bools {
            for square in bools {
                for bpp in [8, 16] {
                    for (x, y) in spacings {
                        let request = ViewCaptureRequest(screenCapture: screen, force8bits: false, removeGraphical: true,
                                                         squarePixels: square, allTiles: false, allowSmartCropping: false)
                        // Only the path of the image in memory resampled.
                        let former = !screen && (square && bpp == 8 && x != y)
                        #expect(request.squaresPixels(bitsPerSample: bpp, spacingX: x, spacingY: y) == former)
                    }
                }
            }
        }
    }

    @Test func theScreenCaptureGeometryIsTheFormerOne() {
        for (spacing, scale) in [(0.5, Float(1)), (0.7, Float(2.5)), (0.390625, Float(0.33)), (1, Float(3))] {
            #expect(ViewCaptureRequest.screenSpacing(pixelSpacingX: spacing, scale: scale) == Float(spacing / Double(scale)))
        }
        for (frame, origin, scale) in [(NSSize(width: 512, height: 400), NSPoint(x: 10, y: -7), Float(2)),
                                       (NSSize(width: 333, height: 777), NSPoint(x: -3.3, y: 0.1), Float(0.7))] {
            var s = scale
            var o = origin
            var destRectSize = frame
            destRectSize.width /= CGFloat(s)
            destRectSize.height /= CGFloat(s)
            o.x /= CGFloat(s)
            o.y /= CGFloat(s)
            s = 1
            let rendering = ViewCaptureRequest.fullResolution(frameSize: frame, origin: origin, scale: scale)
            #expect(rendering.size == destRectSize && rendering.origin == o && s == 1)
        }
        for modality in [nil, "PT", "CT", "NM", "pt"] {
            var slope: Float = 1
            if modality == "PT" { slope = 2.5 * 0.75 }
            #expect(ViewCaptureRequest.sampleSlope(modality: modality, suvFactor: 2.5, slope: 0.75) == slope)
        }
        for invert in bools {
            for id in [nil, "export", "copy", "other"] {
                let inverted = invert && id != "export"
                #expect(ViewCaptureRequest.readsInverted(invertColors: invert, stringID: id) == inverted)
                for whiteBackground in bools {
                    for showsImage in bools {
                        let white = whiteBackground && showsImage
                        let clear: UInt8 = white != inverted ? 255 : 0
                        #expect(ViewCaptureRequest.clearValue(whiteBackground: whiteBackground, showsImage: showsImage,
                                                              inverted: inverted) == clear)
                    }
                }
            }
        }
    }

    @Test func thumbnailsAreMadeOfRGBCapturesOnly() {
        for size: Int32 in [0, 64, 256] {
            for spp in [1, 3] {
                let thumbnail = ViewCaptureRequest.thumbnail(size: size, samplesPerPixel: spp)
                if size == 0 {
                    #expect(thumbnail == .asCaptured)
                } else if spp != 3 {
                    #expect(thumbnail == .notResized)
                } else {
                    #expect(thumbnail == .square(side: Int(size)))
                }
            }
        }
        for (width, height, size) in [(512, 400, Int32(128)), (300, 701, Int32(64)), (256, 256, Int32(256)), (513, 2, Int32(1))] {
            let side = width > height ? height : width
            let rescale = Float(size) / Float(width > height ? height : width)
            let croppedOrigin = NSPoint(x: Double(width - side) / 2.0, y: Double(height - side) / 2.0)
            let geometry = ViewCaptureRequest.thumbnailGeometry(width: width, height: height, size: size)
            #expect(geometry.rescale == rescale && geometry.origin == croppedOrigin)
        }
    }

    @Test func severalViewsAreAssembledAsBefore() {
        for views in 0...3 {
            for rects in 0...3 {
                #expect(ViewCaptureRequest.assemblesViews(viewCount: views, rectCount: rects) == (views > 1 && views == rects))
            }
        }
        for (width, height, spp, bpp) in [(1024, 512, 3, 8), (7, 9, 1, 16)] {
            #expect(ViewCaptureRequest.canvasByteCount(width: width, height: height, samplesPerPixel: spp, bitsPerSample: bpp)
                    == (4 + width) * (4 + height) * spp * bpp / 8)
        }
        let spacings: [[Float]] = [[0.5, 0.5], [0.504, 0.5], [0.506, 0.5], [0.5, 0.4951], [0, 0], [0.7, 0.3]]
        for imSpacing in spacings {
            for iimSpacing in spacings {
                let former = abs(Double(imSpacing[0] - iimSpacing[0])) > 0.005 || abs(Double(imSpacing[1] - iimSpacing[1])) > 0.005
                #expect(ViewCaptureRequest.spacingsDiffer((imSpacing[0], imSpacing[1]), (iimSpacing[0], iimSpacing[1])) == former)
            }
        }
    }

    @Test func windowsAreTakenFromTheTopLeftAsBefore() {
        var generator = SystemRandomNumberGenerator()
        let layouts: [[NSRect]] = [
            [],
            [NSRect(x: 0, y: 0, width: 100, height: 100)],
            [NSRect(x: 500, y: 400, width: 500, height: 400), NSRect(x: 0, y: 400, width: 500, height: 400),
             NSRect(x: 0, y: 0, width: 500, height: 400), NSRect(x: 500, y: 0, width: 500, height: 400)],
            [NSRect(x: 10, y: 10, width: 1, height: 1), NSRect(x: 10, y: 10, width: 1, height: 1),
             NSRect(x: 5, y: 10.25, width: 1, height: 1), NSRect(x: 5, y: 10.0000001, width: 1, height: 1)],
        ] + (0..<200).map { _ in
            (0..<Int.random(in: 2...6, using: &generator)).map { _ in
                NSRect(x: CGFloat(Int.random(in: -3...3, using: &generator) * 400),
                       y: CGFloat(Int.random(in: -2...2, using: &generator) * 300) + CGFloat(Double.random(in: 0..<1, using: &generator)),
                       width: 400, height: 300)
            }
        }
        for frames in layouts {
            let order = ViewCaptureRequest.readingOrder(of: frames)
            #expect(Set(order) == Set(frames.indices) && order.count == frames.count)
            #expect(order.map { frames[$0] } == formerReadingOrder(frames))
        }
    }

    @Test func eachViewerHasTheFormerRectangle() {
        let cases: [(NSRect, NSPoint, Int, Int, CGFloat)] = [
            (NSRect(x: 0, y: 0, width: 512.4, height: 400.6), NSPoint(x: 100.5, y: 33.2), 2, 3, 2),
            (NSRect(x: 4, y: 7, width: 300, height: 200), NSPoint(x: -10.7, y: 0), 1, 1, 1),
            (NSRect(x: 0, y: 0, width: 300.5, height: 200.5), NSPoint(x: 0.3, y: 0.7), 0, 0, 0),
        ]
        for (bounds, origin, columns, rows, scale) in cases {
            for all in bools {
                let rect = ViewCaptureRequest.capturedRect(
                    viewBounds: bounds, screenOrigin: origin,
                    tiles: all ? ViewCaptureRequest.TileGrid(columns: columns, rows: rows) : nil, backingScale: scale)
                #expect(rect == formerCapturedRect(bounds: bounds, screenOrigin: origin, includeAllTiledViews: all,
                                                   columns: columns, rows: rows, scale: scale))
            }
        }
    }

    @Test func secondaryCapturesWriteTheirSpacingAndOriginWhenAsked() {
        let values: [Float] = [0, 1, 2, -1, 0.5]
        for asked in bools {
            for s0 in values {
                for s1 in values {
                    for o0 in values {
                        let imSpacing = [s0, s1], imOrigin = [o0, 0, 0]
                        let former = asked && (imSpacing[0] != 0 || imSpacing[1] != 0 || imOrigin[0] != 0
                                               || imOrigin[0] != 1 || imOrigin[0] != 2)
                        #expect(ViewCaptureRequest.writesSpacingAndOrigin(asked: asked) == former)
                    }
                }
            }
        }
        for keep in bools {
            for current in [0, 1, 2] {
                let former = keep ? current : 1
                #expect(ViewCaptureRequest.secondaryCaptureBars(keepsCLUTBars: keep, current: current, hidden: 1) == former)
            }
        }
    }

    @Test func aCopyMarksItsViewsAndTakesEveryViewerAsBefore() {
        for id in [nil, "copy", "export"] {
            for originalSize in bools {
                #expect(ViewCaptureRequest.copyMarksViews(stringID: id, originalSize: originalSize) == (id == nil && !originalSize))
            }
        }
        for twoD in bools {
            for all in bools {
                for count in 0...3 {
                    #expect(ViewCaptureRequest.copiesAllViewers(twoDViewer: twoD, allViewers: all, viewerCount: count)
                            == (twoD && all && count > 1))
                }
            }
        }
    }
}
