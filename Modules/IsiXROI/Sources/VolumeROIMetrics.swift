//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

/// The metrics every volume ROI (the app's OSIROI) answers, their names,
/// labels and units, the label that lists them, its volume, and the stroke
/// thickness of the 2D ROIs behind it.
public enum VolumeROIMetrics {
    /// The metrics, in the order the label lists them.
    public static let names = ["intensityMean", "intensityMax", "intensityMin", "volume"]

    /// What a metric is called in a label; the volume has no label (nil).
    public static func label(for metric: String?) -> String? {
        switch metric {
        case "intensityMean": return "Mean Intensity"
        case "intensityMax": return "Maximum Intensity"
        case "intensityMin": return "Minimum Intensity"
        default: return nil
        }
    }

    /// The unit written after a metric's value: none for the intensities,
    /// "mm3" for the volume, nil for a metric it does not know.
    public static func unit(for metric: String?) -> String? {
        switch metric {
        case "intensityMean", "intensityMax", "intensityMin": return ""
        case "volume": return "mm3"
        default: return nil
        }
    }

    /// "label: valueunit, " for each metric, in order; a missing part reads
    /// "(null)", as a nil object did in the format.
    public static func summary(_ entries: [(label: String?, value: String?, unit: String?)]) -> String {
        entries.map { "\($0.label ?? "(null)"): \($0.value ?? "(null)")\($0.unit ?? "(null)"), " }.joined()
    }

    /// The volume of `voxelCount` voxels of the given spacing (mm), in cubic
    /// centimetres: the count times the voxel's volume, spacing x * y * z * 0.001.
    public static func volume(voxelCount: UInt, spacingX: Double, spacingY: Double, spacingZ: Double) -> Double {
        let voxelVolume = spacingX * spacingY * spacingZ * 0.001
        return Double(voxelCount) * voxelVolume
    }

    /// The stroke thickness the 2D ROIs share: the first non-zero one, or 0
    /// when another differs from it. A zero thickness on the way starts over.
    public static func commonThickness(_ thicknesses: [Double]) -> Double {
        var thickness = 0.0
        for value in thicknesses {
            if thickness == 0 {
                thickness = value
            } else if thickness != value {
                return 0
            }
        }
        return thickness
    }
}
