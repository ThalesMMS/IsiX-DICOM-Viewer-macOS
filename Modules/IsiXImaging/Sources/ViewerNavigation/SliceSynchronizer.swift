/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

// How a 2D view follows another's slice: the plane of its series nearest a
// point of the patient, the slice nearest a location when the series are not
// loaded yet, the index a stack of phases expects, the tolerance under which
// two planes are parallel, and the reference lines and the patient crosshair
// that the cut of the other slice draws. The view reads its images into these
// values and applies the answer; the rules are here.

/// The synchronization mode every 2D view shares (the Sync menu's), and
/// whether the views answer the sync messages at all. Only the views and the
/// viewers, on the main actor, read and write them.
@MainActor public enum SliceSyncSettings {
    /// syncroOFF, syncroABS, syncroREL, syncroLOC or syncroRatio of DCMView.h;
    /// another value is kept as it was set.
    public static var mode: Int16 = SliceSynchronizer.Mode.location
    /// Off while a viewer moves several views at once, so they do not follow each other.
    public static var listensToMessages = true
}

public struct SliceSynchronizer: Sendable {

    /// The syncro modes of DCMView.h.
    public enum Mode {
        public static let off: Int16 = 0
        public static let absolute: Int16 = 1
        public static let relative: Int16 = 2
        public static let location: Int16 = 3
        public static let ratio: Int16 = 4
    }

    /// Planes this close are the same position for synchronization: a series
    /// with several phases or types stacked one after the other repeats each
    /// position once per sub-stack.
    public static let samePositionTolerance: Float = 0.01
    /// The angle (radians) under which a manually synchronised pair is
    /// parallel: about 45 degrees.
    public static let manualPlaneTolerance: Float = 0.78
    /// The distance a plane search answers when no plane was selected.
    public static let noDistance: Float = 999999

    /// The angle under which a plane of the receiver is parallel to the
    /// direction a search prefers (PARALLELPLANETOLERANCE).
    public var parallelPlaneTolerance: Float
    /// The angle under which two series are parallel enough to follow each
    /// other by location (PARALLELPLANETOLERANCE-Sync).
    public var syncPlaneTolerance: Float

    public init(parallelPlaneTolerance: Float, syncPlaneTolerance: Float) {
        self.parallelPlaneTolerance = parallelPlaneTolerance
        self.syncPlaneTolerance = syncPlaneTolerance
    }

    // MARK: - Which slice

    /// Whether two series are parallel enough to follow each other by
    /// location: under the sync tolerance, or about 45 degrees when the
    /// receiver is synchronised by hand.
    public func followsByLocation(receiverNormal: SIMD3<Float>, sourceNormal: SIMD3<Float>, manual: Bool) -> Bool {
        Self.angle(receiverNormal, sourceNormal) < (manual ? Self.manualPlaneTolerance : syncPlaneTolerance)
    }

    /// The index the receiver would reach by moving from its current image to
    /// `target` without leaving its sub-stack: the step between neighbouring
    /// images is taken on the side that stays in the sub-stack (the smaller
    /// change of position), since the other side of a sub-stack's first or
    /// last image jumps back across the whole range. NaN when it is unknown.
    public static func expectedIndex(current: Int, count: Int, target: Float, position: (Int) -> Float) -> Double {
        guard current >= 0, current < count else { return .nan }
        let here = position(current)
        var step: Float = 0
        if current + 1 < count { step = position(current + 1) - here }
        if current > 0 {
            let back = here - position(current - 1)
            if step == 0 || (back != 0 && abs(back) < abs(step)) { step = back }
        }
        if step == 0 { return Double(current) }
        return Double(current) + Double((target - here) / step)
    }

    /// Whether a candidate slice replaces the one selected so far when a
    /// viewer synchronizes to another's position. The nearer plane wins; at the
    /// same position, the image type of the source, then the slice nearest the
    /// index expected in the receiver's own sub-stack, so each viewer stays in
    /// the phase it shows instead of jumping to the first or last one that
    /// repeats the position.
    public static func candidateWins(distance: Float, selectedDistance: Float,
                                     matchingType: Bool, selectedMatchingType: Bool,
                                     index: Int, selectedIndex: Int, expectedIndex: Double) -> Bool {
        if selectedIndex < 0 || distance < selectedDistance - samePositionTolerance { return true }
        if distance > selectedDistance + samePositionTolerance { return false }
        if matchingType != selectedMatchingType { return matchingType }
        return !expectedIndex.isNaN && abs(Double(index) - expectedIndex) < abs(Double(selectedIndex) - expectedIndex)
    }

    /// A plane of the receiver's series: the normal of its orientation, its
    /// origin, and whether its image type is the one the search prefers.
    public struct Plane: Sendable, Equatable {
        public var normal: SIMD3<Float>
        public var origin: SIMD3<Float>
        public var matchesType: Bool

        public init(normal: SIMD3<Float>, origin: SIMD3<Float>, matchesType: Bool) {
            self.normal = normal
            self.origin = origin
            self.matchesType = matchesType
        }
    }

    /// What a plane search found: the plane (nil for none), its distance to
    /// the point (noDistance for none) and the point's projection on it.
    public struct PlaneSearch: Sendable, Equatable {
        public var index: Int?
        public var distance: Float
        public var location: SIMD3<Float>?

        public init(index: Int?, distance: Float, location: SIMD3<Float>?) {
            self.index = index
            self.distance = distance
            self.location = location
        }
    }

    /// The plane of `planes` nearest `point`: a plane parallel to `parallelTo`
    /// first, then the nearer one; at the same distance the preferred image
    /// type, then the plane nearest the index the receiver's `current` plane
    /// (whose normal is `currentNormal`) expects in its own sub-stack.
    public func nearestPlane(to point: SIMD3<Float>, among planes: [Plane], parallelTo direction: SIMD3<Float>?,
                             current: Int?, currentNormal: SIMD3<Float>?) -> PlaneSearch {
        var expected = Double.nan
        if let current, let normal = currentNormal {
            func along(_ p: SIMD3<Float>) -> Float { p.x * normal.x + p.y * normal.y + p.z * normal.z }
            expected = Self.expectedIndex(current: current, count: planes.count, target: along(point)) { along(planes[$0].origin) }
        }
        var found = PlaneSearch(index: nil, distance: Self.noDistance, location: nil)
        var selectedParallel = false
        for (index, plane) in planes.enumerated() {
            let parallel = direction.map { Self.angle($0, plane.normal) < parallelPlaneTolerance } ?? false
            var projection = SIMD3<Float>()
            let distance = Self.planeBase(point, plane.origin, plane.normal, &projection)
            let selectedMatchingType = found.index.map { planes[$0].matchesType } ?? false
            if (!selectedParallel && parallel) || (parallel == selectedParallel &&
                Self.candidateWins(distance: distance, selectedDistance: found.distance,
                                   matchingType: plane.matchesType, selectedMatchingType: selectedMatchingType,
                                   index: index, selectedIndex: found.index ?? -1, expectedIndex: expected)) {
                selectedParallel = parallel
                found = PlaneSearch(index: index, distance: distance, location: projection)
            }
        }
        return found
    }

    /// Whether a plane found at `distance` is the receiver's: not farther than
    /// twice the slice thickness, when the image has one.
    public static func accepts(distance: Float, sliceThickness: Double) -> Bool {
        sliceThickness == 0 || Double(distance) <= sliceThickness * 2
    }

    /// What a location search found: the slice (-1 when there is none) and
    /// its distance (-1 then).
    public struct LocationSearch: Sendable, Equatable {
        public var index: Int
        public var distance: Float

        public init(index: Int, distance: Float) {
            self.index = index
            self.distance = distance
        }
    }

    /// The slice of `count` whose location is nearest `target`, with the same
    /// preferences as the plane search, for series not loaded yet or
    /// synchronised by hand. `correction`, the difference of the two manual
    /// offsets, is taken off every location when both series are synchronised
    /// by hand across 3D worlds.
    public static func nearestLocation(count: Int, current: Int, target: Float, correction: Float?,
                                       location: (Int) -> Float, matchesType: (Int) -> Bool) -> LocationSearch {
        func corrected(_ i: Int) -> Float {
            let position = location(i)
            return correction.map { position - $0 } ?? position
        }
        let expected = expectedIndex(current: current, count: count, target: target, position: corrected)
        var found = LocationSearch(index: -1, distance: -1)
        for i in 0..<max(count, 0) {
            let distance = abs(corrected(i) - target)
            let selectedMatchingType = found.index >= 0 && matchesType(found.index)
            if found.distance == -1 ||
                candidateWins(distance: distance, selectedDistance: found.distance, matchingType: matchesType(i),
                              selectedMatchingType: selectedMatchingType, index: i, selectedIndex: found.index,
                              expectedIndex: expected) {
                found = LocationSearch(index: i, distance: distance)
            }
        }
        return found
    }

    /// Whether the slice found is too far from the source's to be the same
    /// location: more than two slice intervals.
    public static func locationIsImpossible(distance: Float, sliceInterval: Float) -> Bool {
        abs(distance) > sliceInterval * 2
    }

    /// `index` kept inside a series of `count` images: an index past the end
    /// (or negative, compared as unsigned) is the last, and nothing is below 0.
    public static func clampedIndex(_ index: Int, count: Int) -> Int {
        var index = index
        if UInt(bitPattern: index) >= UInt(bitPattern: max(count, 0)) { index = count - 1 }
        return index < 0 ? 0 : index
    }

    // MARK: - The patient crosshair

    /// Whether the patient crosshair, at `slice` in the coordinates of the
    /// receiver's slice (millimetres), lies on it: within half the larger of
    /// the slice interval and thickness, and inside the image.
    public static func crosshairIsOnSlice(_ slice: SIMD3<Float>, sliceInterval: Double, sliceThickness: Double,
                                          width: Int, height: Int, pixelSpacingX: Double, pixelSpacingY: Double) -> Bool {
        let interval = fabs(sliceInterval), thickness = fabs(sliceThickness)
        let halfSlice = (interval > thickness ? interval : thickness) * 0.5
        return slice.x.isFinite && slice.y.isFinite && slice.z.isFinite &&
            fabs(Double(slice.z)) <= halfSlice + 0.001 &&
            slice.x >= 0 && Double(slice.x) < Double(width) * pixelSpacingX &&
            slice.y >= 0 && Double(slice.y) < Double(height) * pixelSpacingY
    }

    // MARK: - Geometry

    /// The angle between two vectors (PlaneGeometry.angle).
    public static func angle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        withUnsafeTemporaryAllocation(of: Float.self, capacity: 6) { buffer in
            let p = buffer.baseAddress!
            p[0] = a.x; p[1] = a.y; p[2] = a.z
            p[3] = b.x; p[4] = b.y; p[5] = b.z
            return PlaneGeometry.angle(p, p + 3)
        }
    }

    /// The distance from `point` to a plane, and the foot of the perpendicular
    /// (ViewTransform.planeBase).
    static func planeBase(_ point: SIMD3<Float>, _ origin: SIMD3<Float>, _ normal: SIMD3<Float>,
                          _ projection: inout SIMD3<Float>) -> Float {
        withUnsafeTemporaryAllocation(of: Float.self, capacity: 12) { buffer in
            let p = buffer.baseAddress!
            p[0] = point.x; p[1] = point.y; p[2] = point.z
            p[3] = origin.x; p[4] = origin.y; p[5] = origin.z
            p[6] = normal.x; p[7] = normal.y; p[8] = normal.z
            let distance = ViewTransform.planeBase(p, p + 3, p + 6, p + 9)
            projection = SIMD3(p[9], p[10], p[11])
            return distance
        }
    }
}
