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

@Suite struct ViewerMemoryTests {

    @Test func smallImagesCountAsTheMinimumSize() {
        var pixels: UInt64 = 0, padded: UInt64 = 0
        #expect(ViewerMemory.accumulate(width: 128, height: 128, frames: 1, minimumImageSize: true, pixels: &pixels, padded: &padded))
        #expect(pixels == 256 * 256 && padded == 257 * 257)
        #expect(!ViewerMemory.accumulate(width: 0, height: 128, frames: 1, minimumImageSize: false, pixels: &pixels, padded: &padded))
        #expect(!ViewerMemory.accumulate(width: 1 << 31, height: 1 << 31, frames: 1 << 40, minimumImageSize: false, pixels: &pixels, padded: &padded))
    }

    @Test func probesAndBlocks() {
        let sixMegabytes: UInt64 = 6 * 1024 * 1024
        let megabyte: UInt64 = 1024 * 1024
        let allMegabytes = UInt(UInt64.max / megabyte)
        #expect(ViewerMemory.probeBytes(pixels: 0) == sixMegabytes)
        #expect(ViewerMemory.probeBytes(pixels: UInt64.max / 2) == nil)
        #expect(ViewerMemory.requiredMegabytes(paddedPixels: megabyte) == 4)
        #expect(ViewerMemory.requiredMegabytes(paddedPixels: .max) == allMegabytes)
        #expect(ViewerMemory.loadBlock(pixels: 10, padded: 20, total: 5)! == (65536, 25))
        #expect(ViewerMemory.loadBlock(pixels: 10, padded: UInt64(UInt.max), total: 5) == nil)
    }

    @Test func planThinsUntilTheBlocksFit() {
        let image = MemoryImage(width: 512, height: 512, frames: 1, series: 1)
        let twoImages: UInt = 512 * 512 * 2
        var visits: [Int] = [], purges = 0
        let plan = ViewerMemory.plan(imageCounts: [8, 0, 3], image: { _, _ in image }, visit: { visits.append($0) },
                                     allocate: { $0 <= twoImages }, purge: { purges += 1 })
        guard case .success(let result) = plan else { Issue.record("no plan"); return }
        #expect(result.subSampling == 4)
        #expect(result.listIndices == [0, 2])
        #expect(result.imageIndices == [[0, 4], [0]])
        #expect(result.blocks == [twoImages, twoImages / 2])
        #expect(visits == [0, 2, 0, 2, 0, 2])
        #expect(purges == 3)
        let single = ViewerMemory.plan(imageCounts: [1], image: { _, _ in image }, visit: { _ in }, allocate: { _ in false }, purge: {})
        #expect(single == .failure(.notEnoughMemory))
        let unsafe = ViewerMemory.plan(imageCounts: [2], image: { _, _ in MemoryImage(width: -1, height: 2, frames: 1, series: 1) },
                                       visit: { _ in }, allocate: { _ in true }, purge: {})
        #expect(unsafe == .failure(.unsafeDimensions))
    }

    @Test func enoughMemoryHoldsEveryProbe() {
        let image = MemoryImage(width: 100, height: 100, frames: 1, series: 1)
        var probes: [UInt64] = []
        let result = ViewerMemory.enoughMemory(imageCounts: [2, 1], image: { _, _ in image }, allocate: { probes.append($0); return true })
        #expect(result.enough && probes.count == 2)
        let multiFrame = ViewerMemory.enoughMemory(imageCounts: [1], image: { _, _ in MemoryImage(width: 10, height: 10, frames: 0, series: 2) },
                                                   allocate: { _ in true })
        #expect(!multiFrame.enough)
    }
}

@Suite struct SeriesSplittingTests {

    @Test func repeatedPassesAreTimes() {
        let locations: [Float] = [0, 1, 2, 0, 1, 2, 0, 1, 2]
        #expect(SeriesSplitting.movieGroups(sliceLocations: locations) == [[0, 1, 2], [3, 4, 5], [6, 7, 8]])
        #expect(SeriesSplitting.reparseGroups(sliceLocations: locations, comments: Array(repeating: 0, count: 9))
                == [[0, 1, 2], [3, 4, 5], [6, 7, 8]])
        let interleaved: [Float] = [0, 0, 1, 1, 2, 2]
        #expect(SeriesSplitting.movieGroups(sliceLocations: interleaved) == [[0, 2, 4], [1, 3, 5]])
    }

    @Test func commentsCutWhatLocationsCannot() {
        #expect(SeriesSplitting.reparseGroups(sliceLocations: [5, 5, 5, 5], comments: [10, 20, 10, 20]) == [[0, 1], [2, 3]])
        #expect(SeriesSplitting.reparseGroups(sliceLocations: [5, 5, 5], comments: [0, 0, 0]) == [[0], [1], [2]])
        #expect(SeriesSplitting.reparseGroups(sliceLocations: [1], comments: [0]) == [[]])
    }

    @Test func fourDPlayerSelection() {
        #expect(MoviePlayerSelection.check(imageCounts: [4], maximum: 8) == .singleSeries)
        #expect(MoviePlayerSelection.check(imageCounts: Array(repeating: 2, count: 9), maximum: 8) == .tooManySeries)
        #expect(MoviePlayerSelection.check(imageCounts: [2, 3], maximum: 8) == .differentImageCounts)
        #expect(MoviePlayerSelection.check(imageCounts: [3, 3], maximum: 8) == .accepted)
        #expect(SeriesSplitting.isFourD(groupSizes: [3, 3]) && !SeriesSplitting.isFourD(groupSizes: [3, 2]))
    }

    @Test func subSeriesAndTiling() {
        #expect(SubSeriesSelection.indices(imageCount: 10, from: 2, to: 8, interval: 3) == [3, 6])
        #expect(SubSeriesSelection.indices(imageCount: 4, from: 5, to: 2, interval: 1) == [])
        #expect(SubSeriesSelection.indices(imageCount: 3, from: 0, to: 10, interval: 0) == [0, 1, 2])
        #expect(ViewerTiling.rowsAndColumns("23")! == (2, 3))
        #expect(ViewerTiling.rowsAndColumns("234") == nil && ViewerTiling.rowsAndColumns(nil) == nil)
    }
}
