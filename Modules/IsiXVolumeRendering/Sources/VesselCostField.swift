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

/// A growable run of plain values that a trace reads and writes by index:
/// raw memory, without an array's copy-on-write and exclusivity checks,
/// which in an unoptimized build (the Debug app) cost more than the search.
struct VesselStorage<Element> {
    private(set) var base: UnsafeMutablePointer<Element>
    private(set) var count = 0
    private var capacity: Int

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
        base = .allocate(capacity: self.capacity)
    }

    /// `count` copies of `value` at the end.
    mutating func append(_ value: Element, count added: Int) {
        if count + added > capacity {
            let grown = max(capacity * 2, count + added)
            let moved = UnsafeMutablePointer<Element>.allocate(capacity: grown)
            moved.moveInitialize(from: base, count: count)
            base.deallocate()
            base = moved
            capacity = grown
        }
        (base + count).initialize(repeating: value, count: added)
        count += added
    }

    func release() {
        base.deinitialize(count: count)
        base.deallocate()
    }
}

/// The search grid of a trace and what a step through each of its voxels
/// costs, computed as the search reaches them.
///
/// A voxel is of one of three kinds. Lumen of the vessel: its value lies in
/// the lumen's interval and the structure it belongs to is no wider than the
/// vessel; a step in it costs (R / d)^k per millimetre, d its distance to the
/// nearest voxel that is not lumen of the vessel and R the cap radius, so the
/// path keeps to the axis. Out of the lumen: a step costs the outside cost,
/// up to five times more by how far its value is from the interval. Wide: its
/// value is in the interval but it belongs to a structure much wider than the
/// vessel, a cavity of the heart, the aorta or a thick sheet of enhancing
/// myocardium beside a coronary; a step costs as much as through fat, so a
/// cavity is never a shortcut between two parts of a vessel, whatever the
/// thickness of the wall between them. Near an end marked in such a structure
/// (a point in the aorta at a coronary's ostium) it counts as lumen.
///
/// A voxel is wide when at least five of the thirteen lines through it along
/// its neighbours' axes run in the interval for the chord length (three times
/// the vessel's diameter) or more: a tube is that long only along its axis, a
/// bifurcation, or a vessel merged with a vein beside it, along two to four,
/// a cavity of the heart or the aorta beside a coronary along most.
/// A voxel of the interval within three quarters of a millimetre of one above
/// it counts as wide too: it is the blurred rim of something brighter than
/// the lumen, a cavity next to a faint distal vessel, bone or calcium, whose
/// values fall in the interval on their way down.
///
/// A voxel of the interval at the bottom of a dip between two brighter ones
/// is a valley: the fat between two vessels that touch (a vessel that turns
/// back on itself, an artery beside its vein), which the scanner's blur and
/// the search's mean over a millimetre lift into the interval. Along one of
/// the thirteen axes, with means over the three by three voxels across that
/// axis, the brightest within 0.8 mm on each side (the dip's floor may span
/// two voxels) is higher than the voxel by a sixth of the lumen's contrast
/// and eight times the noise of the search's means, whichever is more, and
/// reaches the interval, while the voxel lies that much below the lumen's
/// value: the axis and the edge of a single vessel never dip so, nor does
/// noise in its lumen, nor the fat between a vessel and the myocardium it
/// lies on. A valley costs a step just out of the lumen, so two vessels
/// that touch stay two. It is looked for on the input's own grid, not on
/// blocks, where the vessel is wide enough for a millimetre of fat to show.
///
/// Scratch memory comes by bricks of 8 × 8 × 8 search voxels as the search
/// reaches them, so a trace along a coronary touches a few megabytes, not the
/// volume.
final class VesselCostField {
    /// Kept for the floats it holds alive; the hot paths read `voxels`.
    let volume: VesselVolume
    private let voxels: UnsafePointer<Float>
    private let width: Int, height: Int, depth: Int
    private let spacingX: Double, spacingY: Double, spacingZ: Double

    /// Input voxels per search voxel along each axis.
    let stepX: Int, stepY: Int, stepZ: Int
    /// The search grid's size.
    let sizeX: Int, sizeY: Int, sizeZ: Int
    /// Each search voxel's centre in millimetres along each axis.
    let centresX: UnsafeMutablePointer<Double>, centresY: UnsafeMutablePointer<Double>,
        centresZ: UnsafeMutablePointer<Double>
    /// A search voxel's size in millimetres.
    let gridX: Double, gridY: Double, gridZ: Double

    /// The radius the cost saturates at, millimetres.
    let capRadius: Double
    let exponent: Double
    /// The cost per millimetre of a step just out of the lumen.
    let outsideCost: Double
    /// The cost per millimetre of a step through a wide structure, or far out of the lumen.
    let fullOutsideCost: Double

    /// The 26 neighbours of a search voxel: offsets, three per neighbour, and step lengths in millimetres.
    let neighbourOffsets: UnsafeMutablePointer<Int>
    let neighbourLength: UnsafeMutablePointer<Double>

    /// How many input voxels the mean of a search voxel's value reaches past its block, per axis.
    private let extendX: Int, extendY: Int, extendZ: Int
    private let lower: Float, upper: Float, gradeScale: Float
    /// The rise, per millimetre, of the blurred edge of something brighter than
    /// the interval, and the fall a step up such an edge may show for its noise.
    private let edgeSlope: Float, edgeFall: Float
    /// Spheres round the ends marked in a wide structure, in which it counts
    /// as lumen: centres in millimetres and squared radii, two at most.
    private var exemptCount = 0
    private var exemptX = (0.0, 0.0), exemptY = (0.0, 0.0), exemptZ = (0.0, 0.0), exemptRadius2 = (0.0, 0.0)
    /// The grid offsets within the cap radius, nearest first: three per offset, and their distances.
    private let ringCount: Int
    private let ringOffsets: UnsafeMutablePointer<Int>
    private let ringDistance: UnsafeMutablePointer<Double>
    /// The offsets within three quarters of a millimetre, at least one voxel.
    private let rimCount: Int
    private let rimOffsets: UnsafeMutablePointer<Int>
    /// The thirteen axes through a voxel: offsets of one step, and the steps a long chord takes.
    private let axisOffsets: UnsafeMutablePointer<Int>
    private let axisSteps: UnsafeMutablePointer<Int>
    /// The valley test, on the input's own grid only: for each of the thirteen
    /// axes the nine offsets of the patch across it (input indices), how far
    /// the patch reaches along x, y and z, and the steps along the axis to
    /// look at on each side; the least rise on both sides that makes a dip a
    /// valley, and the patch mean above which a voxel is no dip at all (that
    /// rise below the lumen's value).
    private let checksValleys: Bool
    private let valleyPatch: UnsafeMutablePointer<Int>
    private let valleyReach: UnsafeMutablePointer<Int>
    private let valleySteps: UnsafeMutablePointer<Int>
    private let valleyRise: Float
    private let valleyCeiling: Float

    // Bricks of 8 × 8 × 8 search voxels: the tables map a brick to its first slot, -1 before.
    private let bricksX: Int, bricksY: Int
    private let codeTable: UnsafeMutablePointer<Int32>
    private var codePool = VesselStorage<UInt8>(capacity: 4096)
    /// Beside each code, what the line through the voxel along each of the
    /// thirteen axes was found to be, two bits per axis: 0 not known, 1 short,
    /// 2 long. Every voxel of a line shares its length, so one march settles
    /// all of them.
    private var linePool = VesselStorage<UInt32>(capacity: 4096)
    private let costTable: UnsafeMutablePointer<Int32>
    private var costPool = VesselStorage<Float>(capacity: 4096)

    static let unknown: UInt8 = 0
    /// In the lumen's interval, its shape not yet known.
    static let inInterval: UInt8 = 1
    static let lumen: UInt8 = 2
    static let wide: UInt8 = 3
    /// In the interval, at the bottom of a dip between two brighter voxels.
    static let valley: UInt8 = 4
    /// 5 just below the interval to 129 far below it.
    static let firstBelow: UInt8 = 5
    /// 130 just above the interval to 254 far above it.
    static let firstAbove: UInt8 = 130
    private static let grades: Float = 124

    /// Lines through a voxel that make it wide when they are long.
    private static let longLinesOfWide = 5

    init(volume: VesselVolume, lumen: VesselLumen, options: VesselTraceOptions) {
        self.volume = volume
        voxels = volume.voxels
        width = volume.width
        height = volume.height
        depth = volume.depth
        spacingX = Double(volume.spacing.x)
        spacingY = Double(volume.spacing.y)
        spacingZ = Double(volume.spacing.z)
        let floor = 2 * max(spacingX, spacingY, spacingZ)
        let known = [lumen.radiusA, lumen.radiusB].compactMap { $0 }
        let narrow = known.min() ?? floor, wide = known.max() ?? floor
        // Six search voxels in the narrower end's radius, never finer than the input.
        func step(_ size: Double) -> Int { max(1, Int((narrow / 6 / size).rounded(.down))) }
        stepX = step(spacingX)
        stepY = step(spacingY)
        stepZ = step(spacingZ)
        sizeX = (width + stepX - 1) / stepX
        sizeY = (height + stepY - 1) / stepY
        sizeZ = (depth + stepZ - 1) / stepZ
        func centres(_ count: Int, _ step: Int, _ voxels: Int, _ size: Double) -> UnsafeMutablePointer<Double> {
            let result = UnsafeMutablePointer<Double>.allocate(capacity: count)
            for n in 0..<count { result[n] = Double(n * step + min((n + 1) * step, voxels) - 1) / 2 * size }
            return result
        }
        centresX = centres(sizeX, stepX, width, spacingX)
        centresY = centres(sizeY, stepY, height, spacingY)
        centresZ = centres(sizeZ, stepZ, depth, spacingZ)
        gridX = Double(stepX) * spacingX
        gridY = Double(stepY) * spacingY
        gridZ = Double(stepZ) * spacingZ
        // The mean spans about a millimetre on the input's own grid, a block
        // and half a block on each side on a coarser one: centred on the
        // search voxel's centre either way, and never three slices of a
        // millimetre or more, which would blur the lumen's border along z.
        func extend(_ size: Double, _ step: Int) -> Int { max(Int((0.45 / size).rounded()), step / 2) }
        extendX = extend(spacingX, stepX)
        extendY = extend(spacingY, stepY)
        extendZ = extend(spacingZ, stepZ)
        lower = lumen.lower
        upper = lumen.upper
        gradeScale = max(lumen.halfContrast / 2, 1e-3)
        edgeSlope = gradeScale
        edgeFall = lumen.noise
        exponent = options.centringExponent

        let coarsest = max(gridX, gridY, gridZ), finest = min(gridX, gridY, gridZ)
        // The radius the cost saturates at: the wider end's, but at most
        // twice the narrower's, so that the aorta at one end is no cheaper
        // to walk than the axis of the vessel.
        capRadius = min(max(min(wide, 2 * narrow), 2 * coarsest), 25)
        outsideCost = 100 * pow(capRadius / finest, exponent)
        fullOutsideCost = 5 * outsideCost
        // The widest the vessel itself may be: the wider end, unless it lies
        // in a much wider structure (the aorta at an ostium), then three
        // times the narrower end, which a coronary does not exceed between
        // its ostium and a distal point.
        let chordLength = 6 * max(min(wide, 3 * narrow), capRadius)
        let gx = gridX, gy = gridY, gz = gridZ
        func length(_ dx: Int, _ dy: Int, _ dz: Int) -> Double {
            let mx = Double(dx) * gx, my = Double(dy) * gy, mz = Double(dz) * gz
            return (mx * mx + my * my + mz * mz).squareRoot()
        }

        var rings: [(Int, Int, Int, Double)] = []
        let reachX = Int((capRadius / gridX).rounded(.up)), reachY = Int((capRadius / gridY).rounded(.up))
        let reachZ = Int((capRadius / gridZ).rounded(.up))
        for dz in -reachZ...reachZ { for dy in -reachY...reachY { for dx in -reachX...reachX where dx != 0 || dy != 0 || dz != 0 {
            let d = length(dx, dy, dz)
            if d <= capRadius { rings.append((dx, dy, dz, d)) }
        } } }
        rings.sort { $0.3 < $1.3 }
        ringCount = rings.count
        ringOffsets = .allocate(capacity: 3 * max(rings.count, 1))
        ringDistance = .allocate(capacity: max(rings.count, 1))
        for (n, ring) in rings.enumerated() {
            ringOffsets[3 * n] = ring.0
            ringOffsets[3 * n + 1] = ring.1
            ringOffsets[3 * n + 2] = ring.2
            ringDistance[n] = ring.3
        }

        var rims: [Int] = []
        let rim = max(0.75, finest) * 1.0001
        for dz in -2...2 { for dy in -2...2 { for dx in -2...2 where (dx != 0 || dy != 0 || dz != 0) && length(dx, dy, dz) <= rim {
            rims += [dx, dy, dz]
        } } }
        rimCount = rims.count / 3
        rimOffsets = .allocate(capacity: max(rims.count, 1))
        for (n, offset) in rims.enumerated() { rimOffsets[n] = offset }

        axisOffsets = .allocate(capacity: 39)
        axisSteps = .allocate(capacity: 13)
        neighbourOffsets = .allocate(capacity: 78)
        neighbourLength = .allocate(capacity: 26)
        var axis = 0, neighbour = 0
        for dz in -1...1 { for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 || dz != 0 {
            neighbourOffsets[3 * neighbour] = dx
            neighbourOffsets[3 * neighbour + 1] = dy
            neighbourOffsets[3 * neighbour + 2] = dz
            neighbourLength[neighbour] = length(dx, dy, dz)
            neighbour += 1
            guard dz > 0 || (dz == 0 && (dy > 0 || (dy == 0 && dx > 0))) else { continue }
            axisOffsets[3 * axis] = dx
            axisOffsets[3 * axis + 1] = dy
            axisOffsets[3 * axis + 2] = dz
            // A chord of n voxels besides the centre is (n + 1) steps long.
            axisSteps[axis] = max(Int((chordLength / length(dx, dy, dz)).rounded(.up)) - 1, 1)
            axis += 1
        } } }

        checksValleys = stepX == 1 && stepY == 1 && stepZ == 1
        valleyRise = max(lumen.halfContrast / 3, 8 * lumen.noise)
        valleyCeiling = lumen.peak - valleyRise
        valleyPatch = .allocate(capacity: 13 * 9)
        valleyReach = .allocate(capacity: 13 * 3)
        valleySteps = .allocate(capacity: 13)
        // Across each axis, the two shortest neighbour offsets square to it
        // (in voxels) that are not parallel: the patch's sides.
        var neighbours: [(Int, Int, Int)] = []
        for dz in -1...1 { for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 || dz != 0 { neighbours.append((dx, dy, dz)) } } }
        neighbours.sort { length($0.0, $0.1, $0.2) < length($1.0, $1.1, $1.2) }
        let rowLength = width, sliceLength = width * height
        for n in 0..<13 {
            let a = (axisOffsets[3 * n], axisOffsets[3 * n + 1], axisOffsets[3 * n + 2])
            let across = neighbours.filter { $0.0 * a.0 + $0.1 * a.1 + $0.2 * a.2 == 0 }
            let u = across[0]
            let v = across.first { c in
                c.1 * u.2 - c.2 * u.1 != 0 || c.2 * u.0 - c.0 * u.2 != 0 || c.0 * u.1 - c.1 * u.0 != 0
            } ?? across[1]
            var k = 9 * n
            for i in -1...1 { for j in -1...1 {
                valleyPatch[k] = (i * u.2 + j * v.2) * sliceLength + (i * u.1 + j * v.1) * rowLength + (i * u.0 + j * v.0)
                k += 1
            } }
            valleyReach[3 * n] = abs(u.0) + abs(v.0)
            valleyReach[3 * n + 1] = abs(u.1) + abs(v.1)
            valleyReach[3 * n + 2] = abs(u.2) + abs(v.2)
            valleySteps[n] = max(1, Int((0.8 / length(a.0, a.1, a.2)).rounded(.up)))
        }

        bricksX = (sizeX + 7) / 8
        bricksY = (sizeY + 7) / 8
        let bricks = bricksX * bricksY * ((sizeZ + 7) / 8)
        codeTable = .allocate(capacity: bricks)
        codeTable.initialize(repeating: -1, count: bricks)
        costTable = .allocate(capacity: bricks)
        costTable.initialize(repeating: -1, count: bricks)
    }

    deinit {
        for pointer in [centresX, centresY, centresZ, ringDistance, neighbourLength] { pointer.deallocate() }
        for pointer in [ringOffsets, rimOffsets, axisOffsets, axisSteps, neighbourOffsets] { pointer.deallocate() }
        for pointer in [valleyPatch, valleyReach, valleySteps] { pointer.deallocate() }
        codeTable.deallocate()
        costTable.deallocate()
        codePool.release()
        linePool.release()
        costPool.release()
    }

    // MARK: - Grid

    func index(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * sizeY + y) * sizeX + x }

    func coordinates(_ index: Int) -> (Int, Int, Int) {
        let x = index % sizeX, rest = index / sizeX
        return (x, rest % sizeY, rest / sizeY)
    }

    func contains(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        x >= 0 && x < sizeX && y >= 0 && y < sizeY && z >= 0 && z < sizeZ
    }

    /// The search voxel that holds a point in input coordinates.
    func gridVoxel(_ p: SIMD3<Float>) -> (Int, Int, Int) {
        (min(max(Int(p.x.rounded()), 0), width - 1) / stepX,
         min(max(Int(p.y.rounded()), 0), height - 1) / stepY,
         min(max(Int(p.z.rounded()), 0), depth - 1) / stepZ)
    }

    /// The search voxel whose centre is nearest to a point in millimetres.
    func gridVoxel(millimetres x: Double, _ y: Double, _ z: Double) -> (Int, Int, Int) {
        func along(_ v: Double, _ size: Double, _ step: Int, _ count: Int) -> Int {
            min(max(Int(((v / size - Double(step - 1) / 2) / Double(step)).rounded()), 0), count - 1)
        }
        return (along(x, spacingX, stepX, sizeX), along(y, spacingY, stepY, sizeY), along(z, spacingZ, stepZ, sizeZ))
    }

    /// The distance in millimetres from a search voxel's centre to a point in millimetres.
    func distance(_ x: Int, _ y: Int, _ z: Int, to px: Double, _ py: Double, _ pz: Double) -> Double {
        let dx = centresX[x] - px, dy = centresY[y] - py, dz = centresZ[z] - pz
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }

    private func brick(_ x: Int, _ y: Int, _ z: Int) -> Int {
        ((z >> 3) * bricksY + (y >> 3)) * bricksX + (x >> 3)
    }

    private func local(_ x: Int, _ y: Int, _ z: Int) -> Int { ((z & 7) << 6) | ((y & 7) << 3) | (x & 7) }

    // MARK: - Kinds

    /// The ends marked in a wide structure: around each, that structure is
    /// lumen as far as its radius and twice the cap radius.
    func exempt(around ends: [(centre: SIMD3<Float>, radius: Double)]) {
        for end in ends.prefix(2) {
            let (x, y, z) = gridVoxel(end.centre)
            guard isInInterval(code(x, y, z)) && chordShape(x, y, z) == Self.wide else { continue }
            let radius = end.radius + 2 * capRadius
            if exemptCount == 0 {
                exemptX.0 = centresX[x]
                exemptY.0 = centresY[y]
                exemptZ.0 = centresZ[z]
                exemptRadius2.0 = radius * radius
            } else {
                exemptX.1 = centresX[x]
                exemptY.1 = centresY[y]
                exemptZ.1 = centresZ[z]
                exemptRadius2.1 = radius * radius
            }
            exemptCount += 1
        }
    }

    func isInInterval(_ code: UInt8) -> Bool { code >= Self.inInterval && code <= Self.valley }

    /// The value class of a search voxel: in the interval (its shape unknown)
    /// or out of it by how far, without its shape.
    func code(_ x: Int, _ y: Int, _ z: Int) -> UInt8 {
        let brick = brick(x, y, z)
        var base = codeTable[brick]
        if base < 0 {
            base = Int32(codePool.count)
            codeTable[brick] = base
            codePool.append(Self.unknown, count: 512)
            linePool.append(0, count: 512)
        }
        let slot = codePool.base + (Int(base) + local(x, y, z))
        let known = slot.pointee
        if known != Self.unknown { return known }
        let value = boxMean(x, y, z)
        var code = Self.inInterval
        if value < lower {
            code = Self.firstBelow + UInt8(min(max((lower - value) / gradeScale, 0), 1) * Self.grades)
        } else if value > upper {
            code = Self.firstAbove + UInt8(min(max((value - upper) / gradeScale, 0), 1) * Self.grades)
        }
        slot.pointee = code
        return code
    }

    /// The kind of a search voxel: lumen, wide, a valley, or out of the interval by how far.
    func kind(_ x: Int, _ y: Int, _ z: Int) -> UInt8 {
        let code = code(x, y, z)
        if code != Self.inInterval { return code }
        var shape = isRim(x, y, z) ? Self.wide : isExempt(x, y, z) ? Self.lumen : chordShape(x, y, z)
        if shape == Self.lumen && isValley(x, y, z) { shape = Self.valley }
        codePool.base[Int(codeTable[brick(x, y, z)]) + local(x, y, z)] = shape
        return shape
    }

    /// Whether a voxel lies at the bottom of a dip between two brighter ones
    /// along one of the thirteen axes (the fat between two vessels that touch).
    private func isValley(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        // The voxel alone, noisier than a patch, first: most of the lumen is no dip.
        guard checksValleys && voxels[(z * height + y) * width + x] <= valleyCeiling + valleyRise / 2 else { return false }
        var n = 0
        while n < 13 {
            defer { n += 1 }
            guard let centre = patchMean(x, y, z, across: n), centre <= valleyCeiling else { continue }
            let dx = axisOffsets[3 * n], dy = axisOffsets[3 * n + 1], dz = axisOffsets[3 * n + 2]
            let ahead = brightest(x, y, z, dx, dy, dz, across: n)
            guard ahead - centre >= valleyRise && ahead >= lower else { continue }
            let behind = brightest(x, y, z, -dx, -dy, -dz, across: n)
            if behind - centre >= valleyRise && behind >= lower { return true }
        }
        return false
    }

    /// The brightest patch mean across axis `n` within 0.8 mm of a voxel on
    /// one side, a step of (dx, dy, dz) at a time: the dip's floor may span
    /// two voxels, the voxel tested being either.
    private func brightest(_ x: Int, _ y: Int, _ z: Int, _ dx: Int, _ dy: Int, _ dz: Int, across n: Int) -> Float {
        var result = -Float.greatestFiniteMagnitude
        var d = 1
        while d <= valleySteps[n] {
            if let mean = patchMean(x + d * dx, y + d * dy, z + d * dz, across: n) { result = max(result, mean) }
            d += 1
        }
        return result
    }

    /// The mean of the nine input voxels of the patch across axis `n` round an
    /// input voxel; nil when the patch leaves the volume.
    private func patchMean(_ x: Int, _ y: Int, _ z: Int, across n: Int) -> Float? {
        let rx = valleyReach[3 * n], ry = valleyReach[3 * n + 1], rz = valleyReach[3 * n + 2]
        guard x - rx >= 0 && x + rx < width && y - ry >= 0 && y + ry < height && z - rz >= 0 && z + rz < depth else {
            return nil
        }
        let centre = voxels + ((z * height + y) * width + x)
        var sum: Float = 0
        var k = 9 * n
        while k < 9 * n + 9 {
            sum += centre[valleyPatch[k]]
            k += 1
        }
        return sum / 9
    }

    /// Whether a voxel above the interval lies within the rim's reach, or the
    /// voxel stands on the blurred edge of one.
    private func isRim(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        var n = 0
        while n < rimCount {
            let qx = x + rimOffsets[3 * n], qy = y + rimOffsets[3 * n + 1], qz = z + rimOffsets[3 * n + 2]
            if contains(qx, qy, qz) && code(qx, qy, qz) >= Self.firstAbove { return true }
            n += 1
        }
        return isOnBlurredEdge(x, y, z)
    }

    /// Whether the values rise from a voxel, step after step along one of the
    /// 26 directions, up to a voxel above the interval, at the slope of an
    /// edge. The scanner's blur spreads the edge of a bright cavity over more
    /// than the rim's reach: its values run down through the whole interval,
    /// a shell of "lumen" round the cavity that a path through an occlusion
    /// followed instead of the plaque. The further below the interval's top
    /// the voxel is, the further the edge may reach (the rise, per
    /// millimetre, at least a quarter of the lumen's contrast: the top of an
    /// edge is its flat tail, and a cavity hardly above the interval is
    /// reached through it), 2.5 mm at most; a
    /// step that falls by more than the noise, or leaves the interval
    /// downwards, is a wall between, not the edge.
    private func isOnBlurredEdge(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        let start = boxMean(x, y, z)
        let reach = Double(min((upper - start) / edgeSlope, 2.5))
        var n = 0
        while n < 26 {
            defer { n += 1 }
            let dx = neighbourOffsets[3 * n], dy = neighbourOffsets[3 * n + 1], dz = neighbourOffsets[3 * n + 2]
            let length = neighbourLength[n]
            var previous = start
            var k = 1
            while Double(k) * length <= reach {
                let qx = x + k * dx, qy = y + k * dy, qz = z + k * dz
                guard contains(qx, qy, qz) else { break }
                let code = code(qx, qy, qz)
                if code >= Self.firstAbove { return true }
                guard isInInterval(code) else { break }
                let value = boxMean(qx, qy, qz)
                if value < previous - edgeFall { break }
                previous = max(previous, value)
                k += 1
            }
        }
        return false
    }

    private func isExempt(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        if exemptCount == 0 { return false }
        let px = centresX[x], py = centresY[y], pz = centresZ[z]
        var dx = px - exemptX.0, dy = py - exemptY.0, dz = pz - exemptZ.0
        if dx * dx + dy * dy + dz * dz <= exemptRadius2.0 { return true }
        if exemptCount == 1 { return false }
        dx = px - exemptX.1
        dy = py - exemptY.1
        dz = pz - exemptZ.1
        return dx * dx + dy * dy + dz * dz <= exemptRadius2.1
    }

    /// Wide or lumen, by the lines through the voxel that stay in the interval.
    private func chordShape(_ x: Int, _ y: Int, _ z: Int) -> UInt8 {
        var long = 0, short = 0
        let mostShort = 13 - Self.longLinesOfWide
        var axis = -1
        while axis < 12 {
            axis += 1
            if isLongLine(x, y, z, axis: axis) {
                long += 1
                if long >= Self.longLinesOfWide { return Self.wide }
            } else {
                short += 1
                if short > mostShort { return Self.lumen }
            }
        }
        return long >= Self.longLinesOfWide ? Self.wide : Self.lumen
    }

    /// The slot of a voxel whose code is known.
    private func slot(_ x: Int, _ y: Int, _ z: Int) -> Int { Int(codeTable[brick(x, y, z)]) + local(x, y, z) }

    /// Whether the line through an in-interval voxel along an axis stays in
    /// the interval for the chord length. A march settles the whole line: the
    /// voxels it crossed lie on the same run of the interval, as long as the
    /// chord or more when the march reached the chord length, all shorter
    /// when it ended at both sides first.
    private func isLongLine(_ x: Int, _ y: Int, _ z: Int, axis: Int) -> Bool {
        let shift = UInt32(2 * axis)
        let known = (linePool.base[slot(x, y, z)] >> shift) & 3
        if known != 0 { return known == 2 }
        let dx = axisOffsets[3 * axis], dy = axisOffsets[3 * axis + 1], dz = axisOffsets[3 * axis + 2]
        let needed = axisSteps[axis]
        var ahead = 0, behind = 0
        var qx = x + dx, qy = y + dy, qz = z + dz
        while ahead < needed && contains(qx, qy, qz) && isInInterval(code(qx, qy, qz)) {
            ahead += 1
            qx += dx
            qy += dy
            qz += dz
        }
        qx = x - dx
        qy = y - dy
        qz = z - dz
        while ahead + behind < needed && contains(qx, qy, qz) && isInInterval(code(qx, qy, qz)) {
            behind += 1
            qx -= dx
            qy -= dy
            qz -= dz
        }
        let long = ahead + behind >= needed
        let mark = UInt32(long ? 2 : 1) << shift
        let lines = linePool.base
        var k = -behind
        while k <= ahead {
            lines[slot(x + k * dx, y + k * dy, z + k * dz)] |= mark
            k += 1
        }
        return long
    }

    /// The mean of the input voxels round a search voxel's centre.
    private func boxMean(_ x: Int, _ y: Int, _ z: Int) -> Float {
        let x0 = max(x * stepX - extendX, 0), x1 = min(x * stepX + stepX - 1 + extendX, width - 1)
        let y0 = max(y * stepY - extendY, 0), y1 = min(y * stepY + stepY - 1 + extendY, height - 1)
        let z0 = max(z * stepZ - extendZ, 0), z1 = min(z * stepZ + stepZ - 1 + extendZ, depth - 1)
        var sum: Float = 0
        var k = z0
        while k <= z1 {
            var j = y0
            while j <= y1 {
                let row = voxels + (k * height + j) * width
                var i = x0
                while i <= x1 {
                    sum += row[i]
                    i += 1
                }
                j += 1
            }
            k += 1
        }
        return sum / Float((x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1))
    }

    // MARK: - Cost

    /// The distance in millimetres from a lumen voxel to the nearest voxel
    /// that is not lumen, or out of the grid; the cap radius at most. Every
    /// voxel nearer than `atLeast` is known to be lumen (it lies within the
    /// border distance of a neighbour), and the scan starts past them.
    private func borderDistance(_ x: Int, _ y: Int, _ z: Int, atLeast: Double) -> Double {
        var low = 0, high = ringCount
        while low < high {
            let middle = (low + high) / 2
            if ringDistance[middle] < atLeast { low = middle + 1 } else { high = middle }
        }
        var ring = low
        while ring < ringCount {
            let qx = x + ringOffsets[3 * ring], qy = y + ringOffsets[3 * ring + 1], qz = z + ringOffsets[3 * ring + 2]
            if !contains(qx, qy, qz) || kind(qx, qy, qz) != Self.lumen { return ringDistance[ring] }
            ring += 1
        }
        return capRadius
    }

    /// The cost per millimetre of a step in a search voxel. `nearLumen` is
    /// a lower bound of its distance to the border when a neighbour's is
    /// known: that neighbour's border distance less the step between them.
    func cost(_ x: Int, _ y: Int, _ z: Int, nearLumen: Double = 0) -> Double {
        let brick = brick(x, y, z)
        var base = costTable[brick]
        if base < 0 {
            base = Int32(costPool.count)
            costTable[brick] = base
            costPool.append(-1, count: 512)
        }
        let slot = costPool.base + (Int(base) + local(x, y, z))
        let known = slot.pointee
        if known >= 0 { return Double(known) }
        let kind = kind(x, y, z)
        let cost: Double
        if kind == Self.lumen {
            cost = pow(capRadius / borderDistance(x, y, z, atLeast: nearLumen - 1e-9), exponent)
        } else if kind == Self.wide {
            cost = fullOutsideCost
        } else if kind == Self.valley {
            cost = outsideCost
        } else {
            let grade = kind >= Self.firstAbove ? kind - Self.firstAbove : kind - Self.firstBelow
            cost = outsideCost * (1 + 4 * Double(grade) / Double(Self.grades))
        }
        slot.pointee = Float(cost)
        return cost
    }

    /// The radius in millimetres a step cost stands for: 0 out of the lumen.
    func radius(forCost cost: Double) -> Double {
        cost >= outsideCost ? 0 : capRadius / pow(cost, 1 / exponent)
    }
}
