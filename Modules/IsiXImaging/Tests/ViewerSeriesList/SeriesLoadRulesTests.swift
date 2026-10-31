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

@Suite struct SeriesLoadRulesTests {

    @Test func compressedSeriesLeaveOneProcessorAboveFour() {
        #expect(SeriesLoadRules.compressedDecoders(processors: 0) == 1)
        #expect(SeriesLoadRules.compressedDecoders(processors: 1) == 1)
        #expect(SeriesLoadRules.compressedDecoders(processors: 4) == 4)
        #expect(SeriesLoadRules.compressedDecoders(processors: 5) == 4)
        #expect(SeriesLoadRules.compressedDecoders(processors: 12) == 11)
    }

    @Test func decodedShare() {
        #expect(SeriesLoadRules.decodedShare(decoded: 0, of: 0) == 1)
        #expect(SeriesLoadRules.decodedShare(decoded: 1, of: 4) == 0.25)
        #expect(SeriesLoadRules.decodedShare(decoded: 4, of: 4) == 1)
    }

    @Test func orientations() {
        let axial: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let coronal: [Float] = [1, 0, 0, 0, 0, -1, 0, 1, 0]
        #expect(SeriesLoadRules.compareOrientations(axial, axial) == (true, true))
        #expect(SeriesLoadRules.compareOrientations(axial, coronal) == (false, true))
        #expect(SeriesLoadRules.compareOrientations(axial, [Float](repeating: 0, count: 9)) == (false, false))
        #expect(SeriesLoadRules.compareOrientations([Float](repeating: 0, count: 9), [Float](repeating: 0, count: 9)) == (true, false))
    }

    @Test func nearestSliceStaysWithinTheSeries() {
        let ascending: [Float] = [0, 2, 4, 6, 8]
        #expect(SeriesLoadRules.nearestSlice(to: 5.1, sliceLocations: ascending) == 3)
        #expect(SeriesLoadRules.nearestSlice(to: 5, sliceLocations: ascending) == 2, "the first of equally near slices")
        #expect(SeriesLoadRules.nearestSlice(to: 8, sliceLocations: ascending) == 4)
        #expect(SeriesLoadRules.nearestSlice(to: 8.5, sliceLocations: ascending) == nil, "beyond the last slice")
        #expect(SeriesLoadRules.nearestSlice(to: -1, sliceLocations: ascending) == nil, "before the first slice")
        #expect(SeriesLoadRules.nearestSlice(to: 0.5, sliceLocations: ascending) == nil, "the first slice is where the viewer is anyway")
        #expect(SeriesLoadRules.nearestSlice(to: 6.9, sliceLocations: [8, 6, 4, 2, 0]) == 1, "a descending series")
        #expect(SeriesLoadRules.nearestSlice(to: 3, sliceLocations: []) == nil)
        #expect(SeriesLoadRules.flippedIndex(1, count: 5) == 3)
    }

    @Test func onlyKeyImages() {
        #expect(SeriesLoadRules.showsOnlyKeyImages(listed: [true, true], seriesCount: 5, postprocessed: false))
        #expect(!SeriesLoadRules.showsOnlyKeyImages(listed: [true, false], seriesCount: 5, postprocessed: false))
        #expect(!SeriesLoadRules.showsOnlyKeyImages(listed: [true, true], seriesCount: 2, postprocessed: false), "the whole series")
        #expect(!SeriesLoadRules.showsOnlyKeyImages(listed: [true, true], seriesCount: 5, postprocessed: true))
    }

    @Test func tablesASeriesOpensWith() {
        typealias Table = SeriesLoadRules.OpeningTable
        #expect(SeriesLoadRules.colourTable(modality: "PT", isRGB: false, nmAsPET: false, petMode: "B/W Inverse", petDefault: "PET") == Table.named("B/W Inverse"))
        #expect(SeriesLoadRules.colourTable(modality: "PT", isRGB: false, nmAsPET: false, petMode: "Colour", petDefault: "PET") == Table.named("PET"))
        #expect(SeriesLoadRules.colourTable(modality: "PT", isRGB: false, nmAsPET: false, petMode: nil, petDefault: nil) == Table.named(nil))
        #expect(SeriesLoadRules.colourTable(modality: "NM", isRGB: false, nmAsPET: false, petMode: "Colour", petDefault: "PET") == Table.plain)
        #expect(SeriesLoadRules.colourTable(modality: "NM", isRGB: false, nmAsPET: true, petMode: "Colour", petDefault: "PET") == Table.named("PET"))
        #expect(SeriesLoadRules.colourTable(modality: "PT", isRGB: true, nmAsPET: false, petMode: "Colour", petDefault: "PET") == Table.plain)
        #expect(SeriesLoadRules.colourTable(modality: nil, isRGB: false, nmAsPET: true, petMode: "Colour", petDefault: "PET") == Table.plain)

        #expect(SeriesLoadRules.opacityTable(modality: "PT", isRGB: false, nmAsPET: false, petOpacity: true, petDefault: "Logarithmic Table") == Table.named("Logarithmic Table"))
        #expect(SeriesLoadRules.opacityTable(modality: "PT", isRGB: false, nmAsPET: false, petOpacity: false, petDefault: "Logarithmic Table") == Table.plain)
        #expect(SeriesLoadRules.opacityTable(modality: "NM", isRGB: false, nmAsPET: true, petOpacity: true, petDefault: "Log") == Table.named("Log"))
        #expect(SeriesLoadRules.opacityTable(modality: "CT", isRGB: false, nmAsPET: true, petOpacity: true, petDefault: "Log") == Table.plain)

        #expect(SeriesLoadRules.opensTwelveBit(modality: "MG", isRGB: false, automatic: true, displayCanShow: { true }))
        #expect(!SeriesLoadRules.opensTwelveBit(modality: "MG", isRGB: false, automatic: true, displayCanShow: { false }))
        #expect(!SeriesLoadRules.opensTwelveBit(modality: "MG", isRGB: false, automatic: false, displayCanShow: { true }))
        #expect(!SeriesLoadRules.opensTwelveBit(modality: "CT", isRGB: false, automatic: true, displayCanShow: { true }))
        #expect(!SeriesLoadRules.opensTwelveBit(modality: "DX", isRGB: true, automatic: true, displayCanShow: { true }))
    }

    @Test func savedTilingIsTheLastViewerOfTheSeries() {
        let state: [Any] = [
            ["studyInstanceUID": "1.2", "seriesInstanceUID": "1.2.3", "rows": NSNumber(value: 2), "columns": NSNumber(value: 3)],
            "not a viewer",
            ["studyInstanceUID": "1.2", "seriesInstanceUID": "1.2.4", "rows": NSNumber(value: 4), "columns": NSNumber(value: 4)],
            ["studyInstanceUID": "1.2", "seriesInstanceUID": "1.2.3", "rows": "1", "columns": "2"],
        ]
        let found = SeriesLoadRules.savedTiling(in: state, studyUID: "1.2", seriesUID: "1.2.3")
        #expect(found?.rows == 1 && found?.columns == 2)
        #expect(SeriesLoadRules.savedTiling(in: state, studyUID: "1.2", seriesUID: "9") == nil)
        #expect(SeriesLoadRules.savedTiling(in: state, studyUID: nil, seriesUID: "1.2.3") == nil)
    }

    @Test func openingScreenAndResampling() {
        #expect(SeriesLoadRules.openingScreen(multipleScreens: 1, screenCount: 2) == 1)
        #expect(SeriesLoadRules.openingScreen(multipleScreens: 1, screenCount: 1) == 0)
        #expect(SeriesLoadRules.openingScreen(multipleScreens: 2, screenCount: 3) == 0)
        #expect(SeriesLoadRules.openingScreen(multipleScreens: 0, screenCount: 3) == 0)

        #expect(SeriesLoadRules.resampleRatio(width: 64, height: 128, smallerOrEqual: 128, destination: 256) == 0.25)
        #expect(SeriesLoadRules.resampleRatio(width: 128, height: 64, smallerOrEqual: 64, destination: 256) == 0.25)
        #expect(SeriesLoadRules.resampleRatio(width: 512, height: 512, smallerOrEqual: 256, destination: 512) == nil)
        #expect(SeriesLoadRules.resampleRatio(width: 0, height: 0, smallerOrEqual: 256, destination: 512) == nil)
    }
}
