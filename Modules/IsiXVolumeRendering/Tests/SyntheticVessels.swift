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

/// Gaussian noise that is the same on every run: SplitMix64 and Box–Muller.
struct SyntheticNoise {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }

    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-300), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// A synthetic CT of a vessel whose axis is known: the voxel at (i, j, k) has
/// its centre at (i, j, k) × spacing millimetres, as the input coordinates of
/// the path assistants count it. Each voxel is the mean of 2 × 2 × 2 samples
/// of the scene (the partial volume of a scanner), blurred by a Gaussian of
/// `blur` millimetres when asked (a scanner's point spread), plus Gaussian
/// noise. The scenes are written with scalars: the module's tests build
/// without optimization, where SIMD arithmetic is slow.
struct SyntheticVessel: Sendable {
    let size: SIMD3<Int>
    let spacing: SIMD3<Float>
    let voxels: [Float]
    /// The true axis, dense, in millimetres.
    let axis: [SIMD3<Double>]
    /// The lumen's radius in millimetres.
    let radius: Double
    /// The two points a user marks, in voxel coordinates, on the axis.
    let start: SIMD3<Float>
    let end: SIMD3<Float>

    init(size: SIMD3<Int>, spacing: SIMD3<Float>, axis: [SIMD3<Double>], radius: Double,
         start: SIMD3<Double>, end: SIMD3<Double>, blur: Double = 0, noise sigma: Double, seed: UInt64,
         scene: (Double, Double, Double) -> Double) {
        self.size = size
        self.spacing = spacing
        self.axis = axis
        self.radius = radius
        let sx = Double(spacing.x), sy = Double(spacing.y), sz = Double(spacing.z)
        self.start = SIMD3(Float(start.x / sx), Float(start.y / sy), Float(start.z / sz))
        self.end = SIMD3(Float(end.x / sx), Float(end.y / sy), Float(end.z / sz))
        var clean = [Double](repeating: 0, count: size.x * size.y * size.z)
        let offsets = [-0.25, 0.25]
        var index = 0
        for k in 0..<size.z {
            for j in 0..<size.y {
                for i in 0..<size.x {
                    var sum = 0.0
                    for oz in offsets { for oy in offsets { for ox in offsets {
                        sum += scene((Double(i) + ox) * sx, (Double(j) + oy) * sy, (Double(k) + oz) * sz)
                    } } }
                    clean[index] = sum / 8
                    index += 1
                }
            }
        }
        if blur > 0 {
            for (axis, voxel) in [sx, sy, sz].enumerated() {
                Self.blur(&clean, size: size, along: axis, sigma: blur / voxel)
            }
        }
        var noise = SyntheticNoise(seed: seed)
        voxels = clean.map { Float($0 + sigma * noise.gaussian()) }
    }

    /// A Gaussian of `sigma` voxels along one axis (0 x, 1 y, 2 z), the
    /// volume's edge repeated beyond it.
    private static func blur(_ values: inout [Double], size: SIMD3<Int>, along axis: Int, sigma: Double) {
        let reach = Int((3 * sigma).rounded(.up))
        var weights = (-reach...reach).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = weights.reduce(0, +)
        weights = weights.map { $0 / total }
        let count = [size.x, size.y, size.z][axis], stride = [1, size.x, size.x * size.y][axis]
        let source = values
        for index in source.indices {
            let position = (index / stride) % count
            var sum = 0.0
            for t in -reach...reach {
                let q = min(max(position + t, 0), count - 1)
                sum += source[index + (q - position) * stride] * weights[t + reach]
            }
            values[index] = sum
        }
    }

    /// Millimetres of a point in voxel coordinates.
    func millimetres(_ p: SIMD3<Float>) -> SIMD3<Double> {
        SIMD3(Double(p.x * spacing.x), Double(p.y * spacing.y), Double(p.z * spacing.z))
    }

    /// The distance in millimetres from a point in voxel coordinates to the
    /// true axis: to the nearest of its dense samples, 0.05 mm apart or less.
    func distanceToAxis(_ p: SIMD3<Float>) -> Double {
        let q = millimetres(p)
        var nearest = Double.infinity
        for a in axis {
            let dx = a.x - q.x, dy = a.y - q.y, dz = a.z - q.z
            nearest = min(nearest, dx * dx + dy * dy + dz * dz)
        }
        return nearest.squareRoot()
    }

    /// The largest distance to the axis along a path in voxel coordinates.
    func worstDistance(_ path: [SIMD3<Float>]) -> Double {
        path.map(distanceToAxis).max() ?? .infinity
    }

    // MARK: - Scenes

    /// What `coronaryBesideCavity` varies: the coronary's radius and value,
    /// the cavity's and the wall's values, the wall's thickness, fat between
    /// the coronary and the wall, an occlusion at the arc's middle, where
    /// the two points are marked off the axis (millimetres), the scanner's
    /// blur and the noise.
    struct CoronaryScene {
        var radius = 1.5
        var lumen = 400.0
        var cavity = 450.0
        var wall = 100.0
        var wallThickness = 3.0
        var fatGap = 0.0
        /// The lumen narrows half way to this radius over 4 mm.
        var stenosis: Double?
        /// The lumen is plaque of `plaque` HU over this length.
        var occlusion: Double?
        var plaque = 40.0
        var startOffset = SIMD3<Double>(0, 0, 0)
        var endOffset = SIMD3<Double>(0, 0, 0)
        var blur = 0.0
        var noise = 20.0
        var seed: UInt64 = 1
    }

    /// A coronary of `radius` millimetres (400 HU) that runs half way round a
    /// contrast-filled cavity (450 HU, 18 mm of radius) on the 3 mm of its wall
    /// (100 HU), in fat (-80 HU): the arc between the two points is 1.6 times
    /// as long as the chord, which crosses the wall twice and the cavity. The
    /// voxels of a coronary CT angiography, 0.4 × 0.4 × 0.5 mm; noise of 20 HU.
    /// With `stenosis` the lumen narrows half way to that radius, over 4 mm.
    static func coronaryBesideCavity(radius: Double, stenosis: Double? = nil, seed: UInt64 = 1) -> SyntheticVessel {
        coronaryBesideCavity(CoronaryScene(radius: radius, stenosis: stenosis, seed: seed))
    }

    /// The coronary beside a cavity with the values, wall and points of `scene`.
    static func coronaryBesideCavity(_ scene: CoronaryScene) -> SyntheticVessel {
        let radius = scene.radius
        let cx = 28.0, cy = 12.0, cz = 12.0
        let cavity = 18.0, wall = scene.wallThickness
        let arc = cavity + wall + scene.fatGap + radius
        let first = -15.0 * .pi / 180, last = 195.0 * .pi / 180
        func onArc(_ angle: Double) -> SIMD3<Double> { SIMD3(cx + arc * cos(angle), cy, cz + arc * sin(angle)) }
        let axis = stride(from: 0.0, through: .pi, by: 0.05 / arc).map(onArc)
        let ends = [onArc(first), onArc(last)]
        func lumen(_ angle: Double) -> Double {
            guard let narrowest = scene.stenosis else { return radius }
            let along = abs(angle - .pi / 2) * arc
            return along >= 2 ? radius : narrowest + (radius - narrowest) * (1 - cos(.pi * along / 2)) / 2
        }
        return SyntheticVessel(size: SIMD3(140, 60, 80), spacing: SIMD3(0.4, 0.4, 0.5), axis: axis, radius: radius,
                               start: onArc(0) + scene.startOffset, end: onArc(.pi) + scene.endOffset, blur: scene.blur,
                               noise: scene.noise, seed: scene.seed) { x, y, z in
            let rx = x - cx, ry = y - cy, rz = z - cz
            var angle = atan2(rz, rx)
            if angle < -.pi / 2 { angle += 2 * .pi }
            var toTube: Double
            if angle >= first && angle <= last {
                let inPlane = (rx * rx + rz * rz).squareRoot() - arc
                toTube = (inPlane * inPlane + ry * ry).squareRoot()
            } else {
                toTube = .infinity
                for e in ends {
                    toTube = min(toTube, ((x - e.x) * (x - e.x) + (y - e.y) * (y - e.y) + (z - e.z) * (z - e.z)).squareRoot())
                }
            }
            if toTube <= lumen(angle) {
                if let length = scene.occlusion, abs(angle - .pi / 2) * arc <= length / 2 { return scene.plaque }
                return scene.lumen
            }
            let fromCentre = (rx * rx + ry * ry + rz * rz).squareRoot()
            if fromCentre <= cavity { return scene.cavity }
            if fromCentre <= cavity + wall { return scene.wall }
            return -80
        }
    }

    /// A straight vessel along z with a stent: a lumen of `radius` millimetres
    /// (400 HU) in tissue (50 HU), and from z = 8 to z = 40 mm a ring of metal
    /// (`metal` HU, 0.2 mm thick) round it, 0.05 mm outside the lumen. Voxels of
    /// 0.4 mm, which the ring fills by a quarter to a half; noise of 20 HU.
    /// The two points are inside the stent, `offset` millimetres from the axis
    /// (along x at the first, along y at the second). With `restenosis`,
    /// tissue of 100 HU fills the lumen from z = 26 to z = 38 mm but for its
    /// part at x beyond 0.4 mm from the axis: the second point, on the axis,
    /// is then marked on that tissue, and the lumen left runs beside the mesh.
    static func stented(radius: Double = 1.85, metal: Double = 1500, offset: Double = 0, restenosis: Bool = false,
                        blur: Double = 0, seed: UInt64 = 6) -> SyntheticVessel {
        let cx = 12.8, cy = 12.8
        let axis = stride(from: 2.0, through: 46.0, by: 0.05).map { SIMD3(cx, cy, $0) }
        return SyntheticVessel(size: SIMD3(64, 64, 120), spacing: SIMD3(0.4, 0.4, 0.4), axis: axis, radius: radius,
                               start: SIMD3(cx + offset, cy, 12), end: SIMD3(cx, cy + offset, 34), blur: blur, noise: 20,
                               seed: seed) { x, y, z in
            let r = ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot()
            if r <= radius { return restenosis && z >= 26 && z <= 38 && x - cx < 0.4 ? 100 : 400 }
            if z >= 8 && z <= 40 && r >= radius + 0.05 && r <= radius + 0.25 { return metal }
            return 50
        }
    }

    /// A coronary of 1.5 mm of radius (400 HU) leaving an aorta of 10 mm of
    /// radius (450 HU) at its wall, turning down and running beside it, 3 mm
    /// of fat (-80 HU) away, for 18 mm: the first point lies in the aorta 3 mm
    /// from the ostium, as a user marks it, the second at the coronary's end.
    /// The axis is the coronary's own, from the ostium.
    static func ostium(seed: UInt64 = 4) -> SyntheticVessel {
        let radius = 1.5, aorta = 10.0, ay = 12.0, ax = 12.0
        let bend = SIMD3<Double>(23, 12, 24.5), turn = 3.5
        // From the aortic wall out along x, a quarter turn down, then down along z.
        func onAxis(_ s: Double) -> SIMD3<Double> {
            if s <= 1 { return SIMD3(22 + s, 12, 28) }
            let angle = min(s - 1, turn * .pi / 2) / turn
            if s - 1 <= turn * .pi / 2 { return bend + SIMD3(turn * sin(angle), 0, turn * cos(angle)) }
            return SIMD3(bend.x + turn, 12, bend.z - (s - 1 - turn * .pi / 2))
        }
        let length = 1 + turn * .pi / 2 + 18.5
        let axis = stride(from: 0.0, through: length, by: 0.02).map(onAxis)
        return SyntheticVessel(size: SIMD3(80, 60, 70), spacing: SIMD3(0.4, 0.4, 0.5), axis: axis, radius: radius,
                               start: SIMD3(19, 12, 28), end: onAxis(length - 0.5), noise: 20, seed: seed) { x, y, z in
            var toTube = Double.infinity
            if x >= 21 && z >= bend.z {
                let dy = y - 12, dz = z - 28
                toTube = (dy * dy + dz * dz).squareRoot()
                if x > bend.x {
                    let rx = x - bend.x, rz = z - bend.z
                    let inPlane = (rx * rx + rz * rz).squareRoot() - turn
                    toTube = (inPlane * inPlane + dy * dy).squareRoot()
                }
            } else if z < bend.z && z >= bend.z - 18.5 {
                let dx = x - bend.x - turn, dy = y - 12
                toTube = (dx * dx + dy * dy).squareRoot()
            }
            if toTube <= radius { return 400 }
            let rx = x - ax, ry = y - ay
            return rx * rx + ry * ry <= aorta * aorta ? 450 : -80
        }
    }

    /// A thin vessel of `radius` millimetres (380 HU) that winds through fat
    /// (-80 HU): a helix of 6 mm of radius and 30 mm of pitch, a turn and a
    /// half, on coronary CT angiography voxels; noise of 20 HU. With
    /// `occlusion`, plaque (40 HU) fills the lumen over that many millimetres
    /// of the axis at its middle, where the axis bends by a tenth of a
    /// radian per millimetre; then the scanner's blur is 0.3 mm.
    static func helix(radius: Double, occlusion: Double? = nil, seed: UInt64 = 2) -> SyntheticVessel {
        let cx = 10.0, cy = 10.0, coil = 6.0, pitch = 30.0, z0 = 5.0, z1 = 50.0
        let omega = 2 * .pi / pitch
        func onAxis(_ z: Double) -> SIMD3<Double> {
            SIMD3(cx + coil * cos(omega * (z - z0)), cy + coil * sin(omega * (z - z0)), z)
        }
        // The axis's length per millimetre of height, and the plaque's half height.
        let rise = (coil * omega * coil * omega + 1).squareRoot()
        let plug = (occlusion ?? 0) / 2 / rise
        let axis = stride(from: z0, through: z1, by: 0.02).map(onAxis)
        return SyntheticVessel(size: SIMD3(50, 50, 110), spacing: SIMD3(0.4, 0.4, 0.5), axis: axis, radius: radius,
                               start: onAxis(z0 + 1), end: onAxis(z1 - 1), blur: occlusion == nil ? 0 : 0.3, noise: 20,
                               seed: seed) { x, y, z in
            guard z >= z0 - radius && z <= z1 + radius else { return -80 }
            // Newton's method on the squared distance to the axis, from the
            // point's own height: the axis rises 0.6 mm per mm of arc.
            var t = z
            for _ in 0..<6 {
                let a = omega * (t - z0)
                let px = cx + coil * cos(a), py = cy + coil * sin(a)
                let dx = -coil * omega * sin(a), dy = coil * omega * cos(a)
                let ddx = -coil * omega * omega * cos(a), ddy = -coil * omega * omega * sin(a)
                let f = (px - x) * dx + (py - y) * dy + (t - z)
                let df = dx * dx + dy * dy + 1 + (px - x) * ddx + (py - y) * ddy
                t -= f / df
            }
            t = min(max(t, z0), z1)
            let a = omega * (t - z0)
            let ex = cx + coil * cos(a) - x, ey = cy + coil * sin(a) - y, ez = t - z
            guard (ex * ex + ey * ey + ez * ez).squareRoot() <= radius else { return -80 }
            return occlusion != nil && abs(t - (z0 + z1) / 2) <= plug ? 40 : 380
        }
    }

    /// A carotid-like artery of `radius` millimetres (350 HU), gently curved,
    /// in soft tissue (40 HU), with a vertebra-like column of bone (700 HU)
    /// 2.5 mm from it at the nearest: CT angiography voxels of 0.5 × 0.5 × 0.6
    /// mm, noise of 15 HU.
    static func carotid(radius: Double = 3.5, seed: UInt64 = 3) -> SyntheticVessel {
        let z0 = 3.0, z1 = 75.0
        let kx = 2 * Double.pi / 70, ky = 2 * Double.pi / 100
        func onAxis(_ z: Double) -> SIMD3<Double> { SIMD3(14 + 4 * sin(kx * z), 14 + 3 * sin(ky * z + 1), z) }
        let axis = stride(from: z0, through: z1, by: 0.02).map(onAxis)
        return SyntheticVessel(size: SIMD3(64, 56, 130), spacing: SIMD3(0.5, 0.5, 0.6), axis: axis, radius: radius,
                               start: onAxis(z0 + 3), end: onAxis(z1 - 3), noise: 15, seed: seed) { x, y, z in
            if z >= z0 - radius && z <= z1 + radius {
                var t = z
                for _ in 0..<5 {
                    let px = 14 + 4 * sin(kx * t), py = 14 + 3 * sin(ky * t + 1)
                    let dx = 4 * kx * cos(kx * t), dy = 3 * ky * cos(ky * t + 1)
                    let ddx = -4 * kx * kx * sin(kx * t), ddy = -3 * ky * ky * sin(ky * t + 1)
                    let f = (px - x) * dx + (py - y) * dy + (t - z)
                    let df = dx * dx + dy * dy + 1 + (px - x) * ddx + (py - y) * ddy
                    t -= f / df
                }
                t = min(max(t, z0), z1)
                let ex = 14 + 4 * sin(kx * t) - x, ey = 14 + 3 * sin(ky * t + 1) - y, ez = t - z
                if (ex * ex + ey * ey + ez * ez).squareRoot() <= radius { return 350 }
            }
            let bx = x - 28, by = y - 14
            if bx * bx + by * by <= 16 { return 700 }
            return 40
        }
    }
    /// An aortic arch: a tube of 12 mm of radius (450 HU) bent through half a
    /// circle of 35 mm in soft tissue (40 HU), a column of bone (800 HU) near
    /// its descending end; voxels of 0.78 × 0.78 × 1.0 mm, noise of 15 HU.
    /// The points lie on the axis a quarter of a radian from each end.
    static func aorticArch(seed: UInt64 = 5) -> SyntheticVessel {
        let r = 12.0, bend = 35.0, cx = 55.0, cz = 20.0, cy = 30.0
        func onArc(_ a: Double) -> SIMD3<Double> { SIMD3(cx + bend * cos(a), cy, cz + bend * sin(a)) }
        let axis = stride(from: 0.0, through: .pi, by: 0.0005).map(onArc)
        return SyntheticVessel(size: SIMD3(142, 77, 75), spacing: SIMD3(0.78125, 0.78125, 1.0), axis: axis, radius: r,
                               start: onArc(0.25), end: onArc(.pi - 0.25), noise: 15, seed: seed) { x, y, z in
            let rx = x - cx, rz = z - cz, ry = y - cy
            var a = atan2(rz, rx)
            if a < -.pi / 2 { a += 2 * .pi }
            if a >= 0 && a <= .pi {
                let inPlane = (rx * rx + rz * rz).squareRoot() - bend
                if (inPlane * inPlane + ry * ry).squareRoot() <= r { return 450 }
            }
            let bx = x - 100, by = y - 30
            if bx * bx + by * by <= 25 && z < 25 { return 800 }
            return 40
        }
    }

    /// A thin vessel of 1 mm of radius (400 HU) in fat (-80 HU) that turns
    /// back on itself: two parallel limbs of `limb` millimetres, `gap`
    /// millimetres of fat between them, joined by a half turn; the points lie
    /// a millimetre from the limbs' free ends, close together, and the way
    /// between them goes round the turn. Coronary CT angiography voxels; with
    /// `blur`, the scanner's point spread, which lifts a thin gap's fat toward
    /// the lumen. A `turn` (radians) turns the whole about z round the middle
    /// of the limbs' free ends, so that the gap lies across the voxels' axes,
    /// in a square field wide enough for it.
    static func hairpin(gap: Double, limb: Double, blur: Double = 0, noise: Double = 20, turn: Double = 0,
                        seed: UInt64 = 6) -> SyntheticVessel {
        let radius = 1.0, half = radius + gap / 2
        let side = limb + 12
        let x0 = 4.0, y0 = turn == 0 ? 12.0 : side / 2, z0 = 8.0
        let cosTurn = cos(turn), sinTurn = sin(turn)
        // Turned about (x0, y0); the scene is read at the point turned back.
        func turned(_ p: SIMD3<Double>) -> SIMD3<Double> {
            guard turn != 0 else { return p }
            return SIMD3(x0 + (p.x - x0) * cosTurn - (p.y - y0) * sinTurn, y0 + (p.x - x0) * sinTurn + (p.y - y0) * cosTurn, p.z)
        }
        var axis: [SIMD3<Double>] = []
        for s in stride(from: 0.0, through: limb, by: 0.05) { axis.append(SIMD3(x0 + s, y0 - half, z0)) }
        for a in stride(from: -Double.pi / 2, through: Double.pi / 2, by: 0.05 / half) {
            axis.append(SIMD3(x0 + limb + half * cos(a), y0 + half * sin(a), z0))
        }
        for s in stride(from: limb, through: 0.0, by: -0.05) { axis.append(SIMD3(x0 + s, y0 + half, z0)) }
        let size = SIMD3(Int(side / 0.4), turn == 0 ? 60 : Int(side / 0.4), 32)
        return SyntheticVessel(size: size, spacing: SIMD3(0.4, 0.4, 0.5), axis: axis.map(turned), radius: radius,
                               start: turned(SIMD3(x0 + 1, y0 - half, z0)), end: turned(SIMD3(x0 + 1, y0 + half, z0)),
                               blur: blur, noise: noise, seed: seed) { x, y, z in
            let u = turn == 0 ? x : x0 + (x - x0) * cosTurn + (y - y0) * sinTurn
            let v = turn == 0 ? y : y0 - (x - x0) * sinTurn + (y - y0) * cosTurn
            let dz = z - z0
            var toAxis: Double
            if u <= x0 + limb {
                let toLimb = min(abs(v - (y0 - half)), abs(v - (y0 + half)))
                toAxis = u >= x0 ? (toLimb * toLimb + dz * dz).squareRoot() : .infinity
            } else {
                let inPlane = ((u - x0 - limb) * (u - x0 - limb) + (v - y0) * (v - y0)).squareRoot() - half
                toAxis = (inPlane * inPlane + dz * dz).squareRoot()
            }
            return toAxis <= radius ? 400 : -80
        }
    }
}

/// The voxel the Curved MPR resamples to for its path assistant: the volume's
/// own in-plane spacing, or the field of view over 256 when the matrix is
/// larger than 256 (0.78 mm for a 512 matrix over 200 mm).
func curvedMPRResampleVoxel(matrix: Int, fieldOfView: Float, spacing: Float) -> Float {
    matrix > 256 ? Float(Double(fieldOfView) / 256.0) : spacing
}
