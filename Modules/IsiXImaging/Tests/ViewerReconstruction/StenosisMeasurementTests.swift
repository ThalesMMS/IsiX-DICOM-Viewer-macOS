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
import simd
@testable import IsiXImaging

/// A section as a CT gives it: what the anatomy is, sample by sample, then
/// the blur of the scanner, which is what makes calcium bloom over what lies
/// beside it.
private struct SyntheticSection {
    let settings: Stenosis.Settings
    let size: Int
    var values: [Float]

    /// `anatomy` gives the intensity at a place of the section, in mm from
    /// the centerline; `blur` is the standard deviation of the scanner's
    /// point spread, in mm.
    init(settings: Stenosis.Settings = Stenosis.Settings(), blur: Double = 0.35, anatomy: (Double, Double) -> Double) {
        self.settings = settings
        let size = 2 * Int((settings.maxRadius / settings.pixel).rounded()) + 1
        let c = size / 2
        var sharp = [Double](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size { sharp[y * size + x] = anatomy(Double(x - c) * settings.pixel, Double(y - c) * settings.pixel) }
        }
        let reach = Int((3 * blur / settings.pixel).rounded(.up))
        let kernel = (-reach...reach).map { exp(-pow(Double($0) * settings.pixel, 2) / (2 * blur * blur)) }
        let total = kernel.reduce(0, +)
        func pass(_ input: [Double], dx: Int, dy: Int) -> [Double] {
            var output = input
            for y in 0..<size {
                for x in 0..<size {
                    var sum = 0.0
                    for (k, weight) in kernel.enumerated() {
                        let xx = min(max(x + (k - reach) * dx, 0), size - 1), yy = min(max(y + (k - reach) * dy, 0), size - 1)
                        sum += weight * input[yy * size + xx]
                    }
                    output[y * size + x] = sum / total
                }
            }
            return output
        }
        self.size = size
        values = pass(pass(sharp, dx: 1, dy: 0), dx: 0, dy: 1).map { Float($0) }
    }

    /// The lumen, with calcium told against `contrast`, the contrast of a
    /// reference, or not told when there is none.
    func mask(_ settings: Stenosis.Settings? = nil, contrast: Float? = nil, erased: [Bool] = []) -> [Bool] {
        Stenosis.segment(values: values, size: size, settings: settings ?? self.settings, contrast: contrast, erased: erased)?.mask ?? []
    }

    /// The lumen as the tool found it before it told calcium apart.
    func frozen(_ settings: Stenosis.Settings? = nil) -> [Bool] {
        FrozenSegmentation.segment(values: values, size: size, settings: settings ?? self.settings)?.mask ?? []
    }

    /// The noise of a CT: independent from voxel to voxel of `voxel` mm, of
    /// standard deviation `sd`, and linearly interpolated between them, as
    /// the curved MPR samples the volume. The same `seed`, the same noise.
    mutating func addNoise(sd: Double, seed: UInt64, voxel: Double = 0.4) {
        var state = seed
        func gaussian() -> Double {
            var sum = 0.0
            for _ in 0..<12 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                sum += Double(state >> 11) / Double(1 << 53)
            }
            return sum - 6
        }
        let n = Int((Double(size) * settings.pixel / voxel).rounded(.up)) + 2
        let grid = (0..<(n * n)).map { _ in gaussian() * sd }
        for y in 0..<size {
            for x in 0..<size {
                let gx = Double(x) * settings.pixel / voxel, gy = Double(y) * settings.pixel / voxel
                let (x0, y0) = (Int(gx), Int(gy))
                let (fx, fy) = (gx - Double(x0), gy - Double(y0))
                let top = grid[y0 * n + x0] * (1 - fx) + grid[y0 * n + x0 + 1] * fx
                let bottom = grid[(y0 + 1) * n + x0] * (1 - fx) + grid[(y0 + 1) * n + x0 + 1] * fx
                values[y * size + x] += Float(top * (1 - fy) + bottom * fy)
            }
        }
    }

    /// The area of the part of a mask that `where` keeps, in mm².
    func area(_ mask: [Bool], where keep: (Double, Double) -> Bool = { _, _ in true }) -> Double {
        let c = size / 2
        var count = 0
        for y in 0..<size {
            for x in 0..<size where mask[y * size + x] && keep(Double(x - c) * settings.pixel, Double(y - c) * settings.pixel) { count += 1 }
        }
        return Double(count) * settings.pixel * settings.pixel
    }

    /// The section as a volume that is the same all along z, for `Stenosis.section`.
    func sample(_ p: SIMD3<Double>) -> Float {
        let c = Double(size / 2)
        let x = Int((p.x / settings.pixel + c).rounded()), y = Int((p.y / settings.pixel + c).rounded())
        return x < 0 || y < 0 || x >= size || y >= size ? 0 : values[y * size + x]
    }
}

/// The segmentation of a section as the tool shipped it before it told
/// calcium apart, copied here as it was and frozen: its own center, the
/// lumen between two shares of it, opened by the neck, with its holes
/// filled. A section without calcium, without the ring of a stent's struts
/// and without wide tissue darker than the lumen's edge that the lumen
/// surrounds has to come out of the tool exactly so.
private enum FrozenSegmentation {
    static func segment(values: [Float], size: Int, settings: Stenosis.Settings) -> (mask: [Bool], centerValue: Float)? {
        let c = size / 2
        let pixelsPerMM = 1 / settings.pixel
        let radius = settings.maxRadius * pixelsPerMM
        var around: [Float] = []
        for y in max(c - 2, 0)...min(c + 2, size - 1) {
            for x in max(c - 2, 0)...min(c + 2, size - 1) { around.append(values[y * size + x]) }
        }
        around.sort()
        let center = around[around.count / 2]
        guard center >= settings.minimumLumenValue, center > 0 else { return nil }
        let lower = Float(settings.lowerFraction) * center, upper = Float(settings.upperFraction) * center

        var inside = [Bool](repeating: false, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let dx = Double(x - c), dy = Double(y - c)
                let v = values[y * size + x]
                inside[y * size + x] = dx * dx + dy * dy <= radius * radius && v >= lower && v <= upper
            }
        }
        guard let seed = nearest(in: inside, size: size, to: c * size + c, within: Int(pixelsPerMM)) else { return nil }

        let neck = settings.neck * pixelsPerMM
        let distanceOut = distanceTransform(inside, size: size)
        let eroded = distanceOut.map { $0 > neck }
        var lumen: [Bool]
        if let core = nearest(in: eroded, size: size, to: seed, within: Int(neck) + 1) {
            let kept = component(of: eroded, size: size, from: core)
            let distanceIn = distanceTransform(kept.map { !$0 }, size: size)
            let grown = zip(distanceIn, inside).map { $0 <= neck + 0.5 && $1 }
            lumen = component(of: grown, size: size, from: seed)
        } else {
            lumen = component(of: inside, size: size, from: seed)
        }
        fillHoles(&lumen, size: size)
        return (lumen, center)
    }

    private static func nearest(in mask: [Bool], size: Int, to pixel: Int, within: Int) -> Int? {
        if mask[pixel] { return pixel }
        let (px, py) = (pixel % size, pixel / size)
        var best: (Int, Int)? = nil
        for y in max(py - within, 0)...min(py + within, size - 1) {
            for x in max(px - within, 0)...min(px + within, size - 1) where mask[y * size + x] {
                let d = (x - px) * (x - px) + (y - py) * (y - py)
                if d <= within * within && (best == nil || d < best!.1) { best = (y * size + x, d) }
            }
        }
        return best?.0
    }

    private static func component(of mask: [Bool], size: Int, from start: Int) -> [Bool] {
        var result = [Bool](repeating: false, count: mask.count)
        guard mask[start] else { return result }
        var stack = [start]
        result[start] = true
        while let p = stack.popLast() {
            let (x, y) = (p % size, p / size)
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < size && ny < size {
                let n = ny * size + nx
                if mask[n] && !result[n] { result[n] = true; stack.append(n) }
            }
        }
        return result
    }

    private static func fillHoles(_ mask: inout [Bool], size: Int) {
        var outside = [Bool](repeating: false, count: mask.count)
        var stack: [Int] = []
        for i in 0..<size {
            for p in [i, (size - 1) * size + i, i * size, i * size + size - 1] where !mask[p] && !outside[p] {
                outside[p] = true; stack.append(p)
            }
        }
        while let p = stack.popLast() {
            let (x, y) = (p % size, p / size)
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < size && ny < size {
                let n = ny * size + nx
                if !mask[n] && !outside[n] { outside[n] = true; stack.append(n) }
            }
        }
        for i in mask.indices where !outside[i] { mask[i] = true }
    }

    private static func distanceTransform(_ mask: [Bool], size: Int) -> [Double] {
        let far = Int.max / 4
        var d = mask.map { $0 ? far : 0 }
        func at(_ x: Int, _ y: Int) -> Int { (x < 0 || y < 0 || x >= size || y >= size) ? 0 : d[y * size + x] }
        for y in 0..<size {
            for x in 0..<size where d[y * size + x] > 0 {
                d[y * size + x] = min(d[y * size + x], at(x - 1, y) + 3, at(x, y - 1) + 3, at(x - 1, y - 1) + 4, at(x + 1, y - 1) + 4)
            }
        }
        for y in stride(from: size - 1, through: 0, by: -1) {
            for x in stride(from: size - 1, through: 0, by: -1) where d[y * size + x] > 0 {
                d[y * size + x] = min(d[y * size + x], at(x + 1, y) + 3, at(x, y + 1) + 3, at(x + 1, y + 1) + 4, at(x - 1, y + 1) + 4)
            }
        }
        return d.map { Double($0) / 3 }
    }
}

/// Whether every pixel of `mask` is one of `of`.
private func isWithin(_ mask: [Bool], _ of: [Bool]) -> Bool {
    mask.count == of.count && mask.indices.allSatisfy { !mask[$0] || of[$0] }
}

/// The area a closed polygon encloses, in the square of its unit.
private func enclosedArea(_ polygon: [SIMD2<Double>]) -> Double {
    abs(polygon.indices.reduce(0.0) { sum, i in
        let (a, b) = (polygon[i], polygon[(i + 1) % polygon.count])
        return sum + a.x * b.y - b.x * a.y
    }) / 2
}

/// A lumen of 2 mm radius at 400 HU in soft tissue at 50 HU, and in its wall,
/// on the +x side, a plaque 1 mm thick over 80° of the circumference.
private func plaqueSection(plaque: Double, thickness: Double = 1.0) -> SyntheticSection {
    SyntheticSection { x, y in
        let rho = (x * x + y * y).squareRoot()
        if rho <= 2 { return 400 }
        if isPlaque(x, y, thickness: thickness) { return plaque }
        return 50
    }
}

private func isPlaque(_ x: Double, _ y: Double, thickness: Double = 1.0) -> Bool {
    let rho = (x * x + y * y).squareRoot()
    return rho > 2 && rho <= 2 + thickness && abs(atan2(y, x)) <= 40 * .pi / 180
}

private let lumenArea = Double.pi * 4

/// The frame of a section of a vessel along z, whose axes are the grid's.
private let frame = Stenosis.Frame(point: SIMD3(0, 0, 0), tangent: SIMD3(0, 0, 1), normal: SIMD3(0, 1, 0))

/// What a mask holds beyond the lumen's wall and its blurred edge, in mm².
private func beyondTheWall(_ section: SyntheticSection, _ mask: [Bool]) -> Double {
    section.area(mask) { ($0 * $0 + $1 * $1).squareRoot() > 2.2 }
}

/// A lumen of radius `r` at 400 HU in soft tissue at 50 HU, and in its wall
/// calcium of `calcium` HU, `thickness` mm thick, over an arc of `arc`
/// degrees of the circumference centered on +x.
private func calcifiedSection(r: Double, calcium: Double, thickness: Double, arc: Double = 180, blur: Double = 0.35) -> SyntheticSection {
    SyntheticSection(blur: blur) { x, y in
        let rho = (x * x + y * y).squareRoot()
        if rho <= r { return 400 }
        if rho <= r + thickness && abs(atan2(y, x)) <= arc / 2 * .pi / 180 { return calcium }
        return 50
    }
}

/// The contrast of the reference, a lumen free of calcium.
private let referenceContrast: Float = 400

/// A restenosis inside a stent of 2 mm radius whose struts lie so close
/// that, blurred, they make one ring, 0.15 mm thick at 3000 HU, whose peak
/// stays under 1.6 × the contrast: the threshold counts it as lumen. Inside
/// the stent, against it on +x, the lumen left, of radius `inner`, at
/// 400 HU, around the centerline; in the rest of the stent the neointima,
/// at 50 HU, as dark as the soft tissue outside.
private func restenosisSection(inner: Double, blur: Double) -> SyntheticSection {
    SyntheticSection(blur: blur) { x, y in
        if (x * x + y * y).squareRoot() <= inner { return 400 }
        return abs(fromTheStentAxis(x, y, inner: inner) - 2) <= 0.075 ? 3000 : 50
    }
}

/// The distance of a place of that section from the stent's axis, which
/// lies 2 − `inner` mm from the centerline toward −x.
private func fromTheStentAxis(_ x: Double, _ y: Double, inner: Double) -> Double {
    let sx = x + 2 - inner
    return (sx * sx + y * y).squareRoot()
}

/// A straight stretch along z from the origin: `steps` + 1 places 0.5 mm apart.
private func stretch(of steps: Int) -> [Stenosis.Place] {
    (0...steps).map { i in
        Stenosis.Place(position: Double(i) * 0.5, relativePosition: Double(i) / Double(steps),
                       frame: Stenosis.Frame(point: SIMD3(0, 0, Double(i) * 0.5), tangent: SIMD3(0, 0, 1), normal: SIMD3(0, 1, 0)))
    }
}

/// A stent of the fixture's struts: blurred, one ring 0.3 mm thick at
/// 1500 HU around `radius` mm, whose peak stays under 1.6 × the contrast
/// from a blur of 0.4 mm on. Inside it, the lumen left, of radius `inner`,
/// at 400 HU, around the centerline and against the struts on +x (the whole
/// stent when `inner` is `radius` − 0.15), and neointima at 50 HU in the
/// rest; soft tissue at 50 HU outside. `extra` puts something else at a place.
private func stentSection(radius: Double = 2, inner: Double, blur: Double, noise: Double = 0, seed: UInt64 = 0,
                          extra: @escaping (Double, Double) -> Double? = { _, _ in nil }) -> SyntheticSection {
    let axis = radius - 0.15 - inner
    var section = SyntheticSection(blur: blur) { x, y in
        if let value = extra(x, y) { return value }
        if (x * x + y * y).squareRoot() <= inner { return 400 }
        return abs(((x + axis) * (x + axis) + y * y).squareRoot() - radius) <= 0.15 ? 1500 : 50
    }
    if noise > 0 { section.addNoise(sd: noise, seed: seed) }
    return section
}

/// A section as an edge-enhancing reconstruction kernel gives it: the
/// blurred anatomy sharpened by an unsharp mask of `amount` and `width` mm,
/// v + amount × (v − v blurred again by `width`), which puts a bright rim
/// inside the edge of a lumen and a dark one outside it.
private func sharpenedSection(blur: Double, amount: Double, width: Double, anatomy: @escaping (Double, Double) -> Double) -> SyntheticSection {
    var section = SyntheticSection(blur: blur, anatomy: anatomy)
    let wider = SyntheticSection(blur: (blur * blur + width * width).squareRoot(), anatomy: anatomy)
    for i in section.values.indices { section.values[i] += Float(amount) * (section.values[i] - wider.values[i]) }
    return section
}

/// How far a mask reaches from the center of its grid toward −x, in mm.
private func reachTowardMinusX(_ section: SyntheticSection, _ mask: [Bool]) -> Double {
    let c = section.size / 2
    var k = 0
    while c - k - 1 >= 0 && mask[c * section.size + c - k - 1] { k += 1 }
    return Double(k) * section.settings.pixel
}

/// A CT volume as the curved MPR samples it, linearly between voxels of
/// 0.4 mm from `origin`, in patient space (mm): the anatomy averaged over a
/// grid three times finer in the plane, blurred by the scanner's point
/// spread of `blur` mm, and the noise of a CT of `noise` HU from voxel to
/// voxel. The same `seed`, the same noise. Beyond it lies soft tissue.
private struct SyntheticVolume: Sendable {
    let origin: SIMD3<Double>
    let counts: (x: Int, y: Int, z: Int)
    let values: [Float]
    static let voxel = 0.4

    init(origin: SIMD3<Double>, counts: (x: Int, y: Int, z: Int), blur: Double, noise: Double, seed: UInt64,
         anatomy: (SIMD3<Double>) -> Double) {
        self.origin = origin
        self.counts = counts
        let voxel = Self.voxel
        var v = [Double](repeating: 0, count: counts.x * counts.y * counts.z)
        for k in 0..<counts.z {
            for j in 0..<counts.y {
                for i in 0..<counts.x {
                    var sum = 0.0
                    for b in -1...1 {
                        for a in -1...1 {
                            sum += anatomy(origin + SIMD3(Double(i) * voxel + Double(a) * voxel / 3, Double(j) * voxel + Double(b) * voxel / 3,
                                                          Double(k) * voxel))
                        }
                    }
                    v[(k * counts.y + j) * counts.x + i] = sum / 9
                }
            }
        }
        let sigma = blur / voxel, reach = Int((3 * sigma).rounded(.up))
        let weights = (-reach...reach).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let total = weights.reduce(0, +)
        for (stride, count) in [(1, counts.x), (counts.x, counts.y), (counts.x * counts.y, counts.z)] {
            var blurred = v
            for index in v.indices {
                let at = (index / stride) % count
                var sum = 0.0
                for (t, weight) in weights.enumerated() { sum += weight * v[index + (min(max(at + t - reach, 0), count - 1) - at) * stride] }
                blurred[index] = sum / total
            }
            v = blurred
        }
        var state = seed
        func gaussian() -> Double {
            var sum = 0.0
            for _ in 0..<12 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                sum += Double(state >> 11) / Double(1 << 53)
            }
            return sum - 6
        }
        values = v.map { Float($0 + noise * gaussian()) }
    }

    func sample(_ p: SIMD3<Double>) -> Float {
        let f = (p - origin) / Self.voxel
        let (i, j, k) = (Int(f.x.rounded(.down)), Int(f.y.rounded(.down)), Int(f.z.rounded(.down)))
        guard i >= 0, j >= 0, k >= 0, i + 1 < counts.x, j + 1 < counts.y, k + 1 < counts.z else { return 50 }
        let a = f - SIMD3(Double(i), Double(j), Double(k))
        var sum: Float = 0
        for dk in 0...1 {
            for dj in 0...1 {
                for di in 0...1 {
                    let weight = (di == 0 ? 1 - a.x : a.x) * (dj == 0 ? 1 - a.y : a.y) * (dk == 0 ? 1 - a.z : a.z)
                    sum += Float(weight) * values[((k + dk) * counts.y + j + dj) * counts.x + i + di]
                }
            }
        }
        return sum
    }
}

/// The stented vessel of the in-app check, as its generator writes it: a
/// lumen of 1.85 mm radius at 400 HU along z through (25.6, 25.6) mm, in soft
/// tissue at 50 HU; from z 8 to 40 mm the struts of a stent as one ring
/// 0.3 mm thick at 1500 HU round 2 mm; inside it the lumen left by two
/// restenoses, against the stent on +x, of 1 mm radius from z 15 to 20 and
/// 0.75 mm from z 29 to 34, with ramps of 3 mm, and neointima at 50 HU in the
/// rest of the stent. Blurred by 0.4 mm, with 12 HU of noise.
private enum StentedVessel {
    /// The nodes of its centerline, on the axis of the lumen left: where
    /// they lie along z, and the radius of the lumen left there.
    static let nodes: [(z: Double, left: Double)] = [(4, 1.85), (12, 1.85), (15, 1.0), (20, 1.0), (23, 1.85), (26, 1.85),
                                                     (29, 0.75), (34, 0.75), (37, 1.85), (44, 1.85)]

    /// The radius of the lumen left at `z`.
    static func left(at z: Double) -> Double {
        guard (8...40).contains(z) else { return 1.85 }
        for (a, b) in zip(nodes, nodes.dropFirst()) where a.z <= z && z <= b.z { return a.left + (b.left - a.left) * (z - a.z) / (b.z - a.z) }
        return 1.85
    }

    static let volume = SyntheticVolume(origin: SIMD3(19.2, 19.2, 0), counts: (32, 32, 120), blur: 0.4, noise: 12, seed: 0x57E) { p in
        let x = p.x - 25.6, y = p.y - 25.6
        let radius = StentedVessel.left(at: p.z), offset = 1.85 - radius
        if ((x - offset) * (x - offset) + y * y).squareRoot() <= radius { return 400 }
        return (8...40).contains(p.z) && abs((x * x + y * y).squareRoot() - 2) <= 0.15 ? 1500 : 50
    }

    /// The path the curved MPR draws through the nodes, as the tool reads
    /// it every 0.5 mm from z 4: the point (x, z; y is 25.6) and the tangent
    /// (x, z). The bezier path swings up to 0.37 mm off the axis of the lumen
    /// left, toward the struts, and leans up to 20°.
    static let curvedPath: [(x: Double, z: Double, tx: Double, tz: Double)] = [
    (25.6000, 4.0000, -0.0757, 0.9971), (25.5621, 4.4986, -0.0743, 0.9972), (25.5243, 4.9971, -0.0729, 0.9973),
    (25.4864, 5.4957, -0.0715, 0.9974), (25.4486, 5.9943, -0.0701, 0.9975), (25.4161, 6.4932, -0.0605, 0.9982),
    (25.3840, 6.9922, -0.0505, 0.9987), (25.3518, 7.4911, -0.0404, 0.9992), (25.3197, 7.9901, -0.0303, 0.9995),
    (25.3188, 8.4900, -0.0067, 1.0000), (25.3217, 8.9900, 0.0187, 0.9998), (25.3247, 9.4900, 0.0440, 0.9990),
    (25.3277, 9.9900, 0.0693, 0.9976), (25.3894, 10.4857, 0.1023, 0.9948), (25.4583, 10.9809, 0.1361, 0.9907),
    (25.5272, 11.4762, 0.1699, 0.9855), (25.5960, 11.9714, 0.2034, 0.9791), (25.7281, 12.4534, 0.2258, 0.9742),
    (25.8640, 12.9346, 0.2475, 0.9689), (25.9999, 13.4157, 0.2691, 0.9631), (26.1365, 13.8967, 0.2519, 0.9678),
    (26.2732, 14.3777, 0.2270, 0.9739), (26.4098, 14.8586, 0.2020, 0.9794), (26.4905, 15.3507, 0.1718, 0.9851),
    (26.5478, 15.8474, 0.1391, 0.9903), (26.6051, 16.3441, 0.1063, 0.9943), (26.6624, 16.8408, 0.0733, 0.9973),
    (26.7197, 17.3375, 0.0403, 0.9992), (26.7204, 17.8359, -0.0087, 1.0000), (26.6922, 18.3351, -0.0661, 0.9978),
    (26.6559, 18.8334, -0.1215, 0.9926), (26.5690, 19.3257, -0.1666, 0.9860), (26.4821, 19.8181, -0.2113, 0.9774),
    (26.3614, 20.3026, -0.2368, 0.9715), (26.2209, 20.7825, -0.2513, 0.9679), (26.0804, 21.2623, -0.2657, 0.9641),
    (25.9443, 21.7434, -0.2584, 0.9660), (25.8121, 22.2257, -0.2308, 0.9730), (25.6800, 22.7079, -0.2029, 0.9792),
    (25.5790, 23.1960, -0.1620, 0.9868), (25.5258, 23.6932, -0.1006, 0.9949), (25.4725, 24.1903, -0.0388, 0.9992),
    (25.4582, 24.6875, 0.0270, 0.9996), (25.5119, 25.1846, 0.1001, 0.9950), (25.5656, 25.6817, 0.1729, 0.9849),
    (25.6588, 26.1699, 0.2331, 0.9725), (25.8224, 26.6424, 0.2729, 0.9620), (25.9860, 27.1149, 0.3123, 0.9500),
    (26.1526, 27.5862, 0.3414, 0.9399), (26.3332, 28.0525, 0.3255, 0.9456), (26.5137, 28.5188, 0.3094, 0.9509),
    (26.6942, 28.9851, 0.2933, 0.9560), (26.8080, 29.4718, 0.2378, 0.9713), (26.9195, 29.9592, 0.1799, 0.9837),
    (26.9972, 30.4516, 0.1217, 0.9926), (27.0330, 30.9504, 0.0627, 0.9980), (27.0688, 31.4491, 0.0037, 1.0000),
    (27.0380, 31.9477, -0.0537, 0.9986), (27.0005, 32.4463, -0.1109, 0.9938), (26.9369, 32.9410, -0.1669, 0.9860),
    (26.8277, 33.4289, -0.2213, 0.9752), (26.7186, 33.9169, -0.2749, 0.9615), (26.5555, 34.3888, -0.2996, 0.9541),
    (26.3814, 34.8575, -0.3184, 0.9480), (26.2072, 35.3262, -0.3370, 0.9415), (26.0356, 35.7958, -0.3272, 0.9449),
    (25.8655, 36.2660, -0.2991, 0.9542), (25.6954, 36.7362, -0.2707, 0.9627), (25.5633, 37.2164, -0.2336, 0.9723),
    (25.4797, 37.7094, -0.1852, 0.9827), (25.3962, 38.2023, -0.1362, 0.9907), (25.3133, 38.6953, -0.0871, 0.9962),
    (25.3097, 39.1953, -0.0522, 0.9986), (25.3062, 39.6953, -0.0172, 0.9999), (25.3026, 40.1953, 0.0179, 0.9998),
    (25.3206, 40.6945, 0.0419, 0.9991), (25.3590, 41.1931, 0.0556, 0.9985), (25.3975, 41.6916, 0.0693, 0.9976),
    (25.4359, 42.1901, 0.0830, 0.9966), (25.4808, 42.6881, 0.0855, 0.9963), (25.5260, 43.1860, 0.0874, 0.9962),
    (25.5713, 43.6840, 0.0893, 0.9960)
    ]
    static let curvedPathLength = 40.8173

    /// The places of the stretch from z 4 to 44, every 0.5 mm, along the
    /// curved path, or along the axis of the lumen left (the straight lines
    /// between the nodes), with the length of the stretch.
    static func places(alongTheCurvedPath curved: Bool) -> (places: [Stenosis.Place], length: Double) {
        func place(_ position: Double, length: Double, point: SIMD3<Double>, tangent: SIMD3<Double>) -> Stenosis.Place {
            Stenosis.Place(position: position, relativePosition: position / length,
                           frame: Stenosis.Frame(point: point, tangent: tangent, normal: SIMD3(tangent.z, 0, -tangent.x)))
        }
        if curved {
            let places = curvedPath.enumerated().map { i, p in
                place(min(Double(i) * 0.5, curvedPathLength), length: curvedPathLength, point: SIMD3(p.x, 25.6, p.z),
                      tangent: simd_normalize(SIMD3(p.tx, 0, p.tz)))
            }
            return (places, curvedPathLength)
        }
        let points = nodes.map { SIMD3(25.6 + 1.85 - $0.left, 25.6, $0.z) }
        var along = [0.0]
        for (a, b) in zip(points, points.dropFirst()) { along.append(along[along.count - 1] + simd_length(b - a)) }
        let length = along[along.count - 1]
        let places = (0...Int((length / 0.5).rounded(.down))).map { i -> Stenosis.Place in
            let s = min(Double(i) * 0.5, length)
            var k = 0
            while k < points.count - 2 && along[k + 1] < s { k += 1 }
            let u = (s - along[k]) / (along[k + 1] - along[k])
            return place(s, length: length, point: points[k] + u * (points[k + 1] - points[k]), tangent: simd_normalize(points[k + 1] - points[k]))
        }
        return (places, length)
    }
}

/// A straight stent along z through (6.4, 6.4) mm, of that vessel's struts
/// and contrast, its lumen left of radius `left` against the struts on +x.
private func straightStent(left: Double) -> SyntheticVolume {
    SyntheticVolume(origin: SIMD3(0, 0, 0), counts: (32, 32, 40), blur: 0.4, noise: 12, seed: 7) { p in
        let x = p.x - 6.4, y = p.y - 6.4, offset = 1.85 - left
        if ((x - offset) * (x - offset) + y * y).squareRoot() <= left { return 400 }
        return abs((x * x + y * y).squareRoot() - 2) <= 0.15 ? 1500 : 50
    }
}

/// The lumen edges, the calcium limits and the calcium margins the tool offers.
private let edges = (0...10).map { 0.3 + Double($0) * 0.05 }
private let limits = (0...7).map { Stenosis.Settings.calciumLimits.lowerBound + Double($0) * 0.1 }
private let margins = (0...10).map { Double($0) / 10 }

@Suite struct StenosisMeasurementTests {

    // MARK: - Without calcium

    /// Round lumens without calcium, of 0.38 mm (narrower than twice the
    /// neck) to 6 mm radius (a carotid bulb), whose centerline runs at their
    /// center, halfway to their wall, on their wall (95 and 105 % of the
    /// radius) or outside it (110 %); as bright as the reference, a third
    /// dimmer (the contrast fades along the vessel, or the partial volume of
    /// a narrowing dims it) and 15 % brighter; blurred by 0.35 and 0.5 mm;
    /// without noise and in the noise of a CT of 20 and 40 HU. Each is
    /// measured with the settings as the tool starts and with every lumen
    /// edge, calcium limit and margin the tool offers, in turn. None has the
    /// ring of a stent's struts, nor tissue wider than 1.5 mm that the lumen
    /// surrounds: each is the frozen lumen, even where, with the lowest
    /// edges and a centerline outside the wall, the edge falls to the soft
    /// tissue's own level and the lumen runs into the noise of the tissue.
    @Test(arguments: [0.38, 0.6, 1.0, 2.0, 3.5, 6.0])
    func aSectionWithoutCalciumIsTheLumenItsCenterlineFindsWhateverTheReferenceAndTheSettings(radius r: Double) {
        var turn = 0
        for share in [0.0, 0.5, 0.95, 1.05, 1.1] {
            for brightness in [1.0, 0.65, 1.15] {
                for blur in [0.35, 0.5] {
                    let base = SyntheticSection(blur: blur) { x, y in
                        ((x - share * r) * (x - share * r) + y * y).squareRoot() <= r ? 400 * brightness : 50
                    }
                    for sd in [0.0, 20.0, 40.0] {
                        var section = base
                        if sd > 0 { section.addNoise(sd: sd, seed: 0x5DEECE66D &+ UInt64(turn)) }
                        var settings = [Stenosis.Settings()]
                        var edge = Stenosis.Settings(), limit = Stenosis.Settings(), margin = Stenosis.Settings()
                        edge.lowerFraction = edges[turn % edges.count]
                        limit.upperFraction = limits[turn % limits.count]
                        margin.calciumMargin = margins[turn % margins.count]
                        margin.upperFraction = limits[(turn + 3) % limits.count]
                        settings += [edge, limit, margin]
                        turn += 1
                        for setting in settings {
                            let frozen = section.frozen(setting)
                            for contrast in [referenceContrast, nil] as [Float?] {
                                let measured = Stenosis.segment(values: section.values, size: section.size, settings: setting, contrast: contrast)
                                let what = "r \(r), centerline at \(share) r, \(brightness) of the reference, blur \(blur), sd \(sd), edge \(setting.lowerFraction), limit \(setting.upperFraction), margin \(setting.calciumMargin), contrast \(String(describing: contrast))"
                                #expect((measured?.mask ?? []) == frozen, "\(what)")
                                #expect(measured?.lumenTaken == nil, "\(what)")
                            }
                        }
                    }
                }
            }
        }
    }

    /// Every lumen edge and every calcium limit the tool offers, each on
    /// lumens without calcium whose centerline runs at their center and on
    /// their wall, in the noise of a CT of 40 HU.
    @Test(arguments: edges)
    func everyLumenEdgeAndCalciumLimitLeavesASectionWithoutCalciumAsItsCenterlineFindsIt(edge: Double) {
        for (k, (r, share)) in [(0.6, 0.0), (2.0, 1.0), (6.0, 1.05)].enumerated() {
            var section = SyntheticSection(blur: 0.5) { x, y in ((x - share * r) * (x - share * r) + y * y).squareRoot() <= r ? 400 : 50 }
            section.addNoise(sd: 40, seed: 0xA5A5 &+ UInt64(k) &+ UInt64(edge * 100) &* 7)
            for limit in limits {
                var settings = Stenosis.Settings()
                settings.lowerFraction = edge
                settings.upperFraction = limit
                #expect(section.mask(settings, contrast: referenceContrast) == section.frozen(settings), "r \(r), \(share) r off, edge \(edge), limit \(limit)")
            }
        }
    }

    /// Elliptical lumens without calcium, twice as wide as deep, whose
    /// centerline runs at their center, halfway to their wall along their
    /// major axis and on their wall; as bright as the reference, a third
    /// dimmer and 15 % brighter; blurred by 0.35 and 0.5 mm; without noise
    /// and in the noise of a CT of 25 and 40 HU; with lumen edges from 40 to
    /// 80 %.
    @Test(arguments: [(1.0, 0.5), (2.0, 1.0), (3.0, 1.5)])
    func anEllipticalLumenWithoutCalciumIsTheLumenItsCenterlineFindsIt(a: Double, b: Double) {
        var turn: UInt64 = 0
        for share in [0.0, 0.5, 0.95] {
            for brightness in [1.0, 0.65, 1.15] {
                for blur in [0.35, 0.5] {
                    let base = SyntheticSection(blur: blur) { x, y in
                        let u = (x - share * a) / a, v = y / b
                        return u * u + v * v <= 1 ? 400 * brightness : 50
                    }
                    for sd in [0.0, 25.0, 40.0] {
                        var section = base
                        if sd > 0 { section.addNoise(sd: sd, seed: 0xE111 &+ turn &* 0x9E3779B97F4A7C15) }
                        turn += 1
                        for edge in [0.4, 0.5, 0.65, 0.8] {
                            var settings = Stenosis.Settings()
                            settings.lowerFraction = edge
                            let what = "\(a) × \(b) mm, centerline at \(share), \(brightness) of the reference, blur \(blur), sd \(sd), edge \(edge)"
                            #expect(section.mask(settings, contrast: referenceContrast) == section.frozen(settings), "\(what)")
                        }
                    }
                }
            }
        }
    }

    /// The sections of a stretch without calcium, as `Stenosis.sections`
    /// measures them against the contrast of its reference, against the
    /// lumen the frozen segmentation finds in each. The lumen is never larger
    /// than that one, so the same area is the same lumen.
    private func expectEachSectionAsItsCenterlineFindsIt(_ name: String, length: Double, settings: Stenosis.Settings,
                                                         sample: (SIMD3<Double>) -> Float) throws -> [Stenosis.Section] {
        func along(_ t: Double) -> Stenosis.Frame {
            Stenosis.Frame(point: SIMD3(0, 0, t * length), tangent: SIMD3(0, 0, 1), normal: SIMD3(0, 1, 0))
        }
        let measured = Stenosis.sections(from: 0, to: 1, length: length, settings: settings, frame: along, sample: sample)
        let size = Stenosis.gridSize(settings), c = size / 2
        for section in measured {
            let (xAxis, yAxis) = section.frame.axes
            var values = [Float](repeating: 0, count: size * size)
            for y in 0..<size {
                for x in 0..<size {
                    values[y * size + x] = sample(section.frame.point + Double(x - c) * settings.pixel * xAxis + Double(y - c) * settings.pixel * yAxis)
                }
            }
            let frozen = FrozenSegmentation.segment(values: values, size: size, settings: settings)?.mask.filter { $0 }.count ?? 0
            #expect(Int((section.area / (settings.pixel * settings.pixel)).rounded()) == frozen, "\(name), at \(section.position) mm")
            #expect(!section.calciumBeside && section.lumenTaken == nil, "\(name), at \(section.position) mm")
        }
        return measured
    }

    /// A coronary artery of 3 mm narrowed to half its diameter, and one that
    /// tapers from 3.5 to 2.5 mm with the same narrowing in its middle: the
    /// degree by diameter against a proximal and a distal reference is the
    /// narrowing's, within 6 points, and the tapering one read against its
    /// distal end alone is short of it by what the vessel lost on the way.
    @Test func aCoronaryNarrowingIsReadAgainstAProximalAndADistalReference() throws {
        var settings = Stenosis.Settings(vessel: .coronary)
        #expect(settings.vessel == .coronary && settings.maxRadius == 4 && settings.minimumLumenValue == 130 && settings.neck == 0.3)
        #expect(Stenosis.Settings().vessel == .carotid && Stenosis.Settings().maxRadius == 8 && Stenosis.Settings().neck == 0.5)
        settings.step = 1
        let length = 20.0
        // The radius the vessel would have at z, and the one it has: half of it from 9 to 11 mm.
        func measured(taper: Double) throws -> (two: Stenosis.Result, one: Stenosis.Result) {
            func healthy(_ z: Double) -> Double { 1.5 + taper * (0.5 - z / length) }
            let sections = (0...20).map { i -> SyntheticSection in
                let z = Double(i), r = (9...11).contains(i) ? healthy(z) / 2 : healthy(z)
                var section = SyntheticSection(blur: 0.3) { x, y in (x * x + y * y).squareRoot() <= r ? 400 : 60 }
                section.addNoise(sd: 20, seed: 0xC0C0 &+ UInt64(i))
                return section
            }
            func along(_ t: Double) -> Stenosis.Frame {
                Stenosis.Frame(point: SIMD3(0, 0, t * length), tangent: SIMD3(0, 0, 1), normal: SIMD3(0, 1, 0))
            }
            let places = (0...20).map { Stenosis.Place(position: Double($0), relativePosition: Double($0) / length, frame: along(Double($0) / length)) }
            let proximal = Stenosis.defaultProximalReference(stretch: length), distal = Stenosis.defaultReference(stretch: length)
            #expect(proximal == 0...5 && distal == 15...20)
            let stretch = Stenosis.sections(at: places, settings: settings, reference: distal, proximalReference: proximal) {
                sections[min(max(Int($0.z.rounded()), 0), 20)].sample($0)
            }.sections
            return (try #require(Stenosis.result(of: stretch, proximal: proximal, distal: distal)),
                    try #require(Stenosis.result(of: stretch, reference: distal)))
        }

        let straight = try measured(taper: 0)
        #expect(abs(straight.two.nascetByDiameter - 50) < 6, "straight, by diameter: \(straight.two.nascetByDiameter)")
        #expect(abs(straight.two.referenceDiameter - 3) < 0.25 && abs(straight.two.minimumDiameter - 1.5) < 0.25,
                "straight: \(straight.two.referenceDiameter) and \(straight.two.minimumDiameter) mm")
        #expect(abs(straight.two.nascetByArea - 75) < 8, "straight, by area: \(straight.two.nascetByArea)")
        #expect(straight.two.proximalReference?.range == 0...5 && straight.two.distalReference?.range == 15...20)
        #expect(straight.one.proximalReference == nil && abs(straight.one.nascetByDiameter - straight.two.nascetByDiameter) < 3)

        let tapering = try measured(taper: 0.5)
        let proximal = try #require(tapering.two.proximalReference), distal = try #require(tapering.two.distalReference)
        #expect(abs(proximal.diameter - 3.375) < 0.25 && abs(distal.diameter - 2.625) < 0.25 && proximal.position == 2.5 && distal.position == 17.5,
                "the references: \(proximal.diameter) at \(proximal.position), \(distal.diameter) at \(distal.position)")
        #expect(abs(tapering.two.nascetByDiameter - 50) < 6, "tapering, between the two references: \(tapering.two.nascetByDiameter)")
        #expect(tapering.two.referenceDiameter > distal.diameter + 0.2 && tapering.two.referenceDiameter < proximal.diameter - 0.2)
        #expect(tapering.one.nascetByDiameter < tapering.two.nascetByDiameter - 4, "against the distal end alone: \(tapering.one.nascetByDiameter)")
    }

    /// A coronary artery of 3 mm in fat, with plaque in three rings around
    /// its lumen - fibrous out to 2.1 mm from the axis, fibro-fatty to 2.7,
    /// lipid-rich to 3.3 - and a calcium nodule of 0.5 mm radius in the
    /// fibro-fatty ring, along 10 mm.
    ///
    /// The bands read intensities: at each edge the blur puts samples of
    /// every intensity between the two sides, which fall in the band beside,
    /// and the edge of the lumen, at half its intensity, lies in the fibrous
    /// ring. With a blur of 0.1 mm the volume of the plaque and that of the
    /// vessel are within 12 % of what was put there, and each ring within
    /// 25 %. With the blur of a CT, 0.3 mm, rings of 0.6 mm are all edge:
    /// the whole is within 25 %, a ring within 45 %. The nodule, 8.6 mm³ of
    /// calcium, comes out within 5.5 mm³.
    @Test(arguments: [(0.1, 0.12, 0.25), (0.3, 0.25, 0.45)])
    func thePlaqueOfACoronaryArteryIsItsVolumeAndItsBands(blur: Double, ofTheWhole: Double, ofABand: Double) throws {
        var settings = Stenosis.Settings(vessel: .coronary)
        #expect(settings.plaque == Stenosis.PlaqueLimits() && Stenosis.Settings().plaque == nil)
        #expect(Stenosis.PlaqueLimits().bands == [30, 130, 350] && Stenosis.PlaqueLimits().fat == -30)
        #expect(Stenosis.PlaqueLimits(bands: [20, 100, 400]).bands == [20, 100, 400] && Stenosis.PlaqueLimits(bands: [100, 20, 400]).bands == [30, 130, 350])
        settings.step = 1
        let length = 10.0
        func anatomy(_ x: Double, _ y: Double) -> Double {
            let r = (x * x + y * y).squareRoot()
            if ((x - 2.4) * (x - 2.4) + y * y).squareRoot() <= 0.5 { return 900 }
            switch r {
            case ...1.5: return 400
            case ...2.1: return 150
            case ...2.7: return 80
            case ...3.3: return 0
            default: return -90
            }
        }
        let sections = (0...10).map { i -> SyntheticSection in
            var section = SyntheticSection(blur: blur, anatomy: anatomy)
            section.addNoise(sd: 8, seed: 0xFA7 &+ UInt64(i))
            return section
        }
        let places = (0...10).map {
            Stenosis.Place(position: Double($0), relativePosition: Double($0) / length,
                           frame: Stenosis.Frame(point: SIMD3(0, 0, Double($0)), tangent: SIMD3(0, 0, 1), normal: SIMD3(0, 1, 0)))
        }
        let measured = Stenosis.sections(at: places, settings: settings, reference: 8...10, proximalReference: 0...2) {
            sections[min(max(Int($0.z.rounded()), 0), 10)].sample($0)
        }.sections
        let limits = try #require(settings.plaque)
        let plaque = try #require(Stenosis.plaque(of: measured, step: settings.step, limits: limits))
        #expect(plaque.sectionCount == 11 && plaque.withoutWallCount == 0)

        let nodule: Double = .pi * 0.25
        let rings: [Double] = [.pi * (3.3 * 3.3 - 2.7 * 2.7), .pi * (2.7 * 2.7 - 2.1 * 2.1) - nodule, .pi * (2.1 * 2.1 - 1.5 * 1.5), nodule]
        let truth: [Double] = rings.map { $0 * 11 }
        let total: Double = truth.reduce(0, +)
        let vessel: Double = .pi * 3.3 * 3.3 * 11
        let found: [Double] = plaque.bandVolumes
        #expect(abs(plaque.plaqueVolume - total) < ofTheWhole * total, "blur \(blur), plaque: \(plaque.plaqueVolume) of \(total) mm³")
        #expect(abs(plaque.vesselVolume - vessel) < ofTheWhole * vessel, "blur \(blur), vessel: \(plaque.vesselVolume) of \(vessel) mm³")
        for band in 0..<3 {
            let (measuredBand, put): (Double, Double) = (found[band], truth[band])
            #expect(abs(measuredBand - put) < ofABand * put, "blur \(blur), band \(band): \(measuredBand) of \(put) mm³")
        }
        let calcium: Double = found[3]
        #expect(abs(calcium - truth[3]) < 5.5, "blur \(blur), calcium: \(calcium) of \(truth[3]) mm³")
        let shares: Double = plaque.bandShares.reduce(0, +)
        let burden: Double = (1 - 1.5 * 1.5 / (3.3 * 3.3)) * 100
        #expect(abs(shares - 100) < 1e-6, "shares: \(shares)")
        #expect(abs(plaque.burden - burden) < 100 * ofTheWhole, "blur \(blur), burden: \(plaque.burden) of \(burden)")

        // The same artery on the myocardium, with no fat on one side: no outer wall to find.
        let onMuscle = SyntheticSection(blur: 0.2, anatomy: { x, y in x < -2.5 ? 100 : anatomy(x, y) })
        let alone = Stenosis.sections(at: [places[0]], settings: settings, reference: nil) { onMuscle.sample($0) }.sections
        #expect(alone[0].isValid && alone[0].wall == nil)
        let none = try #require(Stenosis.plaque(of: measured + alone, step: 1, limits: Stenosis.PlaqueLimits()))
        #expect(none.withoutWallCount == 1 && none.sectionCount == 11)
        // A carotid is measured without plaque limits, and has no plaque to report.
        var carotid = Stenosis.Settings()
        carotid.step = 1
        let plain = Stenosis.sections(at: places, settings: carotid, reference: 8...10) { sections[min(max(Int($0.z.rounded()), 0), 10)].sample($0) }.sections
        #expect(plain.allSatisfy { $0.wall == nil } && Stenosis.plaque(of: plain, step: 1, limits: Stenosis.PlaqueLimits()) == nil)
    }

    @Test func aStretchWithoutCalciumMeasuresEachSectionAsItsCenterlineFindsIt() throws {
        var settings = Stenosis.Settings()
        settings.step = 2.5
        let length = 30.0
        func index(_ p: SIMD3<Double>) -> Int { min(max(Int((p.z / 2.5).rounded()), 0), 12) }

        // A narrowing of 0.5 mm, which its partial volume dims, over 18 of 30
        // mm, then a lumen of 2 mm; the noise of a CT of 30 HU.
        let narrowing = (0...12).map { i -> SyntheticSection in
            var section = SyntheticSection(blur: 0.4) { x, y in (x * x + y * y).squareRoot() <= (i < 8 ? 0.5 : 2) ? 400 : 50 }
            section.addNoise(sd: 30, seed: 0x9E3779B97F4A7C15 &+ UInt64(i))
            return section
        }
        for limit in [1.6, Stenosis.Settings.calciumLimits.lowerBound] {
            settings.upperFraction = limit
            let measured = try expectEachSectionAsItsCenterlineFindsIt("narrowing, limit \(limit)", length: length, settings: settings) { narrowing[index($0)].sample($0) }
            let result = try #require(Stenosis.result(of: measured, reference: Stenosis.defaultReference(stretch: length)))
            #expect(abs(result.contrast - 400) < 25 && result.calciumBesideCount == 0 && result.sectionsWithContrast == 13)
            #expect(result.minimumPosition < 18 && result.nascetByArea > 80, "limit \(limit): \(result.nascetByArea)")
        }
        settings.upperFraction = 1.6

        // The contrast fades along the vessel, from 15 % brighter than at the
        // reference to as bright, and the path leaves the lumen over its
        // first 10 mm, from outside its wall back to its center.
        let ramp = (0...12).map { i -> SyntheticSection in
            let z = Double(i) * 2.5
            let off = z < 10 ? 2.2 * (10 - z) / 10 : 0
            let value = 400 * (1.15 - 0.15 * min(z / 22.5, 1))
            var section = SyntheticSection(blur: 0.4) { x, y in ((x - off) * (x - off) + y * y).squareRoot() <= 2 ? value : 50 }
            section.addNoise(sd: 25, seed: 0xD1CE &+ UInt64(i))
            return section
        }
        _ = try expectEachSectionAsItsCenterlineFindsIt("ramp and path off the lumen", length: length, settings: settings) { ramp[index($0)].sample($0) }

        // A carotid bulb of 12 mm across, its centerline off its center, down
        // to a reference of 5 mm; the noise of a CT of 40 HU.
        let bulb = (0...12).map { i -> SyntheticSection in
            let r = i < 6 ? 6.0 : 2.5
            let off = i < 6 ? 2.0 : 0
            var section = SyntheticSection(blur: 0.5) { x, y in ((x - off) * (x - off) + y * y).squareRoot() <= r ? 400 : 50 }
            section.addNoise(sd: 40, seed: 0xB0B &+ UInt64(i))
            return section
        }
        for limit in [1.6, Stenosis.Settings.calciumLimits.lowerBound] {
            settings.upperFraction = limit
            _ = try expectEachSectionAsItsCenterlineFindsIt("bulb, limit \(limit)", length: length, settings: settings) { bulb[index($0)].sample($0) }
        }
    }

    /// A vessel without calcium whose path runs near its wall all along, the
    /// reference included, at 90 % and at 100 % of its radius from its axis,
    /// in the noise of a CT of 25 HU: its centerline is dimmed by the partial
    /// volume of the wall, and on the wall the middle of its lumen is brighter
    /// than the lowest share of that centerline. The contrast of the
    /// reference is the intensity in the middle of its lumen, so no section
    /// takes that middle for calcium.
    @Test(arguments: [1.0, 2.5, 4.0])
    func aStretchWhosePathRunsNearTheWallOfItsReferenceTooMeasuresEachSectionAsItsCenterlineFindsIt(radius r: Double) throws {
        var settings = Stenosis.Settings()
        settings.step = 2.5
        let length = 20.0
        func index(_ p: SIMD3<Double>) -> Int { min(max(Int((p.z / 2.5).rounded()), 0), 8) }
        for share in [0.9, 1.0] {
            let along = (0...8).map { i -> SyntheticSection in
                var section = SyntheticSection(blur: 0.45) { x, y in ((x - share * r) * (x - share * r) + y * y).squareRoot() <= r ? 400 : 50 }
                section.addNoise(sd: 25, seed: 0xFACE &+ UInt64(i) &+ UInt64(r * 10) &* 31 &+ UInt64(share * 100) &* 7)
                return section
            }
            for limit in [1.6, Stenosis.Settings.calciumLimits.lowerBound] {
                settings.upperFraction = limit
                let name = "r \(r), path at \(share) r, limit \(limit)"
                let measured = try expectEachSectionAsItsCenterlineFindsIt(name, length: length, settings: settings) { along[index($0)].sample($0) }
                let result = try #require(Stenosis.result(of: measured, reference: Stenosis.defaultReference(stretch: length)))
                let lowest = Stenosis.Settings.calciumLimits.lowerBound
                #expect(share < 1 || measured.allSatisfy { Double($0.centerValue) * lowest < 380 }, "\(name): the centerline is dimmed")
                #expect(result.contrast > 340 && result.calciumBesideCount == 0, "\(name): contrast \(result.contrast)")
            }
        }
    }

    // MARK: - With calcium

    /// Rings and arcs of calcium of 600 to 1500 HU, 0.3 to 1.2 mm thick,
    /// beside lumens of 0.6 to 3 mm, blurred by 0.35 and 0.5 mm.
    @Test(arguments: [0.6, 1.0, 2.0, 3.0])
    func withCalciumTheLumenIsNeverLargerThanItsCenterlineFindsIt(radius r: Double) {
        var turn = Int(r * 10)
        for calcium in [600.0, 1000.0, 1500.0] {
            for thickness in [0.3, 0.6, 1.2] {
                for arc in [360.0, 180.0, 90.0] {
                    let section = calcifiedSection(r: r, calcium: calcium, thickness: thickness, arc: arc, blur: turn % 2 == 0 ? 0.35 : 0.5)
                    var settings = Stenosis.Settings()
                    settings.upperFraction = limits[turn % limits.count]
                    settings.calciumMargin = margins[turn % 4]
                    settings.lowerFraction = edges[turn % edges.count]
                    turn += 1
                    let frozen = section.frozen(settings)
                    for contrast in [referenceContrast, 300] as [Float] {
                        let mask = section.mask(settings, contrast: contrast)
                        #expect(isWithin(mask, frozen), "r \(r), \(calcium) HU, \(thickness) mm, \(arc)°, limit \(settings.upperFraction), margin \(settings.calciumMargin), contrast \(contrast)")
                    }
                }
            }
        }
    }

    @Test func calciumTheLumenEnclosesLeavesIt() throws {
        // A nodule of calcium of 1300 HU, 0.5 mm in radius, inside a lumen of
        // 3 mm: the lumen stops at it, and filling its holes put it back.
        let nodule = SyntheticSection { x, y in
            if ((x - 1.2) * (x - 1.2) + y * y).squareRoot() <= 0.5 { return 1300 }
            return (x * x + y * y).squareRoot() <= 3 ? 400 : 50
        }
        let frozen = nodule.frozen()
        let measured = try #require(Stenosis.segment(values: nodule.values, size: nodule.size, settings: nodule.settings, contrast: referenceContrast))
        #expect(isWithin(measured.mask, frozen) && measured.calciumBeside && measured.lumenTaken == nil)
        #expect(abs(nodule.area(frozen) - .pi * 9) < .pi * 9 * 0.03)
        // Out goes what is brighter than the limit around the nodule, about
        // its own area, and nothing away from it.
        let out = nodule.area(frozen) - nodule.area(measured.mask)
        #expect(out > .pi * 0.25 * 0.5 && out < .pi * 0.25 * 1.5, "\(out)")
        #expect(nodule.area(measured.mask) { x, _ in x < 0.2 } == nodule.area(frozen) { x, _ in x < 0.2 })

        // Beside a tight lumen, the blooming of an arc reaches round its ends
        // and encloses it: the arc leaves, and the lumen comes nearer to its area.
        let arc = calcifiedSection(r: 0.6, calcium: 1500, thickness: 1.2, arc: 90)
        let arcFrozen = arc.frozen(), arcMask = arc.mask(contrast: referenceContrast)
        #expect(isWithin(arcMask, arcFrozen) && arc.area(arcMask) < arc.area(arcFrozen) - 1)
        #expect(abs(arc.area(arcMask) - .pi * 0.36) < abs(arc.area(arcFrozen) - .pi * 0.36))
    }

    @Test func aPlaqueDimmerThanTheLimitCountsAsLumenUntilTheLimitComesDown() {
        // A plaque of 700 HU, 1 mm thick: blurred, it stays under 1.6 × 400.
        let section = plaqueSection(plaque: 700)
        let today = section.mask(contrast: referenceContrast)
        #expect(today == section.frozen())
        #expect(section.area(today) > lumenArea * 1.3)
        #expect(section.area(today) { isPlaque($0, $1) } > 3)
        #expect(Stenosis.segment(values: section.values, size: section.size, settings: section.settings, contrast: referenceContrast)?.calciumBeside == false)

        var settings = Stenosis.Settings()
        settings.upperFraction = 1.3
        let limited = section.mask(settings, contrast: referenceContrast)
        #expect(section.area(limited) { isPlaque($0, $1) } < 0.2)
        #expect(abs(section.area(limited) - lumenArea) < lumenArea * 0.05)
        #expect(Stenosis.segment(values: section.values, size: section.size, settings: settings, contrast: referenceContrast)?.calciumBeside == true)

        // The margin takes the rest of the plaque's edge, and no more than a
        // rim of the lumen beside it.
        settings.calciumMargin = 0.3
        let withMargin = section.mask(settings, contrast: referenceContrast)
        #expect(section.area(withMargin) { isPlaque($0, $1) } == 0)
        #expect(beyondTheWall(section, withMargin) < 0.08)
        #expect(section.area(withMargin) < section.area(limited))
        #expect(abs(section.area(withMargin) - lumenArea) < lumenArea * 0.05)
    }

    @Test func theMarginTakesARimBesideTheCalciumAndAWiderOneNeverMakesTheLumenLarger() {
        // Dense calcium stays out of the lumen by the limit alone.
        let section = plaqueSection(plaque: 1300)
        let today = section.mask(contrast: referenceContrast)
        #expect(today == section.frozen())
        #expect(section.area(today) { isPlaque($0, $1) } < 0.1)
        #expect(abs(section.area(today) - lumenArea) < lumenArea * 0.03)

        var settings = Stenosis.Settings()
        settings.calciumMargin = 0.3
        let withMargin = section.mask(settings, contrast: referenceContrast)
        #expect(section.area(withMargin) { isPlaque($0, $1) } == 0)
        #expect(beyondTheWall(section, withMargin) < 0.08)
        // The margin is a rim along the plaque: 0.3 mm over the 80° of a
        // lumen of 2 mm, about 1 mm², and nothing away from the plaque.
        #expect(section.area(today) - section.area(withMargin) > 0.5)
        #expect(section.area(today) - section.area(withMargin) < 1.3)
        #expect(section.area(withMargin) { x, _ in x < 0 } == section.area(today) { x, _ in x < 0 })

        // Lumens narrower than twice the neck, beside half a ring of calcium.
        for (r, calcium, thickness) in [(0.6, 1000.0, 1.0), (0.6, 1300.0, 0.6), (0.8, 1300.0, 0.6), (0.8, 1000.0, 1.0), (0.6, 800.0, 1.0)] {
            let tight = calcifiedSection(r: r, calcium: calcium, thickness: thickness)
            var wider = tight.frozen()
            for margin in margins {
                var settings = Stenosis.Settings()
                settings.calciumMargin = margin
                let mask = tight.mask(settings, contrast: referenceContrast)
                #expect(isWithin(mask, wider), "r \(r), \(calcium) HU, \(thickness) mm, margin \(margin)")
                wider = mask
            }
        }
    }

    @Test func withoutTheContrastOfAReferenceNoCalciumIsTold() {
        for section in [plaqueSection(plaque: 1300), calcifiedSection(r: 0.6, calcium: 1500, thickness: 1.2, arc: 90)] {
            var settings = Stenosis.Settings()
            settings.calciumMargin = 0.5
            let measured = Stenosis.segment(values: section.values, size: section.size, settings: settings)
            #expect(measured?.mask == section.frozen(settings) && measured?.calciumBeside == false)
        }
    }

    @Test func aLumenTheCalciumTakesWholeIsLeftOutAndCounted() throws {
        // A lumen of 0.8 mm in a ring of calcium: a margin of 1 mm takes all of it.
        let tight = calcifiedSection(r: 0.8, calcium: 1000, thickness: 1.0, arc: 360)
        var settings = Stenosis.Settings()
        settings.calciumMargin = 1
        let taken = Stenosis.section(at: 0.5, position: 1, frame: frame, settings: settings, contrast: referenceContrast, sample: tight.sample)
        #expect(!taken.isValid && taken.lumenTaken == .byCalcium && !taken.corrected && taken.centerValue > 0 && taken.calciumBeside)
        settings.calciumMargin = 0
        let kept = Stenosis.section(at: 0.5, position: 1, frame: frame, settings: settings, contrast: referenceContrast, sample: tight.sample)
        #expect(kept.isValid && kept.lumenTaken == nil && kept.calciumBeside)
        // Without contrast at the centerline nothing was taken: there was no lumen.
        let none = Stenosis.section(at: 0.5, position: 1, frame: frame, settings: settings, contrast: referenceContrast) { _ in 60 }
        #expect(!none.isValid && none.lumenTaken == nil)

        // In the stretch: left out of the numbers, and counted; outside the
        // reference, the narrowest lumen may be among them.
        let stretch = [section(0, area: 12, diameter: 3.9), taken, section(2, area: 5, diameter: 2.5), section(3, area: 12, diameter: 3.9)]
        let result = try #require(Stenosis.result(of: stretch, reference: 2.5...3))
        #expect(result.minimumArea == 5 && result.takenByCalciumCount == 1 && result.takenByHandCount == 0)
        #expect(result.takenByCalciumOutsideReference && result.calciumBesideCount == 1 && result.sectionsWithContrast == 4)
        let inReference = try #require(Stenosis.result(of: stretch, reference: 0.5...3))
        #expect(inReference.takenByCalciumCount == 1 && !inReference.takenByCalciumOutsideReference)
    }

    @Test func aStretchToldAgainstItsReferenceSaysWhereCalciumTouchedTheLumen() throws {
        // A lumen of 2 mm, and from z = 10 to 15 mm one of 0.8 mm beside half
        // a ring of calcium of 1300 HU, 0.6 mm thick.
        let healthy = SyntheticSection { x, y in (x * x + y * y).squareRoot() <= 2 ? 400 : 50 }
        let tight = calcifiedSection(r: 0.8, calcium: 1300, thickness: 0.6)
        let length = 30.0
        var settings = Stenosis.Settings()
        settings.step = 2.5
        func along(_ t: Double) -> Stenosis.Frame {
            Stenosis.Frame(point: SIMD3(0, 0, t * length), tangent: SIMD3(0, 0, 1), normal: SIMD3(0, 1, 0))
        }
        func sample(_ p: SIMD3<Double>) -> Float { (10...15).contains(p.z) ? tight.sample(p) : healthy.sample(p) }
        let sections = Stenosis.sections(from: 0, to: 1, length: length, settings: settings, frame: along, sample: sample)
        #expect(sections.count == 13 && sections.allSatisfy { abs($0.contrast - 400) < 1 })
        let result = try #require(Stenosis.result(of: sections, reference: Stenosis.defaultReference(stretch: length)))
        #expect(abs(result.contrast - 400) < 1 && (10...15).contains(result.minimumPosition))
        #expect(result.calciumBesideCount == 3 && result.minimumCalciumBeside && result.sectionsWithContrast == 13)
        // Never larger than the centerline alone finds the lumen.
        let alone = Stenosis.section(at: 0.4, position: 12.5, frame: along(12.5 / length), settings: settings, sample: sample)
        #expect(sections[5].area <= alone.area)
    }

    // MARK: - Stents

    /// A patent stent of 1.5, 2 and 3 mm whose struts, blurred, make a ring
    /// brighter than the lumen: by the threshold alone the ring and its blur
    /// were lumen, and the frozen lumen measures about twice the stent. The
    /// lumen stops at the ring now, within 15 % of the lumen inside the
    /// struts. The crest of the blurred ring lies on the struts' inner face
    /// or a little inside it, the more so the smaller the stent and the wider
    /// the blur (a stent of 1.5 mm under 0.45 mm reads about 15 % small);
    /// under a blur of 0.35 mm the ring's peak passes the calcium limit,
    /// which the lumen stops at before it, as at calcium.
    @Test(arguments: [(1.5, 0.4), (2.0, 0.35), (2.0, 0.4), (2.0, 0.45), (3.0, 0.35), (3.0, 0.4), (3.0, 0.45)])
    func aPatentStentMeasuresTheLumenInsideItsStruts(radius: Double, blur: Double) throws {
        let section = stentSection(radius: radius, inner: radius - 0.15, blur: blur)
        let found = try #require(Stenosis.segment(values: section.values, size: section.size, settings: section.settings,
                                                  contrast: referenceContrast))
        let truth = Double.pi * (radius - 0.15) * (radius - 0.15)
        let what = "stent of \(radius) mm, blur \(blur) mm: \(section.area(found.mask)) mm², frozen \(section.area(section.frozen()))"
        #expect(abs(section.area(found.mask) - truth) < 0.15 * truth, "\(what)")
        #expect(blur < 0.4 || section.area(section.frozen()) > 1.5 * truth, "\(what)")
        #expect(section.area(found.mask) { x, y in (x * x + y * y).squareRoot() > radius } == 0, "\(what)")
        #expect(isWithin(found.mask, section.frozen()) && found.lumenTaken == nil, "\(what)")
    }

    /// A restenosis inside a stent: the lumen left, of 0.75 to 1.3 mm,
    /// against the struts on one side, and neointima darker than the lumen's
    /// edge between it and the struts elsewhere. With the ring of the struts
    /// out, the neointima is no longer enclosed, and the lumen is the lumen
    /// left, within 30 % of its area: where the neointima between the lumen
    /// and the struts narrows, the blur of both lifts it above the lumen's
    /// edge, and the lumen stops at its edge against what is left of the dip.
    /// The frozen lumen held the ring, the neointima and the blur beyond.
    @Test(arguments: [0.35, 0.4, 0.45])
    func aRestenosisInsideAStentMeasuresTheLumenLeft(blur: Double) throws {
        for (radius, inner) in [(2.0, 0.75), (2.0, 1.0), (2.0, 1.3), (3.0, 0.75), (3.0, 1.2)] {
            for noise in [0.0, 12.0] {
                let section = stentSection(radius: radius, inner: inner, blur: blur, noise: noise,
                                           seed: 0x57E7 &+ UInt64(blur * 100) &+ UInt64(inner * 100))
                let found = try #require(Stenosis.segment(values: section.values, size: section.size, settings: section.settings,
                                                          contrast: referenceContrast))
                let truth = Double.pi * inner * inner
                let what = "stent of \(radius) mm, lumen left of \(inner) mm, blur \(blur) mm, noise \(noise) HU: \(section.area(found.mask)) mm²"
                #expect(abs(section.area(found.mask) - truth) < 0.3 * truth, "\(what)")
                #expect(blur < 0.4 || section.area(section.frozen()) > 2 * truth, "\(what)")
                #expect(section.area(found.mask) { x, y in (x * x + y * y).squareRoot() > inner + 0.6 } == 0, "\(what)")
                #expect(Stenosis.holeOutlines(of: found.mask, size: section.size).isEmpty, "\(what)")
            }
        }
    }

    /// The restenosis of the 2 mm stent whose struts are 0.15 mm at 3000 HU,
    /// with the lumen left reaching into them on +x: the neointima darker
    /// than the lumen's edge, and the ring with what lies beyond it, stay
    /// out; the lumen left is as it was 0.3 mm or more from the struts and
    /// 0.2 mm from its edge, and the transverse view draws it, without the
    /// outline of a hole. Blurred by 0.55 mm, the ring is not told (see
    /// `whereTheRingIsNotToldTheLumenIsTheThresholds`).
    @Test(arguments: [(1.0, 0.4), (1.0, 0.45), (0.75, 0.4), (0.75, 0.45), (1.2, 0.45), (1.3, 0.4), (1.0, 0.5)])
    func theNeointimaOfARestenosisInsideAStentStaysOutOfTheLumen(inner: Double, blur: Double) throws {
        let section = restenosisSection(inner: inner, blur: blur)
        let found = try #require(Stenosis.segment(values: section.values, size: section.size, settings: section.settings,
                                                  contrast: referenceContrast))
        let frozen = section.frozen()
        let edge = Float(section.settings.lowerFraction) * found.centerValue
        let what = "lumen left of \(inner) mm, blur \(blur) mm"
        let darkNeointima: (Double, Double) -> Bool = { x, y in
            (x * x + y * y).squareRoot() > inner && fromTheStentAxis(x, y, inner: inner) < 1.925
                && section.sample(SIMD3(x, y, 0)) < edge
        }
        #expect(section.area(frozen, where: darkNeointima) > 1.5, "\(what)")
        #expect(section.area(found.mask, where: darkNeointima) == 0, "\(what)")
        #expect(isWithin(found.mask, frozen) && found.lumenTaken == nil, "\(what)")
        let deep: (Double, Double) -> Bool = { x, y in
            (x * x + y * y).squareRoot() < inner - 0.2 && fromTheStentAxis(x, y, inner: inner) < 1.6
        }
        let ring: (Double, Double) -> Bool = { x, y in fromTheStentAxis(x, y, inner: inner) > 1.925 }
        #expect(section.area(found.mask, where: deep) == section.area(frozen, where: deep), "\(what)")
        #expect(section.area(frozen, where: ring) > 5 && section.area(found.mask, where: ring) == 0, "\(what)")
        let truth = Double.pi * inner * inner
        #expect(abs(section.area(found.mask) - truth) < 0.2 * truth, "\(what): \(section.area(found.mask))")
        // The transverse view draws the lumen left: no farther than it toward
        // the neointima (−x), and no hole in it.
        let outline = Stenosis.outline(of: found.mask, size: section.size)
        let farthest = outline.filter { $0.x < 0 && abs($0.y) <= -$0.x / 2 }.map { simd_length($0) * section.settings.pixel }.max() ?? 9
        #expect(farthest < inner + 0.3, "\(what): \(farthest)")
        #expect(Stenosis.holeOutlines(of: found.mask, size: section.size).isEmpty, "\(what)")
        let drawn = enclosedArea(outline) * section.settings.pixel * section.settings.pixel
        #expect(abs(drawn - section.area(found.mask)) < 0.1 * section.area(found.mask), "\(what): \(drawn)")
    }

    /// A stented stretch like the fixture STENOSIS^STENT: a vessel of
    /// 1.85 mm, and from 4 to 36 mm a stent whose struts fit it, with a
    /// restenosis leaving 1 mm of lumen from 12 to 16 mm and one leaving
    /// 0.75 mm from 24 to 28 mm; blur of 0.4 mm and the noise of a CT of 12 HU.
    /// Every stented section counted its ring and the stretch's minimum was a
    /// healthy section; now the patent stent measures within 15 % of the
    /// vessel, the minimum is in the tighter restenosis, and NASCET by area,
    /// against the default reference (patent stent and healthy vessel), is
    /// near its 84 %.
    @Test func theMinimumOfAStentedStretchIsItsTighterRestenosis() throws {
        var settings = Stenosis.Settings()
        settings.step = 2
        let length = 40.0
        func inner(_ z: Double) -> Double? {
            switch z {
            case ..<3, 37...: return nil
            case 11..<17: return 1.0
            case 23..<29: return 0.75
            default: return 1.85
            }
        }
        let sections = (0...20).map { i -> SyntheticSection in
            let z = Double(i) * 2
            guard let left = inner(z) else {
                var healthy = SyntheticSection(blur: 0.4) { x, y in (x * x + y * y).squareRoot() <= 1.85 ? 400 : 50 }
                healthy.addNoise(sd: 12, seed: 0x5E7E &+ UInt64(i))
                return healthy
            }
            return stentSection(inner: left, blur: 0.4, noise: 12, seed: 0x5E7E &+ UInt64(i))
        }
        func along(_ t: Double) -> Stenosis.Frame {
            Stenosis.Frame(point: SIMD3(0, 0, t * length), tangent: SIMD3(0, 0, 1), normal: SIMD3(0, 1, 0))
        }
        let measured = Stenosis.sections(from: 0, to: 1, length: length, settings: settings, frame: along) { p in
            sections[min(max(Int((p.z / 2).rounded()), 0), 20)].sample(p)
        }
        let patent = Double.pi * 1.85 * 1.85
        for section in measured where inner(section.position) == 1.85 {
            #expect(abs(section.area - patent) < 0.15 * patent, "at \(section.position) mm: \(section.area) mm²")
        }
        for section in measured where inner(section.position) == 1.0 {
            #expect(abs(section.area - .pi) < 0.3 * .pi, "at \(section.position) mm: \(section.area) mm²")
        }
        let result = try #require(Stenosis.result(of: measured, reference: Stenosis.defaultReference(stretch: length)))
        #expect((23...29).contains(result.minimumPosition), "minimum at \(result.minimumPosition) mm")
        #expect(abs(result.minimumArea - .pi * 0.5625) < 0.3 * .pi * 0.5625, "minimum \(result.minimumArea) mm²")
        #expect(result.nascetByArea > 75, "NASCET by area \(result.nascetByArea) %")
    }

    /// Calcium in the neointima of a restenosis, a nodule of 0.6 mm at
    /// 2500 HU touching the lumen left or 0.2 and 0.4 mm from it: it stays
    /// out, and the lumen is about the one the same stent has without it:
    /// with the ring out, the blooming of the nodule into the neointima no
    /// longer joins the lumen through the ring; the blooming between the
    /// nodule and the lumen is what the calcium margin is for.
    @Test(arguments: [0.4, 0.45])
    func calciumInsideAStentStaysOutAndItsBloomingIsNoLumen(blur: Double) throws {
        let nodule: (Double, Double, Double) -> Bool = { x, y, gap in
            let cx = -(1.5 + gap + 0.6)
            return ((x - cx) * (x - cx) + y * y).squareRoot() <= 0.6
        }
        let plain = stentSection(radius: 3, inner: 1.5, blur: blur)
        let without = try #require(Stenosis.segment(values: plain.values, size: plain.size, settings: plain.settings,
                                                    contrast: referenceContrast))
        for gap in [0.0, 0.2, 0.4] {
            let section = stentSection(radius: 3, inner: 1.5, blur: blur) { x, y in nodule(x, y, gap) ? 2500 : nil }
            let found = try #require(Stenosis.segment(values: section.values, size: section.size, settings: section.settings,
                                                      contrast: referenceContrast))
            let what = "gap \(gap) mm, blur \(blur) mm: \(section.area(found.mask)) mm² against \(plain.area(without.mask))"
            #expect(section.area(found.mask) { nodule($0, $1, gap) } == 0 && found.calciumBeside, "\(what)")
            #expect(section.area(found.mask) < plain.area(without.mask) + 0.6, "\(what)")
            #expect(section.area(found.mask) < 1.2 * .pi * 1.5 * 1.5 && section.area(section.frozen()) > 25, "\(what)")
        }
    }

    /// Calcium over an arc of the wall, up to half of it, is no ring of
    /// struts, whatever its brightness, thickness and blur, in the noise of
    /// a CT or without.
    @Test(arguments: [90.0, 180.0])
    func calciumOverAnArcOfTheWallIsNoRingOfStruts(arc: Double) {
        for r in [0.6, 1.0, 2.0, 3.0] {
            for (calcium, thickness) in [(600.0, 1.2), (1000.0, 0.3), (1000.0, 0.6), (1500.0, 0.15), (1500.0, 0.3)] {
                for blur in [0.35, 0.45] {
                    for sd in [0.0, 25.0] {
                        var section = calcifiedSection(r: r, calcium: calcium, thickness: thickness, arc: arc, blur: blur)
                        if sd > 0 { section.addNoise(sd: sd, seed: 4242) }
                        let center = Stenosis.centerValue(of: section.values, size: section.size)
                        #expect(Stenosis.strutRing(values: section.values, size: section.size, settings: section.settings, center: center) == nil,
                                "r \(r), \(calcium) HU, \(thickness) mm, \(arc)°, blur \(blur), sd \(sd)")
                    }
                }
            }
        }
    }

    /// Thin calcium round most of the lumen, 240° to 330° of it, can be
    /// taken for a ring of struts and leave with it; where the wall has no
    /// calcium, the lumen still reaches its own edge, as the threshold finds
    /// it: the dip of the lumen's own edge toward the tissue is no neointima.
    @Test(arguments: [240.0, 270.0, 300.0, 330.0])
    func calciumRoundMostOfTheLumenLeavesTheLumenWhereThereIsNoneAsItIs(arc: Double) throws {
        for r in [1.5, 2.0] {
            for (calcium, thickness) in [(1500.0, 0.3), (800.0, 0.6)] {
                for blur in [0.35, 0.45] {
                    let section = calcifiedSection(r: r, calcium: calcium, thickness: thickness, arc: arc, blur: blur)
                    let found = try #require(Stenosis.segment(values: section.values, size: section.size, settings: section.settings,
                                                              contrast: referenceContrast))
                    let free = (360 - arc) / 2 - 10
                    let lumenWithoutCalcium: (Double, Double) -> Bool = { x, y in
                        (x * x + y * y).squareRoot() <= r - 0.15 && abs(abs(atan2(y, x)) * 180 / .pi - 180) <= free
                    }
                    let what = "r \(r), \(calcium) HU, \(thickness) mm, \(arc)°, blur \(blur)"
                    #expect(section.area(found.mask, where: lumenWithoutCalcium) == section.area(section.frozen(), where: lumenWithoutCalcium), "\(what)")
                    #expect(isWithin(found.mask, section.frozen()), "\(what)")
                }
            }
        }
    }

    /// An oval lumen, its long axis 1.4 or 1.6 times its short one, with
    /// thin calcium round 240° or 270° of it and the free part of the wall
    /// at an end of the long axis. Read from the middle of the circle the
    /// calcium makes, the free part is a gap wider than the struts of a
    /// stent leave, where the lumen bulges past the circle: no ring is told,
    /// and the lumen is not cut across the bulge. It keeps nine tenths of
    /// the lumen, or of the lumen the threshold alone finds where the noise
    /// of a CT makes that smaller. Taken for a ring, it lost up to 47 % of
    /// its area.
    @Test(arguments: [240.0, 270.0])
    func calciumRoundMostOfAnOvalLumenIsNoRingOfStruts(arc: Double) throws {
        var turn: UInt64 = 0
        for r in [1.5, 2.0] {
            for ratio in [1.4, 1.6] {
                // Where the lumen's axis lies from the centerline: on it, or
                // 0.3 to 0.6 mm off, toward the calcium, away from it or aside.
                for (d, toward) in [(0.0, 0.0), (0.3, 0.0), (0.3, 90.0), (0.3, 180.0), (0.6, 0.0), (0.6, 180.0)] {
                    let (ax, ay) = (d * cos(toward * .pi / 180), d * sin(toward * .pi / 180))
                    let base = SyntheticSection(blur: 0.4) { x, y in
                        let (u, v) = (x - ax, y - ay)
                        let rho = ((u / (r * ratio)) * (u / (r * ratio)) + (v / r) * (v / r)).squareRoot()
                        if rho <= 1 { return 400 }
                        return rho <= 1 + 0.3 / r && abs(atan2(v, -u)) <= arc / 2 * .pi / 180 ? 1500 : 50
                    }
                    for sd in [0.0, 25.0] {
                        var section = base
                        if sd > 0 { section.addNoise(sd: sd, seed: 0x0FA1 &+ turn) }
                        turn += 1
                        for contrast: Float in [400, 340] {
                            let found = try #require(Stenosis.segment(values: section.values, size: section.size, settings: section.settings,
                                                                      contrast: contrast))
                            let truth = min(Double.pi * r * r * ratio, section.area(section.frozen()))
                            #expect(section.area(found.mask) > 0.9 * truth,
                                    "r \(r), ratio \(ratio), \(arc)°, axis \(d) mm at \(toward)°, sd \(sd), contrast \(contrast): \(section.area(found.mask)) mm² for \(truth)")
                        }
                    }
                }
            }
        }
    }

    /// A stretch of an oval lumen with 6 mm of thin calcium round most of
    /// it, its centerline wandering 0.3 mm round the lumen's axis: every
    /// section keeps its lumen, and the calcium makes no stenosis. Taken for
    /// the ring of a stent, the calcified sections lost a third to a half of
    /// their lumen, a false stenosis of 35 to 48 % by area.
    @Test(arguments: [(1.5, 1.6, 240.0), (1.5, 1.4, 270.0), (2.0, 1.4, 270.0), (2.0, 1.2, 270.0)])
    func aStretchWithCalciumRoundMostOfAnOvalLumenShowsNoStenosis(radius r: Double, ratio: Double, arc: Double) throws {
        func oval(calcium: Bool, seed: UInt64) -> SyntheticSection {
            var section = SyntheticSection(blur: 0.4) { x, y in
                let rho = ((x / (r * ratio)) * (x / (r * ratio)) + (y / r) * (y / r)).squareRoot()
                if rho <= 1 { return 400 }
                return calcium && rho <= 1 + 0.3 / r && abs(atan2(y, -x)) <= arc / 2 * .pi / 180 ? 1500 : 50
            }
            section.addNoise(sd: 20, seed: seed, voxel: 0.6)
            return section
        }
        let calcified = oval(calcium: true, seed: 0x0FA2), healthy = oval(calcium: false, seed: 0x0FA3)
        let length = 20.0
        func along(_ t: Double) -> Stenosis.Frame {
            let z = t * length
            return Stenosis.Frame(point: SIMD3(0.3 * sin(z / 3), 0.25 * cos(z / 4), z), tangent: SIMD3(0, 0, 1), normal: SIMD3(0, 1, 0))
        }
        let sections = Stenosis.sections(from: 0, to: 1, length: length, settings: Stenosis.Settings(), frame: along) { p in
            (4...10).contains(p.z) ? calcified.sample(p) : healthy.sample(p)
        }
        let truth = Double.pi * r * r * ratio
        for section in sections {
            #expect(section.area > 0.9 * truth, "at \(section.position) mm: \(section.area) mm² for \(truth)")
        }
        let result = try #require(Stenosis.result(of: sections, reference: Stenosis.defaultReference(stretch: length)))
        #expect(result.nascetByArea < 10, "NASCET by area \(result.nascetByArea) %")
    }

    /// A patent stent whose struts are missing over 45° to 120° (the ostium
    /// of a side branch, or a fracture): the ring is told from the rest, and
    /// toward the gap the lumen reaches the vessel's wall, which the struts
    /// lie against, as the threshold finds it.
    @Test(arguments: [(2.0, 0.4), (2.0, 0.45), (3.0, 0.4), (3.0, 0.45)])
    func whereTheStrutsAreMissingTheLumenReachesItsOwnEdge(radius: Double, blur: Double) throws {
        for gap in [45.0, 60.0, 90.0] {
            let section = SyntheticSection(blur: blur) { x, y in
                let rho = (x * x + y * y).squareRoot()
                if rho <= radius - 0.15 { return 400 }
                let inGap = abs(abs(atan2(y, x)) * 180 / .pi - 180) <= gap / 2
                return rho <= radius + 0.15 && !inGap ? 1500 : 50
            }
            let found = try #require(Stenosis.segment(values: section.values, size: section.size, settings: section.settings,
                                                      contrast: referenceContrast))
            let truth = Double.pi * (radius - 0.15) * (radius - 0.15)
            let what = "stent of \(radius) mm, struts missing over \(gap)°, blur \(blur): \(section.area(found.mask)) mm²"
            #expect(abs(section.area(found.mask) - truth) < 0.15 * truth, "\(what)")
            #expect(reachTowardMinusX(section, found.mask) >= radius - 0.15 - 0.1, "\(what), reach \(reachTowardMinusX(section, found.mask))")
        }
    }

    /// A stent squashed, or cut across at a slant, shows its ring oval, the
    /// axes of the ellipse up to 1.5 to 1: the ring is told, patent or with
    /// a restenosis whose lumen left lies against the struts at the end of
    /// either axis, and the lumen is the one inside it. Fitted with a circle
    /// alone, a ring more oval than 1.3 to 1 was mostly not told, and the
    /// lumen left of a restenosis measured up to nine times its area.
    @Test(arguments: [1.3, 1.4, 1.5])
    func anOvalStentTellsItsRing(ratio: Double) throws {
        for radius in [2.0, 3.0] {
            for (inner, toward) in [(nil, 0.0), (Optional(1.0), 0.0), (Optional(1.0), 90.0)] {
                let (ax, ay) = (radius * ratio, radius)
                // Where the lumen left touches the inner face of the ring.
                let direction = SIMD2(cos(toward * .pi / 180), sin(toward * .pi / 180))
                let reach = 1 / ((direction.x / ax) * (direction.x / ax) + (direction.y / ay) * (direction.y / ay)).squareRoot()
                let axis = inner.map { direction * (reach - 0.15 - $0) } ?? SIMD2(0, 0)
                var truth = 0.0
                let section = SyntheticSection(blur: 0.4) { x, y in
                    let (u, v) = (x + axis.x, y + axis.y)
                    let rho = ((u / ax) * (u / ax) + (v / ay) * (v / ay)).squareRoot()
                    if abs(rho - 1) * radius <= 0.15 { return 1500 }
                    let lumen = inner.map { (x * x + y * y).squareRoot() <= $0 } ?? (rho < 1)
                    if lumen { truth += 0.01 }
                    return lumen ? 400 : 50
                }
                let what = "stent of \(radius) mm, \(ratio) to 1, \(inner.map { "lumen left of \($0) mm toward \(toward)°" } ?? "patent")"
                let center = Stenosis.centerValue(of: section.values, size: section.size)
                #expect(Stenosis.strutRing(values: section.values, size: section.size, settings: section.settings, center: center,
                                           contrast: referenceContrast) != nil, "\(what): no ring")
                let found = try #require(Stenosis.segment(values: section.values, size: section.size, settings: section.settings,
                                                          contrast: referenceContrast))
                #expect(abs(section.area(found.mask) - truth) < 0.3 * truth, "\(what): \(section.area(found.mask)) mm² for \(truth)")
            }
        }
    }

    /// The ellipse fitted through points of an ellipse is that ellipse, and
    /// tells how far it lies from its middle and where a ray leaves it; six
    /// points on a line give none.
    @Test func theEllipseThroughPointsOfAnEllipseIsThatEllipse() throws {
        let (center, axes, turn) = (SIMD2(3.0, -2.0), SIMD2(26.0, 18.0), 0.4)
        let points = (0..<24).map { k -> SIMD2<Double> in
            let t = Double(k) * 2 * .pi / 24 + 0.1
            let (x, y) = (axes.x * cos(t), axes.y * sin(t))
            return center + SIMD2(x * cos(turn) - y * sin(turn), x * sin(turn) + y * cos(turn))
        }
        let shape = try #require(Stenosis.ellipse(through: points))
        #expect(simd_length(shape.center - center) < 1e-6)
        #expect(abs(max(shape.axes.x, shape.axes.y) - 26) < 1e-6 && abs(shape.shortest - 18) < 1e-6)
        #expect(abs(shape.ratio - 26.0 / 18) < 1e-6 && !shape.isCircle)
        for point in points { #expect(shape.distance(point) < 1e-6) }
        let along = SIMD2(cos(turn), sin(turn))
        #expect(abs(shape.reach(toward: along) - 26) < 1e-6)
        // A ray from the grid's origin leaves the ellipse at one of its points.
        let direction = simd_normalize(SIMD2(1.0, 0.5))
        let crossing = try #require(shape.crossing(direction))
        #expect(shape.distance(direction * crossing) < 1e-6)
        #expect(shape.holds(SIMD2(0, 0), inset: 3) && !shape.holds(center + along * 25, inset: 3))
        #expect(Stenosis.ellipse(through: (0..<6).map { SIMD2(Double($0), 2 * Double($0)) }) == nil)
    }

    /// A dense nodule of calcium in the neointima beside the lumen left of a
    /// restenosis, as bright as the calcium limit and more, hides the struts
    /// behind it from the centerline: the rays that run into it are left out
    /// of the share that must show the ring, the ring is told, and the lumen
    /// is the one left, without the nodule. Counted as rays without a ring,
    /// they left it untold, and the stent's whole section was lumen, five to
    /// thirteen times the lumen left.
    @Test(arguments: [(1.0, 0.45), (0.75, 0.4)])
    func aDenseNoduleBesideTheLumenLeftDoesNotHideTheRing(inner: Double, blur: Double) throws {
        let nodule = SIMD2(-(inner + 0.6), 0.0)
        let section = stentSection(inner: inner, blur: blur) { x, y in
            simd_length(SIMD2(x, y) - nodule) <= 0.6 ? 2500 : nil
        }
        let center = Stenosis.centerValue(of: section.values, size: section.size)
        #expect(Stenosis.strutRing(values: section.values, size: section.size, settings: section.settings, center: center,
                                   contrast: referenceContrast) != nil)
        let found = try #require(Stenosis.segment(values: section.values, size: section.size, settings: section.settings,
                                                  contrast: referenceContrast))
        let truth = Double.pi * inner * inner
        #expect(abs(section.area(found.mask) - truth) < 0.3 * truth, "lumen left of \(inner) mm: \(section.area(found.mask)) mm² for \(truth)")
        let c = section.size / 2
        let inNodule = found.mask.indices.filter { i in
            found.mask[i] && simd_length(SIMD2(Double(i % section.size - c), Double(i / section.size - c)) * section.settings.pixel - nodule) <= 0.6
        }
        #expect(inNodule.isEmpty)
    }

    /// Where the ring is not told, a ring blurred by 0.55 mm here, the lumen is
    /// the threshold's, as before: the ring and its blur, and neointima
    /// narrower than the tissue the lumen leaves out, stay in it.
    @Test func whereTheRingIsNotToldTheLumenIsTheThresholds() {
        for section in [restenosisSection(inner: 1.0, blur: 0.55), stentSection(inner: 1.0, blur: 0.55)] {
            let center = Stenosis.centerValue(of: section.values, size: section.size)
            #expect(Stenosis.strutRing(values: section.values, size: section.size, settings: section.settings, center: center,
                                       contrast: referenceContrast) == nil)
            #expect(section.mask(contrast: referenceContrast) == section.frozen())
        }
    }

    /// A healthy lumen in a series reconstructed with an edge-enhancing
    /// kernel, in soft tissue and in fat, with and without the noise of a
    /// CT, its rim inside its edge up to a fifth brighter than the contrast
    /// in soft tissue and up to 31 % in fat in lumens of 1.5 mm and more (in
    /// a lumen of 1 mm the whole lumen, up to half): the rim is no ring of
    /// struts, and the lumen is the frozen one.
    @Test(arguments: [1.0, 1.5, 2.0, 3.0, 4.0])
    func theRimOfAnEdgeEnhancingKernelIsNoRingOfStruts(radius r: Double) {
        var turn: UInt64 = 0
        for tissue in [50.0, -80.0] {
            for contrast in [260.0, 400.0] {
                for blur in [0.35] {
                    for (amount, width) in [(0.15, 0.4), (0.3, 0.4), (0.5, 0.4), (0.3, 0.7), (0.6, 0.7), (1.0, 0.7)] {
                        let base = sharpenedSection(blur: blur, amount: amount, width: width) { x, y in
                            (x * x + y * y).squareRoot() <= r ? contrast : tissue
                        }
                        let rim = Double(base.values.max() ?? 0) / contrast - 1
                        for sd in [0.0, 20.0] {
                            var section = base
                            if sd > 0 { section.addNoise(sd: sd, seed: 0xED6E &+ turn) }
                            turn += 1
                            let what = "r \(r), \(contrast) HU in \(tissue) HU, blur \(blur), kernel \(amount) over \(width) mm (rim \(Int(rim * 100)) %), sd \(sd)"
                            #expect(section.mask(contrast: Float(contrast)) == section.frozen(), "\(what)")
                        }
                    }
                }
            }
        }
    }

    /// A centerline in a dark spot of its lumen: a small soft island, a
    /// thrombus, or the dark jet of unopacified inflow in the middle of the
    /// lumen. The lumen round it, brighter than the centerline, is no ring
    /// of struts: the lumen is the frozen one.
    @Test(arguments: [1.5, 2.0, 3.0])
    func aCenterlineInADarkSpotOfItsLumenTakesNoRingOfStruts(radius r: Double) {
        var turn: UInt64 = 0
        var spots: [(String, (Double, Double) -> Double)] = []
        for (spot, value) in [(0.3, 50.0), (0.5, 200.0), (0.7, 100.0)] where spot < r - 0.6 {
            spots.append(("island of \(spot) mm at \(value) HU", { x, y in
                (x * x + y * y).squareRoot() <= spot ? value : (x * x + y * y).squareRoot() <= r ? 400 : 50
            }))
        }
        for depth in [0.25, 0.35] {
            spots.append(("jet \(depth) deep", { x, y in
                let rho = (x * x + y * y).squareRoot()
                return rho <= r ? 400 * (1 - depth * exp(-pow(rho / (0.5 * r), 2))) : 50
            }))
        }
        for (name, anatomy) in spots {
            for blur in [0.35, 0.45] {
                let base = SyntheticSection(blur: blur, anatomy: anatomy)
                for sd in [0.0, 15.0, 30.0] {
                    var section = base
                    if sd > 0 { section.addNoise(sd: sd, seed: 0xDA4C &+ turn) }
                    turn += 1
                    #expect(section.mask(contrast: referenceContrast) == section.frozen(), "r \(r), \(name), blur \(blur), sd \(sd)")
                }
            }
        }
    }

    /// In a stretch, a ring of struts is taken where the sections around show
    /// it too: a stent runs 8 mm or more, while the noise of a CT can make
    /// one section look like a ring. One section of a healthy stretch that
    /// alone shows a ring keeps the threshold's lumen; three millimetres of
    /// the same stent are measured inside their struts, to their ends.
    @Test func aRingThatOneSectionAloneShowsIsNoStent() throws {
        var settings = Stenosis.Settings()
        settings.step = 0.5
        let length = 10.0
        let patent = Double.pi * 1.85 * 1.85
        var healthy = SyntheticSection(blur: 0.4) { x, y in (x * x + y * y).squareRoot() <= 1.85 ? 400 : 50 }
        healthy.addNoise(sd: 12, seed: 0xA1)
        let stent = stentSection(inner: 1.85, blur: 0.4, noise: 12, seed: 0xA2)
        let alone = try #require(Stenosis.segment(values: stent.values, size: stent.size, settings: settings, contrast: referenceContrast))
        #expect(abs(stent.area(alone.mask) - patent) < 0.15 * patent)
        func along(_ t: Double) -> Stenosis.Frame {
            Stenosis.Frame(point: SIMD3(0, 0, t * length), tangent: SIMD3(0, 0, 1), normal: SIMD3(0, 1, 0))
        }
        for stented in [4.0...4.0, 2.5...5.5] {
            let measured = Stenosis.sections(from: 0, to: 1, length: length, settings: settings, frame: along) { p in
                stented.contains((p.z * 2).rounded() / 2) ? stent.sample(p) : healthy.sample(p)
            }
            for section in measured where stented.contains(section.position) {
                let what = "stent over \(stented), at \(section.position) mm: \(section.area) mm²"
                if stented.lowerBound == stented.upperBound {
                    #expect(abs(section.area - stent.area(stent.frozen(settings))) < 1e-9, "\(what)")
                } else {
                    #expect(abs(section.area - patent) < 0.15 * patent, "\(what)")
                }
            }
        }
    }

    // MARK: - The struts along the curved path

    /// The stented vessel of the in-app check, measured along the path the
    /// curved MPR draws through its ten nodes (the tool's own points and
    /// tangents, which swing up to 0.37 mm off the axis of the lumen left,
    /// toward the struts, and lean up to 20°) and along that axis. Off the
    /// axis, the middle of each restenosis missed the ring and read the
    /// ring's area, six to ten times the lumen left, and on it two sections
    /// of the tighter one did. Now every section of the stent tells its
    /// struts: the patent stent measures within 15 % of the vessel, the
    /// restenoses near their lumen left, no neointima is left out as a hole,
    /// the minimum is in the tighter restenosis and NASCET by area is near
    /// its 84 %.
    @Test(arguments: [true, false])
    func everySectionOfAStentTellsItsStrutsAlongTheCurvedPathAndAlongItsAxis(curved: Bool) throws {
        let (places, length) = StentedVessel.places(alongTheCurvedPath: curved)
        let reference = Stenosis.defaultReference(stretch: length)
        let (sections, _) = Stenosis.sections(at: places, settings: Stenosis.Settings(), reference: reference,
                                              sample: StentedVessel.volume.sample)
        let patent = Double.pi * 1.85 * 1.85
        for section in sections {
            let z = section.frame.point.z, what = "at z \(z): \(section.area) mm²"
            if [8.5...11.5, 23.5...25.5, 37.5...39.5].contains(where: { $0.contains(z) }) {
                #expect(abs(section.area - patent) < 0.15 * patent, "\(what)")
            } else if (15.5...19.5).contains(z) {
                #expect(section.area > 0.8 * .pi && section.area < 1.4 * .pi, "\(what)")
            } else if (29.5...33.5).contains(z) {
                #expect(section.area < 2 * .pi * 0.5625, "\(what)")
            }
            if (8.5...39.5).contains(z) { #expect(section.holeContours.isEmpty, "\(what), \(section.holeContours.count) holes") }
        }
        let result = try #require(Stenosis.result(of: sections, reference: reference))
        let narrowest = sections[result.minimumIndex].frame.point.z
        #expect((29...34).contains(narrowest), "minimum at z \(narrowest)")
        #expect(result.nascetByArea > 75, "NASCET by area \(result.nascetByArea) %")
    }

    /// Erase Plaque, Undo Last Stroke and Reset Section measure the shown
    /// section again alone. Alone, a section of a stent shows its ring but
    /// none around it does, and the stretch takes a ring only where the
    /// sections around show it too: a patent stent went from 10.6 mm² to
    /// 12.8 with a stroke across its lumen and to 20.7 with its undo.
    /// Measured with the places of its stretch, it keeps its ring: without a
    /// stroke it is again the section its stretch measured, and a stroke
    /// takes the lumen it covers and what that cuts off, nothing else. A
    /// stroke beside the lumen left of a restenosis changes nothing.
    @Test(arguments: [12, 28])
    func aSectionMeasuredAgainAloneKeepsTheRingItsStretchTellsIt(index: Int) throws {
        let (places, length) = StentedVessel.places(alongTheCurvedPath: true)
        let volume = StentedVessel.volume
        let (sections, contrast) = Stenosis.sections(at: places, settings: Stenosis.Settings(),
                                                     reference: Stenosis.defaultReference(stretch: length), sample: volume.sample)
        let stretch = sections[index]
        let alone = Stenosis.sections(at: [places[index]], settings: Stenosis.Settings(), reference: nil, contrast: contrast,
                                      sample: volume.sample).sections[0]
        #expect(alone.area > 1.5 * stretch.area, "alone \(alone.area) mm², in its stretch \(stretch.area)")

        let again = Stenosis.section(index, of: places, settings: Stenosis.Settings(), contrast: contrast, sample: volume.sample)
        #expect(again.area == stretch.area && again.contour == stretch.contour && !again.corrected)

        // A stroke across the vessel at x 24.7 mm: in the patent stent at
        // z 10 (lumen from x 23.75 to 27.45), the lumen left is the part
        // beyond x 25.1, on the centerline's side; the lumen left of the
        // restenosis at z 17.8 starts at x 25.45.
        let z = stretch.frame.point.z
        var stroked = places
        stroked[index].erasures = [Stenosis.Erasure(points: stride(from: -2.5, through: 2.5, by: 1.25).map { SIMD3(24.7, 25.6 + $0, z) },
                                                    radius: 0.4)]
        let erased = Stenosis.section(index, of: stroked, settings: Stenosis.Settings(), contrast: contrast, sample: volume.sample)
        if index == 12 {
            let r = 1.85, d = 0.5
            let beyondTheStroke = Double.pi * r * r - (r * r * acos(d / r) - d * (r * r - d * d).squareRoot())
            #expect(erased.corrected && abs(erased.area - beyondTheStroke) < 0.1 * beyondTheStroke,
                    "stroke: \(erased.area) mm², the lumen beyond it \(beyondTheStroke)")
        } else {
            #expect(!erased.corrected && erased.area == stretch.area)
        }
    }

    /// A straight stent whose lumen left (1.85 mm, a patent stent; 1 and
    /// 0.75 mm, restenoses against the struts on +x) a path crosses up to
    /// 0.5 mm off its axis, toward the struts, away from them or aside, and
    /// at a slant of up to 25°: the ring is told in the middle of 3 mm of
    /// the stretch, which measures near its lumen left (π r² over the cosine
    /// of the slant), and leaves no neointima out as a hole. The threshold
    /// alone makes such a section two to ten times as large. With the path
    /// 0.5 mm toward the struts and leaning 25° in their plane, the blur of
    /// the struts makes the centerline as bright as their crests, and the
    /// tighter restenosis read three times its lumen left.
    @Test(arguments: [(1.85, 0.5, 0.0, 25.0, 90.0), (1.85, -0.5, 0.0, 20.0, 0.0), (1.85, 0.0, 0.5, 25.0, 0.0), (1.85, 0.5, 0.0, 25.0, 0.0),
                      (1.0, 0.5, 0.0, 0.0, 0.0), (1.0, 0.27, 0.0, 20.0, 0.0), (1.0, 0.0, 0.5, 25.0, 90.0), (1.0, -0.5, 0.0, 25.0, 0.0),
                      (1.0, 0.5, 0.0, 25.0, 0.0), (1.0, 0.5, 0.0, 25.0, 180.0),
                      (0.75, 0.37, 0.0, 0.0, 0.0), (0.75, 0.5, 0.0, 10.0, 0.0), (0.75, 0.0, 0.25, 20.0, 90.0), (0.75, -0.25, 0.0, 25.0, 0.0),
                      (0.75, 0.5, 0.0, 20.0, 0.0), (0.75, 0.5, 0.0, 25.0, 0.0), (0.75, 0.5, 0.0, 25.0, 180.0)])
    func theRingIsToldWithThePathOffTheAxisOfTheLumenLeftAndAtASlant(left: Double, dx: Double, dy: Double, slant: Double,
                                                                     toward azimuth: Double) {
        let volume = straightStent(left: left)
        let (theta, phi) = (slant * .pi / 180, azimuth * .pi / 180)
        let tangent = SIMD3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta))
        let normal = simd_normalize(simd_cross(simd_cross(tangent, SIMD3(1, 0, 0)), tangent))
        let middle = SIMD3(6.4 + 1.85 - left + dx, 6.4 + dy, 8)
        let places = (-3...3).map { k in
            Stenosis.Place(position: Double(k + 3) * 0.5, relativePosition: Double(k + 3) / 6,
                           frame: Stenosis.Frame(point: middle + Double(k) * 0.5 * tangent, tangent: tangent, normal: normal))
        }
        let section = Stenosis.sections(at: places, settings: Stenosis.Settings(), reference: nil, contrast: referenceContrast,
                                        sample: volume.sample).sections[3]
        let truth = Double.pi * left * left / cos(theta)
        #expect(section.area > 0.7 * truth && section.area < (left < 1 ? 1.75 : 1.6) * truth, "\(section.area) mm² for \(truth)")
        #expect(section.holeContours.isEmpty)
    }

    /// Where the sections around a section show the ring of a stent and it
    /// misses it (a ring blurred by 0.65 mm here, in 1.5 mm of a stretch of
    /// restenosis), the ring and its blur stay in its lumen, as without a
    /// ring, but the neointima they enclose more than 0.5 mm across leaves:
    /// it never reads more than the threshold's lumen, which kept it.
    @Test func aSectionThatMissesTheRingTheSectionsAroundShowLeavesItsNeointimaOut() throws {
        let told = stentSection(inner: 1.0, blur: 0.4), missed = stentSection(inner: 1.0, blur: 0.65)
        let places = stretch(of: 12)
        let measured = Stenosis.sections(at: places, settings: Stenosis.Settings(), reference: nil, contrast: referenceContrast) { p in
            (2.5...3.5).contains(p.z) ? missed.sample(p) : told.sample(p)
        }.sections
        let alone = try #require(Stenosis.segment(values: missed.values, size: missed.size, settings: missed.settings,
                                                  contrast: referenceContrast))
        #expect(alone.mask == missed.frozen())
        for section in measured {
            let what = "at \(section.position) mm: \(section.area) mm²"
            if (2.5...3.5).contains(section.position) {
                #expect(section.area < missed.area(alone.mask) - 0.5 && !section.holeContours.isEmpty, "\(what)")
            } else {
                #expect(abs(section.area - .pi) < 0.3 * .pi && section.holeContours.isEmpty, "\(what)")
            }
            // The stretch says which of its sections missed the ring, for the summary to say so.
            #expect(section.strutRingMissed == (2.5...3.5).contains(section.position), "\(what)")
        }
        // Measured again alone, a section says the same.
        let again = Stenosis.section(6, of: places, settings: Stenosis.Settings(), contrast: referenceContrast) { p in
            (2.5...3.5).contains(p.z) ? missed.sample(p) : told.sample(p)
        }
        #expect(again.strutRingMissed && again.area == measured[6].area)
        let result = try #require(Stenosis.result(of: measured, reference: 4.5...6))
        #expect(result.strutRingMissedCount == 3 && !result.referenceStrutRingMissed)
        // The section that misses the ring holds it, and is not the narrowest.
        #expect(result.minimumStrutRingMissed == measured[result.minimumIndex].strutRingMissed)
        let within = try #require(Stenosis.result(of: measured, reference: 2.5...3.5))
        #expect(within.referenceStrutRingMissed)
    }

    /// A ring blurred by 0.55 to 0.6 mm, whose crest is too wide and whose
    /// dip is too shallow for a ring anywhere, is read as one where another
    /// section of the stretch shows the struts sharp: the lumen is the lumen
    /// left inside it, and the section misses nothing. In a stretch shorter
    /// than a stent where no section shows them, nothing says a stent is
    /// there, and the section reads what it read alone.
    @Test(arguments: [0.55, 0.6])
    func aBlurredRingIsReadWhereTheStretchShowsAStent(blur: Double) throws {
        let told = stentSection(inner: 1.0, blur: 0.4), blurred = stentSection(inner: 1.0, blur: blur)
        let places = stretch(of: 12)
        let sample: (SIMD3<Double>) -> Float = { p in (2.5...3.5).contains(p.z) ? blurred.sample(p) : told.sample(p) }
        let measured = Stenosis.sections(at: places, settings: Stenosis.Settings(), reference: nil, contrast: referenceContrast,
                                         sample: sample).sections
        for section in measured {
            #expect(abs(section.area - .pi) < 0.3 * .pi && section.holeContours.isEmpty && !section.strutRingMissed,
                    "at \(section.position) mm: \(section.area) mm²")
        }
        #expect(try #require(Stenosis.result(of: measured, reference: 4.5...6)).strutRingMissedCount == 0)
        // Measured again alone, a section reads the same ring.
        let again = Stenosis.section(6, of: places, settings: Stenosis.Settings(), contrast: referenceContrast, sample: sample)
        #expect(again.area == measured[6].area && !again.strutRingMissed)

        let alone = try #require(Stenosis.segment(values: blurred.values, size: blurred.size, settings: blurred.settings,
                                                  contrast: referenceContrast))
        let unanchored = Stenosis.sections(at: places, settings: Stenosis.Settings(), reference: nil, contrast: referenceContrast,
                                           sample: blurred.sample).sections
        for section in unanchored {
            #expect(abs(section.area - blurred.area(alone.mask)) < 1e-6 && !section.strutRingMissed,
                    "at \(section.position) mm: \(section.area) mm²")
        }
    }

    /// A scanner blurs a whole stent alike: a stretch as long as a stent
    /// (8 mm) whose sections all show the ring so blurred holds one, and is
    /// read as one; the same sections in a shorter stretch are not. A section
    /// measured again alone reads what its stretch read.
    @Test func aStretchBlurredAllAlongTheLengthOfAStentIsReadAsOne() throws {
        let blurred = stentSection(inner: 1.0, blur: 0.55)
        let alone = try #require(Stenosis.segment(values: blurred.values, size: blurred.size, settings: blurred.settings,
                                                  contrast: referenceContrast))
        for (steps, stented) in [(20, true), (16, true), (15, false)] {
            let places = stretch(of: steps)
            let measured = Stenosis.sections(at: places, settings: Stenosis.Settings(), reference: nil, contrast: referenceContrast,
                                             sample: blurred.sample).sections
            for section in measured {
                let what = "\(steps) steps, at \(section.position) mm: \(section.area) mm²"
                #expect(section.stretchHoldsStent == stented && !section.strutRingMissed, "\(what)")
                if stented {
                    #expect(abs(section.area - .pi) < 0.3 * .pi && section.holeContours.isEmpty, "\(what)")
                } else {
                    #expect(abs(section.area - blurred.area(alone.mask)) < 1e-6, "\(what)")
                }
            }
            let again = Stenosis.section(steps / 2, of: places, settings: Stenosis.Settings(), contrast: referenceContrast, sample: blurred.sample)
            #expect(again.area == measured[steps / 2].area && again.stretchHoldsStent == stented)
            let told = Stenosis.section(steps / 2, of: places, settings: Stenosis.Settings(), contrast: referenceContrast, stented: stented,
                                        sample: blurred.sample)
            #expect(told.area == measured[steps / 2].area)
        }
    }

    /// A stretch without a stent, and one whose ring every section shows, miss none.
    @Test func noSectionMissesARingThatIsToldOrIsNotThere() throws {
        let told = stentSection(inner: 1.0, blur: 0.4)
        let places = (0...8).map { i in
            Stenosis.Place(position: Double(i) * 0.5, relativePosition: Double(i) / 8,
                           frame: Stenosis.Frame(point: SIMD3(0, 0, Double(i) * 0.5), tangent: SIMD3(0, 0, 1), normal: SIMD3(0, 1, 0)))
        }
        let stented = Stenosis.sections(at: places, settings: Stenosis.Settings(), reference: nil, contrast: referenceContrast, sample: told.sample).sections
        #expect(stented.allSatisfy { !$0.strutRingMissed })
        #expect(try #require(Stenosis.result(of: stented, reference: 3...4)).strutRingMissedCount == 0)
    }

    /// A centerline in a lumen left of 0.25 to 0.5 mm against the struts
    /// stays in its lumen: read from the middle of the ring, the rays first
    /// cross the neointima, and the lumen left beyond it is no part of the
    /// ring. The lumen is never empty, and holds the lumen left.
    @Test(arguments: [(2.0, 0.25), (1.5, 0.3), (1.5, 0.5)])
    func aTightLumenLeftAgainstTheStrutsKeepsItsLumen(radius: Double, inner: Double) throws {
        let section = stentSection(radius: radius, inner: inner, blur: 0.45)
        let found = try #require(Stenosis.segment(values: section.values, size: section.size, settings: section.settings,
                                                  contrast: referenceContrast))
        let isLeft: (Double, Double) -> Bool = { x, y in (x * x + y * y).squareRoot() <= inner - 0.1 }
        #expect(section.area(found.mask, where: isLeft) > 0.9 * section.area(section.values.indices.map { _ in true }, where: isLeft))
        #expect(section.area(found.mask) < section.area(section.frozen()))
    }

    // MARK: - Tissue the lumen surrounds

    /// A thrombus or a soft plaque of 1 mm radius at 40 HU, which a lumen of
    /// 3 mm surrounds: what of it is darker than the lumen's edge stays out
    /// of the lumen, and nothing else changes.
    @Test func softPlaqueTheLumenSurroundsStaysOutOfIt() throws {
        let isPlaque: (Double, Double) -> Bool = { x, y in ((x - 1.2) * (x - 1.2) + y * y).squareRoot() <= 1 }
        let section = SyntheticSection { x, y in isPlaque(x, y) ? 40 : (x * x + y * y).squareRoot() <= 3 ? 400 : 50 }
        let found = try #require(Stenosis.segment(values: section.values, size: section.size, settings: section.settings,
                                                  contrast: referenceContrast))
        let frozen = section.frozen()
        let edge = Float(section.settings.lowerFraction) * found.centerValue
        let dark: (Double, Double) -> Bool = { x, y in isPlaque(x, y) && section.sample(SIMD3(x, y, 0)) < edge }
        #expect(section.area(frozen, where: dark) > 1.5)
        #expect(section.area(found.mask, where: dark) == 0)
        #expect(isWithin(found.mask, frozen))
        #expect(section.area(found.mask) { !isPlaque($0, $1) } == section.area(frozen) { !isPlaque($0, $1) })
        let truth = Double.pi * 9 - .pi
        #expect(abs(section.area(found.mask) - truth) < abs(section.area(frozen) - truth) - 1.5)
        // The section the transverse view shows: the plaque is outlined
        // apart from the lumen round it, and what is drawn is what is counted.
        let shown = Stenosis.section(at: 0.5, position: 0, frame: frame, settings: section.settings, contrast: referenceContrast,
                                     sample: section.sample)
        #expect(shown.area == section.area(found.mask) && shown.holeContours.count == 1)
        let planar = { (points: [SIMD3<Double>]) in points.map { SIMD2($0.x, $0.y) } }
        let drawn = enclosedArea(planar(shown.contour)) - shown.holeContours.map { enclosedArea(planar($0)) }.reduce(0, +)
        #expect(abs(drawn - shown.area) < 0.03 * shown.area, "\(drawn)")
    }

    /// A lumen of 6 mm at 260 HU in the noise of a CT of 40 HU, its edge at
    /// 70 % of its centerline: the noise drops samples inside the lumen
    /// below the edge, in specks too narrow to be tissue at that edge. They
    /// are lumen, and filling the holes still puts them back.
    @Test func specksThatTheNoiseDropsBelowTheEdgeInsideTheLumenStayInIt() throws {
        var section = SyntheticSection(blur: 0.4) { x, y in (x * x + y * y).squareRoot() <= 6 ? 260 : 50 }
        section.addNoise(sd: 40, seed: 1)
        var settings = Stenosis.Settings()
        settings.lowerFraction = 0.7
        let found = try #require(Stenosis.segment(values: section.values, size: section.size, settings: settings, contrast: referenceContrast))
        let frozen = section.frozen(settings)
        let edge = Float(settings.lowerFraction) * found.centerValue
        #expect(section.area(frozen) { section.sample(SIMD3($0, $1, 0)) < edge } > 0.5)
        #expect(found.mask == frozen)
    }

    /// Wide lumens at 260 HU in the noise of a CT of 45 HU of a coarser
    /// grain, over voxels of 1 and 1.25 mm, their edge raised to 70 and 80 %
    /// of the centerline: the specks the noise drops below such an edge
    /// merge into patches wider than the neck. They are lumen too, and
    /// filling the holes still puts them back.
    @Test(arguments: [(4.5, 1.25, UInt64(8), 0.8), (6.0, 1.0, UInt64(5), 0.8), (6.0, 1.25, UInt64(4), 0.7), (4.5, 1.25, UInt64(6), 0.7)])
    func coarserSpecksBelowARaisedEdgeStayInTheLumen(radius r: Double, voxel: Double, seed: UInt64, edge: Double) throws {
        var section = SyntheticSection(blur: 0.5) { x, y in (x * x + y * y).squareRoot() <= r ? 260 : 50 }
        section.addNoise(sd: 45, seed: seed, voxel: voxel)
        var settings = Stenosis.Settings()
        settings.lowerFraction = edge
        let found = try #require(Stenosis.segment(values: section.values, size: section.size, settings: settings, contrast: referenceContrast))
        let frozen = section.frozen(settings)
        let below = Float(edge) * found.centerValue
        #expect(section.area(frozen) { section.sample(SIMD3($0, $1, 0)) < below } > 1, "r \(r), voxel \(voxel), edge \(edge)")
        #expect(found.mask == frozen, "r \(r), voxel \(voxel), edge \(edge)")
    }

    /// A mask with holes: the outline goes round them as round the mask
    /// without them, and each hole has its own outline, along the sides of
    /// its pixels, enclosing its area; two holes that touch at a corner are two.
    @Test func theOutlineGoesRoundTheHolesAndEachHoleHasItsOwn() {
        let size = 61, c = 30
        var mask = [Bool](repeating: false, count: size * size)
        for y in 0..<size {
            for x in 0..<size where (x - c) * (x - c) + (y - c) * (y - c) <= 20 * 20 { mask[y * size + x] = true }
        }
        let whole = mask
        // A rectangle of 4 × 3 pixels, and two pixels touching at a corner.
        for y in 25..<28 { for x in 33..<37 { mask[y * size + x] = false } }
        mask[40 * size + 22] = false
        mask[41 * size + 23] = false
        #expect(Stenosis.outline(of: mask, size: size) == Stenosis.outline(of: whole, size: size))
        let holes = Stenosis.holeOutlines(of: mask, size: size)
        #expect(holes.map(enclosedArea).sorted() == [1, 1, 12])
        #expect(holes.allSatisfy { hole in hole.allSatisfy { simd_length($0) < 20 } })
        #expect(Stenosis.holeOutlines(of: whole, size: size).isEmpty)
    }

    // MARK: - The correction by hand

    /// A stroke of the eraser along the plaque, 0.3 mm wide on each side.
    private func strokeAlongThePlaque(at rho: Double = 2.35) -> Stenosis.Erasure {
        Stenosis.Erasure(points: stride(from: -50.0, through: 50.0, by: 5).map {
            SIMD3(rho * cos($0 * .pi / 180), rho * sin($0 * .pi / 180), 0)
        }, radius: 0.3)
    }

    @Test func whatIsErasedByHandLeavesTheLumenOfItsSectionAndStaysOutWhenTheSettingsChange() {
        // A thin plaque of 700 HU: blurred, no limit down to 1.3 tells it from the contrast.
        let section = plaqueSection(plaque: 700, thickness: 0.5)
        var settings = Stenosis.Settings()
        settings.upperFraction = 1.3
        let automatic = Stenosis.section(at: 0.5, position: 3, frame: frame, settings: settings, contrast: referenceContrast, sample: section.sample)
        #expect(!automatic.corrected)
        #expect(automatic.area > lumenArea * 1.15)

        let stroke = strokeAlongThePlaque()
        let corrected = Stenosis.section(at: 0.5, position: 3, frame: frame, settings: settings, contrast: referenceContrast,
                                         erasures: [stroke], sample: section.sample)
        #expect(corrected.corrected)
        #expect(abs(corrected.area - lumenArea) < lumenArea * 0.06)
        #expect(corrected.minDiameter <= automatic.minDiameter)
        // What the stroke cut off from the lumen left with it: the outline
        // stays on the lumen's side of the stroke.
        #expect((corrected.contour.map { simd_length($0) }.max() ?? 9) < 2.35)

        // The same stroke, the lumen edge moved: the plaque is still out.
        settings.lowerFraction = 0.4
        let moved = Stenosis.section(at: 0.5, position: 3, frame: frame, settings: settings, contrast: referenceContrast,
                                     erasures: [stroke], sample: section.sample)
        let movedAutomatic = Stenosis.section(at: 0.5, position: 3, frame: frame, settings: settings, contrast: referenceContrast, sample: section.sample)
        #expect(moved.corrected && moved.area < movedAutomatic.area - 1)
        #expect((moved.contour.map { simd_length($0) }.max() ?? 9) < 2.35)

        // Without the stroke the section is the automatic one again.
        settings.lowerFraction = 0.5
        let reset = Stenosis.section(at: 0.5, position: 3, frame: frame, settings: settings, contrast: referenceContrast, erasures: [], sample: section.sample)
        #expect(!reset.corrected && reset.area == automatic.area && reset.contour == automatic.contour)
    }

    @Test func anErasureOnlyTakesLumenAwayInASectionWithOrWithoutCalcium() {
        let erased = Stenosis.erasedMask([strokeAlongThePlaque()], frame: frame, size: plaqueSection(plaque: 700).size, pixel: 0.1)
        for (plaque, limit) in [(700.0, 1.6), (700.0, 1.3), (1300.0, 1.6)] {
            let section = plaqueSection(plaque: plaque, thickness: 0.5)
            var settings = Stenosis.Settings()
            settings.upperFraction = limit
            let automatic = section.mask(settings, contrast: referenceContrast)
            let corrected = section.mask(settings, contrast: referenceContrast, erased: erased)
            #expect(corrected.contains(true) && isWithin(corrected, automatic), "\(plaque) HU, limit \(limit)")
            #expect(corrected.indices.allSatisfy { !corrected[$0] || !erased[$0] }, "\(plaque) HU, limit \(limit)")
        }
    }

    @Test func aStrokeThatTakesNoLumenCorrectsNothing() throws {
        let section = plaqueSection(plaque: 1300)
        let automatic = Stenosis.section(at: 0.5, position: 0, frame: frame, settings: section.settings, contrast: referenceContrast, sample: section.sample)
        // Beside the lumen, in soft tissue: the section is the automatic one.
        let away = Stenosis.Erasure(points: [SIMD3(-5, 4, 0), SIMD3(-6, 5, 0)], radius: 0.4)
        let stroked = Stenosis.section(at: 0.5, position: 0, frame: frame, settings: section.settings, contrast: referenceContrast,
                                       erasures: [away], sample: section.sample)
        #expect(!stroked.corrected && stroked.area == automatic.area && stroked.contour == automatic.contour)
        let result = try #require(Stenosis.result(of: [stroked], reference: 0...1))
        #expect(result.correctedCount == 0 && !result.minimumCorrected && !result.referenceCorrected)
        // Across the lumen's edge: corrected.
        let edge = Stenosis.Erasure(points: [SIMD3(0, -2, 0)], radius: 0.4)
        let touched = Stenosis.section(at: 0.5, position: 0, frame: frame, settings: section.settings, contrast: referenceContrast,
                                       erasures: [away, edge], sample: section.sample)
        #expect(touched.corrected && touched.area < automatic.area)
    }

    @Test func aStrokeCoversTheDiscsOfItsRadiusAlongItsLines() {
        let size = 161
        // One point: a disc. Off the plane, it is taken onto it.
        let dot = Stenosis.erasedMask([Stenosis.Erasure(points: [SIMD3(1, -2, 0.7)], radius: 0.5)], frame: frame, size: size, pixel: 0.1)
        #expect(abs(Double(dot.filter { $0 }.count) * 0.01 - .pi * 0.25) < 0.05)
        // The section's x axis is the tangent across the normal: −x here.
        #expect(dot[(80 - 20) * size + 80 - 10] && !dot[80 * size + 80])
        // Two points: the discs and the band between them.
        let line = Stenosis.erasedMask([Stenosis.Erasure(points: [SIMD3(-1, 0, 0), SIMD3(1, 0, 0)], radius: 0.2)], frame: frame, size: size, pixel: 0.1)
        #expect(abs(Double(line.filter { $0 }.count) * 0.01 - (2 * 0.4 + .pi * 0.04)) < 0.25)
        #expect(Stenosis.erasedMask([Stenosis.Erasure(points: [], radius: 1)], frame: frame, size: size, pixel: 0.1).allSatisfy { !$0 })
    }

    @Test func aLumenErasedWholeIsNoSectionAndOneErasedAtItsCenterKeepsItsOutline() {
        let section = plaqueSection(plaque: 1300)
        let all = Stenosis.Erasure(points: [SIMD3(0, 0, 0)], radius: 6)
        let none = Stenosis.section(at: 0.5, position: 0, frame: frame, settings: section.settings, contrast: referenceContrast,
                                    erasures: [all], sample: section.sample)
        #expect(none.corrected && !none.isValid && none.contour.isEmpty && none.minDiameter == 0 && none.lumenTaken == .byHand)

        // The center erased: the outline is drawn from inside what is left.
        let center = Stenosis.Erasure(points: [SIMD3(0, -3, 0), SIMD3(0, 0.5, 0)], radius: 0.4)
        let left = Stenosis.section(at: 0.5, position: 0, frame: frame, settings: section.settings, contrast: referenceContrast,
                                    erasures: [center], sample: section.sample)
        #expect(left.isValid && left.contour.count == 180 && left.lumenTaken == nil)
        #expect(left.contour.allSatisfy { simd_length($0) < 2.3 })
        #expect(left.contour.contains { simd_length($0) > 1.5 })
    }

    // MARK: - The stretch

    private func section(_ position: Double, area: Double, diameter: Double, corrected: Bool = false) -> Stenosis.Section {
        Stenosis.Section(position: position, relativePosition: position / 10, frame: frame, area: area, minDiameter: diameter,
                         centerValue: 400, contour: [], corrected: corrected)
    }

    @Test func theResultCountsCorrectedSectionsAsTheOthersAndSaysWhereTheyComeIn() throws {
        let plain = [section(0, area: 12, diameter: 3.9), section(1, area: 5, diameter: 2.5), section(2, area: 12, diameter: 3.9),
                     section(3, area: 12, diameter: 3.9)]
        let untouched = try #require(Stenosis.result(of: plain, reference: 2...3))
        #expect(!untouched.minimumCorrected && !untouched.minimumDiameterCorrected && !untouched.referenceCorrected)
        #expect(untouched.correctedCount == 0)

        // The narrowest section corrected: the minimum and the degree are its own.
        var sections = plain
        sections[1] = section(1, area: 3, diameter: 1.5, corrected: true)
        let minimum = try #require(Stenosis.result(of: sections, reference: 2...3))
        #expect(minimum.minimumArea == 3 && minimum.minimumCorrected && minimum.minimumDiameterCorrected && !minimum.referenceCorrected)
        #expect(abs(minimum.nascetByArea - 75) < 1e-9 && minimum.correctedCount == 1)

        // A reference section corrected: the reference is the mean with it.
        sections = plain
        sections[3] = section(3, area: 10, diameter: 3.5, corrected: true)
        let reference = try #require(Stenosis.result(of: sections, reference: 2...3))
        #expect(reference.referenceArea == 11 && reference.referenceCorrected && !reference.minimumCorrected)
        #expect(abs(reference.referenceDiameter - 3.7) < 1e-9)

        // The smallest diameter may be another section than the smallest area.
        sections = plain
        sections[0] = section(0, area: 9, diameter: 2.0, corrected: true)
        let narrow = try #require(Stenosis.result(of: sections, reference: 2...3))
        #expect(!narrow.minimumCorrected && narrow.minimumDiameterCorrected && narrow.minimumDiameter == 2.0)

        // A section erased whole is left out, like one without lumen, and counted.
        sections = plain
        sections[1] = section(1, area: 0, diameter: 0, corrected: true)
        sections[1].lumenTaken = .byHand
        let erased = try #require(Stenosis.result(of: sections, reference: 2...3))
        #expect(erased.minimumArea == 12 && erased.correctedCount == 0)
        #expect(erased.takenByHandCount == 1 && erased.takenByCalciumCount == 0)
    }

    /// A lumen of radius r at (cx, cy) with an edge that falls from `value`
    /// to 0 over 0.4 mm, half of it at r.
    private func disc(_ p: SIMD3<Double>, cx: Double, cy: Double, r: Double, value: Double) -> Double {
        let rho = ((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy)).squareRoot()
        return value * min(max(0.5 - (rho - r) / 0.4, 0), 1)
    }

    /// The narrowing: 3 mm, down to 1.5 mm between z = 20 and 25, back up by 30.
    private func radius(_ z: Double) -> Double {
        switch z {
        case ..<15: return 3
        case ..<20: return 3 - 1.5 * (z - 15) / 5
        case ..<25: return 1.5
        case ..<30: return 1.5 + 1.5 * (z - 25) / 5
        default: return 3
        }
    }

    @Test func aNarrowingToHalfTheDiameterIs75PercentByAreaAnd50ByDiameterAndAnErasureReachesItsSectionOnly() throws {
        let length = 50.0
        func along(_ t: Double) -> Stenosis.Frame {
            Stenosis.Frame(point: SIMD3(0, 0, t * length), tangent: SIMD3(0, 0, 1), normal: SIMD3(0, 1, 0))
        }
        // Farther apart than the tool's sections, to keep the test short.
        var settings = Stenosis.Settings()
        settings.step = 2.5
        func tube(_ p: SIMD3<Double>) -> Float { Float(disc(p, cx: 0, cy: 0, r: radius(p.z), value: 400)) }
        let sections = Stenosis.sections(from: 0, to: 1, length: length, settings: settings, frame: along, sample: tube)
        #expect(sections.count == 21)
        let reference = Stenosis.defaultReference(stretch: length)
        #expect(reference == 40...50)
        let result = try #require(Stenosis.result(of: sections, reference: reference))
        #expect(abs(result.nascetByArea - 75) < 2)
        #expect(abs(result.nascetByDiameter - 50) < 2)
        #expect((20...25).contains(result.minimumPosition))
        #expect(result.correctedCount == 0)

        // Half of the lumen of the first section erased: that section alone changes.
        let half = Stenosis.Erasure(points: [SIMD3(-4, -2, 0), SIMD3(4, -2, 0)], radius: 2)
        let corrected = Stenosis.sections(from: 0, to: 1, length: length, settings: settings, erasures: [0: [half]], frame: along, sample: tube)
        #expect(corrected[0].corrected && corrected[0].area < sections[0].area * 0.6)
        for i in 1..<sections.count { #expect(!corrected[i].corrected && corrected[i].area == sections[i].area) }
        #expect(try #require(Stenosis.result(of: corrected, reference: reference)).correctedCount == 1)
    }

    @Test func aNeighbouringVesselSoftTissueAndNoContrastStayOut() {
        let settings = Stenosis.Settings()
        // A neighbouring vessel of 4 mm touching a 3 mm lumen.
        let beside = Stenosis.section(at: 0.1, position: 0, frame: frame, settings: settings, contrast: referenceContrast) { p in
            Float(max(self.disc(p, cx: 0, cy: 0, r: 3, value: 400), self.disc(p, cx: 7, cy: 0, r: 4, value: 350)))
        }
        #expect(abs(beside.area - .pi * 9) < .pi * 9 * 0.04)
        #expect((beside.contour.map { simd_length(SIMD2($0.x, $0.y)) }.max() ?? 9) < 3.4)
        // A centerline that runs beside the lumen, in soft tissue (60 HU).
        let off = Stenosis.section(at: 0.5, position: 0, frame: frame, settings: settings, contrast: referenceContrast) { p in
            Float(max(self.disc(p, cx: 4, cy: 0, r: 2.5, value: 400), 60))
        }
        #expect(!off.isValid && off.lumenTaken == nil)
        let empty = Stenosis.section(at: 0.5, position: 0, frame: frame, settings: settings) { _ in 0 }
        #expect(!empty.isValid && !empty.corrected && empty.lumenTaken == nil)
        #expect(Stenosis.result(of: [empty], reference: 0...1) == nil)
    }
}
