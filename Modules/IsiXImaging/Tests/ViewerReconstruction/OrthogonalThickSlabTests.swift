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

struct OrthogonalThickSlabTests {
    @Test func theCrossingIsTheImageShownInsideTheSeries() {
        for image in 0..<60 { #expect(OrthogonalThickSlab.crossIndex(image: image, count: 60) == image) }
        #expect(OrthogonalThickSlab.crossIndex(image: 80, count: 60) == 59)
        #expect(OrthogonalThickSlab.crossIndex(image: -4, count: 60) == 0)
        #expect(OrthogonalThickSlab.crossIndex(image: 3, count: 0) == 0)
        // The image shown is one of the images its slab fuses, at the ends of the series too.
        for images in [2, 3, 20, 46, 128] {
            for image in 0..<60 {
                let slab = ThickSlabSpan(images: images, at: image, of: 60, towardsStart: false)
                #expect(slab.indices.contains(OrthogonalThickSlab.crossIndex(image: image, count: 60)))
                #expect(slab.count == min(images, 60))
            }
        }
    }

    @Test func aRowNamesAnImageByTheDirectionOfTheSeries() {
        for ascending in [true, false] {
            for index in 0..<60 {
                let row = OrthogonalThickSlab.row(index: index, count: 60, ascending: ascending)
                #expect(row == (ascending ? 59 - index : index))
                #expect(OrthogonalThickSlab.index(row: row, count: 60, ascending: ascending) == index)
            }
        }
    }

    /// The scale of the original view at image `current`, two images at least, and the rows of a reformatted view.
    private func scale(_ locations: [Double], at current: Int, thickness: Double) -> StackFusionScale {
        StackFusionScale(positions: locations, current: current, towardsStart: false, sliceThickness: thickness,
                         fallbackInterval: locations.count > 1 ? locations[1] - locations[0] : 0, capacity: locations.count, minimumImages: 2)
    }

    private func regular(_ count: Int, every interval: Double) -> [Double] { (0..<count).map { -Double($0) * interval } }

    @Test func theThreeViewsFuseOneThickness() {
        func check(_ scale: StackFusionScale, _ requested: Int, _ thickness: Double, rows: Int, spacing: Double, _ comment: Comment) {
            let fused = scale.thickness(requested: requested)
            #expect(abs(fused - thickness) < 1e-9, comment)
            let count = OrthogonalThickSlab.reslicedCount(thickness: fused, pixelSpacing: spacing)
            #expect(count == rows, comment)
            if count > 1 { #expect(abs(Double(count) * spacing - fused) <= spacing / 2 + 1e-9, comment) }
        }
        // 2 mm every 1 mm, pixels of 1 mm, the 41st of 80 images.
        let overlapping = scale(regular(80, every: 1), at: 40, thickness: 2)
        check(overlapping, 2, 3, rows: 3, spacing: 1, "2 images of 2 mm every 1 mm")
        check(overlapping, 10, 11, rows: 11, spacing: 1, "10 images of 2 mm every 1 mm")
        #expect(overlapping.minimum == 3 && overlapping.maximum == 81 && overlapping.available == 80)
        // 2 mm every 2 mm, the 31st of 60.
        let touching = scale(regular(60, every: 2), at: 30, thickness: 2)
        check(touching, 2, 4, rows: 4, spacing: 1, "2 images of 2 mm")
        check(touching, 20, 40, rows: 40, spacing: 1, "20 images of 2 mm")
        // A request for more images than follow the image shown is whole: the slab is pulled back inside the series.
        check(touching, 46, 92, rows: 92, spacing: 1, "46 asked for at the 31st of 60")
        #expect(touching.effectiveCount(requested: 46) == 46 && touching.maximum == 120)
        check(scale(regular(60, every: 2), at: 14, thickness: 2), 46, 92, rows: 92, spacing: 1, "46 images at the 15th")
        check(scale(regular(60, every: 2), at: 59, thickness: 2), 46, 92, rows: 92, spacing: 1, "46 images at the last")
        // 0.625 mm slices, pixels of 0.7 mm.
        let fine = scale(regular(160, every: 0.625), at: 80, thickness: 0.625)
        check(fine, 2, 1.25, rows: 2, spacing: 0.7, "2 images of 0.625 mm")
        check(fine, 16, 10, rows: 14, spacing: 0.7, "16 images of 0.625 mm")
        #expect(abs(fine.maximum - 100) < 1e-9)
        // Pixels that are not square: each axis its count.
        #expect(OrthogonalThickSlab.reslicedCount(thickness: 40, pixelSpacing: 1) == 40)
        #expect(OrthogonalThickSlab.reslicedCount(thickness: 40, pixelSpacing: 0.5) == 80)
        // No slice thickness: the distance to the next image stands for it.
        let unmeasured = scale(regular(60, every: 2), at: 30, thickness: 0)
        check(unmeasured, 20, 40, rows: 40, spacing: 1, "20 images that do not say their thickness")
        // Irregular intervals: the thicknesses there are around the image shown.
        let irregular = scale([0, 1, 2, 4, 5, 8], at: 1, thickness: 2)
        #expect((2...6).map { irregular.thickness(requested: $0) } == [3, 4, 6, 7, 10])
        // The last image has the slab of the images before it.
        let last = scale(regular(60, every: 2), at: 59, thickness: 2)
        #expect(last.available == 60 && last.floor == 2 && last.effectiveCount(requested: 20) == 20 && last.thickness(requested: 20) == 40)
    }

    @Test func noSpacingNoSlab() {
        for spacing in [0, -1, Double.nan, .infinity] { #expect(OrthogonalThickSlab.reslicedCount(thickness: 40, pixelSpacing: spacing) == 1) }
        for thickness in [0, -3, Double.nan, .infinity] { #expect(OrthogonalThickSlab.reslicedCount(thickness: thickness, pixelSpacing: 1) == 1) }
        #expect(OrthogonalThickSlab.reslicedCount(thickness: 0.3, pixelSpacing: 0.7) == 1)
        #expect(OrthogonalThickSlab.reslicedCount(thickness: 1e9, pixelSpacing: 0.001) == Int(Int16.max))
    }

    @Test func aTrackOfTwoImagesAtLeastHasItsMarksOnStops() {
        let track = scale(regular(60, every: 2), at: 30, thickness: 2)
        for exponential in [false, true] {
            #expect(track.count(at: 0, exponential: exponential) == 2)
            #expect(track.count(at: 1, exponential: exponential) == 60)
            #expect(track.position(ofCount: 2, exponential: exponential) == 0)
            #expect(track.position(ofCount: 1, exponential: exponential) == 0)
            // The marks are those of the series, from two images to all of them, and the knob goes to each.
            let marks = track.tickCounts(minimumSpacing: 0.05)
            #expect(marks.first == 2 && marks.last == 60)
            #expect(marks == marks.sorted() && Set(marks).count == marks.count)
            #expect(marks == scale(regular(60, every: 2), at: 0, thickness: 2).tickCounts(minimumSpacing: 0.05))
            let places = track.tickPlaces(minimumSpacing: 0.05, exponential: exponential)
            #expect(places.first == 0 && places.last == 1 && places == places.sorted())
            #expect(places == scale(regular(60, every: 2), at: 0, thickness: 2).tickPlaces(minimumSpacing: 0.05, exponential: exponential))
            for mark in marks {
                let place = track.trackPosition(ofStop: mark, exponential: exponential)
                #expect(track.count(at: place, exponential: exponential) == mark)
                #expect(track.position(ofCount: mark, exponential: exponential) == place)
            }
        }
        #expect(track.text(requested: 1, locale: Locale(identifier: "en_US")) == "4.0 mm")
        #expect(track.text(requested: 46, locale: Locale(identifier: "it_IT")) == "92,0 mm")
    }
}
