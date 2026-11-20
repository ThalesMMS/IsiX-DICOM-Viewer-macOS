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

@Suite struct ThickSlabSpanTests {
    private func span(_ images: Int, at current: Int, of count: Int, towardsStart: Bool = false) -> ClosedRange<Int> {
        ThickSlabSpan(images: images, at: current, of: count, towardsStart: towardsStart).indices
    }

    @Test func anOddSlabHasAsManyImagesOnEitherSide() {
        #expect(span(3, at: 10, of: 60) == 9...11)
        #expect(span(7, at: 10, of: 60) == 7...13)
        #expect(span(59, at: 30, of: 60) == 1...59)
        // The direction changes nothing of it.
        #expect(span(3, at: 10, of: 60, towardsStart: true) == 9...11)
        #expect(span(7, at: 10, of: 60, towardsStart: true) == 7...13)
    }

    @Test func anEvenSlabHasItsImageMoreOnTheSideItGoes() {
        #expect(span(2, at: 10, of: 60) == 10...11)
        #expect(span(4, at: 10, of: 60) == 9...12)
        #expect(span(6, at: 10, of: 60) == 8...13)
        // Towards the start of the series: the image more is before the one shown.
        #expect(span(2, at: 10, of: 60, towardsStart: true) == 9...10)
        #expect(span(4, at: 10, of: 60, towardsStart: true) == 8...11)
        #expect(span(6, at: 10, of: 60, towardsStart: true) == 7...12)
    }

    @Test func theSlabIsPulledBackAtTheStartAndKeepsItsImages() {
        for towardsStart in [false, true] {
            #expect(span(7, at: 0, of: 60, towardsStart: towardsStart) == 0...6)
            #expect(span(6, at: 0, of: 60, towardsStart: towardsStart) == 0...5)
            #expect(span(2, at: 0, of: 60, towardsStart: towardsStart) == 0...1)
        }
        // The images within half a slab of the start show the same slab.
        #expect((0...3).allSatisfy { span(7, at: $0, of: 60) == 0...6 })
        #expect(span(7, at: 4, of: 60) == 1...7)
        #expect((0...2).allSatisfy { span(6, at: $0, of: 60) == 0...5 })
        #expect(span(6, at: 3, of: 60) == 1...6)
        #expect((0...3).allSatisfy { span(6, at: $0, of: 60, towardsStart: true) == 0...5 })
        #expect(span(6, at: 4, of: 60, towardsStart: true) == 1...6)
    }

    @Test func theSlabIsPulledBackAtTheEndAndKeepsItsImages() {
        for towardsStart in [false, true] {
            #expect(span(7, at: 59, of: 60, towardsStart: towardsStart) == 53...59)
            #expect(span(6, at: 59, of: 60, towardsStart: towardsStart) == 54...59)
            #expect(span(2, at: 59, of: 60, towardsStart: towardsStart) == 58...59)
        }
        #expect((56...59).allSatisfy { span(7, at: $0, of: 60) == 53...59 })
        #expect(span(7, at: 55, of: 60) == 52...58)
        #expect((56...59).allSatisfy { span(6, at: $0, of: 60) == 54...59 })
        #expect(span(6, at: 55, of: 60) == 53...58)
        #expect((57...59).allSatisfy { span(6, at: $0, of: 60, towardsStart: true) == 54...59 })
        #expect(span(6, at: 56, of: 60, towardsStart: true) == 53...58)
    }

    @Test func everyImageOfTheSeriesHasTheImagesAskedFor() {
        for count in [1, 2, 5, 12, 60] {
            for images in 1...(count + 3) {
                for towardsStart in [false, true] {
                    for current in 0..<count {
                        let slab = ThickSlabSpan(images: images, at: current, of: count, towardsStart: towardsStart)
                        #expect(slab.count == min(images, count))
                        #expect(slab.first >= 0 && slab.last < count)
                        #expect(slab.indices.contains(current))
                        // An image more never leaves an image out.
                        let more = ThickSlabSpan(images: images + 1, at: current, of: count, towardsStart: towardsStart)
                        #expect(more.first <= slab.first && more.last >= slab.last)
                        // Away from the ends, the images before the one shown, in the slab's direction, are ⌊(N − 1) / 2⌋.
                        let before = towardsStart ? slab.last - current : current - slab.first
                        if slab.first > 0, slab.last < count - 1 { #expect(before == (images - 1) / 2) }
                    }
                }
            }
        }
    }

    @Test func aSeriesOfFewerImagesGivesThemAll() {
        for towardsStart in [false, true] {
            for current in 0..<5 {
                #expect(span(6, at: current, of: 5, towardsStart: towardsStart) == 0...4)
                #expect(span(128, at: current, of: 5, towardsStart: towardsStart) == 0...4)
                #expect(span(5, at: current, of: 5, towardsStart: towardsStart) == 0...4)
            }
            #expect(span(4, at: 0, of: 1, towardsStart: towardsStart) == 0...0)
        }
    }

    @Test func oneImageIsTheImageShown() {
        for towardsStart in [false, true] {
            for current in [0, 10, 59] {
                #expect(span(1, at: current, of: 60, towardsStart: towardsStart) == current...current)
                // No slab, or a count that is none.
                #expect(span(0, at: current, of: 60, towardsStart: towardsStart) == current...current)
                #expect(span(-3, at: current, of: 60, towardsStart: towardsStart) == current...current)
            }
            // An image that is not of the series is alone.
            #expect(span(5, at: -1, of: 60, towardsStart: towardsStart) == -1...(-1))
            #expect(span(5, at: 60, of: 60, towardsStart: towardsStart) == 60...60)
            #expect(span(5, at: 0, of: 0, towardsStart: towardsStart) == 0...0)
        }
    }

    @Test func theEndsAndTheOrderFollowTheDirection() {
        let forwards = ThickSlabSpan(images: 4, at: 10, of: 60, towardsStart: false)
        #expect(forwards.nearEnd == 9 && forwards.farEnd == 12 && forwards.step == 1)
        #expect(forwards.ordered == [9, 10, 11, 12])
        let backwards = ThickSlabSpan(images: 4, at: 10, of: 60, towardsStart: true)
        #expect(backwards.nearEnd == 11 && backwards.farEnd == 8 && backwards.step == -1)
        #expect(backwards.ordered == [11, 10, 9, 8])
        // The order is that of the slab, whichever of its images is shown.
        #expect((0...3).allSatisfy { ThickSlabSpan(images: 7, at: $0, of: 60, towardsStart: false).ordered == Array(0...6) })
        #expect((0...3).allSatisfy { ThickSlabSpan(images: 7, at: $0, of: 60, towardsStart: true).ordered == Array((0...6).reversed()) })
    }

    @Test func theMiddleIsTheImageShownUntilTheSlabIsPulledBack() {
        for towardsStart in [false, true] {
            for images in 1...9 {
                for current in 0..<60 {
                    let slab = ThickSlabSpan(images: images, at: current, of: 60, towardsStart: towardsStart)
                    let before = towardsStart ? slab.last - current : current - slab.first
                    // Pulled back or not, the middle has the images of a centred slab before it, and its slab is this one.
                    #expect((towardsStart ? slab.last - slab.middle : slab.middle - slab.first) == (images - 1) / 2)
                    #expect(ThickSlabSpan(images: images, at: slab.middle, of: 60, towardsStart: towardsStart) == slab)
                    #expect((slab.middle == current) == (before == (images - 1) / 2))
                }
            }
        }
        // Seven images on the first four images are images 0 to 6, around image 3, and on the last four 53 to 59, around 56.
        #expect((0...3).allSatisfy { ThickSlabSpan(images: 7, at: $0, of: 60, towardsStart: false).middle == 3 })
        #expect((56...59).allSatisfy { ThickSlabSpan(images: 7, at: $0, of: 60, towardsStart: true).middle == 56 })
        #expect(ThickSlabSpan(images: 7, at: 4, of: 60, towardsStart: false).middle == 4)
        // An even slab: the image before its two middle ones, in its direction.
        #expect(ThickSlabSpan(images: 6, at: 0, of: 60, towardsStart: false).middle == 2)
        #expect(ThickSlabSpan(images: 6, at: 0, of: 60, towardsStart: true).middle == 3)
        // More images than the series has: the middle of the series, whatever the image.
        #expect((0..<5).allSatisfy { ThickSlabSpan(images: 9, at: $0, of: 5, towardsStart: false).middle == 2 })
        #expect(ThickSlabSpan(images: 1, at: 17, of: 60, towardsStart: false).middle == 17)
    }

    @Test func theUserCountsTheImagesOfFlippedDataFromTheOtherEnd() {
        #expect(ThickSlabSpan(images: 4, at: 10, of: 60, towardsStart: false).userIndices(of: 60) == 9...12)
        // Image 10 of 60 is the user's 49: the slab goes on from it there too, 48 to 51.
        #expect(ThickSlabSpan(images: 4, at: 10, of: 60, towardsStart: true).userIndices(of: 60) == 48...51)
        #expect(ThickSlabSpan(images: 4, at: 59, of: 60, towardsStart: true).userIndices(of: 60) == 0...3)
        #expect(ThickSlabSpan(images: 4, at: 0, of: 60, towardsStart: true).userIndices(of: 60) == 56...59)
        // As the user counts, a flipped slab is the slab of the user's image going forwards.
        for images in 1...9 {
            for current in 0..<12 {
                let flipped = ThickSlabSpan(images: images, at: current, of: 12, towardsStart: true).userIndices(of: 12)
                #expect(flipped == span(images, at: 11 - current, of: 12))
            }
        }
    }
}
