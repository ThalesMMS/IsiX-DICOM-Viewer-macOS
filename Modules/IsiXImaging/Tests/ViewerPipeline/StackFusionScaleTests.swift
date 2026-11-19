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

@Suite struct StackFusionScaleTests {
    private let english = Locale(identifier: "en_US")
    private let italian = Locale(identifier: "it_IT")

    /// A series of `count` images `interval` apart.
    private func regular(_ count: Int, every interval: Double, thickness: Double, current: Int, towardsStart: Bool = false,
                         capacity: Int? = nil) -> StackFusionScale {
        StackFusionScale(positions: (0..<count).map { Double($0) * interval }, current: current, towardsStart: towardsStart,
                         sliceThickness: thickness, fallbackInterval: interval, capacity: capacity ?? max(2, count))
    }

    /// The first recording: slices of 2 mm every 1 mm, where two images read 3.0 mm under a bubble that said 2.
    @Test func overlappingSlicesCoverTheirThicknessAndTheDistancesBetweenThem() {
        let scale = regular(80, every: 1, thickness: 2, current: 40)
        #expect(scale.available == 40)
        #expect([2, 6, 10, 26].map { scale.thickness(requested: $0) } == [3, 7, 11, 27])
        #expect(scale.minimum == 2)
        #expect(scale.maximum == 41)
        #expect(scale.text(requested: 2, locale: english) == "3.0 mm")
        let flipped = regular(80, every: 1, thickness: 2, current: 40, towardsStart: true)
        #expect(flipped.available == 41)
        #expect(flipped.maximum == 42)
        #expect([2, 6, 10, 26, 80].map { flipped.text(requested: $0, locale: english) } == ["3.0 mm", "7.0 mm", "11.0 mm", "27.0 mm", "42.0 mm"])
    }

    /// The second recording: slices of 2 mm every 2 mm, where every number
    /// was doubled and the knob went on after the slab had stopped at 52 mm.
    @Test func theThickEndIsWhatIsLeftOfTheSeries() {
        let flipped = regular(60, every: 2, thickness: 2, current: 34, towardsStart: true)
        #expect(flipped.available == 35)
        #expect(flipped.maximum == 70)
        #expect([2, 5, 20, 26, 46, 60].map { flipped.thickness(requested: $0) } == [4, 10, 40, 52, 70, 70])
        #expect([2, 5, 20, 26, 46, 60].map { flipped.effectiveCount(requested: $0) } == [2, 5, 20, 26, 35, 35])
        #expect(flipped.text(requested: 2, locale: english) == "4.0 mm")
        // From 35 images on the knob stands where the images left end, short of the thick end of the track.
        for exponential in [false, true] {
            let reach = flipped.reach(exponential: exponential)
            #expect(reach < 1 && flipped.position(ofCount: 34, exponential: exponential) < reach)
            #expect([35, 46, 60].allSatisfy { flipped.position(ofCount: $0, exponential: exponential) == reach })
        }
        #expect(flipped.reach(exponential: false) == (70.0 - 2) / (120 - 2))

        let forwards = regular(60, every: 2, thickness: 2, current: 34)
        #expect(forwards.available == 26)
        #expect(forwards.maximum == 52)

        // The last image in the slab's direction: one stop, the slice, at the thin end of the track of the series.
        let last = regular(60, every: 2, thickness: 2, current: 0, towardsStart: true)
        #expect(last.available == 1)
        #expect(last.stops == [2])
        #expect(last.minimum == 2 && last.maximum == 2)
        #expect(last.thickness(requested: 10) == 2)
        #expect(last.text(requested: 10, locale: english) == "2.0 mm")
        #expect(last.trackStops == flipped.trackStops && last.trackStops.count == 60)
        for exponential in [false, true] {
            #expect(last.tickCounts(minimumSpacing: 8.0 / 175)
                    == flipped.tickCounts(minimumSpacing: 8.0 / 175))
            #expect(last.reach(exponential: exponential) == 0 && last.position(ofCount: 10, exponential: exponential) == 0)
            #expect(last.count(at: 0.7, exponential: exponential) == 1)
        }

        // A request is kept: it fuses what the image has, and all of it where the series allows.
        #expect(regular(60, every: 2, thickness: 2, current: 10, towardsStart: true).thickness(requested: 46) == 22)
        #expect(regular(60, every: 2, thickness: 2, current: 50, towardsStart: true).thickness(requested: 46) == 92)
    }

    @Test func theImagesLeftStayWithinTheSlidersCapacity() {
        #expect(regular(120, every: 1, thickness: 1, current: 0, capacity: 118).available == 118)
        #expect(regular(120, every: 1, thickness: 1, current: 119, towardsStart: true, capacity: 118).available == 118)
        #expect(regular(120, every: 1, thickness: 1, current: 100, capacity: 118).available == 20)
        // The track is of the images the slider can ask for, wherever the image shown is.
        for current in [0, 100, 119] {
            #expect(regular(120, every: 1, thickness: 1, current: current, capacity: 118).trackStops == (1...118).map(Double.init))
        }
        #expect(StackFusionScale.available(current: 34, count: 60, towardsStart: true, capacity: 60) == 35)
        #expect(StackFusionScale.available(current: 34, count: 60, towardsStart: false, capacity: 60) == 26)
        #expect(StackFusionScale.available(current: 59, count: 60, towardsStart: false, capacity: 60) == 1)
        // An image that is not of the series, or no series, has the one image.
        #expect(StackFusionScale.available(current: -1, count: 60, towardsStart: false, capacity: 60) == 1)
        #expect(StackFusionScale.available(current: 60, count: 60, towardsStart: true, capacity: 60) == 1)
        #expect(StackFusionScale.available(current: 0, count: 0, towardsStart: false, capacity: 60) == 1)
        #expect(StackFusionScale.available(current: 5, count: 60, towardsStart: false, capacity: 0) == 1)
        let outside = StackFusionScale(positions: [0, 1, 2], current: 7, towardsStart: false, sliceThickness: 2, fallbackInterval: 1, capacity: 3)
        #expect(outside.available == 1 && outside.stops == [2] && outside.trackStops == [2, 3, 4])
    }

    @Test func thinSlicesKeepNeighbouringStopsApartInTheirText() {
        let scale = regular(300, every: 0.625, thickness: 0.625, current: 0)
        #expect((1...4).map { scale.text(requested: $0, locale: english) } == ["0.6 mm", "1.3 mm", "1.9 mm", "2.5 mm"])
        let texts = (1...300).map { scale.text(requested: $0, locale: english) }
        #expect(zip(texts, texts.dropFirst()).allSatisfy { $0 != $1 })
        // Stops less than a tenth of a millimetre apart take two decimals, all of them.
        let fine = regular(40, every: 0.05, thickness: 0.3, current: 0)
        #expect((1...3).map { fine.text(requested: $0, locale: english) } == ["0.30 mm", "0.35 mm", "0.40 mm"])
        let fineTexts = (1...40).map { fine.text(requested: $0, locale: english) }
        #expect(zip(fineTexts, fineTexts.dropFirst()).allSatisfy { $0 != $1 })
    }

    @Test func aSliceWithoutThicknessCountsTheDistanceToItsNeighbour() {
        let scale = regular(10, every: 1, thickness: 0, current: 3)
        #expect(scale.isPhysical)
        #expect(scale.text(requested: 1, locale: english) == "1.0 mm")
        #expect(scale.text(requested: 2, locale: english) == "2.0 mm")
        #expect(scale.thickness(requested: 5) == 5)
        // At the series' end, the other neighbour.
        let last = regular(10, every: 1.5, thickness: 0, current: 9)
        #expect(last.stops == [1.5])
        // A thickness that is no number, or negative, is none.
        #expect(regular(10, every: 1, thickness: .nan, current: 3).minimum == 1)
        #expect(regular(10, every: 1, thickness: -2, current: 3).minimum == 1)
        // Without positions, the interval of the series.
        let unplaced = StackFusionScale(positions: [Double](repeating: .nan, count: 10), current: 3, towardsStart: false,
                                        sliceThickness: 0, fallbackInterval: -2.5, capacity: 10)
        #expect(unplaced.isPhysical && unplaced.stops.prefix(3) == [2.5, 5, 7.5])
    }

    @Test func positionsNotKnownYetAreARegularSeries() {
        let loading = StackFusionScale(positions: [0, 1, .nan, 3, 4, 5], current: 0, towardsStart: false,
                                       sliceThickness: 2, fallbackInterval: 1, capacity: 6)
        #expect(loading.isPhysical && loading.stops == [2, 3, 4, 5, 6, 7])
        // No interval either: each image counts a slice.
        let bare = StackFusionScale(positions: [Double](repeating: .nan, count: 4), current: 0, towardsStart: false,
                                    sliceThickness: 2, fallbackInterval: 0, capacity: 4)
        #expect(bare.isPhysical && bare.stops == [2, 4, 6, 8])
        // The unknown image is not needed by a slab that runs the other way.
        let away = StackFusionScale(positions: [0, 1, .nan, 3.5, 4, 5], current: 1, towardsStart: true,
                                    sliceThickness: 2, fallbackInterval: 9, capacity: 6)
        #expect(away.stops == [2, 3])
    }

    @Test func aSeriesWithNoGeometryCountsImages() {
        let pictures = StackFusionScale(positions: [Double](repeating: .nan, count: 12), current: 2, towardsStart: false,
                                        sliceThickness: 0, fallbackInterval: 0, capacity: 12)
        #expect(!pictures.isPhysical)
        #expect(pictures.available == 10)
        #expect(pictures.stops == (1...10).map(Double.init))
        #expect(pictures.text(requested: 4, locale: english) == "4")
        #expect(pictures.text(requested: 40, locale: english) == "10")
        #expect(pictures.count(at: 1, exponential: false) == 10)
        // Images that all stand at one place have no thickness to add: a
        // slab of them counts images too, whatever one of them says of itself.
        let stacked = StackFusionScale(positions: [Double](repeating: 12.5, count: 8), current: 0, towardsStart: false,
                                       sliceThickness: 5, fallbackInterval: 0, capacity: 8)
        #expect(!stacked.isPhysical && stacked.stops == (1...8).map(Double.init))
        #expect(stacked.text(requested: 3, locale: italian) == "3")
        // A long series of them writes its count without grouping.
        let long = StackFusionScale(positions: [Double](repeating: .nan, count: 2000), current: 0, towardsStart: false,
                                    sliceThickness: 0, fallbackInterval: 0, capacity: 2000)
        #expect(long.text(requested: 1536, locale: italian) == "1536")
    }

    @Test func irregularIntervalsGiveTheThicknessesThereAre() {
        let scale = StackFusionScale(positions: [0, 1, 2, 3, 8, 13, 18, 23], current: 0, towardsStart: false,
                                     sliceThickness: 1, fallbackInterval: 1, capacity: 8)
        #expect(scale.stops == [1, 2, 3, 4, 9, 14, 19, 24])
        // Equal steps of millimetres, each taken to the nearest stop.
        let marks = scale.tickCounts(minimumSpacing: 8.0 / 175)
        #expect(marks.first == 1 && marks.last == 8)
        #expect(Set(marks).count == marks.count && marks == marks.sorted())
        let step = 5.0 * ((24.0 - 1) / (10 * 5)).rounded(.up)
        for mark in marks.dropFirst().dropLast() {
            let thickness = scale.stops[mark - 1]
            let target = 1 + ((thickness - 1) / step).rounded() * step
            #expect(scale.stops.allSatisfy { abs($0 - target) >= abs(thickness - target) - 1e-9 }, "mark at \(thickness) mm")
        }
        // Backwards from the other end, the same distances in the other order.
        let back = StackFusionScale(positions: [0, 1, 2, 3, 8, 13, 18, 23], current: 7, towardsStart: true,
                                    sliceThickness: 1, fallbackInterval: 1, capacity: 8)
        #expect(back.stops == [1, 6, 11, 16, 21, 22, 23, 24])
    }

    /// An oblique series, 1 mm apart along its normal: measured on the
    /// dominant axis each image added 0.94 mm.
    @Test func anObliqueSeriesIsMeasuredAlongItsNormal() {
        let angle = 20.0 * Double.pi / 180
        let normal = [0, sin(angle), cos(angle)]
        var origins: [Double] = [], locations: [Double] = []
        for image in 0..<12 {
            let along = Double(image)
            origins += [10 + along * normal[0], -30 + along * normal[1], 5 + along * normal[2]]
            locations.append(5 + along * normal[2])
        }
        let positions = StackFusionScale.positions(origins: origins, normal: normal, locations: locations)
        let scale = StackFusionScale(positions: positions, current: 2, towardsStart: false, sliceThickness: 1.5, fallbackInterval: 1, capacity: 12)
        for images in 1...10 { #expect(abs(scale.stops[images - 1] - (1.5 + Double(images - 1))) < 1e-9) }
        let dominant = StackFusionScale(positions: locations, current: 2, towardsStart: false, sliceThickness: 1.5, fallbackInterval: 1, capacity: 12)
        #expect(abs(dominant.stops[1] - dominant.stops[0] - 0.94) < 0.001)
        // A normal that is not unit is the same direction; none is the locations.
        let scaled = StackFusionScale.positions(origins: origins, normal: normal.map { $0 * 3 }, locations: locations)
        #expect(zip(scaled, positions).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(StackFusionScale.positions(origins: origins, normal: [0, 0, 0], locations: locations) == locations)
        #expect(StackFusionScale.positions(origins: origins, normal: [], locations: locations) == locations)
        #expect(StackFusionScale.positions(origins: origins, normal: [.nan, 0, 1], locations: locations) == locations)
    }

    @Test func positionsThatGoBackNeverThinTheSlab() {
        let scale = StackFusionScale(positions: [0, 0, 2, 2, 4, 4], current: 0, towardsStart: false,
                                     sliceThickness: 1, fallbackInterval: 2, capacity: 6)
        #expect(scale.stops == [1, 1, 3, 3, 5, 5])
        for exponential in [false, true] {
            // Stops of one thickness share a place: the fewest images of them.
            #expect(scale.count(at: 0, exponential: exponential) == 1)
            #expect(scale.count(at: scale.position(ofCount: 4, exponential: exponential), exponential: exponential) == 3)
            #expect(scale.count(at: 1, exponential: exponential) == 5)
            var last = 0
            for step in 0...200 {
                let count = scale.count(at: Double(step) / 200, exponential: exponential)
                #expect(count >= last && [1, 3, 5].contains(count))
                last = count
            }
            let marks = scale.tickCounts(minimumSpacing: 8.0 / 175)
            #expect(marks.first == 1 && marks.last == 6 && marks == marks.sorted())
        }
        // Several stacks in one series: the span of what is fused, whichever the order.
        let phases = StackFusionScale(positions: [0, 2, 4, 0, 2, 4, 0, 2, 4], current: 1, towardsStart: false,
                                      sliceThickness: 2, fallbackInterval: 2, capacity: 9)
        #expect(phases.stops == [2, 4, 6, 6, 6, 6, 6, 6])
        #expect(zip(phases.stops, phases.stops.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test func theMarksAreStopsEquallySpacedInMillimetres() {
        let track = 8.0 / 175
        let whole = regular(60, every: 2, thickness: 2, current: 0)
        let wholeMarks = whole.tickCounts(minimumSpacing: track)
        #expect(wholeMarks.map { whole.stops[$0 - 1] } == [2, 14, 26, 38, 50, 62, 74, 86, 98, 110, 120])
        // Further on in the series the marks are where they were: they are those of the series.
        let rest = regular(60, every: 2, thickness: 2, current: 34)
        #expect(rest.tickCounts(minimumSpacing: track) == wholeMarks)
        for exponential in [false, true] {
            #expect(rest.tickPlaces(minimumSpacing: track, exponential: exponential)
                    == whole.tickPlaces(minimumSpacing: track, exponential: exponential))
        }

        for scale in [whole, rest, regular(80, every: 1, thickness: 2, current: 40, towardsStart: true),
                      regular(300, every: 0.625, thickness: 0.625, current: 10), regular(3, every: 5, thickness: 5, current: 0),
                      regular(2, every: 1, thickness: 3, current: 0)] {
            let marks = scale.tickCounts(minimumSpacing: track)
            #expect(marks.first == 1 && marks.last == scale.trackStops.count)
            #expect(marks == marks.sorted() && Set(marks).count == marks.count)
            let places = marks.map { scale.trackPosition(ofStop: $0, exponential: false) }
            #expect(places == scale.tickPlaces(minimumSpacing: track, exponential: false))
            #expect(places.first == 0 && places.last == 1)
            #expect(zip(places, places.dropFirst()).allSatisfy { $1 - $0 >= track - 1e-9 }, "marks at \(places)")
            // Each mark the image reaches reads what its stop does, and the knob put on it stands on it;
            // a mark beyond gives the images left.
            for (mark, place) in zip(marks, places) {
                let landed = scale.count(at: place, exponential: false)
                #expect(landed == min(mark, scale.available))
                #expect(scale.text(requested: mark, locale: english) == scale.text(requested: landed, locale: english))
                if mark <= scale.available { #expect(scale.position(ofCount: mark, exponential: false) == place) }
            }
            // The linear marks stay evenly spaced; the last step is what the series leaves.
            let steps = zip(places, places.dropFirst()).map { $1 - $0 }.dropLast()
            #expect((steps.max() ?? 0) - (steps.min() ?? 0) < 1e-9, "linear steps \(steps)")
        }
    }

    @Test func theMarksOfTheExponentialTrackGatherTowardsItsThickEnd() {
        let track = 8.0 / 175
        for scale in [regular(60, every: 2, thickness: 2, current: 0), regular(461, every: 1.5, thickness: 3, current: 200),
                      regular(300, every: 0.625, thickness: 0.625, current: 10), regular(12, every: 5, thickness: 5, current: 0)] {
            let places = scale.tickPlaces(minimumSpacing: track, exponential: true)
            #expect(places.first == 0 && places.last == 1)
            let gaps = zip(places, places.dropFirst()).map { $1 - $0 }
            // Each step of the ruler is shorter than the one before it, down to a third of the linear distance.
            #expect(zip(gaps, gaps.dropFirst()).allSatisfy { $1 < $0 }, "gaps \(gaps)")
            #expect((gaps.last ?? 0) >= track / 3 - 1e-12)
            // No more intervals than the track has stops, and more than the linear ruler where the series has them.
            #expect(gaps.count <= scale.trackStops.count - 1 && gaps.count <= 16)
            if scale.trackStops.count > 100 {
                #expect(gaps.count > scale.tickCounts(minimumSpacing: track).count - 1)
                // The thin end has its marks: a third of the track is not left bare, and the first quarter has one.
                #expect(gaps[0] < 1.0 / 3 && places.filter { $0 > 0 && $0 <= 0.5 }.count >= 3, "marks at \(places)")
                // The thick end is as dense as the marks can be told apart.
                #expect((gaps.last ?? 1) < track)
            }
        }
        // A track of two stops has its ends, and one whose thin end says no thickness has the linear ruler.
        #expect(regular(2, every: 1, thickness: 3, current: 0).tickPlaces(minimumSpacing: track, exponential: true) == [0, 1])
        let whole = regular(60, every: 2, thickness: 2, current: 0)
        #expect(whole.tickPlaces(minimumSpacing: 0.8, exponential: true).count == 3 && whole.tickPlaces(minimumSpacing: 2, exponential: true) == [0, 1])
        // A linear track too short for a mark between its ends has the ends.
        #expect(whole.tickCounts(minimumSpacing: 0.8) == [1, 60])
        #expect(whole.tickCounts(minimumSpacing: .nan).count == 11)
    }

    @Test func theKnobComesBackToTheStopItWasPutOn() {
        for scale in [regular(60, every: 2, thickness: 2, current: 34, towardsStart: true), regular(80, every: 1, thickness: 2, current: 3),
                      regular(300, every: 0.625, thickness: 0.625, current: 0),
                      StackFusionScale(positions: [0, 1, 2, 3, 8, 13, 18, 23], current: 0, towardsStart: false,
                                       sliceThickness: 1, fallbackInterval: 1, capacity: 8)] {
            for exponential in [false, true] {
                var last = -1.0
                for count in 1...scale.available {
                    let place = scale.position(ofCount: count, exponential: exponential)
                    #expect(place > last, "\(count) images do not move the knob")
                    last = place
                    #expect(scale.count(at: place, exponential: exponential) == count)
                }
                // The images left end the knob's way: the thick end of the track where the series is whole before the image.
                #expect(last == scale.reach(exponential: exponential))
                #expect((last == 1) == (scale.available == scale.trackStops.count))
                #expect(scale.position(ofCount: 1, exponential: exponential) == 0)
                // Anywhere on the track: a stop, never going back; beyond the ends, the ends.
                var landed = 1
                for step in 0...500 {
                    let count = scale.count(at: Double(step) / 500, exponential: exponential)
                    #expect(count >= landed && count <= scale.available)
                    landed = count
                }
                #expect(landed == scale.available)
                #expect(scale.count(at: -3, exponential: exponential) == 1 && scale.count(at: 7, exponential: exponential) == scale.available)
                #expect(scale.count(at: .nan, exponential: exponential) == 1)
            }
        }
    }

    /// A recording of a chest series of 383 images every millimetre: with a
    /// slab of 10 mm asked for, the knob went from one place to another, and
    /// to the end of its track, as the series scrolled.
    @Test func theTrackIsOfTheSeriesAndTheKnobStaysWhereTheRequestIs() {
        let whole = regular(383, every: 1, thickness: 1, current: 0)
        #expect(whole.trackStops == (1...383).map(Double.init))
        for towardsStart in [false, true] {
            for exponential in [false, true] {
                let places = stride(from: 0, to: 383, by: 7).map { current -> Double in
                    let scale = regular(383, every: 1, thickness: 1, current: current, towardsStart: towardsStart)
                    #expect(scale.trackStops == whole.trackStops)
                    #expect(scale.tickCounts(minimumSpacing: 8.0 / 175)
                            == whole.tickCounts(minimumSpacing: 8.0 / 175))
                    // Wherever ten images are left, they are 10 mm at one place of the track.
                    guard scale.available >= 10 else { return -1 }
                    #expect(scale.text(requested: 10, locale: english) == "10.0 mm")
                    #expect(scale.reach(exponential: exponential) >= scale.position(ofCount: 10, exponential: exponential))
                    return scale.position(ofCount: 10, exponential: exponential)
                }.filter { $0 >= 0 }
                #expect(places.count > 50 && Set(places).count == 1)
                #expect(places[0] == whole.trackPosition(ofStop: 10, exponential: exponential))
            }
        }
        // The two directions of one series measure the same distances from opposite ends: one track.
        #expect(regular(383, every: 1, thickness: 1, current: 200, towardsStart: true).trackStops == whole.trackStops)
        // Another series, another track.
        #expect(regular(120, every: 2.5, thickness: 2.5, current: 60).trackStops.last == 300)
    }

    @Test func aRequestTheImageCannotHoldStandsAtTheReach() {
        for exponential in [false, true] {
            // Six images left of 383: a request for ten fuses the six, and reads them.
            let near = regular(383, every: 1, thickness: 1, current: 377)
            #expect(near.available == 6 && near.effectiveCount(requested: 10) == 6)
            #expect(near.text(requested: 10, locale: english) == "6.0 mm")
            let reach = near.reach(exponential: exponential)
            #expect(reach == near.trackPosition(ofStop: 6, exponential: exponential))
            #expect(reach > 0 && reach < near.trackPosition(ofStop: 10, exponential: exponential))
            #expect(near.position(ofCount: 10, exponential: exponential) == reach)
            // A smaller request is where it was.
            #expect(near.position(ofCount: 4, exponential: exponential) == near.trackPosition(ofStop: 4, exponential: exponential))
            // No place of the track gives more than the images left; within them, each its stop.
            for step in 0...200 { #expect(near.count(at: Double(step) / 200, exponential: exponential) <= 6) }
            #expect(near.count(at: 1, exponential: exponential) == 6 && near.count(at: reach, exponential: exponential) == 6)
            #expect((1...6).allSatisfy { near.count(at: near.trackPosition(ofStop: $0, exponential: exponential), exponential: exponential) == $0 })
            // One image earlier the reach is one stop further; with all the series before the image it is the whole track.
            #expect(regular(383, every: 1, thickness: 1, current: 376).reach(exponential: exponential) > reach)
            #expect(regular(383, every: 1, thickness: 1, current: 0).reach(exponential: exponential) == 1)
            // Flipped data: the same from the other end.
            let flipped = regular(383, every: 1, thickness: 1, current: 5, towardsStart: true)
            #expect(flipped.available == 6 && flipped.reach(exponential: exponential) == reach)
            #expect(flipped.position(ofCount: 10, exponential: exponential) == reach)
            #expect(regular(383, every: 1, thickness: 1, current: 382, towardsStart: true).reach(exponential: exponential) == 1)
        }
    }

    @Test func theLastImageKeepsTheTrackAndHasNoReach() {
        for (current, towardsStart) in [(382, false), (0, true)] {
            let last = regular(383, every: 1, thickness: 1, current: current, towardsStart: towardsStart)
            #expect(last.available == 1 && last.stops == [1] && last.trackStops.count == 383)
            #expect(last.text(requested: 10, locale: english) == "1.0 mm")
            for exponential in [false, true] {
                #expect(last.reach(exponential: exponential) == 0 && last.position(ofCount: 10, exponential: exponential) == 0)
                #expect(last.count(at: 0.5, exponential: exponential) == 1 && last.count(at: 1, exponential: exponential) == 1)
                #expect(last.tickCounts(minimumSpacing: 8.0 / 175).last == 383)
            }
        }
        // A series of one image has one stop and no track: nothing to reach, nothing beyond.
        let single = regular(1, every: 1, thickness: 1, current: 0, capacity: 1)
        #expect(single.trackStops == [1] && single.reach(exponential: false) == 1 && single.position(ofCount: 3, exponential: false) == 0)
        #expect(single.tickCounts(minimumSpacing: 8.0 / 175).isEmpty)
        // A slab of two images at least: its track starts at two, and the last image, which has no slab, reaches none of it.
        let pairs = StackFusionScale(positions: (0..<60).map { Double($0) * 2 }, current: 59, towardsStart: false, sliceThickness: 2,
                                     fallbackInterval: 2, capacity: 60, minimumImages: 2)
        #expect(pairs.floor == 1 && pairs.reach(exponential: false) == 0)
        #expect(pairs.tickCounts(minimumSpacing: 8.0 / 175).first == 2)
        let before = StackFusionScale(positions: (0..<60).map { Double($0) * 2 }, current: 30, towardsStart: false, sliceThickness: 2,
                                      fallbackInterval: 2, capacity: 60, minimumImages: 2)
        #expect(before.position(ofCount: 2, exponential: false) == 0 && before.reach(exponential: false) == (60.0 - 4) / (120 - 4))
    }

    /// Images that are not evenly spaced: the request keeps its place, and the text says what its images make where they are.
    @Test func anIrregularSeriesKeepsTheKnobStillAndWritesWhatIsFused() {
        let positions: [Double] = [0, 1, 2, 3, 8, 13, 18, 23]
        let start = StackFusionScale(positions: positions, current: 0, towardsStart: false, sliceThickness: 1, fallbackInterval: 1, capacity: 8)
        let later = StackFusionScale(positions: positions, current: 3, towardsStart: false, sliceThickness: 1, fallbackInterval: 1, capacity: 8)
        #expect(later.trackStops == start.trackStops && later.stops == [1, 6, 11, 16, 21])
        for exponential in [false, true] {
            #expect(later.position(ofCount: 3, exponential: exponential) == start.position(ofCount: 3, exponential: exponential))
            #expect(later.reach(exponential: exponential) == start.trackPosition(ofStop: 5, exponential: exponential))
        }
        #expect(start.text(requested: 3, locale: english) == "3.0 mm" && later.text(requested: 3, locale: english) == "11.0 mm")
        // Thin steps anywhere in the series give every image the same decimals.
        let fine = StackFusionScale(positions: [0, 0.05, 0.1, 1, 2, 3], current: 3, towardsStart: false, sliceThickness: 0.3,
                                    fallbackInterval: 1, capacity: 6)
        #expect(fine.text(requested: 2, locale: english) == "1.30 mm")
    }

    @Test func aThicknessIsWrittenWithTheSeparatorOfTheRegionAndNoGrouping() {
        let scale = regular(80, every: 1, thickness: 2, current: 0)
        #expect(scale.text(requested: 2, locale: italian) == "3,0 mm")
        #expect(scale.text(requested: 2, locale: english) == "3.0 mm")
        let long = regular(2000, every: 1, thickness: 1, current: 0, capacity: 2000)
        #expect(long.text(requested: 1536, locale: italian) == "1536,0 mm")
        #expect(long.text(requested: 1536, locale: english) == "1536.0 mm")
        // Halves round away from zero, so 1.25 mm is 1.3 and not 1.2.
        let quarters = regular(8, every: 1.25, thickness: 1.25, current: 0)
        #expect((1...4).map { quarters.text(requested: $0, locale: english) } == ["1.3 mm", "2.5 mm", "3.8 mm", "5.0 mm"])
        // No request, or a negative one, is the one image.
        #expect(scale.text(requested: 0, locale: english) == "2.0 mm" && scale.text(requested: -4, locale: english) == "2.0 mm")
    }

    @Test func aRequestKeepsItsMillimetresInAnotherPlane() {
        func images(_ thickness: Double?, _ slice: Double, _ interval: Double) -> Int? {
            thickness.flatMap { StackFusionScale.count(forThickness: $0, sliceThickness: slice, interval: interval) }
        }
        // Ten slices of 2 mm are 20 mm: twenty slices of 1 mm across them, and ten again on the way back.
        let axial = StackFusionScale.requestedThickness(count: 10, sliceThickness: 2, interval: 2)
        #expect(axial == 20)
        #expect(images(axial, 1, 1) == 20)
        #expect(StackFusionScale.requestedThickness(count: 20, sliceThickness: 1, interval: 1) == 20)
        #expect(images(axial, 2, 2) == 10)
        // 6.25 mm of 0.625 mm slices are nine slices of 0.7 mm, 6.3 mm; the request kept is ten again.
        let fine = StackFusionScale.requestedThickness(count: 10, sliceThickness: 0.625, interval: 0.625)
        #expect(fine == 6.25)
        #expect(images(fine, 0.7, 0.7) == 9)
        #expect(images(fine, 0.625, -0.625) == 10)
        // Overlapping slices, and a series that says one of the two only.
        #expect(StackFusionScale.requestedThickness(count: 10, sliceThickness: 2, interval: 1) == 11)
        #expect(images(11, 2, 1) == 10)
        #expect(StackFusionScale.requestedThickness(count: 5, sliceThickness: 0, interval: 2) == 10)
        #expect(StackFusionScale.requestedThickness(count: 5, sliceThickness: 2, interval: 0) == 10)
        #expect(images(10, 0, 2) == 5)
        // A thickness below one slice is one image: the window keeps two while the slab is on.
        #expect(images(0.5, 2, 2) == 1)
        #expect(images(3.1, 2, 2) == 2)
        // More than the series has is still asked for: the bar shows what is fused.
        #expect(images(500, 1, 1) == 500)
        // No geometry, no request.
        #expect(StackFusionScale.requestedThickness(count: 5, sliceThickness: 0, interval: 0) == nil)
        #expect(StackFusionScale.requestedThickness(count: 5, sliceThickness: .nan, interval: .nan) == nil)
        #expect(images(10, 0, 0) == nil)
        #expect(images(.nan, 2, 2) == nil)
    }
}
