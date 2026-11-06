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
import IsiXImaging

/// The database preview's window and the moves of its slider.
struct PreviewWindowingTests {

    @Test func aWindowIsOnScreenOnlyWhenThePixelsAndTheViewBothHaveIt() {
        let shown = PreviewWindowing(pixels: WindowLevelState(level: 40, width: 400),
                                     view: WindowLevelState(level: 40, width: 400))
        #expect(shown.isShowing(level: 40, width: 400))
        #expect(!shown.isShowing(level: 40, width: 350))
        #expect(!shown.isShowing(level: 50, width: 400))

        // The pixels already have it, the view still draws the previous frame's.
        let stale = PreviewWindowing(pixels: WindowLevelState(level: 40, width: 400),
                                     view: WindowLevelState(level: 300, width: 1500))
        #expect(!stale.isShowing(level: 40, width: 400))
        let behind = PreviewWindowing(pixels: WindowLevelState(level: 300, width: 1500),
                                      view: WindowLevelState(level: 40, width: 400))
        #expect(!behind.isShowing(level: 40, width: 400))
    }

    @Test func aZeroOrNonFiniteWidthAsksForTheAutomaticWindow() {
        #expect(PreviewWindowing.isWindowOnScreen(level: 40, width: 400))
        #expect(PreviewWindowing.isWindowOnScreen(level: -1000, width: 0.5))
        #expect(!PreviewWindowing.isWindowOnScreen(level: 40, width: 0))
        #expect(!PreviewWindowing.isWindowOnScreen(level: 40, width: -10))
        #expect(!PreviewWindowing.isWindowOnScreen(level: 40, width: .infinity))
        #expect(!PreviewWindowing.isWindowOnScreen(level: 40, width: .nan))
        #expect(!PreviewWindowing.isWindowOnScreen(level: .nan, width: 400))
        #expect(!PreviewWindowing.isWindowOnScreen(level: -.infinity, width: 400))
    }

    @Test func theDefaultsOfASeriesComeFromItsMiddleImage() {
        var asked: [Int] = []
        let reference = PreviewWindowing.referenceFrame(imageCount: 9, fileFrames: 1, shownFrame: 0) { index in
            asked.append(index)
            return (false, 0)
        }
        #expect(asked == [4])
        #expect(reference == .seriesImage(4, of: 9, frame: 0))

        // Two images: the second is the middle one.
        #expect(PreviewWindowing.referenceFrame(imageCount: 2, fileFrames: 1, shownFrame: 0) { _ in (false, 3) }
                == .seriesImage(1, of: 2, frame: 3))
        // The middle image on screen at its frame is the frame shown.
        #expect(PreviewWindowing.referenceFrame(imageCount: 9, fileFrames: 1, shownFrame: 2) { _ in (true, 2) } == .shown)
        // The middle image on screen at another frame is read again.
        #expect(PreviewWindowing.referenceFrame(imageCount: 9, fileFrames: 1, shownFrame: 1) { _ in (true, 2) }
                == .seriesImage(4, of: 9, frame: 2))
        // No image: the frame shown.
        #expect(PreviewWindowing.referenceFrame(imageCount: 0, fileFrames: 0, shownFrame: 0) { _ in (false, 0) } == .shown)
    }

    @Test func aSingleFileUsesItsMiddleFrame() {
        var asked = false
        let reference = PreviewWindowing.referenceFrame(imageCount: 1, fileFrames: 30, shownFrame: 0) { _ in
            asked = true
            return (false, 0)
        }
        #expect(!asked)
        #expect(reference == .fileFrame(15, of: 30))
        #expect(PreviewWindowing.referenceFrame(imageCount: 1, fileFrames: 3, shownFrame: 0) { _ in (false, 0) } == .fileFrame(1, of: 3))
        #expect(PreviewWindowing.referenceFrame(imageCount: 1, fileFrames: 30, shownFrame: 15) { _ in (false, 0) } == .shown)
        #expect(PreviewWindowing.referenceFrame(imageCount: 1, fileFrames: 1, shownFrame: 0) { _ in (false, 0) } == .shown)
        #expect(PreviewWindowing.referenceFrame(imageCount: 1, fileFrames: 0, shownFrame: 0) { _ in (false, 0) } == .shown)
    }

    @Test func theFrameRangeIsReadOnlyWhenNothingElseDescribesTheFrame() {
        #expect(PreviewWindowing.needsFrameRange(hasAutomaticWindow: false, isColor: false, hasValidFileWindow: false))
        #expect(!PreviewWindowing.needsFrameRange(hasAutomaticWindow: true, isColor: false, hasValidFileWindow: false))
        #expect(!PreviewWindowing.needsFrameRange(hasAutomaticWindow: false, isColor: true, hasValidFileWindow: false))
        #expect(!PreviewWindowing.needsFrameRange(hasAutomaticWindow: false, isColor: false, hasValidFileWindow: true))
    }

    @Test func aWheelNotchMovesOneStepAndWrapsAround() {
        #expect(PreviewWindowing.wheelPosition(from: 3, deltaY: 0, reversed: false, maxValue: 9) == nil)
        #expect(PreviewWindowing.wheelPosition(from: 3, deltaY: 2.5, reversed: false, maxValue: 9) == 4)
        #expect(PreviewWindowing.wheelPosition(from: 3, deltaY: -0.1, reversed: false, maxValue: 9) == 2)
        #expect(PreviewWindowing.wheelPosition(from: 3, deltaY: 2.5, reversed: true, maxValue: 9) == 2)
        #expect(PreviewWindowing.wheelPosition(from: 3, deltaY: -2.5, reversed: true, maxValue: 9) == 4)
        // Past the last image, the first; before the first, the last.
        #expect(PreviewWindowing.wheelPosition(from: 9, deltaY: 1, reversed: false, maxValue: 9) == 0)
        #expect(PreviewWindowing.wheelPosition(from: 0, deltaY: -1, reversed: false, maxValue: 9) == 9)
        // A slider of one image stays on it.
        #expect(PreviewWindowing.wheelPosition(from: 0, deltaY: 1, reversed: false, maxValue: 0) == 0)
        #expect(PreviewWindowing.wheelPosition(from: 0, deltaY: -1, reversed: false, maxValue: 0) == 0)
        // A delta that is not a number goes back, as it is not above zero.
        #expect(PreviewWindowing.wheelPosition(from: 3, deltaY: .nan, reversed: false, maxValue: 9) == 2)
    }

    @Test func theAnimationStepsOnAndStartsAgainAfterTheLast() {
        #expect(PreviewWindowing.nextAnimationPosition(from: 0, maxValue: 4) == 1)
        #expect(PreviewWindowing.nextAnimationPosition(from: 3, maxValue: 4) == 4)
        #expect(PreviewWindowing.nextAnimationPosition(from: 4, maxValue: 4) == 0)
        #expect(PreviewWindowing.nextAnimationPosition(from: 0, maxValue: 0) == 0)
        // The step wraps as the int it is, and the slider clamps what it is given.
        #expect(PreviewWindowing.nextAnimationPosition(from: Int32.max, maxValue: 4) == Int32.min)
    }
}
