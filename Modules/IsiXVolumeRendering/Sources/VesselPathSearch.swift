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

/// The search's queue: a binary heap on the estimated total cost, the
/// deeper of equal estimates first (fewer voxels opened on a plateau).
final class VesselSearchQueue {
    struct Entry {
        var estimate: Double
        var g: Double
        var index: Int
    }

    private var entries = VesselStorage<Entry>(capacity: 4096)
    private var count = 0

    var isEmpty: Bool { count == 0 }

    deinit { entries.release() }

    private static func before(_ a: Entry, _ b: Entry) -> Bool {
        a.estimate < b.estimate || (a.estimate == b.estimate && a.g > b.g)
    }

    func push(_ entry: Entry) {
        if count == entries.count { entries.append(entry, count: 1) }
        let heap = entries.base
        var child = count
        count += 1
        while child > 0 {
            let parent = (child - 1) / 2
            if !Self.before(entry, heap[parent]) { break }
            heap[child] = heap[parent]
            child = parent
        }
        heap[child] = entry
    }

    func pop() -> Entry {
        let heap = entries.base
        let top = heap[0]
        count -= 1
        let last = heap[count]
        var parent = 0
        while true {
            let left = 2 * parent + 1
            if left >= count { break }
            var child = left
            if left + 1 < count && Self.before(heap[left + 1], heap[left]) { child = left + 1 }
            if !Self.before(heap[child], last) { break }
            heap[parent] = heap[child]
            parent = child
        }
        if count > 0 { heap[parent] = last }
        return top
    }
}

/// What one search keeps of the voxels it reached, by bricks of 8 × 8 × 8
/// as it reaches them: the cost of the cheapest path from its root, the
/// neighbour step (0 to 25) that reached each voxel (255 for none), and
/// whether it closed.
final class VesselSearchTree {
    private let bricksX: Int, bricksY: Int
    private let table: UnsafeMutablePointer<Int32>
    private var costs = VesselStorage<Double>(capacity: 4096)
    private var parents = VesselStorage<UInt8>(capacity: 4096)
    private var closedFlags = VesselStorage<Bool>(capacity: 4096)
    /// The grid indices of the closed voxels, in the order they closed.
    private(set) var closedIndices = VesselStorage<Int>(capacity: 4096)

    init(field: VesselCostField) {
        bricksX = (field.sizeX + 7) / 8
        bricksY = (field.sizeY + 7) / 8
        let bricks = bricksX * bricksY * ((field.sizeZ + 7) / 8)
        table = .allocate(capacity: bricks)
        table.initialize(repeating: -1, count: bricks)
    }

    deinit {
        table.deallocate()
        costs.release()
        parents.release()
        closedFlags.release()
        closedIndices.release()
    }

    func slot(_ x: Int, _ y: Int, _ z: Int) -> Int {
        let brick = ((z >> 3) * bricksY + (y >> 3)) * bricksX + (x >> 3)
        var base = table[brick]
        if base < 0 {
            base = Int32(costs.count)
            table[brick] = base
            costs.append(.infinity, count: 512)
            parents.append(255, count: 512)
            closedFlags.append(false, count: 512)
        }
        return Int(base) + (((z & 7) << 6) | ((y & 7) << 3) | (x & 7))
    }

    func g(_ slot: Int) -> Double { costs.base[slot] }
    func parent(_ slot: Int) -> UInt8 { parents.base[slot] }
    func isClosed(_ slot: Int) -> Bool { closedFlags.base[slot] }

    func reach(_ slot: Int, g: Double, parent: UInt8) {
        costs.base[slot] = g
        parents.base[slot] = parent
    }

    func close(_ slot: Int, index: Int) {
        closedFlags.base[slot] = true
        closedIndices.append(index, count: 1)
    }
}

/// The shortest path between the two ends over the search grid, A* with the
/// straight-line distance in millimetres as its heuristic: every step costs
/// at least its length, so the heuristic never overestimates and a voxel
/// closes once.
///
/// The search gives up past a budget of a few millimetres out of the lumen:
/// a longer gap is an occlusion, or two ends that lie on different vessels,
/// and finding its cheapest crossing by A* would open every voxel within the
/// gap's length of the lumen reached. It also gives up after closing a set
/// number of voxels, a hundred times what a coronary segment takes, which
/// only ends marked far from any vessel reach. Instead a second search runs
/// from the other end within the same limits, and the two are joined across
/// the gap, between the voxels of each that make the cheapest whole: the
/// time stays that of the two limits whatever the gap. When the path found
/// leaves the lumen and the region round the two ends cut a promising part
/// of it, a search kept to the lumen in a region twice as large looks for a
/// way round (a vessel that turns back on itself between two close points).
/// Last, each stretch of the path out of the lumen becomes a curve that
/// carries on the lumen's axis from both sides (`bridgingGaps`).
final class VesselPathSearch {
    private let field: VesselCostField
    private let lumen: VesselLumen
    private let options: VesselTraceOptions
    private let a: SIMD3<Float>
    private let b: SIMD3<Float>
    /// The ellipsoid the search keeps to: foci at the ends, in millimetres.
    private let focusA: SIMD3<Double>, focusB: SIMD3<Double>
    private let reach: Double
    /// The largest cost a search goes to before the ends are joined across a gap.
    private let budget: Double
    /// The voxels the searches closed, all together.
    private var closed = 0

    init(volume: VesselVolume, lumen: VesselLumen, options: VesselTraceOptions, a: SIMD3<Float>, b: SIMD3<Float>) {
        field = VesselCostField(volume: volume, lumen: lumen, options: options)
        var ends: [(centre: SIMD3<Float>, radius: Double)] = []
        if let radius = lumen.radiusA { ends.append((lumen.centreA, radius)) }
        if let radius = lumen.radiusB { ends.append((lumen.centreB, radius)) }
        field.exempt(around: ends)
        self.lumen = lumen
        self.options = options
        self.a = a
        self.b = b
        let spacing = SIMD3(Double(volume.spacing.x), Double(volume.spacing.y), Double(volume.spacing.z))
        focusA = SIMD3(Double(lumen.centreA.x), Double(lumen.centreA.y), Double(lumen.centreA.z)) * spacing
        focusB = SIMD3(Double(lumen.centreB.x), Double(lumen.centreB.y), Double(lumen.centreB.z)) * spacing
        reach = options.detour * VesselMath.length(focusA - focusB) + 2 * options.marginMillimetres
        // The gap budget at the full outside cost, and as much again as the
        // dearest steps in the lumen along the whole region could cost.
        let gap = max(options.gapBudgetMillimetres, 2 * max(field.gridX, field.gridY, field.gridZ))
        budget = field.fullOutsideCost * gap + field.outsideCost / 100 * reach
    }

    // MARK: - Search

    private struct Outcome {
        var found = false
        var cost = Double.infinity
        /// The least estimate of a voxel in the interval the region cut off.
        var promise = Double.infinity
    }

    /// A* from `start` to `goal` within an ellipsoid round the ends `reach`
    /// millimetres across, to costs of `bound` at most; with `lumenOnly`,
    /// over lumen voxels only. `report` hears the share of the way covered.
    private func search(_ tree: VesselSearchTree, from start: (Int, Int, Int), to goal: (Int, Int, Int),
                        reach: Double, bound: Double, lumenOnly: Bool,
                        report: (Double) -> Void, isCancelled: () -> Bool) throws(VesselTraceError) -> Outcome {
        let field = field
        let goalIndex = field.index(goal.0, goal.1, goal.2)
        let tx = field.centresX[goal.0], ty = field.centresY[goal.1], tz = field.centresZ[goal.2]
        let ax = focusA.x, ay = focusA.y, az = focusA.z, bx = focusB.x, by = focusB.y, bz = focusB.z
        let offsets = field.neighbourOffsets, lengths = field.neighbourLength
        let limit = options.searchedVoxelLimit
        let startSlot = tree.slot(start.0, start.1, start.2)
        tree.reach(startSlot, g: 0, parent: 255)
        let startHeuristic = field.distance(start.0, start.1, start.2, to: tx, ty, tz)
        let queue = VesselSearchQueue()
        queue.push(.init(estimate: startHeuristic, g: 0, index: field.index(start.0, start.1, start.2)))
        var outcome = Outcome()
        var nearest = startHeuristic
        var pops = 0

        while !queue.isEmpty {
            let entry = queue.pop()
            if entry.estimate > bound || tree.closedIndices.count >= limit { break }
            let (x, y, z) = field.coordinates(entry.index)
            let slot = tree.slot(x, y, z)
            if tree.isClosed(slot) || entry.g > tree.g(slot) { continue }
            tree.close(slot, index: entry.index)
            closed += 1
            if entry.index == goalIndex {
                outcome.found = true
                outcome.cost = entry.g
                break
            }
            pops += 1
            if pops & 1023 == 0 {
                if isCancelled() { throw .cancelled }
                if startHeuristic > 0 { report(1 - nearest / startHeuristic) }
            }
            nearest = min(nearest, entry.estimate - entry.g)
            let g = entry.g
            let here = field.cost(x, y, z)
            let hereRadius = field.radius(forCost: here)
            var step = -1
            while step < 25 {
                step += 1
                let nx = x + offsets[3 * step], ny = y + offsets[3 * step + 1], nz = z + offsets[3 * step + 2]
                if !field.contains(nx, ny, nz) { continue }
                let next = tree.slot(nx, ny, nz)
                if tree.isClosed(next) { continue }
                let length = lengths[step]
                if tree.g(next) == .infinity
                    && field.distance(nx, ny, nz, to: ax, ay, az) + field.distance(nx, ny, nz, to: bx, by, bz) > reach {
                    if field.isInInterval(field.code(nx, ny, nz)) {
                        outcome.promise = min(outcome.promise, g + length + field.distance(nx, ny, nz, to: tx, ty, tz))
                    }
                    continue
                }
                if lumenOnly && field.kind(nx, ny, nz) != VesselCostField.lumen
                    && field.index(nx, ny, nz) != goalIndex { continue }
                let total = g + 0.5 * (here + field.cost(nx, ny, nz, nearLumen: hereRadius - length)) * length
                if total < tree.g(next) {
                    tree.reach(next, g: total, parent: UInt8(step))
                    queue.push(.init(estimate: total + field.distance(nx, ny, nz, to: tx, ty, tz), g: total,
                                     index: field.index(nx, ny, nz)))
                }
            }
        }
        return outcome
    }

    /// The voxels from `index` back to the root of `tree`, by the steps that reached them.
    private func chain(_ tree: VesselSearchTree, from index: Int) -> [(Int, Int, Int)] {
        var (x, y, z) = field.coordinates(index)
        var voxels = [(x, y, z)]
        let offsets = field.neighbourOffsets
        while true {
            let code = Int(tree.parent(tree.slot(x, y, z)))
            if code == 255 { break }
            x -= offsets[3 * code]
            y -= offsets[3 * code + 1]
            z -= offsets[3 * code + 2]
            voxels.append((x, y, z))
        }
        return voxels
    }

    func run(progress: (Double) -> Void, isCancelled: () -> Bool) throws(VesselTraceError) -> VesselCenterline {
        // From the narrower end: its side holds less lumen to open than a
        // cavity or the aorta at the other end.
        let fromA = (lumen.radiusA ?? .infinity) <= (lumen.radiusB ?? .infinity)
        let start = field.gridVoxel(fromA ? lumen.centreA : lumen.centreB)
        let goal = field.gridVoxel(fromA ? lumen.centreB : lumen.centreA)
        if start == goal { throw .samePoint }
        let goalIndex = field.index(goal.0, goal.1, goal.2)

        var reported = 0.0
        func report(_ share: Double) {
            if share >= reported + 0.01 {
                reported = share
                progress(share)
            }
        }

        let forward = VesselSearchTree(field: field)
        let first = try search(forward, from: start, to: goal, reach: reach, bound: budget, lumenOnly: false,
                               report: { report(0.9 * $0) }, isCancelled: isCancelled)
        var voxels: [(Int, Int, Int)]
        if first.found {
            voxels = chain(forward, from: goalIndex).reversed()
            var leaves = false
            for (x, y, z) in voxels where field.kind(x, y, z) != VesselCostField.lumen {
                leaves = true
                break
            }
            if leaves && first.promise < first.cost {
                let wider = VesselSearchTree(field: field)
                let second = try search(wider, from: start, to: goal, reach: 2 * reach, bound: first.cost, lumenOnly: true,
                                        report: { _ in }, isCancelled: isCancelled)
                if second.found && second.cost < first.cost { voxels = chain(wider, from: goalIndex).reversed() }
            }
        } else {
            let base = reported
            let backward = VesselSearchTree(field: field)
            _ = try search(backward, from: goal, to: start, reach: reach, bound: budget, lumenOnly: false,
                           report: { report(base + (0.95 - base) * $0) }, isCancelled: isCancelled)
            voxels = try join(forward, backward, start: start, goal: goal, isCancelled: isCancelled)
        }
        if !fromA { voxels.reverse() }
        report(1)
        return centerline(through: voxels)
    }

    // MARK: - Joining across a gap

    private struct Candidate {
        var index: Int
        var g: Double
        var x: Double, y: Double, z: Double
    }

    /// Groups of candidates by cubes of `size` millimetres.
    private struct Cells {
        var members: [[Candidate]] = []
        var least: [Double] = []
        var low: [SIMD3<Double>] = []
        var high: [SIMD3<Double>] = []

        init(_ candidates: [Candidate], size: Double) {
            var slots: [Int: Int] = [:]
            for c in candidates {
                let key = (Int((c.z / size).rounded(.down)) * 4096 + Int((c.y / size).rounded(.down))) * 4096
                    + Int((c.x / size).rounded(.down))
                if let n = slots[key] {
                    members[n].append(c)
                    least[n] = min(least[n], c.g)
                    low[n] = SIMD3(min(low[n].x, c.x), min(low[n].y, c.y), min(low[n].z, c.z))
                    high[n] = SIMD3(max(high[n].x, c.x), max(high[n].y, c.y), max(high[n].z, c.z))
                } else {
                    slots[key] = members.count
                    members.append([c])
                    least.append(c.g)
                    low.append(SIMD3(c.x, c.y, c.z))
                    high.append(SIMD3(c.x, c.y, c.z))
                }
            }
        }

        /// The least distance between the boxes of two groups, millimetres.
        func gap(_ n: Int, _ other: Cells, _ m: Int) -> Double {
            let dx = max(low[n].x - other.high[m].x, other.low[m].x - high[n].x, 0)
            let dy = max(low[n].y - other.high[m].y, other.low[m].y - high[n].y, 0)
            let dz = max(low[n].z - other.high[m].z, other.low[m].z - high[n].z, 0)
            return (dx * dx + dy * dy + dz * dz).squareRoot()
        }
    }

    /// The lumen voxels a search closed, and its root.
    private func candidates(_ tree: VesselSearchTree, root: (Int, Int, Int)) -> [Candidate] {
        var result: [Candidate] = []
        let rootIndex = field.index(root.0, root.1, root.2)
        let closedIndices = tree.closedIndices
        for n in 0..<closedIndices.count {
            let index = closedIndices.base[n]
            let (x, y, z) = field.coordinates(index)
            guard index == rootIndex || field.kind(x, y, z) == VesselCostField.lumen else { continue }
            result.append(Candidate(index: index, g: tree.g(tree.slot(x, y, z)),
                                    x: field.centresX[x], y: field.centresY[y], z: field.centresZ[z]))
        }
        if result.isEmpty {
            result.append(Candidate(index: rootIndex, g: 0, x: field.centresX[root.0], y: field.centresY[root.1],
                                    z: field.centresZ[root.2]))
        }
        return result
    }

    /// The path from `start` to `goal` through the voxels of the two searches
    /// and a straight line between them, the cheapest whole: the cost from
    /// each end plus the line's length at the full outside cost. The line
    /// says where the gap lies; `bridgingGaps` then bends it to the lumen.
    private func join(_ forward: VesselSearchTree, _ backward: VesselSearchTree,
                      start: (Int, Int, Int), goal: (Int, Int, Int),
                      isCancelled: () -> Bool) throws(VesselTraceError) -> [(Int, Int, Int)] {
        let near = candidates(forward, root: start), far = candidates(backward, root: goal)
        let unit = field.fullOutsideCost
        var size = 2.0
        var nearCells = Cells(near, size: size), farCells = Cells(far, size: size)
        while nearCells.members.count * farCells.members.count > 40_000 {
            size *= 2
            nearCells = Cells(near, size: size)
            farCells = Cells(far, size: size)
        }
        var pairs: [(bound: Double, n: Int, m: Int)] = []
        for n in nearCells.members.indices {
            for m in farCells.members.indices {
                pairs.append((nearCells.least[n] + farCells.least[m] + nearCells.gap(n, farCells, m) * unit, n, m))
            }
        }
        pairs.sort { $0.bound < $1.bound }
        var best = Double.infinity
        var bestNear = near[0], bestFar = far[0]
        var checked = 0
        for pair in pairs {
            if pair.bound >= best { break }
            let farMembers = farCells.members[pair.m], farLeast = farCells.least[pair.m]
            for p in nearCells.members[pair.n] {
                checked += 1
                if checked & 4095 == 0 && isCancelled() { throw .cancelled }
                if p.g + farLeast >= best { continue }
                for q in farMembers {
                    let dx = p.x - q.x, dy = p.y - q.y, dz = p.z - q.z
                    let total = p.g + q.g + (dx * dx + dy * dy + dz * dz).squareRoot() * unit
                    if total < best {
                        best = total
                        bestNear = p
                        bestFar = q
                    }
                }
            }
        }

        var voxels = Array(chain(forward, from: bestNear.index).reversed())
        // The straight line, every half of the finest grid step.
        let dx = bestFar.x - bestNear.x, dy = bestFar.y - bestNear.y, dz = bestFar.z - bestNear.z
        let length = (dx * dx + dy * dy + dz * dz).squareRoot()
        let samples = Int((length / (0.5 * min(field.gridX, field.gridY, field.gridZ))).rounded(.up))
        if samples > 1 {
            for k in 1..<samples {
                let t = Double(k) / Double(samples)
                let voxel = field.gridVoxel(millimetres: bestNear.x + dx * t, bestNear.y + dy * t, bestNear.z + dz * t)
                if let last = voxels.last, last == voxel { continue }
                voxels.append(voxel)
            }
        }
        for voxel in chain(backward, from: bestFar.index) {
            if let last = voxels.last, last == voxel { continue }
            voxels.append(voxel)
        }
        return voxels
    }

    // MARK: - Result

    /// A point of the path: its search voxel, where it lies in millimetres,
    /// and its distance to the lumen's border (0 out of the lumen).
    private struct PathPoint {
        var x: Int, y: Int, z: Int
        var at: SIMD3<Double>
        var radius: Double
    }

    private func pathPoint(_ x: Int, _ y: Int, _ z: Int, at: SIMD3<Double>? = nil) -> PathPoint {
        PathPoint(x: x, y: y, z: z, at: at ?? SIMD3(field.centresX[x], field.centresY[y], field.centresZ[z]),
                  radius: field.radius(forCost: field.cost(x, y, z)))
    }

    private func centerline(through voxels: [(Int, Int, Int)]) -> VesselCenterline {
        let path = bridgingGaps(voxels.map { pathPoint($0.0, $0.1, $0.2) })
        let spacing = SIMD3(Double(field.volume.spacing.x), Double(field.volume.spacing.y), Double(field.volume.spacing.z))
        var points: [SIMD3<Float>] = [], radii: [Float] = []
        var outside = 0
        var longestGap = 0.0
        var lastLumen: SIMD3<Double>?
        var runStart: SIMD3<Double>?
        for p in path {
            let input = p.at / spacing
            points.append(SIMD3(Float(input.x), Float(input.y), Float(input.z)))
            radii.append(Float(p.radius))
            if p.radius == 0 {
                outside += 1
                if runStart == nil { runStart = lastLumen ?? p.at }
            } else {
                if let from = runStart {
                    longestGap = max(longestGap, VesselMath.length(p.at - from))
                    runStart = nil
                }
                lastLumen = p.at
            }
        }
        if let from = runStart, let last = path.last {
            longestGap = max(longestGap, VesselMath.length(last.at - from))
        }
        let margin = lumen.margin(courseA: course(path, from: 0, by: 1), courseB: course(path, from: path.count - 1, by: -1))
        return VesselCenterline(points: points, radii: radii, start: a, end: b, lumenRange: lumen.lower...lumen.upper,
                                pointsOutsideLumen: outside, longestGap: Float(longestGap), lumenMargin: margin,
                                gridStep: SIMD3(field.stepX, field.stepY, field.stepZ), spacing: field.volume.spacing,
                                searchedVoxels: closed)
    }

    /// The vessel's course at one end of the path, a unit vector in
    /// millimetres: the line fitted to the path's points within 3 mm of
    /// `index` along it, going by `by` (1 on from the first point, -1 back
    /// from the last); nil when they span less than a millimetre.
    private func course(_ path: [PathPoint], from index: Int, by: Int) -> SIMD3<Double>? {
        var samples: [(s: Double, p: SIMD3<Double>)] = []
        var k = index, along = 0.0
        while k >= 0 && k < path.count {
            if k != index { along += VesselMath.length(path[k].at - path[k - by].at) }
            if along > 3 { break }
            samples.append((along, path[k].at))
            k += by
        }
        guard let far = samples.last, far.s >= 1 else { return nil }
        let slope = VesselMath.lineFit(samples).slope
        let length = VesselMath.length(slope)
        return length > 1e-9 ? slope / length : nil
    }

    // MARK: - Across a stretch out of the lumen

    /// The path with each stretch out of the lumen between two stretches in
    /// it (an occlusion, calcium, the line joining the two searches) carried
    /// on as the lumen runs on both sides. On each side, the path's points
    /// well inside the lumen (at least 0.85 of its usual radius: nearer the
    /// gap the path may already be cutting toward the gap's shortest crossing)
    /// give where the lumen's axis runs and which way; a cubic joins the two,
    /// so that across an occlusion of a curved vessel the path follows the
    /// curve rather than its chord, and no longer hugs the inner side of the
    /// bend. A stretch at either end of the path (an end the lumen's estimate
    /// could not move onto the lumen) is left as it is: the stretches bent
    /// lie between the path's first and last points in the lumen.
    private func bridgingGaps(_ path: [PathPoint]) -> [PathPoint] {
        let last = path.count - 1
        guard let lead = path.firstIndex(where: { $0.radius > 0 }),
              let tail = path.lastIndex(where: { $0.radius > 0 }) else { return path }
        // Each stretch out of the lumen, widened to the points well inside it
        // on both sides; stretches whose widenings meet become one.
        var spans: [(a: Int, b: Int, before: Double, after: Double)] = []
        var n = lead + 1
        while n < tail {
            guard path[n].radius == 0 else {
                n += 1
                continue
            }
            var a = n - 1, b = n + 1
            while b < tail && path[b].radius == 0 { b += 1 }
            n = b + 1
            let before = usualRadius(path, from: a, by: -1, stop: 0)
            let after = usualRadius(path, from: b, by: 1, stop: last)
            while a > lead && path[a].radius < 0.85 * before { a -= 1 }
            while b < tail && path[b].radius < 0.85 * after { b += 1 }
            n = max(n, b + 1)
            if let previous = spans.last, a <= previous.b {
                spans[spans.count - 1] = (min(previous.a, a), b, previous.before, after)
            } else {
                spans.append((a, b, before, after))
            }
        }
        guard !spans.isEmpty else { return path }
        var result: [PathPoint] = []
        var copied = 0
        for (k, span) in spans.enumerated() {
            let next = k + 1 < spans.count ? spans[k + 1].a : last
            let into = axisEnd(path, at: span.a, by: -1, stop: copied, radius: span.before)
            let outOf = axisEnd(path, at: span.b, by: 1, stop: next, radius: span.after)
            result.append(contentsOf: path[copied..<into.index])
            result.append(contentsOf: curve(from: (into.point, into.direction), to: (outOf.point, outOf.direction)))
            copied = outOf.index + 1
        }
        result.append(contentsOf: path[min(copied, path.count)...])
        return result
    }

    /// The median radius of the lumen's points within 4 mm of `index` along
    /// the path, going by `by` (-1 back, 1 on) no further than `stop`.
    private func usualRadius(_ path: [PathPoint], from index: Int, by: Int, stop: Int) -> Double {
        var radii: [Double] = []
        var k = index, along = 0.0
        while along <= 4 {
            if path[k].radius > 0 { radii.append(path[k].radius) }
            if k == stop { break }
            along += VesselMath.length(path[k + by].at - path[k].at)
            k += by
        }
        radii.sort()
        return radii.isEmpty ? 0 : radii[radii.count / 2]
    }

    /// The lumen's axis beside a gap, from the path's lumen points over four
    /// radii (3 to 8 mm) from `index`, going by `by` (-1 back from the gap, 1
    /// on), no further than `stop`: a line fitted, by their length along the
    /// path, to the middles of the lumen's cross-sections through them. On a
    /// bend it runs along the axis at the middle of those points, where the
    /// curve across the gap starts or ends. Also the index of the path's
    /// point nearest that middle, and the direction in which the path runs;
    /// the point at `index` and no direction when too few points lie in the
    /// lumen there.
    private func axisEnd(_ path: [PathPoint], at index: Int, by: Int, stop: Int,
                         radius: Double) -> (index: Int, point: PathPoint, direction: SIMD3<Double>?) {
        let reach = min(max(4 * radius, 3), 8)
        var samples: [(s: Double, p: SIMD3<Double>)] = []
        var indices: [Int] = []
        var k = index, along = 0.0
        while along <= reach {
            if path[k].radius > 0 {
                samples.append((Double(by) * along, path[k].at))
                indices.append(k)
            }
            if k == stop { break }
            along += VesselMath.length(path[k + by].at - path[k].at)
            k += by
        }
        guard samples.count >= 3, let far = samples.last, abs(far.s) >= 1 else { return (index, path[index], nil) }
        var fit = VesselMath.lineFit(samples)
        var length = VesselMath.length(fit.slope)
        guard length > 1e-9 else { return (index, path[index], nil) }
        // The path cuts the inside of a bend a little, and its voxels step a
        // quarter of a millimetre either way; the middles of the lumen's
        // cross-sections across that line lie on the axis itself.
        let direction = fit.slope / length
        fit = VesselMath.lineFit(samples.map { ($0.s, crossSectionCentre($0.p, across: direction, radius: radius) ?? $0.p) })
        length = VesselMath.length(fit.slope)
        guard length > 1e-9 else { return (index, path[index], nil) }
        let middle = samples.reduce(0) { $0 + $1.s } / Double(samples.count)
        var nearest = 0
        for n in samples.indices where abs(samples[n].s - middle) < abs(samples[nearest].s - middle) { nearest = n }
        let (x, y, z) = field.gridVoxel(millimetres: fit.value.x, fit.value.y, fit.value.z)
        return (indices[nearest], pathPoint(x, y, z, at: fit.value), fit.slope / length)
    }

    /// The middle of the lumen's cross-section through a point, square to
    /// `direction` (a unit vector), in millimetres: the mean of the points
    /// every 0.2 mm of that plane (no more than 41 across a wide lumen),
    /// within one and a half `radius` and a voxel of the point, that lie in
    /// lumen voxels joined to the point's own (a valley parts it from a vessel
    /// beside it). Nil when the point's own voxel is not lumen.
    private func crossSectionCentre(_ at: SIMD3<Double>, across direction: SIMD3<Double>, radius: Double) -> SIMD3<Double>? {
        let helper = abs(direction.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        var first = helper - direction * VesselMath.dot(helper, direction)
        first /= VesselMath.length(first)
        let second = SIMD3(direction.y * first.z - direction.z * first.y, direction.z * first.x - direction.x * first.z,
                           direction.x * first.y - direction.y * first.x)
        let reach = 1.5 * radius + max(field.gridX, field.gridY, field.gridZ)
        let step = max(0.2, reach / 20)
        let cells = Int((reach / step).rounded(.up)), side = 2 * cells + 1
        let volume = field.volume
        let extent = SIMD3(Double(volume.width - 1) * Double(volume.spacing.x), Double(volume.height - 1) * Double(volume.spacing.y),
                           Double(volume.depth - 1) * Double(volume.spacing.z))
        // 0 not yet seen, 1 lumen joined to the point, 2 anything else.
        var state = [UInt8](repeating: 0, count: side * side)
        func isLumen(_ i: Int, _ j: Int) -> Bool {
            let u = Double(i - cells) * step, v = Double(j - cells) * step
            guard u * u + v * v <= reach * reach else { return false }
            let q = at + first * u + second * v
            guard q.x >= 0 && q.y >= 0 && q.z >= 0 && q.x <= extent.x && q.y <= extent.y && q.z <= extent.z else { return false }
            let (x, y, z) = field.gridVoxel(millimetres: q.x, q.y, q.z)
            return field.kind(x, y, z) == VesselCostField.lumen
        }
        guard isLumen(cells, cells) else { return nil }
        var queue = [(cells, cells)]
        state[cells * side + cells] = 1
        var sum = SIMD3<Double>(repeating: 0)
        var head = 0
        while head < queue.count {
            let (i, j) = queue[head]
            head += 1
            sum += at + first * (Double(i - cells) * step) + second * (Double(j - cells) * step)
            for (ni, nj) in [(i + 1, j), (i - 1, j), (i, j + 1), (i, j - 1)] where ni >= 0 && ni < side && nj >= 0 && nj < side {
                guard state[nj * side + ni] == 0 else { continue }
                state[nj * side + ni] = isLumen(ni, nj) ? 1 : 2
                if state[nj * side + ni] == 1 { queue.append((ni, nj)) }
            }
        }
        return sum / Double(queue.count)
    }

    /// The points from one end of the lumen to the other across a gap: a
    /// cubic Hermite curve with the lumen's directions at both ends, as long
    /// as the circular arc between them would make them (a straight line when
    /// a direction is missing or turns away from the other end), one point
    /// in each search voxel it crosses, both ends included.
    private func curve(from start: (point: PathPoint, direction: SIMD3<Double>?),
                       to end: (point: PathPoint, direction: SIMD3<Double>?)) -> [PathPoint] {
        let p0 = start.point.at, p1 = end.point.at
        let chord = p1 - p0
        let length = VesselMath.length(chord)
        guard length > 1e-9 else { return [start.point, end.point] }
        let unit = chord / length
        var t0 = unit, t1 = unit
        if let d0 = start.direction, let d1 = end.direction, VesselMath.dot(d0, unit) >= 0.2, VesselMath.dot(d1, unit) >= 0.2 {
            t0 = d0
            t1 = d1
        }
        let turn = acos(min(max(VesselMath.dot(t0, t1), -1), 1))
        // The tangents' length that makes a cubic follow a circular arc.
        let scale = turn > 1e-3 ? 2 * tan(turn / 4) / sin(turn / 2) : 1
        let m0 = t0 * (length * scale), m1 = t1 * (length * scale)
        let arc = length * (turn > 1e-3 ? (turn / 2) / sin(turn / 2) : 1)
        let samples = max(Int((arc / (0.5 * min(field.gridX, field.gridY, field.gridZ))).rounded(.up)), 1)
        var points = [start.point]
        for k in 1..<samples {
            let t = Double(k) / Double(samples)
            let t2 = t * t, t3 = t2 * t
            let at = p0 * (2 * t3 - 3 * t2 + 1) + m0 * (t3 - 2 * t2 + t) + p1 * (-2 * t3 + 3 * t2) + m1 * (t3 - t2)
            let (x, y, z) = field.gridVoxel(millimetres: at.x, at.y, at.z)
            if let last = points.last, last.x == x && last.y == y && last.z == z { continue }
            points.append(pathPoint(x, y, z, at: at))
        }
        if let last = points.last, last.x == end.point.x && last.y == end.point.y && last.z == end.point.z {
            points.removeLast()
        }
        points.append(end.point)
        return points
    }
}
