//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

/// The region growing the bone removal of the volume rendering used before it
/// asked ITK: from a seed, the voxels above a value, reached through a box
/// that grows a voxel at a time on the sides the region touches. In a plane
/// the region spreads to its four neighbours until nothing changes; between
/// planes it spreads from the two end planes of the box only, so a voxel
/// reached from a neighbouring plane inside the box is marked and not grown
/// from. The labels say which is which, and a plug-in of the former SDK still
/// gets them as brush textures.
public enum FastRegionGrowing {
    /// A voxel of the region, grown from.
    public static let grown: UInt8 = 0xFF
    /// A voxel above the value, reached and not grown from.
    public static let reached: UInt8 = 0xFE
    /// A voxel reached and refused: not above the value.
    public static let refused: UInt8 = 2

    /// The labels of `width` × `height` × `depth` voxels of `volume`, a byte a
    /// voxel in the volume's order: 0 where the region did not come. `seed`
    /// is brought two voxels inside the volume, and the growth starts from
    /// the voxel on its right, as it always did. A volume too small to hold
    /// the seed's neighbourhood gives no label.
    public static func labels(volume: UnsafeBufferPointer<Float>, width w: Int, height h: Int, depth: Int,
                              seed: inout SIMD3<Int>, above from: Float) -> [UInt8] {
        let s = w * h, total = s * depth
        guard w > 0, h > 0, depth > 0, volume.count >= total else { return [] }
        var labels = [UInt8](repeating: 0, count: total)

        if seed.x <= 1 { seed.x = 2 }
        if seed.x >= w - 2 { seed.x = w - 3 }
        if seed.y <= 1 { seed.y = 2 }
        if seed.y >= h - 2 { seed.y = h - 3 }
        if seed.z <= 1 { seed.z = 2 }
        if seed.z >= depth - 2 { seed.z = depth - 3 }

        var minX = seed.x - 1, maxX = seed.x + 2
        var minY = seed.y - 1, maxY = seed.y + 2
        var minZ = seed.z, maxZ = seed.z + 1

        let start = seed.x + 1 + seed.y * w + seed.z * s
        guard start >= 0, start < total else { return labels }
        labels[start] = reached

        /// A neighbour not yet seen is reached when above the value, refused otherwise.
        func visit(_ index: Int) {
            guard index >= 0, index < total, labels[index] == 0 else { return }
            labels[index] = volume[index] > from ? reached : refused
        }
        func label(_ index: Int) -> UInt8 {
            index >= 0 && index < total ? labels[index] : 0
        }
        func clampBox() {
            if minX <= 0 { minX = 1 }
            if maxX >= w - 1 { maxX = w - 1 }
            if minY <= 0 { minY = 1 }
            if maxY >= h - 1 { maxY = h - 1 }
            if minZ <= 0 { minZ = 1 }
            if maxZ >= depth - 1 { maxZ = depth - 1 }
        }
        /// Whether a face of the box holds a label.
        func touches(x: Int) -> Bool {
            for z in stride(from: minZ, to: maxZ, by: 1) {
                for y in stride(from: minY, to: maxY, by: 1) where label(x + y * w + z * s) != 0 { return true }
            }
            return false
        }
        func touches(y: Int) -> Bool {
            for z in stride(from: minZ, to: maxZ, by: 1) {
                for x in stride(from: minX, to: maxX, by: 1) where label(x + y * w + z * s) != 0 { return true }
            }
            return false
        }
        func touches(z: Int) -> Bool {
            for y in stride(from: minY, to: maxY, by: 1) {
                for x in stride(from: minX, to: maxX, by: 1) where label(x + y * w + z * s) != 0 { return true }
            }
            return false
        }

        var found = true
        while found {
            found = false
            clampBox()

            var addZ = maxZ - minZ - 1
            if addZ == 0 { addZ += 1 }

            var z = minZ
            while z < maxZ {
                var foundPlane = true
                while foundPlane {
                    clampBox()
                    foundPlane = false
                    for y in stride(from: minY, to: maxY, by: 1) {
                        for x in stride(from: minX, to: maxX, by: 1) {
                            let index = x + y * w + z * s
                            if label(index) == reached {
                                labels[index] = grown
                                visit(index + 1)
                                visit(index - 1)
                                visit(index + w)
                                visit(index - w)
                                foundPlane = true
                            }
                        }
                    }

                    // Should the box grow?
                    if foundPlane {
                        found = true
                        let lowX = touches(x: minX), highX = touches(x: maxX - 1)
                        let lowY = touches(y: minY), highY = touches(y: maxY - 1)
                        if lowX { minX -= 1 }
                        if highX { maxX += 1 }
                        if lowY { minY -= 1 }
                        if highY { maxY += 1 }
                    }
                }

                for y in stride(from: minY, to: maxY, by: 1) {
                    for x in stride(from: minX, to: maxX, by: 1) {
                        let index = x + y * w + z * s
                        if label(index) == grown {
                            visit(index - s)
                            visit(index + s)
                        }
                    }
                }
                if addZ <= 0 { break }
                z += addZ
            }

            if found {
                let low = touches(z: minZ), high = touches(z: maxZ - 1)
                if low { minZ -= 1 }
                if high { maxZ += 1 }
            }
        }
        return labels
    }
}
