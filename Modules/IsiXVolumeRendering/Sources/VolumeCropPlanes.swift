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

/// The crop as the Metal renderer clips its rays: planes in voxel index space,
/// four floats a plane, the kept side where a·x + b·y + c·z + d ≥ 0.
///
/// The crop reaches VTK as clipping planes on the mapper - the box widget's or
/// a saved camera's, possibly rotated - which the mapper gives in voxel index
/// space, as its ray caster clips against them. Planes that do not cut into the
/// voxel centres, such as the six a restored camera installs around an
/// uncropped volume, change nothing and are left out.
public enum VolumeCropPlanes {

    /// VTK's cropping regions as the mapper holds them.
    public struct Cropping: Sendable {
        public var subvolume: Bool
        /// xmin, xmax, ymin, ymax, zmin, zmax, in the data's coordinates.
        public var planes: [Double]
        /// The mapper input's origin and spacing; nil without an input.
        public var origin: [Double]?, spacing: [Double]?

        public init(subvolume: Bool, planes: [Double], origin: [Double]?, spacing: [Double]?) {
            self.subvolume = subvolume
            self.planes = planes
            self.origin = origin
            self.spacing = spacing
        }
    }

    /// Why the planes cannot go to the renderer; the text is the fallback
    /// reason the view shows.
    public enum Refusal: Error, Equatable, Sendable {
        case regionsNotSubvolume, noInput, unusableSpacing

        public var reason: String {
            switch self {
            case .regionsNotSubvolume: return "VTK cropping regions other than a subvolume use the original renderer."
            case .noInput: return "The 3D view has no volume yet."
            case .unusableSpacing: return "The volume spacing is not usable."
            }
        }
    }

    /// The planes that cut into a `width` × `height` × `depth` volume: the
    /// mapper's `voxelPlanes`, then - when VTK's cropping regions are on - the
    /// six axis-aligned planes of their one subvolume (the only set of regions
    /// that is one convex volume; the host never turns regions on).
    public static func cuttingPlanes(voxelPlanes: [Float], cropping: Cropping?, width: Int, height: Int,
                                     depth: Int) throws(Refusal) -> [Float] {
        var planes = voxelPlanes
        if let cropping {
            guard cropping.subvolume else { throw .regionsNotSubvolume }
            guard let origin = cropping.origin, let spacing = cropping.spacing else { throw .noInput }
            for axis in 0..<3 {
                guard spacing[axis] > 0 else { throw .unusableSpacing }
                let low = (cropping.planes[2 * axis] - origin[axis]) / spacing[axis]
                let high = (cropping.planes[2 * axis + 1] - origin[axis]) / spacing[axis]
                var lower: [Float] = [0, 0, 0, Float(-low)], upper: [Float] = [0, 0, 0, Float(high)]
                lower[axis] = 1
                upper[axis] = -1
                planes += lower
                planes += upper
            }
        }
        let lastVoxel = [Double(width) - 1.0, Double(height) - 1.0, Double(depth) - 1.0]
        var cutting: [Float] = []
        var i = 0
        while i + 4 <= planes.count {
            var cuts = false
            for corner in 0..<8 where !cuts {
                var distance = Double(planes[i + 3])
                for axis in 0..<3 { distance += Double(planes[i + axis]) * (((corner >> axis) & 1) != 0 ? lastVoxel[axis] : 0) }
                cuts = distance < -1e-4
            }
            if cuts { cutting += planes[i..<(i + 4)] }
            i += 4
        }
        return cutting
    }
}
