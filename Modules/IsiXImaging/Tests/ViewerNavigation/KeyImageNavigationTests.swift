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

@Suite struct KeyImageNavigationTests {
    /// Images 2 and 5 of 8 are key images.
    private static let keys: Set<Int> = [2, 5]
    private static func isKey(_ index: Int) -> Bool { keys.contains(index) }

    @Test func controlsFollowThePostProcessingAndTheImageShown() {
        #expect(KeyImageNavigation.controls(postprocessed: true, current: 2, isKey: Self.isKey) == .init(isEnabled: false, isChecked: nil))
        #expect(KeyImageNavigation.controls(postprocessed: false, current: 2, isKey: Self.isKey) == .init(isEnabled: true, isChecked: true))
        #expect(KeyImageNavigation.controls(postprocessed: false, current: 3, isKey: Self.isKey) == .init(isEnabled: true, isChecked: false))
        // No image shown: the box is cleared without asking.
        var asked = false
        #expect(KeyImageNavigation.controls(postprocessed: false, current: -1) { _ in asked = true; return true }.isChecked == false)
        #expect(!asked)
        #expect(KeyImageNavigation.toggled(isChecked: false))
        #expect(!KeyImageNavigation.toggled(isChecked: true))
    }

    @Test func nextAndPreviousInTheSeriesShown() {
        #expect(KeyImageNavigation.nextInSeries(from: 0, count: 8, isPrevious: false, flipped: false, isKey: Self.isKey) == 2)
        #expect(KeyImageNavigation.nextInSeries(from: 2, count: 8, isPrevious: false, flipped: false, isKey: Self.isKey) == 5)
        #expect(KeyImageNavigation.nextInSeries(from: 5, count: 8, isPrevious: false, flipped: false, isKey: Self.isKey) == nil)
        #expect(KeyImageNavigation.nextInSeries(from: 7, count: 8, isPrevious: true, flipped: false, isKey: Self.isKey) == 5)
        #expect(KeyImageNavigation.nextInSeries(from: 2, count: 8, isPrevious: true, flipped: false, isKey: Self.isKey) == nil)
        // A flipped series runs the other way.
        #expect(KeyImageNavigation.nextInSeries(from: 7, count: 8, isPrevious: false, flipped: true, isKey: Self.isKey) == 5)
        #expect(KeyImageNavigation.nextInSeries(from: 0, count: 8, isPrevious: true, flipped: true, isKey: Self.isKey) == 2)
        // The image shown itself is never the answer.
        #expect(KeyImageNavigation.nextInSeries(from: 2, count: 3, isPrevious: false, flipped: false, isKey: Self.isKey) == nil)
    }

    @Test func otherSeriesAreSearchedInOrder() {
        #expect(KeyImageNavigation.seriesToSearch(from: 1, count: 4, nextSeries: true) == [2, 3])
        #expect(KeyImageNavigation.seriesToSearch(from: 2, count: 4, nextSeries: false) == [1, 0])
        #expect(KeyImageNavigation.seriesToSearch(from: 3, count: 4, nextSeries: true) == [])
        #expect(KeyImageNavigation.seriesToSearch(from: 0, count: 4, nextSeries: false) == [])
        #expect(KeyImageNavigation.seriesToSearch(from: nil, count: 4, nextSeries: true) == [])
    }

    @Test func landingInTheSeriesMovedTo() {
        // Next from an unflipped viewer: the first key image from the start.
        #expect(KeyImageNavigation.landing(count: 8, nextSeries: true, flipped: false, isKey: Self.isKey) == 2)
        // Previous: from the end, backwards.
        #expect(KeyImageNavigation.landing(count: 8, nextSeries: false, flipped: false, isKey: Self.isKey) == 5)
        #expect(KeyImageNavigation.landing(count: 8, nextSeries: true, flipped: true, isKey: Self.isKey) == 5)
        #expect(KeyImageNavigation.landing(count: 0, nextSeries: true, flipped: false, isKey: Self.isKey) == nil)
        #expect(KeyImageNavigation.landing(count: 0, nextSeries: false, flipped: false, isKey: Self.isKey) == nil)
    }

    @Test func theKeyImagesOfAFrame() {
        #expect(KeyImageNavigation.keyImages(count: 8, isKey: { $0 == 2 || $0 == 5 }) == IndexSet([2, 5]))
        #expect(KeyImageNavigation.keyImages(count: 0, isKey: { _ in true }).isEmpty)
        #expect(KeyImageNavigation.keyImages(count: -3, isKey: { _ in true }).isEmpty)
    }

    /// A mark in the middle of each key image's place on the strip, which
    /// counts the images as the user does.
    @Test func stripMarksStandInTheMiddleOfEachKeyImage() {
        let marks = KeyImageNavigation.stripMarks(of: IndexSet([0, 10, 99]), count: 100, flipped: false, from: 1, width: 400)
        #expect(marks == [3, 43, 399])
        // Flipped data: the view's first image is the strip's last.
        let flipped = KeyImageNavigation.stripMarks(of: IndexSet([0, 10, 99]), count: 100, flipped: true, from: 1, width: 400)
        #expect(flipped == [3, 359, 399])
        // The strip's marker for the image shown, slab or not, is centred on the same place.
        #expect(KeyImageNavigation.stripMarks(of: IndexSet([4]), count: 9, flipped: false, from: 0, width: 90) == [45])
        #expect(KeyImageNavigation.stripMarks(of: IndexSet([4]), count: 9, flipped: true, from: 0, width: 90) == [45])
        #expect(KeyImageNavigation.stripMarks(of: IndexSet([0]), count: 1, flipped: false, from: 10, width: 60) == [40])
    }

    @Test func stripMarksLeaveOutWhatCannotBeDrawn() {
        // Images outside the series, an empty series, a strip without width.
        #expect(KeyImageNavigation.stripMarks(of: IndexSet([3, 12]), count: 10, flipped: false, from: 0, width: 100) == [35])
        #expect(KeyImageNavigation.stripMarks(of: IndexSet([3]), count: 0, flipped: false, from: 0, width: 100).isEmpty)
        #expect(KeyImageNavigation.stripMarks(of: IndexSet([3]), count: 10, flipped: false, from: 0, width: 0).isEmpty)
        #expect(KeyImageNavigation.stripMarks(of: IndexSet(), count: 10, flipped: false, from: 0, width: 100).isEmpty)
        // Every image marked in a series longer than the strip: marks a point apart, not one per image.
        let all = KeyImageNavigation.stripMarks(of: IndexSet(integersIn: 0..<2000), count: 2000, flipped: true, from: 0, width: 400)
        #expect(all.count == 400)
        #expect(zip(all, all.dropFirst()).allSatisfy { $1 - $0 >= 1 })
        let wide = KeyImageNavigation.stripMarks(of: IndexSet(integersIn: 0..<2000), count: 2000, flipped: false, from: 0, width: 400, spacing: 4)
        #expect(wide.count == 100)
    }
}
