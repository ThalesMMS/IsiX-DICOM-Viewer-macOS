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


import Accelerate
import Foundation

/// The fly-through assistant of the endoscopy and of the curved MPR: from a
/// volume of floats it builds a distance map of the lumen around a threshold
/// interval and follows its center, step by step (the endoscopy's path
/// navigator) or from one point to another (the centerline between two
/// points, a shortest path over the map).
///
/// The arithmetic is the Objective-C++ class's, rounding included: clang
/// fused each multiplication into the addition or subtraction that used it
/// (one rounding, as `fma`), and the same sums are written here with
/// `addingProduct`. Coordinates are voxels of the input volume unless a
/// method says resample coordinates: the distance map's voxels, cubes of
/// `resampleVoxelSize` millimetres.
///
/// The volume belongs to the caller and must outlive the assistant. A
/// distance transform may run on another thread (`setThreshold` of the app's
/// wrapper), as it did; nothing else here is synchronized.
public final class FlyPathAssistant: @unchecked Sendable {
    public static let noEnoughMemory: Int32 = 1
    public static let cannotFindPath: Int32 = 2
    public static let distanceTransformNotFinished: Int32 = 3

    static let slicesPerBlock = 32
    static let crossSectionSize = 64
    static let optimized: UInt8 = 0x80
    static let labelOfPointA: UInt8 = 0x20
    static let labelOfPointB: UInt8 = 0x40
    static let labelBitsMask: UInt8 = 0x60
    static let directionBitsMask: UInt8 = 0x1f
    /// Of the 27 neighbours' directions, 0 to 26, the one to the voxel itself.
    static let directionToSelf: UInt8 = 13
    /// What the threshold gives a voxel of the lumen before the transform.
    static let farAway = Float(3.4e+38)

    let input: UnsafePointer<Float>
    public let inputWidth: Int
    public let inputHeight: Int
    public let inputDepth: Int
    let inputImageSize: Int
    let inputVolumeSize: Int
    let inputSpacing: SIMD3<Float>

    var distmap: UnsafeMutablePointer<Float>?
    public private(set) var distmapWidth = 0
    public private(set) var distmapHeight = 0
    public private(set) var distmapDepth = 0
    var distmapImageSize = 0
    var distmapVolumeSize = 0
    public private(set) var resampleVoxelSize: Float = 0
    public private(set) var resampleScale = SIMD3<Float>(repeating: 0)

    /// The plane of the cross section: two unit vectors normal to the direction.
    var sampleMetric = (SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 0))
    let csmap: UnsafeMutablePointer<Float>

    public var centerlineResampleStepLength: Float = 0
    public var threshold: Float = 0
    public private(set) var isDistanceTransformFinished = false

    /// The interval of the lumen's values.
    public internal(set) var thresholdA: Float = 0
    public internal(set) var thresholdB: Float = 0
    public internal(set) var inputMinValue: Float = 0
    public internal(set) var inputMaxValue: Float = 0

    var inputHistogram: UnsafeMutablePointer<vImagePixelCount>?
    /// The tests' window on the view scan: told of every ray `traceLine`
    /// follows (origin and direction), and when it answers a distance, that
    /// distance stands for the volume's.
    var traceProbe: ((SIMD3<Float>, SIMD3<Float>) -> UInt32?)?
    public internal(set) var histogramSize: UInt32 = 0

    /// The assistant of `volume`, `width` × `height` × `depth` floats spaced
    /// by `spacing` millimetres, resampled at `resampleVoxelSize`. nil when
    /// the distance map cannot be allocated.
    public init?(volume: UnsafePointer<Float>, width: Int, height: Int, depth: Int,
                 spacing: SIMD3<Float>, resampleVoxelSize vsize: Float) {
        input = volume
        inputWidth = width
        inputHeight = height
        inputDepth = depth
        inputImageSize = Int(Int32(truncatingIfNeeded: width &* height))
        inputVolumeSize = Int(Int32(truncatingIfNeeded: width &* height &* depth))
        inputSpacing = spacing
        csmap = .allocate(capacity: Self.crossSectionSize * Self.crossSectionSize)
        csmap.initialize(repeating: 0, count: Self.crossSectionSize * Self.crossSectionSize)

        // The input's range and its smoothed histogram, for the thresholds.
        determineImageRange()
        computeHistogram()
        smoothHistogram(window: 5)

        if setResampleVoxelSize(vsize) != 0 { return nil }
    }

    deinit {
        free(distmap)
        csmap.deallocate()
        inputHistogram?.deallocate()
    }

    /// Allocates the distance map for voxels of `vsize` millimetres; 1
    /// (`noEnoughMemory`) when it cannot.
    @discardableResult
    public func setResampleVoxelSize(_ vsize: Float) -> Int32 {
        resampleVoxelSize = vsize
        free(distmap)
        distmap = nil
        distmapWidth = cInt(Float(inputWidth) * inputSpacing.x / vsize)
        distmapHeight = cInt(Float(inputHeight) * inputSpacing.y / vsize)
        distmapDepth = cInt(Float(inputDepth) * inputSpacing.z / vsize)

        resampleScale = SIMD3(Float(distmapWidth) / Float(inputWidth),
                              Float(distmapHeight) / Float(inputHeight),
                              Float(distmapDepth) / Float(inputDepth))

        distmapImageSize = Int(Int32(truncatingIfNeeded: distmapWidth &* distmapHeight))
        distmapVolumeSize = Int(Int32(truncatingIfNeeded: distmapWidth &* distmapHeight &* distmapDepth))
        guard distmapVolumeSize >= 0,
              let map = malloc(max(distmapVolumeSize, 0) * MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self) else {
            NSLog("no enough memory for distance map")
            return Self.noEnoughMemory
        }
        distmap = map
        return 0
    }

    /// The distance transform for the lumen at `threshold`, on this thread.
    public func setThreshold(_ value: Float) {
        threshold = value
        distanceTransform()
    }

    public func toResampleCoordinates(_ p: SIMD3<Float>) -> SIMD3<Float> { p * resampleScale }
    public func toInputCoordinates(_ p: SIMD3<Float>) -> SIMD3<Float> { p / resampleScale }

    /// The distance map's value at a resampled voxel, 0 outside the map.
    func distance(_ index: Int) -> Float {
        guard let distmap, index >= 0, index < distmapVolumeSize else { return 0 }
        return distmap[index]
    }

    /// The index of the voxel holding (x, y, z), in resample coordinates,
    /// each coordinate truncated as C's conversion to int does.
    func mapIndex(_ p: SIMD3<Float>) -> Int {
        cInt(p.z) &* distmapImageSize &+ cInt(p.y) &* distmapWidth &+ cInt(p.x)
    }

    // MARK: - Threshold and distance transform

    /// The distance map before the transform: 0 outside the threshold
    /// interval, `farAway` in it, each resampled voxel taking the largest of
    /// the input voxels it starts from and their next ones; then closed by a
    /// 3 × 3 kernel on each slice, and by a 1 × 3 one over the whole map read
    /// as an image of its slices' pixels by its slices.
    func thresholdImage() {
        guard let distmap else { return }
        let w = distmapWidth, h = distmapHeight, d = distmapDepth
        var z = 0
        while z < d {
            var y = 0
            while y < h {
                var x = 0
                while x < w {
                    let inputx = cInt(Float(x) / resampleScale.x)
                    let inputy = cInt(Float(y) / resampleScale.y)
                    let inputz = cInt(Float(z) / resampleScale.z)
                    var inValue = -Float.greatestFiniteMagnitude
                    for i in inputx...(inputx + 1) {
                        for j in inputy...(inputy + 1) {
                            for k in inputz...(inputz + 1) where k < inputDepth && j < inputHeight && i < inputWidth {
                                let value = input[k * inputImageSize + j * inputWidth + i]
                                if inValue < value { inValue = value }
                            }
                        }
                    }
                    distmap[z * distmapImageSize + y * w + x] = (inValue > thresholdB || inValue < thresholdA) ? 0 : Self.farAway
                    x += 1
                }
                y += 1
            }
            z += 1
        }

        var buffer = vImage_Buffer(data: nil, height: vImagePixelCount(h), width: vImagePixelCount(w),
                                   rowBytes: w * MemoryLayout<Float>.size)
        for slice in 0..<max(d, 0) {
            buffer.data = UnsafeMutableRawPointer(distmap + slice * distmapImageSize)
            morphologicalClosing(&buffer, kernelHeight: 3, kernelWidth: 3)
        }
        buffer = vImage_Buffer(data: UnsafeMutableRawPointer(distmap), height: vImagePixelCount(distmapImageSize),
                               width: vImagePixelCount(d), rowBytes: d * MemoryLayout<Float>.size)
        morphologicalClosing(&buffer, kernelHeight: 1, kernelWidth: 3)
    }

    /// The chamfer distance (1, √2, √3) of every voxel of the lumen to the
    /// nearest voxel outside it, in resampled voxels: forward and backward
    /// passes over blocks of 32 slices, in parallel, until a forward pass
    /// changes nothing. The blocks share their border slices without a lock,
    /// as they did: the passes repeat until nothing changes, and every order
    /// of the updates ends at the same distances.
    public func distanceTransform() {
        guard let distmap else { return }
        thresholdImage()

        let w = distmapWidth, h = distmapHeight, d = distmapDepth, imageSize = distmapImageSize
        let blocks = (d + Self.slicesPerBlock - 1) / Self.slicesPerBlock
        guard blocks > 0 else {
            isDistanceTransformFinished = true
            return
        }
        let map = SharedFloats(pointer: distmap)
        let counts = UnsafeMutablePointer<Int>.allocate(capacity: blocks)
        defer { counts.deallocate() }
        let changes = SharedInts(pointer: counts)

        var changedPoints = 1
        while changedPoints > 0 {
            counts.initialize(repeating: 0, count: blocks)
            DispatchQueue.concurrentPerform(iterations: blocks) { block in
                changes.pointer[block] = Self.forwardPass(map.pointer, block: block, width: w, height: h, depth: d,
                                                          imageSize: imageSize)
            }
            changedPoints = (0..<blocks).reduce(0) { $0 + counts[$1] }
            if changedPoints == 0 { break }
            counts.initialize(repeating: 0, count: blocks)
            DispatchQueue.concurrentPerform(iterations: blocks) { block in
                changes.pointer[block] = Self.backwardPass(map.pointer, block: block, width: w, height: h, depth: d,
                                                           imageSize: imageSize)
            }
            changedPoints = (0..<blocks).reduce(0) { $0 + counts[$1] }
        }
        isDistanceTransformFinished = true
    }

    private static let chamfer: (Float, Float, Float, Float) = (0, 1, 1.414213, 1.73205)

    private static func chamferStep(_ dx: Int, _ dy: Int, _ dz: Int) -> Float {
        switch abs(dx) + abs(dy) + abs(dz) {
        case 0: return chamfer.0
        case 1: return chamfer.1
        case 2: return chamfer.2
        default: return chamfer.3
        }
    }

    /// One block of the forward pass; the number of updates it made. The
    /// voxel is written after each of its neighbours' slices once it changed,
    /// as the former loop did.
    private static func forwardPass(_ map: UnsafeMutablePointer<Float>, block: Int, width w: Int, height h: Int,
                                    depth d: Int, imageSize: Int) -> Int {
        var starti = block * slicesPerBlock
        var endi = starti + slicesPerBlock
        if starti == 0 { starti = 1 }
        if endi >= d - 1 { endi = d - 1 }
        var changes = 0
        var z = starti
        while z < endi {
            var y = 1
            while y < h - 1 {
                var x = 1
                while x < w - 1 {
                    let index = z * imageSize + y * w + x
                    var changed = false
                    var current = map[index]
                    if current > 0 {
                        for dz in -1...1 {
                            for dy in -1...1 {
                                for dx in -1...1 {
                                    let next = map[(z + dz) * imageSize + (y + dy) * w + x + dx] + chamferStep(dx, dy, dz)
                                    if next < current {
                                        current = next
                                        changed = true
                                    }
                                }
                            }
                            if changed {
                                map[index] = current
                                changes += 1
                            }
                        }
                    }
                    x += 1
                }
                y += 1
            }
            z += 1
        }
        return changes
    }

    /// One block of the backward pass, from its last slice to its first.
    private static func backwardPass(_ map: UnsafeMutablePointer<Float>, block: Int, width w: Int, height h: Int,
                                     depth d: Int, imageSize: Int) -> Int {
        let starti = block * slicesPerBlock
        var endi = starti + slicesPerBlock
        if endi >= d - 1 { endi = d - 2 }
        var changes = 0
        var z = endi
        while z > starti {
            var y = h - 2
            while y > 0 {
                var x = w - 2
                while x > 0 {
                    let index = z * imageSize + y * w + x
                    var changed = false
                    var current = map[index]
                    if current > 0 {
                        for dz in -1...1 {
                            for dy in -1...1 {
                                for dx in -1...1 {
                                    let next = map[(z + dz) * imageSize + (y + dy) * w + x + dx] + chamferStep(dx, dy, dz)
                                    if next < current {
                                        current = next
                                        changed = true
                                    }
                                }
                            }
                        }
                        if changed {
                            map[index] = current
                            changes += 1
                        }
                    }
                    x -= 1
                }
                y -= 1
            }
            z -= 1
        }
        return changes
    }

    /// A closing (dilation, then erosion) of a planar float image by a kernel
    /// of ones, `kernelHeight` × `kernelWidth`, in place. A vImage error is
    /// logged and leaves the image as it was before that step.
    func morphologicalClosing(_ buffer: inout vImage_Buffer, kernelHeight: Int, kernelWidth: Int) {
        guard buffer.data != nil, buffer.height > 0, buffer.rowBytes > 0 else { return }
        let bytes = buffer.rowBytes * Int(buffer.height)
        guard let scratch = malloc(bytes) else { return }
        defer { free(scratch) }
        var result = vImage_Buffer(data: scratch, height: buffer.height, width: buffer.width, rowBytes: buffer.rowBytes)
        let kernel = [Float](repeating: 1, count: kernelHeight * kernelWidth)
        var error = vImageDilate_PlanarF(&buffer, &result, 0, 0, kernel, vImagePixelCount(kernelHeight),
                                         vImagePixelCount(kernelWidth), vImage_Flags(kvImageNoFlags))
        if error != kvImageNoError {
            Self.log(error)
            return
        }
        error = vImageErode_PlanarF(&result, &buffer, 0, 0, kernel, vImagePixelCount(kernelHeight),
                                    vImagePixelCount(kernelWidth), vImage_Flags(kvImageNoFlags))
        if error != kvImageNoError { Self.log(error) }
    }

    static func log(_ error: vImage_Error) {
        let names: [vImage_Error: String] = [
            kvImageRoiLargerThanInputBuffer: "kvImageRoiLargerThanInputBuffer",
            kvImageInvalidKernelSize: "kvImageInvalidKernelSize",
            kvImageInvalidEdgeStyle: "kvImageInvalidEdgeStyle",
            kvImageInvalidOffset_X: "kvImageInvalidOffset_X",
            kvImageInvalidOffset_Y: "kvImageInvalidOffset_Y",
            kvImageMemoryAllocationError: "kvImageMemoryAllocationError",
            kvImageNullPointerArgument: "kvImageNullPointerArgument",
            kvImageInvalidParameter: "kvImageInvalidParameter",
            kvImageBufferSizeMismatch: "kvImageBufferSizeMismatch",
            kvImageUnknownFlagsBit: "kvImageUnknownFlagsBit",
        ]
        if let name = names[error] { NSLog("%@", name) }
    }

    // MARK: - Cross sections

    /// The plane normal to (a, b, c): two unit vectors, the first horizontal
    /// when it can be. 1 for a direction of length 0, which leaves the plane as
    /// it was; so does a product a b c that underflows to 0 with no component 0.
    @discardableResult
    func calculateSampleMetric(_ a: Float, _ b: Float, _ c: Float) -> Int32 {
        if a * b * c == 0 {
            if a == 0 && b == 0 && c == 0 {
                return 1
            } else if a == 0 && b == 0 {
                sampleMetric = (SIMD3(1, 0, 0), SIMD3(0, 1, 0))
            } else if b == 0 && c == 0 {
                sampleMetric = (SIMD3(0, 1, 0), SIMD3(0, 0, 1))
            } else if a == 0 && c == 0 {
                sampleMetric = (SIMD3(1, 0, 0), SIMD3(0, 0, 1))
            } else if a == 0 {
                let n = (c * c).addingProduct(b, b).squareRoot()
                sampleMetric = (SIMD3(1, 0, 0), SIMD3(0, c / n, -b / n))
            } else if b == 0 {
                let n = (c * c).addingProduct(a, a).squareRoot()
                sampleMetric = (SIMD3(0, 1, 0), SIMD3(c / n, 0, -a / n))
            } else if c == 0 {
                let n = (a * a).addingProduct(b, b).squareRoot()
                sampleMetric = (SIMD3(0, 0, 1), SIMD3(b / n, -a / n, 0))
            }
        } else {
            // a x + b y + c z = 0, with z = 0 and y = 1
            var z: Float = 0
            var y: Float = 1
            var x = -b * y / a
            let n0 = (y * y).addingProduct(x, x).squareRoot()
            let first = SIMD3(x / n0, y / n0, z)
            let e = x, f = y, g = z
            // and e x + f y + g z = 0, with z = -1
            z = -1
            x = (-(g * b)).addingProduct(c, f) / (-(b * e)).addingProduct(f, a)
            y = (-(a * g)).addingProduct(c, e) / (-(f * a)).addingProduct(b, e)
            let n1 = ((y * y).addingProduct(x, x) + 1).squareRoot()
            sampleMetric = (first, SIMD3(x / n1, y / n1, z / n1))
        }
        return 0
    }

    /// A point along `dir` from `pt`, `stepLength` away, in resample coordinates:
    /// pt + stepLength · dir / |dir|, rounded as the former code did.
    func pointAhead(_ pt: SIMD3<Float>, _ dir: SIMD3<Float>, _ stepLength: Float) -> SIMD3<Float> {
        let length = (dir.y * dir.y).addingProduct(dir.x, dir.x).addingProduct(dir.z, dir.z).squareRoot()
        return SIMD3(pt.x + stepLength * dir.x / length,
                     pt.y + stepLength * dir.y / length,
                     pt.z + stepLength * dir.z / length)
    }

    /// The distance map on the 64 × 64 plane normal to `dir`, one resampled
    /// voxel apart, centered `stepLength` ahead of `pt` (resample coordinates);
    /// 0 outside the map.
    @discardableResult
    func resampleCrossSection(_ pt: SIMD3<Float>, _ dir: SIMD3<Float>, _ stepLength: Float) -> Int32 {
        let error = calculateSampleMetric(dir.x, dir.y, dir.z)
        if error != 0 { return error }
        let center = pointAhead(pt, dir, stepLength)
        let half = Self.crossSectionSize / 2
        let (m0, m1) = sampleMetric
        for i in 0..<Self.crossSectionSize {
            for j in 0..<Self.crossSectionSize {
                let fi = Float(i - half), fj = Float(j - half)
                let x = center.x.addingProduct(fi, m0.x).addingProduct(fj, m1.x)
                let y = center.y.addingProduct(fi, m0.y).addingProduct(fj, m1.y)
                let z = center.z.addingProduct(fi, m0.z).addingProduct(fj, m1.z)
                if x >= 0 && x < Float(distmapWidth) && y >= 0 && y < Float(distmapHeight) && z >= 0 && z < Float(distmapDepth) {
                    csmap[i * Self.crossSectionSize + j] = distance(mapIndex(SIMD3(x, y, z)))
                } else {
                    csmap[i * Self.crossSectionSize + j] = 0
                }
            }
        }
        return 0
    }

    /// The center of the lumen on the cross section `stepLength` ahead of
    /// `pt` along `dir`, in resample coordinates: the local maximum of the
    /// distance map reached by climbing from the section's center. nil
    /// without a map, for a direction of length 0, or when the maximum is
    /// below 1 (out of the lumen).
    public func nextCenterPoint(from pt: SIMD3<Float>, towards dir: SIMD3<Float>, stepLength: Float) -> SIMD3<Float>? {
        guard distmap != nil else { return nil }
        if resampleCrossSection(pt, dir, stepLength) != 0 { return nil }
        let size = Self.crossSectionSize
        var centerx = size / 2, centery = size / 2
        var maxX = centerx, maxY = centery
        var maxV: Float = 0
        while true {
            maxV = csmap[centery * size + centerx]
            maxX = centerx
            maxY = centery
            for dx in -1...1 {
                for dy in -1...1 where dx + centerx >= 0 && dx + centerx < size && dy + centery >= 0 && dy + centery < size {
                    let value = csmap[(centery + dy) * size + centerx + dx]
                    if maxV < value {
                        maxV = value
                        maxX = centerx + dx
                        maxY = centery + dy
                    }
                }
            }
            if centerx == maxX && centery == maxY { break }
            centerx = maxX
            centery = maxY
        }
        let ahead = pointAhead(pt, dir, stepLength)
        let (m0, m1) = sampleMetric
        let fy = Float(centery - size / 2), fx = Float(centerx - size / 2)
        let point = SIMD3(ahead.x.addingProduct(fy, m0.x).addingProduct(fx, m1.x),
                          ahead.y.addingProduct(fy, m0.y).addingProduct(fx, m1.y),
                          ahead.z.addingProduct(fy, m0.z).addingProduct(fx, m1.z))
        if Double(maxV) < 1.0 { return nil }
        return point
    }

    /// One step of the path navigator: `pt` moves halfway to the center of
    /// the lumen ahead and `dir` turns along it, both in input coordinates,
    /// in and out. Before a distance transform, the thresholds come from the
    /// voxels around `pt`. 0, or 1 without a map, or 2 (`cannotFindPath`)
    /// with `pt` and `dir` as they were given.
    public func nextPosition(from pt: inout SIMD3<Float>, towards dir: inout SIMD3<Float>) -> Int32 {
        guard distmap != nil else { return Self.noEnoughMemory }
        // The thresholds sample the input around pt, in the input coordinates it comes in.
        let inputX = cInt(pt.x), inputY = cInt(pt.y), inputZ = cInt(pt.z)
        pt = toResampleCoordinates(pt)
        dir = toResampleCoordinates(dir)
        if !isDistanceTransformFinished {
            var pixVal: Float = 0
            var count = 0
            addInputNeighborhood(inputX, inputY, inputZ, &pixVal, &count)
            if count != 0 { pixVal /= Float(count) }
            computeIntervalThresholds(from: pixVal)
            distanceTransform()
        }

        var newpos = SIMD3<Float>(repeating: 0)
        var newdir = SIMD3<Float>(repeating: 0)
        let currentcenter = nextCenterPoint(from: pt, towards: dir, stepLength: 0) ?? pt
        let steplen = distance(mapIndex(currentcenter))

        var x: Float = 0, y: Float = 0, z: Float = 0
        var i = 0
        while i < 20 {
            let step = Float(Double(steplen).addingProduct(Double(steplen) * 0.1, Double(i)))
            guard let nextcenter = nextCenterPoint(from: pt, towards: dir, stepLength: step) else { break }
            newdir = nextcenter - currentcenter
            let len = (newdir.y * newdir.y).addingProduct(newdir.x, newdir.x).addingProduct(newdir.z, newdir.z).squareRoot()
            if len < 1.0e-5 {
                i += 1
                continue
            }
            x += newdir.x / len
            y += newdir.y / len
            z += newdir.z / len
            i += 1
        }
        if i < 10 {
            // turning
            i = 0
            newpos = pt
            newdir = dir
            x = 0; y = 0; z = 0
        }
        while i < 10 {
            guard let nextcenter = nextCenterPoint(from: newpos, towards: newdir, stepLength: steplen) else { break }
            newdir = nextcenter - newpos
            newpos = SIMD3(halfway(newpos.x, nextcenter.x, 0.1), halfway(newpos.y, nextcenter.y, 0.1),
                           halfway(newpos.z, nextcenter.z, 0.1))
            let len = (newdir.y * newdir.y).addingProduct(newdir.x, newdir.x).addingProduct(newdir.z, newdir.z).squareRoot()
            if len < 1.0e-5 {
                i += 1
                continue
            }
            x += newdir.x / len
            y += newdir.y / len
            z += newdir.z / len
            i += 1
        }

        guard let ahead = nextCenterPoint(from: pt, towards: dir, stepLength: steplen) else {
            // pt and dir go back in the input coordinates, as the other returns give them.
            pt = toInputCoordinates(pt)
            dir = toInputCoordinates(dir)
            return Self.cannotFindPath
        }
        pt = SIMD3(halfway(pt.x, ahead.x, 0.5), halfway(pt.y, ahead.y, 0.5), halfway(pt.z, ahead.z, 0.5))
        let len = (y * y).addingProduct(x, x).addingProduct(z, z).squareRoot()
        dir = SIMD3(x / len, y / len, z / len)
        pt = toInputCoordinates(pt)
        dir = toInputCoordinates(dir)
        return 0
    }

    /// from + (to - from) · fraction, in double precision as `from + (to-from)*0.1` was.
    private func halfway(_ from: Float, _ to: Float, _ fraction: Double) -> Float {
        Float(Double(from).addingProduct(Double(to - from), fraction))
    }

    /// Adds to `sum` the input's voxels of the 3 × 3 × 3 neighbourhood of
    /// (x, y, z), in input coordinates, and counts them in `count`; the
    /// neighbours outside the volume are left out.
    func addInputNeighborhood(_ x: Int, _ y: Int, _ z: Int, _ sum: inout Float, _ count: inout Int) {
        for i in -1...1 {
            for j in -1...1 {
                for k in -1...1 {
                    let vx = x + i, vy = y + j, vz = z + k
                    if vx < 0 || vx >= inputWidth || vy < 0 || vy >= inputHeight || vz < 0 || vz >= inputDepth { continue }
                    sum += input[(vz * inputHeight + vy) * inputWidth + vx]
                    count += 1
                }
            }
        }
    }

    // MARK: - Radius

    /// The lumen's radius in millimetres at a point in input coordinates, 0
    /// outside the map.
    public func radius(at p: SIMD3<Float>) -> Float {
        let x = cInt(p.x * resampleScale.x), y = cInt(p.y * resampleScale.y), z = cInt(p.z * resampleScale.z)
        if x >= 0 && x < distmapWidth && y >= 0 && y < distmapHeight && z >= 0 && z < distmapDepth {
            return distance(z * distmapImageSize + y * distmapWidth + x) * resampleVoxelSize
        }
        return 0
    }

    /// The mean of the radii at the points `range` before `index` up to the
    /// one before `index + range`, those in the line.
    public func averageRadius(at index: Int, on line: [SIMD3<Float>], range: Int) -> Float {
        var sum: Float = 0
        var counter = 0
        for i in -range..<max(range, -range) where index + i >= 0 && index + i < line.count {
            sum += radius(at: line[index + i])
            counter += 1
        }
        return counter != 0 ? sum / Float(counter) : 0
    }
}

/// C's conversion of a float to int on arm64 (fcvtzs): toward zero,
/// saturated, NaN to 0. Swift's traps instead.
func cInt(_ value: Float) -> Int {
    if value.isNaN { return 0 }
    if value >= 2147483647.0 { return Int(Int32.max) }
    if value <= -2147483648.0 { return Int(Int32.min) }
    return Int(Int32(value))
}

/// C's conversion of a float to unsigned int on arm64 (fcvtzu).
func cUInt32(_ value: Float) -> UInt32 {
    if value.isNaN || value <= 0 { return 0 }
    if value >= 4294967295.0 { return UInt32.max }
    return UInt32(value)
}

/// The distance map, shared by the blocks of a pass.
struct SharedFloats: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Float>
}

/// The blocks' counts of updates, one slot each.
struct SharedInts: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Int>
}
