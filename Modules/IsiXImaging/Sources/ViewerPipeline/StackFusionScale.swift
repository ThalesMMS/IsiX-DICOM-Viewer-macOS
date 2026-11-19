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

/// The scale of a 2D viewer's thick slab at the image it shows: the
/// thicknesses the slab can have there, in millimetres, where the slider's
/// knob stands for each, the marks along its track and the text written for
/// it.
///
/// The slab fuses the image shown with those after it, towards the end of the
/// series, or towards its start when the data is flipped, and stops where the
/// series does. So the thicknesses it can have depend on the image: from the
/// one of a single slice, S0, to that of the `available` images left, and
/// each image more adds the distance to it along the normal of the slices.
/// With slices that overlap (2 mm every 1 mm) two images cover 3 mm, and with
/// slices that touch (2 mm every 2 mm) they cover 4.
///
/// The slider keeps what the user asked for, in images. This scale says what
/// that request is at the image shown: the images really fused
/// (`effectiveCount`), their thickness, and one text for the slider's bubble
/// and the toolbar. A request for more images than are left shows the
/// thickness of those left, and comes back whole where the series has them.
///
/// A series that says neither how thick its slices are nor where they are
/// counts images: there are no millimetres to show.
public struct StackFusionScale: Sendable, Equatable {
    /// The images the slab can fuse from the current one, itself included:
    /// those left to the end of the series in the slab's direction, within
    /// the slider's capacity; one at least.
    public let available: Int
    /// The fewest images of a slab on this track: one in the 2D viewer, whose
    /// slider also switches the slab off; two where a control of its own
    /// does that (the orthogonal MPR). Never more than `available`.
    public let floor: Int
    /// The thickness of a slab of 1 … `available` images, never decreasing:
    /// millimetres, or the counts themselves when the scale is not physical.
    public let stops: [Double]
    /// Whether the stops are millimetres.
    public let isPhysical: Bool
    /// The decimals a thickness is written with: one, or two when two
    /// neighbouring stops are less than a tenth of a millimetre apart, so
    /// that they never read the same and the digits do not change in a drag.
    private let decimals: Int

    /// - Parameters:
    ///   - positions: where each image of the movie frame stands along one
    ///     normal, in millimetres, in the viewer's order; NaN where unknown.
    ///   - current: the index of the image shown.
    ///   - towardsStart: the slab runs towards index 0 (flipped data).
    ///   - sliceThickness: the SliceThickness of the image shown; none when
    ///     not above zero.
    ///   - fallbackInterval: the interval of the series, for a slice with no
    ///     thickness and for positions that are not known.
    ///   - capacity: the most images the slider can ask for.
    ///   - minimumImages: the fewest images of a slab on this track.
    public init(positions: [Double], current: Int, towardsStart: Bool, sliceThickness: Double, fallbackInterval: Double, capacity: Int,
                minimumImages: Int = 1) {
        let count = positions.count
        let available = Self.available(current: current, count: count, towardsStart: towardsStart, capacity: capacity)
        let direction = towardsStart ? -1 : 1
        func position(_ offset: Int) -> Double {
            let index = current + direction * offset
            return index >= 0 && index < count ? positions[index] : .nan
        }
        let interval = fallbackInterval.isFinite ? abs(fallbackInterval) : 0

        // How far the slab reaches with each image more: the span of the
        // positions fused, whichever their order; nil when one is unknown.
        var extents: [Double]? = []
        var low = Double.infinity, high = -Double.infinity
        for offset in 0..<available {
            let place = position(offset)
            guard place.isFinite else { extents = nil; break }
            low = min(low, place)
            high = max(high, place)
            extents?.append(high - low)
        }
        // Images that all stand at one place say nothing of a thickness.
        // Only a slab with no extent at all can be of such a series.
        var flat = false
        if count > 1, let reach = extents?.last, reach == 0 {
            flat = positions.allSatisfy { $0 == positions[0] }
            if flat { extents = nil }
        }

        // One slice: its thickness, else the distance to its neighbour in
        // the slab's direction, or to the other one at the series' end.
        var first = sliceThickness.isFinite && sliceThickness > 0 ? sliceThickness : 0
        if first == 0, !flat {
            let apart = abs(position(available > 1 ? 1 : -1) - position(0))
            if apart.isFinite, apart > 0 { first = apart }
        }
        if first == 0 { first = interval }

        self.available = available
        floor = min(max(1, minimumImages), available)
        if let extents, first > 0 {
            stops = extents.map { first + $0 }
            isPhysical = true
        } else if first > 0, !flat || interval > 0 {
            // Positions that are not known yet: a regular series.
            let step = interval > 0 ? interval : first
            stops = (0..<available).map { first + Double($0) * step }
            isPhysical = true
        } else {
            stops = (1...available).map(Double.init)
            isPhysical = false
        }
        var finest = Double.infinity
        for index in stops.indices.dropFirst() where stops[index] > stops[index - 1] {
            finest = min(finest, stops[index] - stops[index - 1])
        }
        decimals = finest < 0.1 ? 2 : 1
    }

    /// The images left from `current` to the end of a series of `count` in
    /// the slab's direction, the current one included, within `capacity`.
    public static func available(current: Int, count: Int, towardsStart: Bool, capacity: Int) -> Int {
        guard current >= 0, current < count else { return 1 }
        return max(1, min(towardsStart ? current + 1 : count - current, capacity))
    }

    /// The thickness a request for `count` images has in a series of slices
    /// `sliceThickness` thick every `interval`, wherever the series ends: what
    /// the user asked for, in millimetres, which a change of plane keeps.
    /// Nil for a series that says neither.
    public static func requestedThickness(count: Int, sliceThickness: Double, interval: Double) -> Double? {
        guard let (first, step) = regular(sliceThickness: sliceThickness, interval: interval) else { return nil }
        return first + Double(max(1, count) - 1) * step
    }

    /// The images whose slab is nearest to `thickness` in such a series: the
    /// request that thickness is in another plane of the volume.
    public static func count(forThickness thickness: Double, sliceThickness: Double, interval: Double) -> Int? {
        guard thickness.isFinite, let (first, step) = regular(sliceThickness: sliceThickness, interval: interval) else { return nil }
        return Int(min(max(((thickness - first) / step).rounded(), 0), Double(Int32.max - 1))) + 1
    }

    /// One slice and the step to the next of a regular series: the thickness
    /// and the interval, each standing for the other when it is missing.
    private static func regular(sliceThickness: Double, interval: Double) -> (first: Double, step: Double)? {
        let apart = interval.isFinite ? abs(interval) : 0
        let first = sliceThickness.isFinite && sliceThickness > 0 ? sliceThickness : apart
        guard first > 0 else { return nil }
        return (first, apart > 0 ? apart : first)
    }

    /// Where each image stands along `normal`: its origin projected on it.
    /// `origins` holds x, y, z of each image. Without a normal, `locations`.
    public static func positions(origins: [Double], normal: [Double], locations: [Double]) -> [Double] {
        guard normal.count == 3 else { return locations }
        let length = (normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]).squareRoot()
        guard length.isFinite, length >= 0.5 else { return locations }
        return (0..<origins.count / 3).map {
            (origins[3 * $0] * normal[0] + origins[3 * $0 + 1] * normal[1] + origins[3 * $0 + 2] * normal[2]) / length
        }
    }

    /// The thin end of the track: one image, or the fewest of a slab here.
    public var minimum: Double { stops[floor - 1] }
    /// The thick end of the track: every image left.
    public var maximum: Double { stops[stops.count - 1] }

    /// The images a request for `requested` fuses at this image.
    public func effectiveCount(requested: Int) -> Int { min(max(floor, requested), available) }

    /// The thickness a request for `requested` images has at this image.
    public func thickness(requested: Int) -> Double { stops[effectiveCount(requested: requested) - 1] }

    private func curve(_ exponential: Bool) -> ThickSlabSliderScale {
        ThickSlabSliderScale(minimum: minimum, maximum: maximum, exponential: exponential)
    }

    /// Where the knob stands on the track, 0 … 1, for a request for `count` images.
    public func position(ofCount count: Int, exponential: Bool) -> Double {
        curve(exponential).position(for: thickness(requested: count))
    }

    /// The images of the stop nearest to a place on the track; the fewest of
    /// those that make the same thickness.
    public func count(at position: Double, exponential: Bool) -> Int {
        guard maximum > minimum else { return floor }
        let scale = curve(exponential)
        let target = position.isNaN ? 0 : min(1, max(0, position))
        // The first stop at or after the place, then the nearer of it and the one before.
        var low = floor - 1, high = stops.count - 1
        while low < high {
            let middle = (low + high) / 2
            if scale.position(for: stops[middle]) < target { low = middle + 1 } else { high = middle }
        }
        if low > floor - 1, target - scale.position(for: stops[low - 1]) <= scale.position(for: stops[low]) - target { low -= 1 }
        return max(floor, firstIndex(reaching: stops[low]) + 1)
    }

    /// The first stop that is at least `thickness`.
    private func firstIndex(reaching thickness: Double) -> Int {
        var low = 0, high = stops.count - 1
        while low < high {
            let middle = (low + high) / 2
            if stops[middle] < thickness { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The most intervals the marks divide the track in, from the ruler of a
    /// long track to that of a short one.
    private static let divisions = [10, 5, 2]

    /// The marks along the track, as the images of the stop each stands on:
    /// both ends, and between them stops never closer than `minimumSpacing`
    /// of the track. None for a single stop.
    ///
    /// On the linear curve the marks are equal steps of millimetres from the
    /// thin end, whole numbers of the usual distance between two images, each
    /// taken to the nearest stop; a mark less than half a step before the
    /// thick end gives way to it. On the logarithmic curve they are the stops
    /// nearest to equal shares of the track, each the same ratio of thickness.
    public func tickCounts(minimumSpacing: Double, exponential: Bool) -> [Int] {
        guard maximum > minimum else { return [] }
        let scale = curve(exponential)
        let spacing = minimumSpacing.isFinite ? max(minimumSpacing, 0) : 0
        guard let intervals = Self.divisions.first(where: { 1 / Double($0) >= spacing }) else { return [floor, available] }
        var targets: [Double] = []
        var margin = 0.0
        if scale.exponential {
            targets = (1..<intervals).map { minimum * pow(maximum / minimum, Double($0) / Double(intervals)) }
        } else {
            let steps = zip(stops, stops.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
            let usual = steps[steps.count / 2]
            let step = usual * max(1, ((maximum - minimum) / (Double(intervals) * usual) - 1e-9).rounded(.up))
            var number = 1.0
            while minimum + number * step < maximum - 1e-9 {
                targets.append(minimum + number * step)
                number += 1
            }
            margin = step / 2
        }
        let edge = max(spacing, 1e-9)
        var marks = [floor]
        var last = 0.0
        for target in targets {
            let count = count(at: scale.position(for: target), exponential: exponential)
            let place = scale.position(for: stops[count - 1])
            guard place - last >= edge, 1 - place >= edge, maximum - stops[count - 1] >= margin else { continue }
            marks.append(count)
            last = place
        }
        return marks + [available]
    }

    /// What the slider's bubble and the toolbar write for a request: the
    /// thickness fused at this image, in millimetres, with the decimal
    /// separator of the region and no grouping; the count of images for a
    /// scale that is not physical.
    ///
    /// The separator is the one the user set for numbers in the system
    /// (SlabThicknessText). A half rounds away from zero, so 1.25 mm reads 1.3.
    public func text(requested: Int, locale: Locale = .autoupdatingCurrent) -> String {
        guard isPhysical else { return write(Double(effectiveCount(requested: requested)), decimals: 0, locale) }
        let unit = pow(10, Double(decimals))
        let rounded = (thickness(requested: requested) * unit).rounded(.toNearestOrAwayFromZero) / unit
        return write(rounded, decimals: decimals, locale) + " mm"
    }

    private func write(_ number: Double, decimals: Int, _ locale: Locale) -> String {
        SlabThicknessText.write(number, minimumDecimals: decimals, maximumDecimals: decimals, locale: locale)
    }
}
