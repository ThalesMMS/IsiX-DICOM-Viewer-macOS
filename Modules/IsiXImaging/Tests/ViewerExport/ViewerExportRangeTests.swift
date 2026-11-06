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

@Suite struct ViewerExportRangeTests {

    /// The images, 1-based, the export takes for the sheet's fields.
    private func exported(_ first: Int32, _ last: Int32, _ step: Int32) -> [Int] {
        ViewerExportRange(first: first, last: last, step: step).indices.map { $0 + 1 }
    }

    @Test func theSheetCountsTheImagesTheExportTakes() {
        for (first, last, step) in [(1, 10, 3), (1, 9, 2), (10, 1, 3), (1, 1, 1), (1, 10, 1), (1, 10, 20),
                                    (3, 7, 0), (1, 5, -2), (2, 40, 7), (5, 1, 1), (2, 1, 1)] as [(Int32, Int32, Int32)] {
            let range = ViewerExportRange(first: first, last: last, step: step)
            let images = exported(first, last, step)
            #expect(Int(ViewerExportRange.imageCount(first: first, last: last, interval: step)) == images.count,
                    "\(first)...\(last) by \(step): \(images)")
            #expect(Int(range.progressMaximum) == images.count)
        }
    }

    @Test func theRangeTakesBothEndsInEitherOrderAndEveryImageBelowAnIntervalOfOne() {
        #expect(exported(1, 10, 3) == [1, 4, 7, 10])
        #expect(exported(5, 1, 1) == [1, 2, 3, 4, 5])
        #expect(exported(2, 1, 1) == [1, 2])
        #expect(exported(3, 3, 1) == [3])
        #expect(exported(1, 5, 0) == [1, 2, 3, 4, 5])
        #expect(exported(1, 5, -2) == [1, 2, 3, 4, 5])
        #expect(ViewerExportRange(first: 1, last: 5, step: 0).interval == 1)
    }

    @Test func theWholeSeriesIsEveryImage() {
        #expect(Array(ViewerExportRange.whole(count: 4).indices) == [0, 1, 2, 3])
        #expect(ViewerExportRange.whole(count: 4).progressMaximum == 4)
        #expect(Array(ViewerExportRange.whole(count: 0).indices).isEmpty)
        #expect(ViewerExportRange.whole(count: 0).progressMaximum == 0)
    }

    @Test func aFlippedSeriesCountsFromTheEnd() {
        #expect(ViewerExportRange.position(0, count: 5, flipped: false) == 0)
        #expect(ViewerExportRange.position(0, count: 5, flipped: true) == 4)
        #expect(ViewerExportRange.position(4, count: 5, flipped: true) == 0)
    }

    @Test func theImageExportTakesTheChoiceOfItsSheet() {
        let keys: Set<Int> = [1, 3]
        func positions(_ selection: Int, flipped: Bool = false) -> [Int] {
            ViewerExportRange.imagePositions(selection: selection, count: 5, current: 2, flipped: flipped,
                                             isKeyImage: { keys.contains($0) })
        }
        #expect(positions(ViewerExportRange.ImageSelection.currentImage.rawValue) == [2])
        #expect(positions(ViewerExportRange.ImageSelection.allImages.rawValue) == [0, 1, 2, 3, 4])
        #expect(positions(ViewerExportRange.ImageSelection.allImages.rawValue, flipped: true) == [4, 3, 2, 1, 0])
        #expect(positions(ViewerExportRange.ImageSelection.keyImages.rawValue) == [1, 3])
        #expect(positions(ViewerExportRange.ImageSelection.keyImages.rawValue, flipped: true) == [3, 1])
        // A choice the sheet does not have takes every image, as before.
        #expect(positions(7) == [0, 1, 2, 3, 4])
        #expect(ViewerExportRange.imagePositions(selection: 1, count: 0, current: 0, flipped: false, isKeyImage: { _ in true }).isEmpty)
    }

    @Test func everyViewerIsTakenFromLeftTopToRightBottom() {
        // Screen coordinates: y grows upwards. Two rows of two windows, given in any order.
        let origins = [CGPoint(x: 600, y: 0), CGPoint(x: 0, y: 500), CGPoint(x: 0, y: 0), CGPoint(x: 600, y: 500)]
        #expect(ViewerExportRange.readingOrder(of: origins) == [1, 3, 2, 0])
        // A window lower than the highest one is not taken before it, even when further left.
        #expect(ViewerExportRange.readingOrder(of: [CGPoint(x: 500, y: 300), CGPoint(x: 0, y: 200)]) == [0, 1])
        #expect(ViewerExportRange.readingOrder(of: []).isEmpty)
        #expect(ViewerExportRange.readingOrder(of: [CGPoint(x: 3, y: 4)]) == [0])
    }
}
