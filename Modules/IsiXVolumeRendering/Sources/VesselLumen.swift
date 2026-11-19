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

/// The lumen of a vessel as the voxels around its two ends show it: the
/// interval of its values, its radius at each end and where each end lies on it.
///
/// The interval comes from each end's own neighbourhood, not from the
/// volume's histogram, whose bright peak in a cardiac CT is the blood of the
/// cavities and the aorta, not that of a coronary, which holds too few voxels
/// to make a peak and is often fainter. Each end is first moved onto the
/// middle of the bright structure it marks (`brightCentre`), so that a point
/// marked off the axis, on the lumen's edge or just out of a thin vessel
/// measures the lumen and not its edge. There the lumen's value is the upper
/// quartile of the voxels within a millimetre; past the lumen's first edge
/// along 26 rays lies the tissue that touches it, and the upper quartile of
/// the rays is the brighter surroundings (myocardium where the vessel lies on
/// it, even behind a millimetre or two of fat), the lower quartile the darker
/// (fat), but neither the lung a few millimetres further nor a cavity behind
/// a wall. The lower bound is the higher of half way from the darker
/// surroundings to the lumen (the half maximum at which a scanner blurs a
/// border) and a quarter of the way from the brighter: myocardium stays out
/// of the interval whether or not it touches the vessel at the ends, and the
/// lumen's side toward the fat is not cut short. The upper bound lies half
/// the contrast above the lumen. The two ends' intervals are joined, so that
/// the fainter distal lumen stays in, unless the rays of one end met an edge
/// in less than a quarter of their directions: a point marked far from any
/// lumen says little of it, and the other end sets the interval alone.
///
/// A lumen darker than what surrounds it (air in an airway or a colon) is
/// told apart the same way with the values turned over: the rays from each
/// point marked meet a rising edge first in at least six directions out of
/// ten, and the contrast they show is the larger.
struct VesselLumen {
    let lower: Float
    let upper: Float
    /// Half the weaker end's contrast: the scale of how far out of the
    /// interval a value is.
    let halfContrast: Float
    /// The noise of the means over about a millimetre that the search reads,
    /// one standard deviation, the larger of the two ends'.
    let noise: Float
    /// The brighter end's lumen value.
    let peak: Float
    /// The brighter tissue round the ends, as their rays met it past the
    /// lumen's first edge.
    let tissue: Float
    /// Round each end whose lumen is thin, the level the rays meet a
    /// millimetre or two past the lumen's usual edge, but for levels brighter
    /// than that end's own lumen beyond the noise (a cavity or calcium, which
    /// the rim and the wide structures keep the path out of); empty for a
    /// wide end or one the interval left aside.
    let besideA: [VesselSampler.Beside]
    let besideB: [VesselSampler.Beside]
    /// The radius in millimetres of the lumen at each end; nil where the end
    /// is more than 2 mm from any voxel of the interval.
    let radiusA: Double?
    let radiusB: Double?
    /// Each end on the lumen, in input coordinates: the voxel of the interval
    /// nearest to where the end was moved, within 2 mm; that place itself
    /// when no voxel is that near.
    let centreA: SIMD3<Float>
    let centreB: SIMD3<Float>

    /// The interval and the radii for the ends `a` and `b`, in input
    /// coordinates within the volume. `.darkLumen` when the ends lie in a
    /// lumen darker than what surrounds it.
    static func estimate(volume: VesselVolume, a: SIMD3<Float>, b: SIMD3<Float>) throws(VesselTraceError) -> VesselLumen {
        let sampler = VesselSampler(volume: volume)
        var marked = [sampler.brightCentreOrShell(near: a), sampler.brightCentreOrShell(near: b)]
        // An end within a stent's mesh tells the level above which the values
        // there are the mesh's. The other end, marked on plaque in the same
        // stent, climbs to the lumen and no higher; and the rays that measure
        // the lumen from both ends take the mesh for no more than lumen: from
        // within it they met a rise where an edge is looked for, and that
        // end was left out of the interval, which the mesh then set alone.
        // Tissue within a stent lies within its mesh too, at its own, lower
        // level: the lumen's is the higher of the two ends', and an end far
        // under it (twelve times the noise of the smoothed values) is on
        // tissue.
        let shellCeiling = marked.compactMap(\.shellCeiling).max()
        var ceilings: [Float?] = [nil, nil]
        if let shellCeiling {
            let spread = 12 * max(sampler.smoothedNoise(near: marked[0].centre), sampler.smoothedNoise(near: marked[1].centre))
            for (index, point) in [a, b].enumerated() {
                if let own = marked[index].shellCeiling, own >= shellCeiling - spread {
                    ceilings[index] = own
                } else {
                    marked[index] = sampler.brightCentreOrShell(near: point, lumenCeiling: shellCeiling)
                    ceilings[index] = shellCeiling
                }
            }
        }
        let centres = marked.map(\.centre)
        let bright = [0, 1].map { sampler.probe(at: centres[$0], sign: 1, ceiling: ceilings[$0]) }
        let dark = [a, b].map { sampler.probe(at: sampler.voxel($0), sign: -1) }
        // Dark only when the rays from both points rise nearly all round, as
        // in air: a point in myocardium between fat and a cavity rises on
        // one side only, and is left to the bright search. So is a point in a
        // stent, where they rise all round to the mesh: past that thin shell
        // lies tissue darker than the lumen, which past an airway's wall it
        // is not.
        let brightScore = bright.reduce(0) { $0 + $1.score }, darkScore = dark.reduce(0) { $0 + $1.score }
        if darkScore > brightScore && dark.allSatisfy({ $0.share >= 0.6 }) && shellCeiling == nil { throw .darkLumen }
        guard brightScore > 0 else { throw .darkLumen }

        // An end whose rays met an edge in less than a quarter of their
        // directions (a point marked far from any lumen) says little of the
        // lumen's interval; the other end sets it alone.
        let used = bright.indices.filter { bright[$0].share >= 0.25 }
        let noise = max(sampler.smoothedNoise(near: centres[0]), sampler.smoothedNoise(near: centres[1]), 1e-3)
        var lower = Float.greatestFiniteMagnitude, upper = -Float.greatestFiniteMagnitude
        var contrast = Float.greatestFiniteMagnitude
        var tissue = -Float.greatestFiniteMagnitude, peak = -Float.greatestFiniteMagnitude
        var beside: [[VesselSampler.Beside]] = [[], []]
        for index in used.isEmpty ? Array(bright.indices) : used {
            let end = bright[index]
            let endContrast = max(end.value - end.surroundings, 0)
            lower = min(lower, max(end.surroundings + endContrast / 4, (end.value + end.darkSurroundings) / 2))
            upper = max(upper, end.value + endContrast / 2)
            if endContrast > 0 { contrast = min(contrast, endContrast) }
            tissue = max(tissue, end.surroundings)
            peak = max(peak, end.value)
            beside[index] = end.beside.filter { $0.level <= end.value + 3 * noise }
        }
        if contrast == .greatestFiniteMagnitude { contrast = max(upper - lower, 1) }
        upper = max(upper, lower)

        func point(_ voxel: (Int, Int, Int)) -> SIMD3<Float> { SIMD3(Float(voxel.0), Float(voxel.1), Float(voxel.2)) }
        let range = lower...upper
        let (onA, radiusA) = sampler.lumenRadius(near: centres[0], in: range)
        let (onB, radiusB) = sampler.lumenRadius(near: centres[1], in: range)
        return VesselLumen(lower: lower, upper: upper, halfContrast: max(contrast / 2, 1e-3), noise: noise, peak: peak,
                           tissue: tissue, besideA: beside[0], besideB: beside[1], radiusA: radiusA, radiusB: radiusB,
                           centreA: onA ?? point(centres[0]), centreB: onB ?? point(centres[1]))
    }

    /// How far the interval's floor lies above the brighter tissue round the
    /// ends, in `noise`: below two, that tissue's noise reaches into the
    /// interval in spots that may join up, and the path can run through them.
    /// The tissue is the brighter of what the rays met past the lumen's first
    /// edge and, round a thin end, the upper quartile of the levels past its
    /// lumen across the vessel's course there (`courseA`, `courseB`, unit
    /// vectors in millimetres; nil when not known), more than 45° from it:
    /// across its course a ray leaves the vessel, while along it the vessel
    /// itself goes on. A lumen too faint to show an edge against the tissue
    /// under it leaves no edge on those rays for that tissue to be met past,
    /// but its level is there all the same.
    func margin(courseA: SIMD3<Double>?, courseB: SIMD3<Double>?) -> Float {
        var level = tissue
        for (beside, course) in [(besideA, courseA), (besideB, courseB)] {
            guard let course else { continue }
            var across = beside.filter { abs(VesselMath.dot($0.direction, course)) < 0.7 }.map(\.level)
            across.sort()
            if across.count >= 3, let quartile = across.quantile(0.75) { level = max(level, quartile) }
        }
        return (lower - level) / noise
    }
}

/// Reads of the input volume on its own grid, for the ends of a trace.
struct VesselSampler {
    let volume: VesselVolume
    /// How many voxels the mean of a voxel's value reaches on each side, per
    /// axis: about half a millimetre, none along an axis of a millimetre.
    private let extendX: Int, extendY: Int, extendZ: Int

    init(volume: VesselVolume) {
        self.volume = volume
        func extend(_ size: Float) -> Int { Int((0.45 / Double(size)).rounded()) }
        extendX = extend(volume.spacing.x)
        extendY = extend(volume.spacing.y)
        extendZ = extend(volume.spacing.z)
    }

    /// What one end shows, with values multiplied by a sign (-1 for a dark lumen).
    struct Probe {
        /// The upper quartile of the voxels within a millimetre: the lumen's value.
        var value: Float
        /// The upper quartile, over the rays, of the brightest tissue just past the lumen's first edge.
        var surroundings: Float
        /// The lower quartile of the same: the darker tissue round the lumen.
        var darkSurroundings: Float
        /// The share of the rays that meet an edge.
        var share: Float
        /// That share times the contrast.
        var score: Float
        /// For a thin lumen, each ray's level past it (`Beside`); empty for a wide one.
        var beside: [Beside]
    }

    /// The level a ray meets from three quarters of a millimetre to 2.25 mm
    /// past the lumen's usual edge (the median distance of the edges the
    /// rays met, a millimetre when fewer than three met one), the median of
    /// its means over a millimetre there, values times the probe's sign; and
    /// the ray's direction, a unit vector in millimetres.
    struct Beside {
        var direction: SIMD3<Double>
        var level: Float
    }

    /// A lumen whose rays meet its edge further than this, in millimetres,
    /// is no thin vessel: its own course fills more directions round the
    /// point than a cone round one axis, and its contrast is no faint one's.
    private static let thinLumenEdge = 2.5

    private var spacing: SIMD3<Double> {
        SIMD3(Double(volume.spacing.x), Double(volume.spacing.y), Double(volume.spacing.z))
    }

    func value(_ x: Int, _ y: Int, _ z: Int) -> Float {
        volume.voxels[(z * volume.height + y) * volume.width + x]
    }

    func contains(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        x >= 0 && x < volume.width && y >= 0 && y < volume.height && z >= 0 && z < volume.depth
    }

    /// The mean of the voxels round (x, y, z) that lie in the volume, as the
    /// search reads a voxel of the input's own grid.
    func smoothed(_ x: Int, _ y: Int, _ z: Int) -> Float {
        var sum: Float = 0
        var count = 0
        for k in max(z - extendZ, 0)...min(z + extendZ, volume.depth - 1) {
            for j in max(y - extendY, 0)...min(y + extendY, volume.height - 1) {
                for i in max(x - extendX, 0)...min(x + extendX, volume.width - 1) {
                    sum += value(i, j, k)
                    count += 1
                }
            }
        }
        return sum / Float(count)
    }

    /// The voxel nearest to a point in input coordinates (within the volume).
    func voxel(_ p: SIMD3<Float>) -> (Int, Int, Int) {
        (min(max(Int(p.x.rounded()), 0), volume.width - 1),
         min(max(Int(p.y.rounded()), 0), volume.height - 1),
         min(max(Int(p.z.rounded()), 0), volume.depth - 1))
    }

    /// The 26 directions to the neighbours of a voxel, in millimetres, unit length.
    static let directions: [SIMD3<Double>] = {
        var result: [SIMD3<Double>] = []
        for dz in -1...1 { for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 || dz != 0 {
            let v = SIMD3(Double(dx), Double(dy), Double(dz))
            result.append(v / VesselMath.length(v))
        } } }
        return result
    }()

    /// The middle of the bright structure a point marks, by the values
    /// smoothed over about a millimetre within 2.5 mm of it. A point in the
    /// lumen climbs up the values no higher than their brightest tenth, so
    /// that from the lumen's edge it reaches the middle but never climbs
    /// onto a calcified plaque beside it. A point below half way between the
    /// darkest and the brightest tenth starts from the nearest voxel above
    /// that, and a point in plain fat beside a vessel too small to reach the
    /// brightest tenth (the brightest of all four times as high above the
    /// darkest tenth) from the nearest voxel half way up to the brightest;
    /// both climb to the summit. Each step gains more than the noise and 5 %
    /// of the height above the darkest tenth, so that it never wanders along
    /// a wide lumen; differences within six times the noise of the smoothed
    /// values (from the spread of the voxels round their means) are no
    /// structure to move to.
    func brightCentre(near p: SIMD3<Float>) -> (Int, Int, Int) {
        brightCentreOrShell(near: p).centre
    }

    /// The same, and for a point inside a thin shell brighter than its own
    /// values (a stent's mesh), which is moved to the shell's middle and no
    /// further, the level above which the values there are the shell's. With
    /// `lumenCeiling`, that level from the other point, the climb starts from
    /// the nearest voxel that high at most and ends there: a point on plaque
    /// within the stent reaches its lumen, not its mesh.
    func brightCentreOrShell(near p: SIMD3<Float>, lumenCeiling: Float? = nil) -> (centre: (Int, Int, Int), shellCeiling: Float?) {
        let s = spacing
        let (cx, cy, cz) = voxel(p)
        let radius = 2.5
        let reach = (Int((radius / s.x).rounded(.up)), Int((radius / s.y).rounded(.up)), Int((radius / s.z).rounded(.up)))
        var around: [(x: Int, y: Int, z: Int, distance: Double, value: Float)] = []
        var residuals: [Float] = []
        for dz in -reach.2...reach.2 { for dy in -reach.1...reach.1 { for dx in -reach.0...reach.0 {
            let x = cx + dx, y = cy + dy, z = cz + dz
            let mx = Double(dx) * s.x, my = Double(dy) * s.y, mz = Double(dz) * s.z
            let squared = mx * mx + my * my + mz * mz
            if contains(x, y, z) && squared <= radius * radius {
                let mean = smoothed(x, y, z)
                around.append((x, y, z, squared.squareRoot(), mean))
                residuals.append(abs(value(x, y, z) - mean))
            }
        } } }
        residuals.sort()
        let boxVoxels = Float((2 * extendX + 1) * (2 * extendY + 1) * (2 * extendZ + 1))
        let noise = 1.4826 * (residuals.quantile(0.5) ?? 0) / boxVoxels.squareRoot()
        let sorted = around.map(\.value).sorted()
        let low = sorted.quantile(0.1) ?? 0, high = sorted.quantile(0.9) ?? 0
        let brightest = sorted.last ?? low
        let middle = (low + high) / 2
        var current = (cx, cy, cz)
        var level = smoothed(cx, cy, cz)
        let below = high - low > 6 * noise && level < middle
        let small = brightest - low > 6 * noise && brightest - low > 4 * (high - low) && level - low < 0.25 * (brightest - low)
        // Inside a thin shell brighter than the point's own values on both sides (a stent's mesh
        // round its lumen), the lumen is where the point is: the climb would end on the mesh, and
        // where the mesh fills the neighbourhood the point counts as below it.
        // The noise from the quieter quarter of the voxels here: round a mesh the spread of half of
        // them is the mesh's own, several times the noise.
        let quiet = (residuals.quantile(0.25) ?? 0) / 0.3186 / boxVoxels.squareRoot()
        let rise = max(6 * quiet, 0.05 * (level - low))
        if !small, lumenCeiling == nil, let middle = middleOfBrighterShell(cx, cy, cz, level: level, rise: rise) {
            return (middle, level + rise)
        }
        var ceiling = min(high, lumenCeiling ?? .greatestFiniteMagnitude)
        if below || small {
            let start = min(below ? middle : (low + brightest) / 2, lumenCeiling ?? .greatestFiniteMagnitude)
            var nearest = Double.infinity
            for v in around where v.value >= start && v.distance < nearest {
                nearest = v.distance
                current = (v.x, v.y, v.z)
                level = v.value
            }
            ceiling = min(brightest, lumenCeiling ?? .greatestFiniteMagnitude)
        }
        let limit = (radius + 1) * (radius + 1)
        for _ in 0..<Int((radius / min(s.x, s.y, s.z)).rounded(.up)) where level < ceiling {
            var next = current, nextLevel = level
            for dz in -1...1 { for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 || dz != 0 {
                let x = current.0 + dx, y = current.1 + dy, z = current.2 + dz
                let mx = Double(x - cx) * s.x, my = Double(y - cy) * s.y, mz = Double(z - cz) * s.z
                guard contains(x, y, z) && mx * mx + my * my + mz * mz <= limit else { continue }
                let v = smoothed(x, y, z)
                if v > nextLevel {
                    next = (x, y, z)
                    nextLevel = v
                }
            } } }
            if next == current || nextLevel - level <= max(noise, 0.05 * (level - low)) { break }
            current = next
            level = nextLevel
        }
        return (current, nil)
    }

    /// Whether the smoothed values rise by `rise` on both sides of a voxel,
    /// within 4 mm and before they fall by as much, and within 1.5 mm past
    /// that fall under the voxel's own by `rise`, along three or more of the
    /// thirteen axes: the voxel lies in a lumen with a thin shell of something
    /// brighter all round it and no wall between, as inside a stent or a ring
    /// of calcium. At a lumen's edge the values rise on one side, toward its
    /// middle, and beside a calcified plaque on the plaque's side; between
    /// two vessels that touch, along the one axis through both; and from soft
    /// plaque within a lumen they rise to the lumen, which is no thin shell
    /// and ends in tissue no darker than the plaque. Answers the voxel half
    /// way between the shell's two sides along x, y and z, where they are met
    /// on both: the lumen's middle, from which the rays that measure the
    /// lumen meet the shell at the same distance all round. Nil outside a shell.
    private func middleOfBrighterShell(_ cx: Int, _ cy: Int, _ cz: Int, level: Float, rise: Float) -> (Int, Int, Int)? {
        let s = spacing
        /// The steps from a voxel to the shell along a direction, nil when it is not met.
        func shell(from c: (Int, Int, Int), _ dx: Int, _ dy: Int, _ dz: Int) -> Int? {
            let (cx, cy, cz) = c
            var k = 1
            var risen: Int?
            let mx = Double(dx) * s.x, my = Double(dy) * s.y, mz = Double(dz) * s.z
            let step = (mx * mx + my * my + mz * mz).squareRoot()
            while Double(k) * step <= 4 || risen != nil, contains(cx + k * dx, cy + k * dy, cz + k * dz) {
                let v = smoothed(cx + k * dx, cy + k * dy, cz + k * dz)
                if let risen {
                    if v <= level - rise { return risen }
                    if Double(k - risen) * step > 1.5 { return nil }
                } else {
                    if v >= level + rise { risen = k }
                    if v <= level - rise { return nil }
                }
                k += 1
            }
            return nil
        }
        var axes = 0
        for dz in -1...1 { for dy in -1...1 { for dx in -1...1 where dz > 0 || (dz == 0 && (dy > 0 || (dy == 0 && dx > 0))) {
            if shell(from: (cx, cy, cz), dx, dy, dz) != nil && shell(from: (cx, cy, cz), -dx, -dy, -dz) != nil { axes += 1 }
        } } }
        guard axes >= 3 else { return nil }
        var middle = (cx, cy, cz)
        for (dx, dy, dz) in [(1, 0, 0), (0, 1, 0), (0, 0, 1)] {
            guard let ahead = shell(from: middle, dx, dy, dz), let behind = shell(from: middle, -dx, -dy, -dz) else { continue }
            let shift = (ahead - behind) / 2
            middle = (middle.0 + shift * dx, middle.1 + shift * dy, middle.2 + shift * dz)
        }
        return middle
    }

    /// The lumen's value and its surroundings at a voxel, values times `sign`,
    /// none of them taken for more than `ceiling`.
    func probe(at centre: (Int, Int, Int), sign: Float, ceiling: Float? = nil) -> Probe {
        let ceiling = ceiling ?? .greatestFiniteMagnitude
        let (cx, cy, cz) = centre
        let s = spacing
        let ball = max(1.0, 1.5 * max(s.x, s.y, s.z))
        var near: [Float] = []
        let reach = SIMD3(Int((ball / s.x).rounded(.up)), Int((ball / s.y).rounded(.up)), Int((ball / s.z).rounded(.up)))
        for dz in -reach.z...reach.z { for dy in -reach.y...reach.y { for dx in -reach.x...reach.x {
            let x = cx + dx, y = cy + dy, z = cz + dz
            let mx = Double(dx) * s.x, my = Double(dy) * s.y, mz = Double(dz) * s.z
            if contains(x, y, z) && mx * mx + my * my + mz * mz <= ball * ball { near.append(min(sign * value(x, y, z), ceiling)) }
        } } }
        near.sort()
        let value = near.quantile(0.75) ?? 0

        // Each ray's profile every quarter millimetre up to 20 mm or the
        // volume's edge, as means over a millimetre.
        let origin = SIMD3(Double(cx), Double(cy), Double(cz))
        var profiles: [[Float]] = [], directions: [SIMD3<Double>] = []
        var nearMinima: [Float] = [], farMinima: [Float] = []
        for direction in Self.directions {
            var samples: [Float] = []
            var t = 0.0
            while t <= 20, let sample = interpolated(origin + direction * t / s) {
                samples.append(min(sign * sample, ceiling))
                t += 0.25
            }
            guard samples.count > 4 else { continue }
            var means = samples
            for n in samples.indices {
                let low = max(n - 2, 0), high = min(n + 2, samples.count - 1)
                var sum: Float = 0
                for k in low...high { sum += samples[k] }
                means[n] = sum / Float(high - low + 1)
            }
            profiles.append(means)
            directions.append(direction)
            nearMinima.append(means.prefix(21).min() ?? value)
            farMinima.append(means.min() ?? value)
        }
        nearMinima.sort()
        farMinima.sort()
        // The darkest within 5 mm, the median over the rays: fat round a
        // coronary rather than the lung beyond it. In a lumen wider than
        // that (the aorta) it is the lumen itself, and the darkest within
        // 20 mm stands in.
        let nearDark = nearMinima.quantile(0.5) ?? value, farDark = farMinima.quantile(0.5) ?? value
        let dark = value - nearDark >= 0.25 * (value - farDark) ? nearDark : farDark

        // Along each ray, the first edge: a drop over a millimetre of more
        // than 15 % of the way down to that darkest, at its steepest, unless
        // the ray rises as much first. Past it, from 1 to 3 mm, the brightest
        // mean below the middle of the drop: the tissue that touches the
        // lumen, or the one behind a thin layer of fat, but not a cavity
        // behind a wall.
        let threshold = 0.15 * (value - dark)
        var past: [Float] = []
        var edges: [Double] = []
        if threshold > 0 {
            for m in profiles {
                var n = 2
                while n + 12 < m.count {
                    let change = m[n - 2] - m[n + 2]
                    // A ray that first rises leaves the point for something
                    // brighter: it meets no edge of this lumen.
                    if -change >= threshold { break }
                    if change >= threshold {
                        while n + 13 < m.count && m[n - 1] - m[n + 3] > m[n - 2] - m[n + 2] { n += 1 }
                        let middle = (m[n - 2] + m[n + 2]) / 2
                        var brightest = -Float.greatestFiniteMagnitude, dimmest = Float.greatestFiniteMagnitude
                        for k in (n + 4)...(n + 12) {
                            if m[k] < middle { brightest = max(brightest, m[k]) }
                            dimmest = min(dimmest, m[k])
                        }
                        past.append(brightest > -Float.greatestFiniteMagnitude ? brightest : dimmest)
                        edges.append(Double(n) * 0.25)
                        break
                    }
                    n += 1
                }
            }
        }
        past.sort()
        let enough = past.count >= 3
        let surroundings = min(enough ? (past.quantile(0.75) ?? dark) : dark, value)
        let darkSurroundings = min(enough ? (past.quantile(0.25) ?? dark) : dark, surroundings)
        let share = Float(past.count) / Float(Self.directions.count)

        edges.sort()
        let edge = edges.count >= 3 ? edges[edges.count / 2] : 1
        var beside: [Beside] = []
        let first = Int(((edge + 0.75) / 0.25).rounded()), last = Int(((edge + 2.25) / 0.25).rounded())
        if edge <= Self.thinLumenEdge {
            for (m, direction) in zip(profiles, directions) where last < m.count {
                let window = m[first...last].sorted()
                beside.append(Beside(direction: direction, level: window[window.count / 2]))
            }
        }
        return Probe(value: value, surroundings: surroundings, darkSurroundings: darkSurroundings, share: share,
                     score: share * (value - surroundings), beside: beside)
    }

    /// The noise of the means `smoothed` gives round a voxel, one standard
    /// deviation: from the differences between two such means side by side
    /// (boxes that touch without overlapping) along each axis, about every
    /// 0.8 mm within 3 mm, so that it holds for the correlated noise of a scanner's
    /// reconstruction as for noise voxel by voxel. Only the flattest pairs
    /// count, whose voxels together spread no more than one and a half times
    /// the spread under which a tenth of all pairs lie: a pair across an
    /// edge, across two tissues or on the slope of a blurred edge spreads
    /// more, and the noise alone hardly varies.
    func smoothedNoise(near centre: (Int, Int, Int)) -> Float {
        let s = spacing
        let radius = 3.0
        let (cx, cy, cz) = centre
        let reach = (Int((radius / s.x).rounded(.up)), Int((radius / s.y).rounded(.up)), Int((radius / s.z).rounded(.up)))
        let apart = (2 * extendX + 1, 2 * extendY + 1, 2 * extendZ + 1)
        let boxVoxels = Double(apart.0 * apart.1 * apart.2)
        // Every box the pairs need, its centre within the volume's edge by its extent.
        let x0 = max(cx - reach.0, extendX), x1 = min(cx + reach.0 + apart.0, volume.width - 1 - extendX)
        let y0 = max(cy - reach.1, extendY), y1 = min(cy + reach.1 + apart.1, volume.height - 1 - extendY)
        let z0 = max(cz - reach.2, extendZ), z1 = min(cz + reach.2 + apart.2, volume.depth - 1 - extendZ)
        guard x0 <= x1 && y0 <= y1 && z0 <= z1 else { return 0 }
        let nx = x1 - x0 + 1, ny = y1 - y0 + 1, nz = z1 - z0 + 1
        // The boxes' sums one axis at a time: along x for every row of
        // voxels they reach, then along y, then along z.
        let rows = ny + 2 * extendY, slices = nz + 2 * extendZ
        var alongX = [Double](repeating: 0, count: nx * rows * slices), squaresX = alongX
        var index = 0
        for k in (z0 - extendZ)...(z1 + extendZ) { for j in (y0 - extendY)...(y1 + extendY) { for x in x0...x1 {
            var sum = 0.0, square = 0.0
            var i = x - extendX
            while i <= x + extendX {
                let v = Double(value(i, j, k))
                sum += v
                square += v * v
                i += 1
            }
            alongX[index] = sum
            squaresX[index] = square
            index += 1
        } } }
        var alongY = [Double](repeating: 0, count: nx * ny * slices), squaresY = alongY
        index = 0
        for k in 0..<slices { for y in 0..<ny { for x in 0..<nx {
            var j = y
            while j <= y + 2 * extendY {
                alongY[index] += alongX[(k * rows + j) * nx + x]
                squaresY[index] += squaresX[(k * rows + j) * nx + x]
                j += 1
            }
            index += 1
        } } }
        var sums = [Double](repeating: 0, count: nx * ny * nz), squares = sums
        index = 0
        for z in 0..<nz { for y in 0..<ny { for x in 0..<nx {
            var k = z
            while k <= z + 2 * extendZ {
                sums[index] += alongY[(k * ny + y) * nx + x]
                squares[index] += squaresY[(k * ny + y) * nx + x]
                k += 1
            }
            index += 1
        } } }
        func slot(_ x: Int, _ y: Int, _ z: Int) -> Int? {
            guard x >= x0 && x <= x1 && y >= y0 && y <= y1 && z >= z0 && z <= z1 else { return nil }
            return ((z - z0) * ny + (y - y0)) * nx + (x - x0)
        }
        // Pairs about every 0.8 mm: closer ones share most of their voxels.
        func every(_ size: Double) -> Int { max(Int((0.8 / size).rounded()), 1) }
        let xs = stride(from: -reach.0, through: reach.0, by: every(s.x))
        let ys = stride(from: -reach.1, through: reach.1, by: every(s.y)), zs = stride(from: -reach.2, through: reach.2, by: every(s.z))
        var spreads: [Double] = [], pairs: [(spread: Double, difference: Double)] = []
        for dz in zs { for dy in ys { for dx in xs {
            let mx = Double(dx) * s.x, my = Double(dy) * s.y, mz = Double(dz) * s.z
            let x = cx + dx, y = cy + dy, z = cz + dz
            guard mx * mx + my * my + mz * mz <= radius * radius, let here = slot(x, y, z) else { continue }
            for there in [slot(x + apart.0, y, z), slot(x, y + apart.1, z), slot(x, y, z + apart.2)] {
                guard let there else { continue }
                let mean = (sums[here] + sums[there]) / (2 * boxVoxels)
                let spread = max((squares[here] + squares[there]) / (2 * boxVoxels) - mean * mean, 0)
                let difference = abs(sums[there] - sums[here]) / boxVoxels
                // A box holding a voxel that is not a number says nothing of the noise.
                guard spread.isFinite && difference.isFinite else { continue }
                spreads.append(spread)
                pairs.append((spread, difference))
            }
        } } }
        guard !spreads.isEmpty else { return 0 }
        spreads.sort()
        let flat = 1.5 * spreads[(spreads.count - 1) / 10]
        var differences = pairs.filter { $0.spread <= flat }.map(\.difference)
        guard !differences.isEmpty else { return 0 }
        differences.sort()
        // The median of |a - b| for two independent normal values of deviation σ is 0.6745 √2 σ.
        return Float(differences[differences.count / 2] / (0.6745 * 2.0.squareRoot()))
    }

    /// The volume's value at a point in input coordinates, interpolated
    /// between its eight voxels; nil outside the volume.
    func interpolated(_ q: SIMD3<Double>) -> Float? {
        guard q.x >= 0, q.y >= 0, q.z >= 0, q.x <= Double(volume.width - 1), q.y <= Double(volume.height - 1),
              q.z <= Double(volume.depth - 1) else { return nil }
        let x0 = Int(q.x), y0 = Int(q.y), z0 = Int(q.z)
        let x1 = min(x0 + 1, volume.width - 1), y1 = min(y0 + 1, volume.height - 1), z1 = min(z0 + 1, volume.depth - 1)
        let fx = Float(q.x - Double(x0)), fy = Float(q.y - Double(y0)), fz = Float(q.z - Double(z0))
        func line(_ y: Int, _ z: Int) -> Float { value(x0, y, z) * (1 - fx) + value(x1, y, z) * fx }
        func plane(_ z: Int) -> Float { line(y0, z) * (1 - fy) + line(y1, z) * fy }
        return plane(z0) * (1 - fz) + plane(z1) * fz
    }

    /// The lumen's radius in millimetres near a voxel: from the voxel of
    /// `range` nearest to it (within 2 mm, nil beyond), half the shortest
    /// chord of the lumen through it along the 13 axes of its neighbours,
    /// each chord ending at the first sample out of range or out of the
    /// volume (25 mm at most). Also that voxel, in input coordinates.
    func lumenRadius(near centre: (Int, Int, Int), in range: ClosedRange<Float>) -> (SIMD3<Float>?, Double?) {
        let s = spacing
        let (cx, cy, cz) = centre
        func inside(_ x: Int, _ y: Int, _ z: Int) -> Bool { contains(x, y, z) && range.contains(smoothed(x, y, z)) }

        var start: (Int, Int, Int)?
        var best = Double.infinity
        let reach = SIMD3(Int((2 / s.x).rounded(.up)), Int((2 / s.y).rounded(.up)), Int((2 / s.z).rounded(.up)))
        for dz in -reach.z...reach.z { for dy in -reach.y...reach.y { for dx in -reach.x...reach.x {
            let mx = Double(dx) * s.x, my = Double(dy) * s.y, mz = Double(dz) * s.z
            let squared = mx * mx + my * my + mz * mz
            if squared <= 4 && squared < best && inside(cx + dx, cy + dy, cz + dz) {
                best = squared
                start = (cx + dx, cy + dy, cz + dz)
            }
        } } }
        guard let (x0, y0, z0) = start else { return (nil, nil) }

        let origin = SIMD3(Double(x0), Double(y0), Double(z0))
        let step = 0.5 * min(s.x, s.y, s.z)
        func reachOut(_ direction: SIMD3<Double>) -> Double {
            var t = step
            while t <= 25 {
                let q = origin + direction * t / s
                if !inside(Int(q.x.rounded()), Int(q.y.rounded()), Int(q.z.rounded())) { return t }
                t += step
            }
            return 25
        }
        var radius = Double.infinity
        for direction in Self.directions.prefix(13) {
            radius = min(radius, (reachOut(direction) + reachOut(-direction)) / 2)
        }
        return (SIMD3(Float(x0), Float(y0), Float(z0)), radius)
    }
}

private extension Array where Element == Float {
    /// The element at `fraction` of a sorted array, nil when empty.
    func quantile(_ fraction: Double) -> Float? {
        isEmpty ? nil : self[Swift.min(Int(Double(count - 1) * fraction + 0.5), count - 1)]
    }
}
