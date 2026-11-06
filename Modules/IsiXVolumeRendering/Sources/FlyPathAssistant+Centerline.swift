/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

/*=========================================================================
 Author: Chunliang Wang (chunliang.wang@liu.se)
 
 
 Program:  FLy Through Assistant And Centerline tracking for CT endoscopy
 
 This file is part of FLy Through Assistant And Centerline tracking for CT endoscopy.
 
 Copyright (c) 2010,
 Center for Medical Image Science and Visualization (CMIV),
 Linköping University, Sweden, http://www.cmiv.liu.se/
 
 FLy Through Assistant And Centerline tracking for CT endoscopy is free software;
 you can redistribute it and/or modify it under the terms of the
 GNU General Public License as published by the Free Software 
 Foundation, either version 3 of the License, or (at your option)
 any later version.
 
 FLy Through Assistant And Centerline tracking for CT endoscopy  is distributed in
 the hope that it will be useful, but WITHOUT ANY WARRANTY; 
 without even the implied warranty of MERCHANTABILITY or FITNESS
 FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 for more details.
 
 You should have received a copy of the GNU General Public License
 along with this program.  If not, see <http://www.gnu.org/licenses/>.
 
 =========================================================================*/


import Foundation

/// The spline a centerline is smoothed with: the app's, over VTK's cardinal
/// spline, which this module cannot link.
public protocol FlyPathSpline: AnyObject {
    func addPoint(_ t: Float, _ point: SIMD3<Float>)
    func evaluate(_ t: Float) -> SIMD3<Float>
}

/// A node of the search's queue: a resampled voxel and its cost.
struct FlyPathNode {
    var index: Int
    var cost: Float
}

/// The search's queue, a binary heap ordered as std::priority_queue with
/// std::greater on the cost ordered it in libc++ (push_heap's sift up,
/// pop_heap's Floyd sift down followed by a sift up): nodes of equal cost come
/// out in the same order, and so the same path is found.
struct FlyPathQueue {
    private(set) var nodes: [FlyPathNode] = []

    var isEmpty: Bool { nodes.isEmpty }
    var top: FlyPathNode { nodes[0] }

    /// The heap's comparison: `a` below `b` when it costs more.
    private static func below(_ a: FlyPathNode, _ b: FlyPathNode) -> Bool { a.cost > b.cost }

    mutating func push(_ node: FlyPathNode) {
        nodes.append(node)
        siftUp(count: nodes.count)
    }

    mutating func pop() {
        let count = nodes.count
        if count > 1 {
            let top = nodes[0]
            var hole = floydSiftDown(count: count)
            let last = count - 1
            if hole == last {
                nodes[hole] = top
            } else {
                nodes[hole] = nodes[last]
                hole += 1
                nodes[last] = top
                siftUp(count: hole)
            }
        }
        nodes.removeLast()
    }

    /// Moves the node at `count - 1` up to its place among the first `count`.
    private mutating func siftUp(count: Int) {
        guard count > 1 else { return }
        var parentCount = (count - 2) / 2
        var parent = parentCount
        var last = count - 1
        if Self.below(nodes[parent], nodes[last]) {
            let moving = nodes[last]
            repeat {
                nodes[last] = nodes[parent]
                last = parent
                if parentCount == 0 { break }
                parentCount = (parentCount - 1) / 2
                parent = parentCount
            } while Self.below(nodes[parent], moving)
            nodes[last] = moving
        }
    }

    /// Moves the hole at the top down to a leaf along the larger children,
    /// and answers the leaf.
    private mutating func floydSiftDown(count: Int) -> Int {
        var hole = 0
        var childIndex = 0
        var child = 0
        while true {
            childIndex += child + 1
            child = 2 * child + 1
            if child + 1 < count && Self.below(nodes[childIndex], nodes[childIndex + 1]) {
                childIndex += 1
                child += 1
            }
            nodes[hole] = nodes[childIndex]
            hole = childIndex
            if child > (count - 2) / 2 { return hole }
        }
    }
}

extension FlyPathAssistant {

    /// The centerline from `a` to `b`, in input coordinates: the cheapest
    /// path over the resampled voxels, a step costing e^-distance, searched
    /// from both ends at once until the two searches meet. The thresholds
    /// come from the mean of the input voxels around a and b; a and b, clamped
    /// to the volume, are the caller's and stay as they are. The points are
    /// the resampled voxels' corners, from a's end to b's, not yet thinned or
    /// smoothed. 0, 1 without memory, 2 (`cannotFindPath`) when the ends are
    /// the same voxel or the searches do not meet, 3 without a distance map.
    public func centerline(from a: SIMD3<Float>, to b: SIMD3<Float>) -> (code: Int32, points: [SIMD3<Float>]) {
        guard distmapVolumeSize >= 0,
              let costmap = malloc(distmapVolumeSize * MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self) else {
            NSLog("no enough memory")
            return (Self.noEnoughMemory, [])
        }
        defer { free(costmap) }

        let dimensions = [inputWidth, inputHeight, inputDepth]
        var pta = a, ptb = b
        for axis in 0..<3 {
            if pta[axis] < 0 { pta[axis] = 0 }
            if pta[axis] >= Float(dimensions[axis]) { pta[axis] = Float(dimensions[axis] - 1) }
            if ptb[axis] < 0 { ptb[axis] = 0 }
            if ptb[axis] >= Float(dimensions[axis]) { ptb[axis] = Float(dimensions[axis] - 1) }
        }

        // check that origin != destination
        if pta == ptb {
            NSLog("Can not define path from point to itself.")
            return (Self.cannotFindPath, [])
        }

        // the thresholds, from the mean of the voxels around A and B that lie in the volume
        var pixVal: Float = 0
        var count = 0
        addInputNeighborhood(cInt(pta.x), cInt(pta.y), cInt(pta.z), &pixVal, &count)
        addInputNeighborhood(cInt(ptb.x), cInt(ptb.y), cInt(ptb.z), &pixVal, &count)
        pixVal /= Float(count)
        computeIntervalThresholds(from: pixVal)
        NSLog("Opt. thresholds from %f : Min = %f / Max = %f", pixVal, thresholdA, thresholdB)
        distanceTransform()

        guard let distmap, isDistanceTransformFinished else { return (Self.distanceTransformNotFinished, []) }
        let labelmap = UnsafeMutablePointer<UInt8>.allocate(capacity: max(distmapVolumeSize, 1))
        defer { labelmap.deallocate() }

        pta = toResampleCoordinates(pta)
        ptb = toResampleCoordinates(ptb)
        costmap.initialize(repeating: Self.farAway, count: distmapVolumeSize)
        labelmap.initialize(repeating: 0, count: distmapVolumeSize)

        let w = distmapWidth, h = distmapHeight, d = distmapDepth, imageSize = distmapImageSize
        func stepCost(_ index: Int) -> Float { expf(-distmap[index]) }

        var queue = FlyPathQueue()
        var currentlabel: UInt8 = 0
        // plant the seeds
        for (seed, label) in [(pta, Self.labelOfPointA), (ptb, Self.labelOfPointB)] {
            let x = cInt(seed.x), y = cInt(seed.y), z = cInt(seed.z)
            currentlabel = label
            let currentindex = z * imageSize + y * w + x
            if currentindex >= distmapVolumeSize {
                NSLog("***** currentindex >= distmapVolumeSize")
                return (Self.distanceTransformNotFinished, [])
            }
            let currentcost: Float = 0
            costmap[currentindex] = 0
            labelmap[currentindex] = Self.optimized | label | Self.directionToSelf
            for dz in -1...1 {
                for dy in -1...1 {
                    for dx in -1...1 {
                        let neighbor = (z + dz) * imageSize + (y + dy) * w + (x + dx)
                        guard neighbor < distmapVolumeSize && neighbor >= 0 else { continue }
                        if labelmap[neighbor] & Self.optimized != 0 { continue }
                        let cost = currentcost + stepCost(neighbor)
                        if cost < costmap[neighbor] {
                            costmap[neighbor] = cost
                            labelmap[neighbor] = label | Self.direction(dx, dy, dz)
                            queue.push(FlyPathNode(index: neighbor, cost: cost))
                        }
                    }
                }
            }
        }

        var met = false
        var jointA = 0, jointB = 0
        while !queue.isEmpty && !met {
            let currentindex = queue.top.index
            queue.pop()
            // The queue cannot change a node's cost, so a voxel can be in it
            // more than once: the copies after the first are skipped.
            if labelmap[currentindex] & Self.optimized != 0 { continue }

            let z = currentindex / imageSize
            let y = (currentindex - z * imageSize) / w
            let x = currentindex - z * imageSize - y * w
            currentlabel = labelmap[currentindex] & Self.labelBitsMask
            labelmap[currentindex] |= Self.optimized
            let currentcost = costmap[currentindex]

            for dz in -1...1 {
                for dy in -1...1 {
                    for dx in -1...1 {
                        if x + dx < 0 || x + dx >= w || y + dy < 0 || y + dy >= h || z + dz < 0 || z + dz >= d || met { continue }
                        let neighbor = (z + dz) * imageSize + (y + dy) * w + (x + dx)
                        let neighborLabel = labelmap[neighbor] & Self.labelBitsMask
                        if neighborLabel != 0 && neighborLabel != currentlabel {
                            met = true
                            jointA = currentindex
                            jointB = neighbor
                            break
                        }
                        if labelmap[neighbor] & Self.optimized == 0 {
                            let cost = currentcost + stepCost(neighbor)
                            if cost < costmap[neighbor] {
                                costmap[neighbor] = cost
                                labelmap[neighbor] = currentlabel | Self.direction(dx, dy, dz)
                                queue.push(FlyPathNode(index: neighbor, cost: cost))
                            }
                        }
                    }
                }
            }
        }

        guard met else { return (Self.cannotFindPath, []) }
        let toA: [SIMD3<Int>], toB: [SIMD3<Int>]
        if currentlabel == Self.labelOfPointA {
            toA = trackCenterline(from: jointA, labelmap: labelmap)
            toB = trackCenterline(from: jointB, labelmap: labelmap)
        } else {
            toA = trackCenterline(from: jointB, labelmap: labelmap)
            toB = trackCenterline(from: jointA, labelmap: labelmap)
        }
        let voxels = toA.reversed() + toB
        let points = voxels.map { SIMD3(Float($0.x), Float($0.y), Float($0.z)) / resampleScale }
        return (0, points)
    }

    /// The direction toward the neighbour at (dx, dy, dz) seen from that
    /// neighbour, 0 to 26, as the labels keep it.
    static func direction(_ dx: Int, _ dy: Int, _ dz: Int) -> UInt8 {
        UInt8((-dz + 1) * 9 + (-dy + 1) * 3 - dx + 1)
    }

    /// The voxels from `index` back to its search's seed, along the labels'
    /// directions.
    func trackCenterline(from start: Int, labelmap: UnsafeMutablePointer<UInt8>) -> [SIMD3<Int>] {
        let w = distmapWidth, imageSize = distmapImageSize
        var currentindex = start
        var z = currentindex / imageSize
        var y = (currentindex - z * imageSize) / w
        var x = currentindex - z * imageSize - y * w
        var line = [SIMD3(x, y, z)]
        while currentindex >= 0 && currentindex < distmapVolumeSize
                && labelmap[currentindex] & Self.directionBitsMask != Self.directionToSelf {
            let direction = Int(labelmap[currentindex] & Self.directionBitsMask)
            let dz = direction / 9
            let dy = (direction - dz * 9) / 3
            let dx = direction - dz * 9 - dy * 3
            x += dx - 1
            y += dy - 1
            z += dz - 1
            line.append(SIMD3(x, y, z))
            currentindex = z * imageSize + y * w + x
        }
        return line
    }

    /// The points of a centerline (input coordinates) kept when it is thinned
    /// by the lumen's radius: a point closer to the last kept one than the
    /// mean of their radii goes. Two points or fewer are all kept.
    public func thinnedCenterlineIndices(_ line: [SIMD3<Float>]) -> [Int] {
        guard line.count > 2 else { return Array(line.indices) }
        var kept = [0]
        var previous = line[0] * resampleScale
        var previousRadius = distance(mapIndex(previous))
        for i in 1..<line.count {
            let point = line[i] * resampleScale
            let radius = distance(mapIndex(point))
            let step = point - previous
            let length = (step.y * step.y).addingProduct(step.x, step.x).addingProduct(step.z, step.z).squareRoot()
            if length < (previousRadius + radius) / 2 { continue }
            kept.append(i)
            previousRadius = radius
            previous = point
        }
        return kept
    }

    /// A centerline resampled along `spline` every `stepLength` (input
    /// coordinates): the points are the spline's knots, evenly spaced in t,
    /// and the new ones as many as whole steps fit in the line's length. nil
    /// for two points or fewer, which stay as they are.
    public static func smoothedCenterline(_ line: [SIMD3<Float>], stepLength: Float,
                                          spline: FlyPathSpline) -> [SIMD3<Float>]? {
        guard line.count > 2 else { return nil }
        var deltaT = Float(1.0 / Double(Float(line.count - 1)))
        var previous = line[0]
        var total: Float = 0
        for (i, point) in line.enumerated() {
            spline.addPoint(deltaT * Float(i), point)
            let step = point - previous
            total += (step.y * step.y).addingProduct(step.x, step.x).addingProduct(step.z, step.z).squareRoot()
            previous = point
        }
        let count = cInt(total / stepLength)
        deltaT = Float(1.0 / Double(Float(count - 1)))
        var points: [SIMD3<Float>] = []
        var i = 0
        while i < count {
            points.append(spline.evaluate(deltaT * Float(i)))
            i += 1
        }
        return points
    }

    // MARK: - View direction

    /// Where to look from `center` toward `direction`, two centerline points
    /// in input voxels: the ray, among those 3° apart up to 45° about the two
    /// axes normal to center → direction, that goes furthest in the lumen. The
    /// scan runs in the resampled volume, whose voxels are cubes, so its angles
    /// are angles in the patient; the view found comes back in input voxels as
    /// a point as far from center as direction is. With nowhere to look, the
    /// view is direction itself.
    public func maximizingViewDirection(from center: SIMD3<Float>, lookingAt direction: SIMD3<Float>) -> SIMD3<Float> {
        var best = direction
        let window = 45, step = 3
        var maxView: UInt32 = 0

        let origin = toResampleCoordinates(center)
        // the conversion is a scale on each axis, so it converts a vector as it does a point
        let ahead = toResampleCoordinates(direction - center)
        let aheadVector = SIMD3(Double(ahead.x), Double(ahead.y), Double(ahead.z))
        let aheadLength = FlyVector.length(aheadVector)
        if !(aheadLength > 0) || !aheadLength.isFinite { return best }
        let forward = aheadVector * (1.0 / aheadLength)

        // (vxAxis, vyAxis) is an orthonormal base of the plane normal to
        // forward, so the grid is square: vxAxis is horizontal (normal to z)
        // unless forward is along z, and vyAxis completes the right-handed frame.
        var vxAxis = SIMD3(-forward.y, forward.x, 0)
        if FlyVector.length(vxAxis) < 1e-6 { vxAxis = SIMD3(1, 0, 0) }
        vxAxis = FlyVector.normalize(vxAxis)
        let vyAxis = FlyVector.normalize(FlyVector.cross(forward, vxAxis))

        // Each ray turns the forward direction itself: turns about two fixed
        // axes do not add up, so a ray turned from the previous one drifts off the grid.
        for x in stride(from: -window, through: window, by: step) {
            let xAxisRot = FlyQuaternion(axis: vxAxis, degrees: Float(x))
            for y in stride(from: -window, through: window, by: step) {
                let yAxisRot = FlyQuaternion(axis: vyAxis, degrees: Float(y))
                let cdir = (yAxisRot * xAxisRot).rotate(forward)
                let viewDistance = traceLine(from: origin, along: SIMD3(Float(cdir.x), Float(cdir.y), Float(cdir.z)))
                if viewDistance > maxView {
                    maxView = viewDistance
                    let view = toInputCoordinates(SIMD3(Float(cdir.x * aheadLength), Float(cdir.y * aheadLength),
                                                        Float(cdir.z * aheadLength)))
                    best = center + view
                }
            }
        }
        return best
    }

    /// The number of steps of one resampled voxel along `direction` from
    /// `center` (resample coordinates) up to the first out of the lumen or of
    /// the volume; 0 for a direction of length 0 or not finite.
    public func traceLine(from center: SIMD3<Float>, along direction: SIMD3<Float>) -> UInt32 {
        if let probe = traceProbe, let distance = probe(center, direction) { return distance }
        let unit = FlyVector.normalize(SIMD3(Double(direction.x), Double(direction.y), Double(direction.z)))
        if unit == SIMD3(repeating: 0) || !unit.x.isFinite || !unit.y.isFinite || !unit.z.isFinite { return 0 }
        let step = SIMD3(Float(unit.x), Float(unit.y), Float(unit.z))
        var current = center
        var viewDistance: UInt32 = 0
        repeat {
            current += step
            viewDistance += 1
        } while isInside(current) && distance(cInt(current.x) + distmapWidth * cInt(current.y) + distmapImageSize * cInt(current.z)) != 0
        return viewDistance
    }

    /// Strictly inside the distance map, in resample coordinates.
    func isInside(_ p: SIMD3<Float>) -> Bool {
        p.x > 0 && p.x < Float(distmapWidth) && p.y > 0 && p.y < Float(distmapHeight) && p.z > 0 && p.z < Float(distmapDepth)
    }
}

/// The vector functions of N3Geometry, in double precision, rounded as clang
/// compiled them (each product fused into the sum that uses it).
enum FlyVector {
    static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        (a.y * b.y).addingProduct(a.x, b.x).addingProduct(a.z, b.z)
    }

    static func length(_ v: SIMD3<Double>) -> Double {
        dot(v, v).squareRoot()
    }

    static func normalize(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let l = length(v)
        if l == 0 { return SIMD3(repeating: 0) }
        return v * (1.0 / l)
    }

    static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3((-(a.z * b.y)).addingProduct(a.y, b.z),
              (-(a.x * b.z)).addingProduct(a.z, b.x),
              (-(a.y * b.x)).addingProduct(a.x, b.y))
    }
}
