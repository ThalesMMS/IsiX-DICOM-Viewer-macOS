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

/// A volume of floats for the vessel tracer: `width` × `height` × `depth`
/// voxels spaced by `spacing` millimetres, x fastest. Input coordinates count
/// voxels, the voxel (i, j, k) at (i, j, k), as the Curved MPR's volume
/// transform gives them. The voxels are only read. The spacing is taken by
/// its size: a negative one (a stack that runs down) is the same distance.
public struct VesselVolume: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let depth: Int
    public let spacing: SIMD3<Float>
    let voxels: UnsafePointer<Float>
    /// What keeps `voxels` alive: the copy this volume made, or the caller's owner.
    private let owner: AnyObject?

    /// A volume of a copy of `values`, which must hold at least
    /// `width` × `height` × `depth` floats.
    public init(copying values: [Float], width: Int, height: Int, depth: Int, spacing: SIMD3<Float>) {
        self = values.withUnsafeBufferPointer {
            VesselVolume(copying: $0, width: width, height: height, depth: depth, spacing: spacing)
        }
    }

    /// A volume of a copy of the floats of `values` (the bytes of a data
    /// object the caller holds, for instance), which must hold at least
    /// `width` × `height` × `depth` floats: one copy, and the trace reads it
    /// whatever later happens to the original.
    public init(copying values: UnsafeBufferPointer<Float>, width: Int, height: Int, depth: Int, spacing: SIMD3<Float>) {
        let count = max(width, 0) * max(height, 0) * max(depth, 0)
        precondition(values.count >= count, "fewer values than voxels")
        let storage = VesselVoxelStorage(values, count: count)
        self.init(voxels: storage.pointer, width: width, height: height, depth: depth, spacing: spacing, owner: storage)
    }

    /// A volume over the caller's floats, without a copy: `owner` (the data
    /// object that holds them, for instance) is kept alive with the volume,
    /// so the floats stay as long as a trace reads them. Floats that may
    /// change while a trace runs (a viewer's volume edited in place) give an
    /// unpredictable path, without a crash; copy them in that case. With a
    /// nil owner the caller keeps the floats until every trace over them ends.
    public init(borrowing voxels: UnsafePointer<Float>, width: Int, height: Int, depth: Int, spacing: SIMD3<Float>,
                keepingAlive owner: AnyObject?) {
        self.init(voxels: voxels, width: width, height: height, depth: depth, spacing: spacing, owner: owner)
    }

    private init(voxels: UnsafePointer<Float>, width: Int, height: Int, depth: Int, spacing: SIMD3<Float>, owner: AnyObject?) {
        self.voxels = voxels
        self.width = max(width, 0)
        self.height = max(height, 0)
        self.depth = max(depth, 0)
        self.spacing = SIMD3(abs(spacing.x), abs(spacing.y), abs(spacing.z))
        self.owner = owner
    }

    var isEmpty: Bool { width == 0 || height == 0 || depth == 0 }

    /// Every voxel size finite and above zero.
    var hasValidSpacing: Bool {
        spacing.x.isFinite && spacing.y.isFinite && spacing.z.isFinite && spacing.x > 0 && spacing.y > 0 && spacing.z > 0
    }

    /// A point clamped to the volume, as the former assistant clamped its ends.
    func clamped(_ p: SIMD3<Float>) -> SIMD3<Float> {
        func clamp(_ v: Float, _ count: Int) -> Float { min(max(v, 0), Float(count - 1)) }
        return SIMD3(clamp(p.x, width), clamp(p.y, height), clamp(p.z, depth))
    }
}

/// The floats a volume copied.
private final class VesselVoxelStorage {
    let pointer: UnsafeMutablePointer<Float>

    init(_ values: UnsafeBufferPointer<Float>, count: Int) {
        pointer = .allocate(capacity: max(count, 1))
        if let base = values.baseAddress, count > 0 { pointer.initialize(from: base, count: count) }
    }

    deinit { pointer.deallocate() }
}

/// How the tracer weighs the lumen and how far it searches.
public struct VesselTraceOptions: Sendable {
    /// A step at half the lumen's radius costs 2 to this power times a step
    /// on its axis: the higher, the closer the path keeps to the axis.
    public var centringExponent: Double = 4
    /// The search keeps to the points whose distances to the two ends add up
    /// to at most `detour` times the distance between them plus twice `margin`
    /// millimetres: an ellipsoid round the two ends, wide enough for a vessel
    /// that winds half way round the heart between them.
    public var detour: Double = 2.5
    public var marginMillimetres: Double = 15
    /// The most the path goes out of the lumen before the search gives up
    /// on a cheapest crossing and joins the two ends across the gap (an
    /// occlusion, or ends on two vessels), in millimetres.
    public var gapBudgetMillimetres: Double = 3
    /// The most voxels one pass of the search closes before it is treated as
    /// a gap too: a coronary segment takes a few thousand, an occlusion some
    /// tens of thousands; ends marked in the myocardium or across a cavity
    /// would take millions.
    public var searchedVoxelLimit: Int = 120_000

    public init() {}
}

/// Why a trace gave no centerline.
public enum VesselTraceError: Error, Sendable, Equatable {
    /// The volume has no voxels.
    case emptyVolume
    /// A voxel size is zero or not a number.
    case invalidSpacing
    /// A point is not a number or infinite.
    case invalidPoint
    /// The two points fall in the same voxel of the search.
    case samePoint
    /// Around the points the lumen is darker than what surrounds it (air in
    /// an airway or a colon): the former fly-through assistant traces it.
    case darkLumen
    /// The caller cancelled the trace.
    case cancelled
}

/// The centerline the tracer found between two points.
public struct VesselCenterline: Sendable {
    /// The path from the first point to the second, in input coordinates:
    /// the centres of the search's voxels it goes through, one per step to
    /// one of the 26 neighbours, but for the curve that carries the lumen's
    /// course across a stretch out of it, a point in each voxel it crosses.
    /// It starts and ends where each point was moved onto the lumen (its
    /// middle, for a point marked off the axis or just out of a thin vessel).
    public let points: [SIMD3<Float>]
    /// The distance in millimetres from each point to the lumen's border, 0
    /// for a point out of the lumen.
    public let radii: [Float]
    /// The two points given, clamped to the volume.
    public let start: SIMD3<Float>
    public let end: SIMD3<Float>
    /// The values taken as the lumen.
    public let lumenRange: ClosedRange<Float>
    /// The points of the path out of the lumen: an occlusion, a calcified
    /// plaque, an end marked off the vessel, or a wide structure (a cavity,
    /// the aorta) the path had to cross.
    public let pointsOutsideLumen: Int
    /// The longest stretch of the path out of the lumen, in millimetres, from
    /// the last point in it to the next: 0 for a path all in the lumen, the
    /// length of an occlusion it crosses, or of the line it takes between two
    /// ends that lie on different vessels.
    public let longestGap: Float
    /// How far the lowest value taken as lumen lies above the brighter tissue
    /// round the two points (myocardium under a coronary, whether or not the
    /// lumen shows an edge against it), in standard deviations of the noise
    /// of the input's means over about a millimetre, the values the search
    /// reads on the input's own grid.
    public let lumenMargin: Float
    /// The lumen hardly stands out from the tissue it lies on (`lumenMargin`
    /// below 2: more than one in fifty of that tissue's values, as the search
    /// reads them, falls in the lumen's interval): those spots may join up,
    /// and the path can run through them rather than along the vessel, as on
    /// a thin, faint distal vessel lying on the myocardium. The path is given
    /// all the same; it needs checking.
    public var isLumenFaint: Bool { lumenMargin < 2 }
    /// The search's voxel in input voxels along each axis: 1 on the input's
    /// own grid, more for a wide vessel.
    public let gridStep: SIMD3<Int>
    /// The input's voxel size in millimetres.
    public let spacing: SIMD3<Float>
    /// The voxels the search closed, all its passes together: the work the trace took.
    let searchedVoxels: Int

    /// The nodes of a curved path along the centerline, in input coordinates:
    /// the points averaged over about a lumen radius on each side (at least 1
    /// mm), which takes the voxels' steps away, then kept about a mean radius
    /// apart as the former assistant thinned them (at least 1 mm); the first
    /// and last nodes are the two points given.
    public func curveNodes() -> [SIMD3<Float>] {
        guard points.count > 1 else { return [start, end] }
        let scale = SIMD3<Double>(Double(spacing.x), Double(spacing.y), Double(spacing.z))
        let millimetres = points.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) * scale }
        var along = [0.0]
        for i in 1..<millimetres.count {
            along.append(along[i - 1] + VesselMath.length(millimetres[i] - millimetres[i - 1]))
        }
        let typical = Double(radii.filter { $0 > 0 }.sorted().middle ?? 1)
        let window = min(max(typical, 1), 5)
        var smoothed = millimetres
        var low = 0, high = 0
        var sum = SIMD3<Double>(repeating: 0)
        for i in millimetres.indices {
            while high < millimetres.count && along[high] <= along[i] + window { sum += millimetres[high]; high += 1 }
            while along[low] < along[i] - window { sum -= millimetres[low]; low += 1 }
            smoothed[i] = sum / Double(high - low)
        }
        smoothed[0] = SIMD3(Double(start.x), Double(start.y), Double(start.z)) * scale
        smoothed[smoothed.count - 1] = SIMD3(Double(end.x), Double(end.y), Double(end.z)) * scale

        var nodes = [smoothed[0]]
        var lastRadius = Double(radii[0])
        for i in 1..<(smoothed.count - 1) {
            let radius = Double(radii[i])
            if VesselMath.length(smoothed[i] - nodes[nodes.count - 1]) >= max((lastRadius + radius) / 2, 1) {
                nodes.append(smoothed[i])
                lastRadius = radius
            }
        }
        if nodes.count > 1 && VesselMath.length(smoothed[smoothed.count - 1] - nodes[nodes.count - 1]) < 0.5 {
            nodes.removeLast()
        }
        nodes.append(smoothed[smoothed.count - 1])
        return nodes.map { SIMD3<Float>(Float($0.x / scale.x), Float($0.y / scale.y), Float($0.z / scale.z)) }
    }
}

/// The vessel tracer of the Curved MPR: the centerline of a contrast-filled
/// vessel between two points marked in it, a coronary of a millimetre of
/// radius beside the heart's cavities as well as a carotid.
///
/// The lumen's values come from the voxels around the two points, each moved
/// onto the bright structure it marks, not from the volume's histogram: from
/// the value of the lumen to half way down to the brightest tissue that
/// touches it (the half maximum), and as far above. The search is a shortest
/// path (A*, the straight-line distance as its heuristic) over the voxels of
/// the input itself, or of whole multiples of them when the narrower end is
/// wide enough to keep six of them in its radius, within an ellipsoid round
/// the two ends. A step in the lumen costs (R / d)^k per millimetre, d the
/// distance to the lumen's border and R the vessel's radius at the ends, so
/// the path keeps to the axis. A step out of the lumen costs a hundred times
/// the dearest step in it, up to five times more by how far its value is from
/// the lumen's; a structure in the lumen's interval but much wider than the
/// vessel (a cavity of the heart, the aorta, a sheet of enhancing myocardium)
/// costs as much as fat, except round an end marked in it; so does the dip
/// of fat between two vessels that touch, which the scanner's blur lifts
/// into the interval. The path crosses as few voxels out of the lumen as it
/// can, and neither a cavity behind a wall, however thin, nor a vessel lying
/// against this one is a shortcut. Past a few millimetres out of the lumen
/// (an occlusion, or ends on two vessels) the two ends are searched each
/// within that budget and joined across the gap, which `longestGap` gives.
/// Across every stretch out of the lumen the path follows a curve that
/// carries on the lumen's axis from both sides, as an occluded bend does. A
/// lumen that hardly stands out from the tissue under it is traced all the
/// same and flagged by `isLumenFaint`.
///
/// The memory and the time grow with the voxels the search reaches, not with
/// the volume: scratch memory comes by bricks of 8 × 8 × 8 voxels as it
/// reaches them.
public enum VesselTracer {

    /// The centerline from `a` to `b`, input coordinates, on the calling
    /// thread. `progress` hears, from time to time, the share of the way
    /// covered (0 to 1); `isCancelled` is asked as often, and true ends the
    /// trace with `.cancelled`.
    public static func trace(from a: SIMD3<Float>, to b: SIMD3<Float>, in volume: VesselVolume,
                             options: VesselTraceOptions = VesselTraceOptions(),
                             progress: (Double) -> Void = { _ in },
                             isCancelled: () -> Bool = { false }) throws(VesselTraceError) -> VesselCenterline {
        guard !volume.isEmpty else { throw .emptyVolume }
        guard volume.hasValidSpacing else { throw .invalidSpacing }
        guard [a.x, a.y, a.z, b.x, b.y, b.z].allSatisfy(\.isFinite) else { throw .invalidPoint }
        let pa = volume.clamped(a), pb = volume.clamped(b)
        let lumen = try VesselLumen.estimate(volume: volume, a: pa, b: pb)
        if isCancelled() { throw .cancelled }
        let search = VesselPathSearch(volume: volume, lumen: lumen, options: options, a: pa, b: pb)
        return try search.run(progress: progress, isCancelled: isCancelled)
    }

    /// The centerlines between each node and the next, input coordinates, off
    /// the caller's actor: what the Curved MPR's path assistant traces through
    /// the nodes of its path. Each segment gives its centerline or its error;
    /// `progress` hears the share of all the segments done (0 to 1), on the
    /// tracer's thread. Cancelling the task ends the trace with `.cancelled`.
    @concurrent
    public static func traceSegments(through nodes: [SIMD3<Float>], in volume: VesselVolume,
                                     options: VesselTraceOptions = VesselTraceOptions(),
                                     progress: @escaping @Sendable (Double) -> Void = { _ in })
        async throws(VesselTraceError) -> [Result<VesselCenterline, VesselTraceError>] {
        let count = max(nodes.count - 1, 0)
        var segments: [Result<VesselCenterline, VesselTraceError>] = []
        for index in 0..<count {
            let share = { (done: Double) in progress((Double(index) + done) / Double(count)) }
            do {
                let line = try trace(from: nodes[index], to: nodes[index + 1], in: volume, options: options,
                                     progress: share, isCancelled: { Task.isCancelled })
                segments.append(.success(line))
            } catch .cancelled {
                throw .cancelled
            } catch {
                segments.append(.failure(error))
            }
            progress(Double(index + 1) / Double(count))
        }
        if Task.isCancelled { throw .cancelled }
        return segments
    }
}

/// Vector arithmetic in doubles, without SIMD's generic calls in unoptimized builds.
enum VesselMath {
    static func length(_ v: SIMD3<Double>) -> Double { (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot() }

    static func dot(_ u: SIMD3<Double>, _ v: SIMD3<Double>) -> Double { u.x * v.x + u.y * v.y + u.z * v.z }

    /// The line in s nearest to the points by least squares: where it is at
    /// the points' mean s, and its slope. No slope when all the points lie at
    /// one s.
    static func lineFit(_ samples: [(s: Double, p: SIMD3<Double>)]) -> (value: SIMD3<Double>, slope: SIMD3<Double>) {
        guard !samples.isEmpty else { return (.zero, .zero) }
        let count = Double(samples.count)
        let meanS = samples.reduce(0) { $0 + $1.s } / count
        let meanP = samples.reduce(SIMD3<Double>(repeating: 0)) { $0 + $1.p } / count
        var spread = 0.0, slope = SIMD3<Double>(repeating: 0)
        for sample in samples {
            let ds = sample.s - meanS
            spread += ds * ds
            slope += (sample.p - meanP) * ds
        }
        return (meanP, spread > 1e-12 ? slope / spread : .zero)
    }
}

private extension Array where Element == Float {
    /// The middle element of a sorted array, nil when empty.
    var middle: Float? { isEmpty ? nil : self[count / 2] }
}
