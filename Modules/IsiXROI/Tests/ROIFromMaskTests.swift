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
import IsiXROI

/// The brushes made from a mask of labels and the picture of a layer.
struct ROIFromMaskTests {

    @Test func theLabelsAreTheValuesOtherThanZeroInTheOrderTheyComeFirst() {
        let mask: [UInt8] = [0, 3, 3, 0,
                             7, 0, 3, 1,
                             0, 7, 0, 0]
        let labels = mask.withUnsafeBufferPointer { ROIFromMask.labels(in: $0) }
        #expect(labels == [3, 7, 1])
        #expect([UInt8](repeating: 0, count: 6).withUnsafeBufferPointer { ROIFromMask.labels(in: $0) }.isEmpty)
    }

    @Test func aRegionIsTheBoxOfItsLabelWithItsBrushMask() throws {
        let mask: [UInt8] = [0, 0, 0, 0, 0,
                             0, 5, 0, 2, 0,
                             0, 5, 5, 0, 0,
                             0, 0, 5, 0, 0]
        let region = try #require(mask.withUnsafeBufferPointer { ROIFromMask.region(of: 5, in: $0, width: 5, height: 4) })
        #expect((region.x, region.y, region.width, region.height) == (1, 1, 2, 3))
        #expect(region.texture == [0xFF, 0,
                                   0xFF, 0xFF,
                                   0, 0xFF])
        let single = try #require(mask.withUnsafeBufferPointer { ROIFromMask.region(of: 2, in: $0, width: 5, height: 4) })
        #expect((single.x, single.y, single.width, single.height) == (3, 1, 1, 1))
        #expect(single.texture == [0xFF])
        #expect(mask.withUnsafeBufferPointer { ROIFromMask.region(of: 9, in: $0, width: 5, height: 4) } == nil)
        #expect(mask.withUnsafeBufferPointer { ROIFromMask.region(of: 5, in: $0, width: 0, height: 0) } == nil)
    }

    @Test func anEmptyNameIsTheAreaOfTheLabel() {
        #expect(ROIFromMask.name("", label: 12) == "area 12")
        #expect(ROIFromMask.name("Liver", label: 12) == "Liver")
        #expect(ROIFromMask.name(nil, label: 12) == nil)
    }

    @Test func theRegionsTakeTheSixColoursInTurn() {
        #expect(ROIFromMask.palette.count == 6)
        #expect(ROIFromMask.colour(ofRegion: 0) == ROIFromMask.Colour(red: 61423, green: 61423, blue: 37))
        #expect(ROIFromMask.colour(ofRegion: 1) == ROIFromMask.Colour(red: 61423, green: 2570, blue: 61423))
        #expect(ROIFromMask.colour(ofRegion: 5) == ROIFromMask.Colour(red: 0, green: 61937, blue: 56540))
        #expect(ROIFromMask.colour(ofRegion: 8) == ROIFromMask.colour(ofRegion: 2))
    }

    @Test func aLayerTakesItsBoundsFromTheFinitePoints() throws {
        var nanFirst: [Float] = [.nan, .nan, 2, 3, 5, 7, .infinity, 1]
        let layer = try #require(ROIFromMask.Layer(locations: &nanFirst, count: 4))
        #expect((layer.minX, layer.minY, layer.maxX, layer.maxY) == (2, 3, 5, 7))
        #expect((layer.width, layer.height) == (4, 5))
        var allNaN: [Float] = [.nan, 1, 2, .nan]
        #expect(ROIFromMask.Layer(locations: &allNaN, count: 2) == nil)
        var none: [Float] = []
        #expect(ROIFromMask.Layer(locations: &none, count: 0) == nil)
    }

    @Test func aLayerDrawsItsValuesThroughTheWindowOpaque() throws {
        var locations: [Float] = [0, 0, 1, 0, 0, 1, 1, 1, .nan, 0]
        var values: [Float] = [-1000, 1000, 50, 0, 7]
        let layer = try #require(ROIFromMask.Layer(locations: &locations, count: 5))
        var pixels = [UInt8](repeating: 0, count: Int(layer.width * layer.height * 4))
        pixels.withUnsafeMutableBufferPointer { pixels in
            layer.draw(values: &values, locations: &locations, count: 5, windowLevel: 50, windowWidth: 100, isRGB: false,
                       into: pixels.baseAddress!, bytesPerRow: layer.width * 4)
        }
        // Below the window black, above it white, the level grey, all opaque.
        #expect(Array(pixels[0..<4]) == [0, 0, 0, 255])
        #expect(Array(pixels[4..<8]) == [255, 255, 255, 255])
        #expect(Array(pixels[8..<12]) == [127, 127, 127, 255])
        #expect(Array(pixels[12..<16]) == [0, 0, 0, 255])
        var colour = [UInt8](repeating: 0, count: 16)
        var rgb: [Float] = [300, 0, 0, 0]
        colour.withUnsafeMutableBufferPointer { colour in
            layer.draw(values: &rgb, locations: &locations, count: 1, windowLevel: 0, windowWidth: 1, isRGB: true,
                       into: colour.baseAddress!, bytesPerRow: 8)
        }
        // A colour value keeps its low byte.
        #expect(Array(colour[0..<4]) == [44, 44, 44, 255])
    }
}
