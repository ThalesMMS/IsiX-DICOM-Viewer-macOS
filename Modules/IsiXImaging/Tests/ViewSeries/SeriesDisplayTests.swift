//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Testing
@testable import IsiXImaging

// The expected values are those the Objective-C DCMView gave: -setIndex:,
// -setPixels:..., -writeCopySettingsInSeriesForPixels: and +findWLWWPreset:::.
@Suite struct SeriesDisplayTests {

    @Test func indexIsClampedToTheSeries() {
        #expect(SeriesDisplay.clampedIndex(3, count: 10) == 3)
        #expect(SeriesDisplay.clampedIndex(9, count: 10) == 9)
        #expect(SeriesDisplay.clampedIndex(10, count: 10) == 9)
        #expect(SeriesDisplay.clampedIndex(99, count: 10) == 9)
        #expect(SeriesDisplay.clampedIndex(0, count: 1) == 0)
        // A short compared with an NSUInteger is unsigned: a negative index is
        // past the end, and picks the last image.
        #expect(SeriesDisplay.clampedIndex(-1, count: 10) == 9)
        // The last index of an empty series is -1, then 0.
        #expect(SeriesDisplay.clampedIndex(0, count: 0) == 0)
        // Past the short's range, the index is kept whole.
        #expect(SeriesDisplay.clampedIndex(32_768, count: 32_769) == 32_768)
        #expect(SeriesDisplay.clampedIndex(40_000, count: 32_769) == 32_768)
        #expect(SeriesDisplay.clampedIndex(Int(Int16.max) + 1, count: 70_000) == 32_768)
        #expect(SeriesDisplay.clampedIndex(-1, count: 70_000) == 69_999)
    }

    @Test func aVolumeHasImagesAtSeveralLocations() {
        #expect(SeriesDisplay.isVolume(count: 0, firstSliceLocation: 0, lastSliceLocation: 0) == false)
        #expect(SeriesDisplay.isVolume(count: 1, firstSliceLocation: 0, lastSliceLocation: 5) == false)
        #expect(SeriesDisplay.isVolume(count: 2, firstSliceLocation: 1.5, lastSliceLocation: 1.5) == false)
        #expect(SeriesDisplay.isVolume(count: 20, firstSliceLocation: -10, lastSliceLocation: 30) == true)
    }

    @Test func ageReadsAsTheFormatPrintedIt() {
        #expect(SeriesDisplay.ageText(now: "56 y", atAcquisition: "56 y") == "56 y")
        #expect(SeriesDisplay.ageText(now: "57 y", atAcquisition: "56 y") == "57 y / 56 y")
        #expect(SeriesDisplay.ageText(now: nil, atAcquisition: "56 y") == "(null) / 56 y")
        #expect(SeriesDisplay.ageText(now: nil, atAcquisition: nil) == "(null) / (null)")
    }

    typealias P = SeriesSettingsPropagation
    let none = P.Stored(scale: false, rotationAngle: false, yFlipped: false, xFlipped: false, xOffset: false, yOffset: false)
    let all = P.Stored(scale: true, rotationAngle: true, yFlipped: true, xFlipped: true, xOffset: true, yOffset: true)

    @Test func propagationClearsEveryKey() {
        #expect(P.writes(propagate: true, onScreen: false, stored: all) == P.Key.all.map { P.Write.clear($0) })
        #expect(P.writes(propagate: true, onScreen: true, stored: none) == P.Key.all.map { P.Write.clear($0) })
    }

    @Test func theImageOnScreenKeepsWhatIsShown() {
        #expect(P.writes(propagate: false, onScreen: true, stored: all)
                == [.windowWidth, .windowLevel, .scale, .rotationAngle, .yFlipped, .xFlipped, .offsets])
    }

    @Test func anotherImageKeepsItsOwnAndTakesWhatItLacks() {
        #expect(P.writes(propagate: false, onScreen: false, stored: all) == [])
        #expect(P.writes(propagate: false, onScreen: false, stored: none) == [.scale, .rotationAngle, .yFlipped, .xFlipped, .offsets])
        var onlyX = all
        onlyX.yOffset = false
        // Both offsets are written when either is missing.
        #expect(P.writes(propagate: false, onScreen: false, stored: onlyX) == [.offsets])
    }

    @Test func presetNamesComeFirstThenTheImage() {
        let presets: [(name: String, level: Float, width: Float)] = [("Abdomen", 40, 350), ("Lung", -600, 1500)]
        #expect(WindowLevelPreset.match(level: -600, width: 1500, presets: presets, fullDynamic: nil, imageDefault: nil) == .named("Lung"))
        #expect(WindowLevelPreset.match(level: 40, width: 350, presets: presets, fullDynamic: (40, 350), imageDefault: nil) == .named("Abdomen"))
        #expect(WindowLevelPreset.match(level: 10, width: 20, presets: presets, fullDynamic: (10, 20), imageDefault: (10, 20)) == .fullDynamic)
        #expect(WindowLevelPreset.match(level: 5, width: 20, presets: presets, fullDynamic: (10, 20), imageDefault: (5, 20)) == .imageDefault)
        // Without an image, neither of its windows is compared.
        #expect(WindowLevelPreset.match(level: 10, width: 20, presets: presets, fullDynamic: nil, imageDefault: nil) == .other)
        #expect(WindowLevelPreset.match(level: 1, width: 2, presets: [], fullDynamic: (10, 20), imageDefault: (5, 20)) == .other)
    }
}
