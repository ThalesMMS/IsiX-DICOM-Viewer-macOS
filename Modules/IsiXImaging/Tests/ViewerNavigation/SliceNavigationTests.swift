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

@Suite struct SliceNavigationTests {

    @Test func movieIndexesWrapIntoTheFrames() {
        #expect(SliceNavigation.wrappedMovieIndex(2, count: 3) == 2)
        #expect(SliceNavigation.wrappedMovieIndex(3, count: 3) == 0)
        #expect(SliceNavigation.wrappedMovieIndex(-1, count: 3) == 2)
        #expect(SliceNavigation.wrappedMovieIndex(-7, count: 3) == 2)
        #expect(SliceNavigation.wrappedMovieIndex(Int.min, count: 3) == 0)
        #expect(SliceNavigation.wrappedMovieIndex(5, count: 0) == 0)

        var frames = SliceNavigation(movieIndex: 0, movieCount: 4)
        frames.showMovie(9)
        #expect(frames.movieIndex == 1)
        #expect(frames.nextMovieIndex == 2)
        frames.showMovie(3)
        #expect(frames.nextMovieIndex == 0)
        #expect(SliceNavigation(movieIndex: Int.max, movieCount: 4).nextMovieIndex == 0)
        #expect(SliceNavigation(movieIndex: 0, movieCount: 0).nextMovieIndex == 0)
    }

    @Test func framesAreAddedUpToTheCapacity() {
        #expect(SliceNavigation.canAddMovie(at: 0, capacity: 500))
        #expect(SliceNavigation.canAddMovie(at: 499, capacity: 500))
        #expect(!SliceNavigation.canAddMovie(at: 500, capacity: 500))
        #expect(!SliceNavigation.canAddMovie(at: -1, capacity: 500))
        #expect(!SliceNavigation.canAddMovie(at: 0, capacity: 0))
    }

    @Test func timePointKeysGoRoundTheFramesOfA4DSeries() {
        var frames = SliceNavigation(movieIndex: 0, movieCount: 3)
        let back = frames.stepTimePoint(-1)
        #expect(back && frames.movieIndex == 2)
        let forward = frames.stepTimePoint(1)
        #expect(forward && frames.movieIndex == 0)
        _ = frames.stepTimePoint(1)
        _ = frames.stepTimePoint(1)
        #expect(frames.movieIndex == 2)

        // One time point: nothing to go through, the key goes on.
        var still = SliceNavigation(movieIndex: 0, movieCount: 1)
        let moved = still.stepTimePoint(1)
        #expect(!moved && still.movieIndex == 0)
    }

    @Test func aTiledViewIsMovedAwayBeforeTheFrameChanges() {
        #expect(SliceNavigation.movieChangeImages(image: 2, count: 5, tiled: false) == [2])
        #expect(SliceNavigation.movieChangeImages(image: 2, count: 5, tiled: true) == [0, 2])
        #expect(SliceNavigation.movieChangeImages(image: 0, count: 5, tiled: true) == [4, 0])
    }

    @Test func aFileIsFoundInTheFirstFrameThatHasIt() {
        let frames = [["a", "b"], ["c", "b"]]
        let found = SliceNavigation.position(movieCount: 2, files: { frames[$0].count }, matches: { frames[$0][$1] == "b" })
        #expect(found?.movie == 0 && found?.image == 1)
        let later = SliceNavigation.position(movieCount: 3, files: { $0 < 2 ? frames[$0].count : nil }, matches: { frames[$0][$1] == "c" })
        #expect(later?.movie == 1 && later?.image == 0)
        #expect(SliceNavigation.position(movieCount: 2, files: { frames[$0].count }, matches: { _, _ in false }) == nil)
    }

    @Test func theUserCountsAFlippedSeriesFromItsEnd() {
        let stack = StackNavigation(current: 7)
        #expect(SliceNavigation.userIndex(of: stack, count: 10, flipped: false) == 7)
        #expect(SliceNavigation.userIndex(of: stack, count: 10, flipped: true) == 2)
        #expect(SliceNavigation.sliderValue(of: stack, count: 10, flipped: true) == 2)
        #expect(SliceNavigation.stackImage(forUserIndex: 2, count: 10, flipped: true) == 7)
        #expect(SliceNavigation.stackImage(forUserIndex: 12, count: 10, flipped: false) == 9)
        #expect(SliceNavigation.stackImage(forUserIndex: 0, count: 0, flipped: false) == -1)
        #expect(SliceNavigation.slabImageCount(stack: 0) == 1)
        #expect(SliceNavigation.slabImageCount(stack: 3) == 3)
    }

    @Test func browsingStepsFromTheStack() {
        let step = SliceNavigation.browseStep(from: StackNavigation(current: 4), direction: 1, flipped: false, count: 5, loops: false)
        #expect(step.image == 3 && step.direction == -1)
        let loop = SliceNavigation.browseStep(from: StackNavigation(current: 0), direction: 1, flipped: true, count: 5, loops: true)
        #expect(loop.image == 4 && loop.direction == 1)
        #expect(SliceNavigation.edgeImage(movingBy: -1, count: 10, flipped: false) == 9)
    }
}
