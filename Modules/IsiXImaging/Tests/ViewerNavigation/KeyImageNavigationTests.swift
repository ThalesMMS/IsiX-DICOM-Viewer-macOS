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
}
