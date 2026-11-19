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
/// The slider's track does not depend on the image. It is the ruler of the
/// series in the slab's direction (`trackStops`): from S0 to the thickness of
/// all the images the slider can ask for, or of the whole series when it has
/// fewer, counted from the end of the series the slab runs away from. A
/// request has one place on it wherever the image shown is, so the knob
/// stays still while the series scrolls under it. What changes with the image
/// is how far along the track the slab can go (`reach`): the track beyond is
/// of images the series does not have from there, the knob does not pass it,
/// and a request for more stands at the reach.
///
/// The slider keeps what the user asked for, in images. This scale says what
/// that request is at the image shown: the images really fused
/// (`effectiveCount`), their thickness, and one text for the slider's bubble
/// and the toolbar. A request for more images than are left shows the
/// thickness of those left, and comes back whole where the series has them.
/// In a series whose images are not evenly spaced a request keeps its place
/// on the track too, and the text says what its images make where they are.
///
/// A series that says neither how thick its slices are nor where they are
/// counts images: there are no millimetres to show.
public struct StackFusionScale: Sendable, Equatable {
    /// The images the slab can fuse from the current one, itself included:
    /// those left to the end of the series in the slab's direction, within
    /// the slider's capacity; one at least.
    public let available: Int
    /// The fewest images of a slab at the image shown: one in the 2D viewer,
    /// whose slider also switches the slab off; two where a control of its
    /// own does that (the orthogonal MPR). Never more than `available`.
    public let floor: Int
    /// The thickness of a slab of 1 … `available` images, never decreasing:
    /// millimetres, or the counts themselves when the scale is not physical.
    public let stops: [Double]
    /// Whether the stops are millimetres.
    public let isPhysical: Bool
    /// The ruler of the track: the thickness of a slab of 1 … n images from
    /// the end of the series the slab runs away from, n being the slider's
    /// capacity or the images of the series when they are fewer. The same at
    /// every image of a series, in one direction.
    public let trackStops: [Double]
    /// The fewest images of a slab on the track: the images of its thin end.
    private let trackFloor: Int
    /// The decimals a thickness is written with: one, or two when two
    /// neighbouring stops are less than a tenth of a millimetre apart, so
    /// that they never read the same and the digits do not change in a drag
    /// nor from one image to the next.
    private let decimals: Int

    /// - Parameters:
    ///   - positions: where each image of the movie frame stands along one
    ///     normal, in millimetres, in the viewer's order; NaN where unknown.
    ///   - current: the index of the image shown.
    ///   - towardsStart: the slab runs towards index 0 (flipped data).
    ///   - sliceThickness: the SliceThickness of the image shown; none when
    ///     not above zero. A series has one for all its images, and the
    ///     track is measured with it.
    ///   - fallbackInterval: the interval of the series, for a slice with no
    ///     thickness and for positions that are not known.
    ///   - capacity: the most images the slider can ask for.
    ///   - minimumImages: the fewest images of a slab on this track.
    public init(positions: [Double], current: Int, towardsStart: Bool, sliceThickness: Double, fallbackInterval: Double, capacity: Int,
                minimumImages: Int = 1) {
        let count = positions.count
        let available = Self.available(current: current, count: count, towardsStart: towardsStart, capacity: capacity)
        let direction = towardsStart ? -1 : 1
        let interval = fallbackInterval.isFinite ? abs(fallbackInterval) : 0
        let shown = Self.ruler(positions: positions, from: current, direction: direction, images: available,
                               sliceThickness: sliceThickness, interval: interval)
        // The track starts where the slab has the whole series before it.
        let origin = towardsStart ? count - 1 : 0
        let extent = max(1, min(count, capacity))
        let track = current == origin && available == extent ? shown
            : Self.ruler(positions: positions, from: origin, direction: direction, images: extent,
                         sliceThickness: sliceThickness, interval: interval)

        self.available = available
        floor = min(max(1, minimumImages), available)
        stops = shown.stops
        isPhysical = shown.isPhysical
        trackStops = track.stops
        trackFloor = min(max(1, minimumImages), extent)
        var finest = Double.infinity
        for ruler in [shown.stops, track.stops] {
            for index in ruler.indices.dropFirst() where ruler[index] > ruler[index - 1] {
                finest = min(finest, ruler[index] - ruler[index - 1])
            }
        }
        decimals = finest < 0.1 ? 2 : 1
    }

    /// The thicknesses of a slab of 1 … `images` images that starts at the
    /// image `start` and goes on by `direction`, and whether they are
    /// millimetres.
    private static func ruler(positions: [Double], from start: Int, direction: Int, images: Int, sliceThickness: Double,
                              interval: Double) -> (stops: [Double], isPhysical: Bool) {
        let count = positions.count
        func position(_ offset: Int) -> Double {
            let index = start + direction * offset
            return index >= 0 && index < count ? positions[index] : .nan
        }

        // How far the slab reaches with each image more: the span of the
        // positions fused, whichever their order; nil when one is unknown.
        var extents: [Double]? = []
        var low = Double.infinity, high = -Double.infinity
        for offset in 0..<images {
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
            let apart = abs(position(images > 1 ? 1 : -1) - position(0))
            if apart.isFinite, apart > 0 { first = apart }
        }
        if first == 0 { first = interval }

        if let extents, first > 0 {
            return (extents.map { first + $0 }, true)
        }
        if first > 0, !flat || interval > 0 {
            // Positions that are not known yet: a regular series.
            let step = interval > 0 ? interval : first
            return ((0..<images).map { first + Double($0) * step }, true)
        }
        return ((1...images).map(Double.init), false)
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

    /// The thinnest slab at the image shown: one image, or the fewest of a slab here.
    public var minimum: Double { stops[floor - 1] }
    /// The thickest slab at the image shown: every image left.
    public var maximum: Double { stops[stops.count - 1] }

    /// The images a request for `requested` fuses at this image.
    public func effectiveCount(requested: Int) -> Int { min(max(floor, requested), available) }

    /// The thickness a request for `requested` images has at this image.
    public func thickness(requested: Int) -> Double { stops[effectiveCount(requested: requested) - 1] }

    /// The curve of the track, between the thicknesses of its two ends.
    private func curve(_ exponential: Bool) -> ThickSlabSliderScale {
        ThickSlabSliderScale(minimum: trackStops[trackFloor - 1], maximum: trackStops[trackStops.count - 1], exponential: exponential)
    }

    /// Where the stop of `count` images stands on the track, 0 … 1, whether
    /// the image shown reaches it or not: the place of a mark.
    public func trackPosition(ofStop count: Int, exponential: Bool) -> Double {
        curve(exponential).position(for: trackStops[min(max(1, count), trackStops.count) - 1])
    }

    /// How far along the track the slab can go at the image shown, 0 … 1: the
    /// place of the stop of the images left. The whole track where the image
    /// has every image of it before it.
    public func reach(exponential: Bool) -> Double {
        available >= trackStops.count ? 1 : trackPosition(ofStop: available, exponential: exponential)
    }

    /// Where the knob stands on the track, 0 … 1, for a request for `count`
    /// images: at the stop of the images fused, the same at every image that
    /// has them, and at the reach for a request the image cannot hold whole.
    public func position(ofCount count: Int, exponential: Bool) -> Double {
        trackPosition(ofStop: effectiveCount(requested: count), exponential: exponential)
    }

    /// The images of the stop nearest to a place on the track, among those
    /// the image shown reaches; the fewest of those that make the same
    /// thickness.
    public func count(at position: Double, exponential: Bool) -> Int {
        nearestStop(to: position, exponential: exponential, from: floor, through: available)
    }

    /// The stop of `fewest` … `most` images nearest to a place on the track.
    private func nearestStop(to position: Double, exponential: Bool, from fewest: Int, through most: Int) -> Int {
        guard most > fewest, trackStops[most - 1] > trackStops[fewest - 1] else { return fewest }
        let scale = curve(exponential)
        let target = position.isNaN ? 0 : min(1, max(0, position))
        // The first stop at or after the place, then the nearer of it and the one before.
        var low = fewest - 1, high = most - 1
        while low < high {
            let middle = (low + high) / 2
            if scale.position(for: trackStops[middle]) < target { low = middle + 1 } else { high = middle }
        }
        if low > fewest - 1, target - scale.position(for: trackStops[low - 1]) <= scale.position(for: trackStops[low]) - target { low -= 1 }
        return max(fewest, firstIndex(reaching: trackStops[low]) + 1)
    }

    /// The first stop of the track that is at least `thickness`.
    private func firstIndex(reaching thickness: Double) -> Int {
        var low = 0, high = trackStops.count - 1
        while low < high {
            let middle = (low + high) / 2
            if trackStops[middle] < thickness { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The most intervals the marks divide the track in, from the ruler of a
    /// long track to that of a short one.
    private static let divisions = [10, 5, 2]

    /// Where the marks stand along the track, 0 … 1, both ends included; none
    /// for a single stop. They are the marks of the series, the same at every
    /// image, those beyond the reach included.
    ///
    /// On the linear curve they are the stops of `tickCounts`, evenly spaced:
    /// the knob stops on each. On the exponential curve they draw the curve
    /// (`ThickSlabSliderScale.tickPositions`): far apart at the thin end and
    /// closer at every step towards the thick one, no more intervals than
    /// the track has stops. Those are not stops: the knob stops where the
    /// images put it between them.
    public func tickPlaces(minimumSpacing: Double, exponential: Bool) -> [Double] {
        let scale = curve(exponential)
        guard scale.exponential else {
            return tickCounts(minimumSpacing: minimumSpacing).map { trackPosition(ofStop: $0, exponential: false) }
        }
        return scale.tickPositions(minimumSpacing: minimumSpacing, most: trackStops.count - trackFloor)
    }

    /// The marks of the linear track, as the images of the stop each stands
    /// on: both ends, and between them stops never closer than
    /// `minimumSpacing` of the track. None for a single stop.
    ///
    /// They are equal steps of millimetres from the thin end, whole numbers
    /// of the usual distance between two images, each taken to the nearest
    /// stop; a mark less than half a step before the thick end gives way to
    /// it.
    public func tickCounts(minimumSpacing: Double) -> [Int] {
        let last = trackStops.count
        let minimum = trackStops[trackFloor - 1], maximum = trackStops[last - 1]
        guard maximum > minimum else { return [] }
        let scale = curve(false)
        let spacing = minimumSpacing.isFinite ? max(minimumSpacing, 0) : 0
        guard let intervals = Self.divisions.first(where: { 1 / Double($0) >= spacing }) else { return [trackFloor, last] }
        let steps = zip(trackStops, trackStops.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
        let usual = steps[steps.count / 2]
        let step = usual * max(1, ((maximum - minimum) / (Double(intervals) * usual) - 1e-9).rounded(.up))
        var targets: [Double] = []
        var number = 1.0
        while minimum + number * step < maximum - 1e-9 {
            targets.append(minimum + number * step)
            number += 1
        }
        let margin = step / 2
        let edge = max(spacing, 1e-9)
        var marks = [trackFloor]
        var passed = 0.0
        for target in targets {
            let count = nearestStop(to: scale.position(for: target), exponential: false, from: trackFloor, through: last)
            let place = scale.position(for: trackStops[count - 1])
            guard place - passed >= edge, 1 - place >= edge, maximum - trackStops[count - 1] >= margin else { continue }
            marks.append(count)
            passed = place
        }
        return marks + [last]
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
