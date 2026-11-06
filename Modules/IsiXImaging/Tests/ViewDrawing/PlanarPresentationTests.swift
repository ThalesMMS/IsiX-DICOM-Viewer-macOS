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
import Testing
@testable import IsiXImaging

@Suite struct PlanarPresentationTests {

    @Test func refusesWhatTheHostCannotDraw() {
        #expect(PlanarPresentation.drawsStackMode(0) && PlanarPresentation.drawsStackMode(5))
        #expect(!PlanarPresentation.drawsStackMode(-1) && !PlanarPresentation.drawsStackMode(6))
        #expect(PlanarPresentation.accepts(width: 65535, height: 1, planeBytes: 65535 * 4))
        #expect(!PlanarPresentation.accepts(width: 65536, height: 1, planeBytes: 65536 * 4))
        #expect(!PlanarPresentation.accepts(width: 0, height: 10, planeBytes: 0))
        #expect(!PlanarPresentation.accepts(width: 30000, height: 30000, planeBytes: 30000 * 30000 * 4))
        #expect(PlanarPresentation.drawsEightBitRepresentation(width: 16384, height: 2))
        #expect(!PlanarPresentation.drawsEightBitRepresentation(width: 16383, height: 16383))
    }

    @Test func choosesWhatAFrameIsDrawnFrom() {
        typealias Source = PlanarPresentation.Source
        let plain = Source(stackMode: 0, stack: 1, seriesCount: 10, isRGB: false, packed: false, subtracted: false,
                           shutter: false, eightBit: false)
        #expect(plain.drawsOwnSamples && plain.takesDisplayPlane && !plain.hostBytes && !plain.isColour)
        let shutter = Source(stackMode: 0, stack: 1, seriesCount: 10, isRGB: false, packed: false, subtracted: false,
                             shutter: true, eightBit: false)
        #expect(shutter.hostBytes && !shutter.drawsOwnSamples && shutter.takesDisplayPlane && !shutter.isColour)
        let colour = Source(stackMode: 4, stack: 3, seriesCount: 10, isRGB: true, packed: false, subtracted: false,
                            shutter: false, eightBit: false)
        #expect(colour.hostBytes && colour.isColour && !colour.volumeSlab && !colour.scalarSlab)
        let volume = Source(stackMode: 5, stack: 1, seriesCount: 10, isRGB: false, packed: false, subtracted: true,
                            shutter: false, eightBit: false)
        #expect(volume.volumeSlab && !volume.hostBytes && volume.isColour && volume.bytesCarryAlpha(packed: false))
        let mip = Source(stackMode: 2, stack: 4, seriesCount: 10, isRGB: false, packed: false, subtracted: false,
                         shutter: false, eightBit: false)
        #expect(mip.scalarSlab && mip.stackReduced && !mip.takesDisplayPlane && !mip.drawsOwnSamples)
        let large = Source(stackMode: 2, stack: 4, seriesCount: 10, isRGB: false, packed: false, subtracted: false,
                           shutter: false, eightBit: true)
        #expect(!large.scalarSlab && large.hostBytes)
        let single = Source(stackMode: 5, stack: 3, seriesCount: 1, isRGB: false, packed: false, subtracted: false,
                            shutter: false, eightBit: false)
        #expect(!single.volumeSlab && !single.scalarSlab)
    }

    @Test func windowsAndScales() {
        let own = PlanarPresentation.window(level: 40, width: 400, fixed: false, inverted: false)
        #expect(own.level == 40 && own.width == 400)
        let fixed = PlanarPresentation.window(level: 40, width: 400, fixed: true, inverted: true)
        #expect(fixed.level == 127 && fixed.width == -256)
        #expect(PlanarPresentation.softwareScale(interpolates: true, width: 256) == 3)
        #expect(PlanarPresentation.softwareScale(interpolates: true, width: 257) == 2)
        #expect(PlanarPresentation.softwareScale(interpolates: false, width: 100) == 1)
        #expect(PlanarPresentation.drawsFusion(hasFusedSeries: true, locationsInSync: true, isKeyView: false, is2DViewer: false))
        #expect(!PlanarPresentation.drawsFusion(hasFusedSeries: true, locationsInSync: true, isKeyView: false, is2DViewer: true))
        #expect(!PlanarPresentation.drawsFusion(hasFusedSeries: true, locationsInSync: false, isKeyView: true, is2DViewer: true))
        #expect(PlanarPresentation.whitensImageUnderFusion(hasFusedSeries: true, locationsInSync: true, whiteBackground: true))
    }

    @Test func tablesTheColoursAsTheHostDid() {
        let ramp = (0..<256).map { UInt8($0) }
        let reversed = Array(ramp.reversed())
        ramp.withUnsafeBufferPointer { up in
            reversed.withUnsafeBufferPointer { down in
                let scalar = PlanarPresentation.scalarTable(red: up.baseAddress!, green: down.baseAddress!, blue: up.baseAddress!,
                                                            alpha: nil, redFactor: 2, greenFactor: 1, blueFactor: -1)
                #expect(scalar[4 * 200] == 255 && scalar[4 * 100] == 200 && scalar[4 * 10 + 1] == 245)
                #expect(scalar[4 * 10 + 2] == 0 && scalar[4 * 10 + 3] == 255)
                let fused = PlanarPresentation.scalarTable(red: up.baseAddress!, green: up.baseAddress!, blue: up.baseAddress!,
                                                           alpha: down.baseAddress!, redFactor: 1, greenFactor: 1, blueFactor: 1)
                #expect(fused[4 * 3 + 3] == 252)
                // Unclamped, as C stores a float in a byte: 200 × 1.5 = 300 keeps its low byte.
                let colour = PlanarPresentation.colourTable(red: up.baseAddress!, green: up.baseAddress!, blue: up.baseAddress!,
                                                            alpha: nil, redFactor: 1.5, greenFactor: -1, blueFactor: 1)
                #expect(colour[200] == 255 && colour[256 + 200] == UInt8(300 & 0xFF) && colour[512 + 7] == 249 && colour[768 + 9] == 9)
                let plain = PlanarPresentation.colourTable(red: up.baseAddress!, green: down.baseAddress!, blue: up.baseAddress!,
                                                           alpha: down.baseAddress!, redFactor: 1, greenFactor: 1, blueFactor: 1)
                #expect(plain[0] == 255 && plain[256 + 4] == 4 && plain[512 + 4] == 251)
            }
        }
        #expect(PlanarPresentation.convertedByte(.nan) == 0 && PlanarPresentation.convertedByte(-3) == 253)
        #expect(PlanarPresentation.convertedByte(5e9) == 255 && PlanarPresentation.convertedByte(511.9) == 255)
        #expect(PlanarPresentation.convertedByte(-.infinity) == 0 && PlanarPresentation.convertedByte(-0.0) == 0)
    }

    @Test func mapsAFusedViewIntoTheImageView() {
        // No rotation, flip or pan, a scale of 1: the centre of the frame is
        // the centre of the image.
        let centre = PlanarPresentation.fusedImagePixel(backing: CGPoint(x: 100, y: 50), frame: CGSize(width: 200, height: 100),
                                                        xFlipped: false, yFlipped: false, scale: 1, rotation: 0, origin: .zero,
                                                        image: (width: 64, height: 32, pixelRatio: 1))
        #expect(centre == CGPoint(x: 32, y: 16))
        // Twice the scale halves the distance from the centre; a flip mirrors it.
        let flipped = PlanarPresentation.fusedImagePixel(backing: CGPoint(x: 140, y: 50), frame: CGSize(width: 200, height: 100),
                                                         xFlipped: true, yFlipped: false, scale: 2, rotation: 0, origin: .zero,
                                                         image: (width: 64, height: 32, pixelRatio: 1))
        #expect(flipped == CGPoint(x: 12, y: 16))
        // A pixel ratio stretches the rows.
        let ratio = PlanarPresentation.fusedImagePixel(backing: CGPoint(x: 100, y: 50), frame: CGSize(width: 200, height: 100),
                                                       xFlipped: false, yFlipped: false, scale: 1, rotation: 0, origin: .zero,
                                                       image: (width: 64, height: 32, pixelRatio: 2))
        #expect(ratio == CGPoint(x: 32, y: 16))
    }
}
