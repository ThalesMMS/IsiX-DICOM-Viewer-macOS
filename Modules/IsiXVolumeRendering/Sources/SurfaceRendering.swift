//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Foundation

/// Where the surfaces of a series go in VTK's world: VTK applies an actor's
/// user matrix about its origin, then moves the result to its position.
public enum SurfacePlacement {
    /// The identity, sixteen doubles row by row.
    public static let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

    /// The user matrix of the slices' orientation, row by row: the row, the
    /// column and the normal of the slices (`cosines`, nine floats) are its
    /// first three columns.
    public static func userMatrix(cosines: [Float]) -> [Double] {
        precondition(cosines.count >= 9)
        let c = cosines.map(Double.init)
        return [c[0], c[3], c[6], 0,
                c[1], c[4], c[7], 0,
                c[2], c[5], c[8], 0,
                0, 0, 0, 1]
    }

    /// The position of an actor whose origin is the first slice's origin,
    /// times `factor`: the origin turned by the user matrix's transpose.
    public static func position(origin: SIMD3<Double>, factor: Float = 1, userMatrix m: [Double]) -> SIMD3<Double> {
        let f = Double(factor)
        let x = f * origin.x, y = f * origin.y, z = f * origin.z
        return SIMD3(x * m[0] + y * m[4] + z * m[8],
                     x * m[1] + y * m[5] + z * m[9],
                     x * m[2] + y * m[6] + z * m[10])
    }
}

/// The resolution of the surfaces: the factor the slices are resampled by in
/// x and y before the iso-surface is extracted. The settings sheet's slider
/// goes from 0.1 to 1; VTK cannot resample by 0.
public enum SurfaceResolution {
    public static let range: ClosedRange<Float> = 0.1...1
    /// The sheet's default.
    public static let standard: Float = 0.5

    /// `value` brought within the slider's range; a value that is not a
    /// number is the sheet's default.
    public static func clamped(_ value: Float) -> Float {
        value.isNaN ? standard : min(max(value, range.lowerBound), range.upperBound)
    }
}

/// What a surface's geometry is built from: the resolution, the iso value,
/// the decimation and the smoothing. Two settings with the same key build the
/// same geometry, so a change of colour or transparency alone keeps it.
public struct SurfaceGeometryKey: Equatable, Sendable {
    public let values: [Float]

    public init(resolution: Float, isoValue: Float, decimate: Bool, reduction: Float, smooth: Bool, iterations: Int) {
        values = [resolution, isoValue, decimate ? 1 : 0, decimate ? reduction : 0, smooth ? 1 : 0,
                  smooth ? Float(iterations) : 0]
    }

    /// Whether `other` built the same geometry; no key never did. A value that
    /// is not a number matches nothing.
    public func sameGeometry(as other: SurfaceGeometryKey?) -> Bool {
        guard let other else { return false }
        for (a, b) in zip(values, other.values) where a != b { return false }
        return true
    }
}

/// The voxels the surfaces are contoured from.
public enum SurfaceVoxels {
    /// The grey level of each ARGB pixel of `argb`: the integer mean of its
    /// red, green and blue, the alpha byte skipped.
    public static func greyLevels(argb: UnsafeBufferPointer<UInt8>, into grey: UnsafeMutableBufferPointer<Float>) {
        let count = min(grey.count, argb.count / 4)
        for i in 0..<count {
            let sum = Int(argb[4 * i + 1]) + Int(argb[4 * i + 2]) + Int(argb[4 * i + 3])
            grey[i] = Float(sum / 3)
        }
    }
}

/// The orientation of a 3D view's camera, in patient directions.
public enum SurfaceOrientation {
    /// A patient direction, as the letters at the view's edges name it.
    public enum Letter: Sendable, Equatable {
        case right, left, anterior, posterior, inferior, superior
    }

    /// The view's rows and columns in patient coordinates, nine floats: the
    /// view transform's first three rows, the second one turned around.
    public static func vectors(viewTransform m: [Double]) -> [Float] {
        var o = [Float](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 { o[3 * i + j] = Float(m[4 * i + j]) }
        }
        o[3] = -o[3]
        o[4] = -o[4]
        o[5] = -o[5]
        return o
    }

    /// The directions `vector` points to, the strongest first, each above a
    /// fifth; `inverted` reads the vector the other way.
    public static func letters(_ vector: (Float, Float, Float), inverted: Bool) -> [Letter] {
        let (vx, vy, vz) = inverted ? (-vector.0, -vector.1, -vector.2) : vector
        let x: Letter = vx < 0 ? .right : .left
        let y: Letter = vy < 0 ? .anterior : .posterior
        let z: Letter = vz < 0 ? .inferior : .superior
        var absX = abs(vector.0), absY = abs(vector.1), absZ = abs(vector.2)
        var letters: [Letter] = []
        for _ in 0..<3 {
            if Double(absX) > 0.2 && absX >= absY && absX >= absZ {
                letters.append(x)
                absX = 0
            } else if Double(absY) > 0.2 && absY >= absX && absY >= absZ {
                letters.append(y)
                absY = 0
            } else if Double(absZ) > 0.2 && absZ >= absX && absZ >= absY {
                letters.append(z)
                absZ = 0
            } else {
                break
            }
        }
        return letters
    }
}

/// The surface view's frame in its window.
public enum SurfaceViewFrame {
    /// The square frame the view takes in `frame` for the VRDefaultViewSize
    /// preference: the largest square (1 keeps the frame: nil), or 512 (2) or
    /// 768 (3) pixels, centred, ten points above the middle.
    public static func square(_ frame: CGRect, preference: Int) -> CGRect? {
        if preference == 1 { return nil }
        var border = Int(frame.size.height - 1)
        if CGFloat(border) > frame.size.width { border = Int(frame.size.width) }
        if preference == 2 { border = 512 }
        if preference == 3 { border = 768 }
        let side = CGFloat(border)
        return CGRect(x: CGFloat(Int((frame.size.width - side) / 2)), y: CGFloat(Int(10 + (frame.size.height - side) / 2)),
                      width: side, height: side)
    }

    /// The frame a drag from the view's bottom left corner gives it in a window
    /// content of `content`: centred, its corner at the mouse (in the window),
    /// at least 100 points wide and high and 10 from the edges; with `square`,
    /// as wide as high. The frame keeps nothing of `frame` but its type.
    public static func dragResize(mouse: CGPoint, content: CGSize, frame: CGRect, square: Bool) -> CGRect {
        var resized = frame
        var corner = mouse
        if square {
            resized.size.width = content.width - corner.x * 2
            resized.size.height = resized.size.width
            corner.x = (content.width - resized.size.width) / 2
            corner.y = (content.height - resized.size.height) / 2
        }
        if content.width - corner.x * 2 < 100 { corner.x = (content.width - 100) / 2 }
        if content.height - corner.y * 2 < 100 { corner.y = (content.height - 100) / 2 }
        if corner.x < 10 { corner.x = 10 }
        if corner.y < 10 { corner.y = 10 }
        resized.origin = corner
        resized.size.width = content.width - corner.x * 2
        resized.size.height = content.height - corner.y * 2
        return resized
    }

    /// The frame of a matrix export for the EXPORTMATRIXFOR3D preference in a
    /// window content of `content`: 512 (1) or 768 (2) pixels centred in it, ten
    /// points shorter; nil keeps the view's frame.
    public static func matrixExport(content: CGSize, preference: Int) -> CGRect? {
        let side: CGFloat
        switch preference {
        case 1: side = 512
        case 2: side = 768
        default: return nil
        }
        let width = content.width, height = content.height - 10
        return CGRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)
    }
}

/// The pick of a scene's 3D points: the nearest sphere a ray from the eye
/// meets, each prop taken as the sphere around its bounds, as vtkPropPicker
/// found the surface view's spheres.
public enum SceneSpherePick {
    public struct Box: Sendable {
        public let xmin, xmax, ymin, ymax, zmin, zmax: Double
        public init(xmin: Double, xmax: Double, ymin: Double, ymax: Double, zmin: Double, zmax: Double) {
            self.xmin = xmin
            self.xmax = xmax
            self.ymin = ymin
            self.ymax = ymax
            self.zmin = zmin
            self.zmax = zmax
        }
    }

    /// The index of the box whose sphere the ray from `from` towards `to`
    /// enters first, in front of `from`; nil when it meets none.
    public static func nearest(from: SIMD3<Double>, to: SIMD3<Double>, boxes: [Box]) -> Int? {
        let ray = (to.x - from.x, to.y - from.y, to.z - from.z)
        let length2 = ray.0 * ray.0 + ray.1 * ray.1 + ray.2 * ray.2
        var nearest = Double.infinity
        var picked: Int?
        for (index, box) in boxes.enumerated() {
            if length2 <= 0 { continue }
            let centre = ((box.xmin + box.xmax) / 2, (box.ymin + box.ymax) / 2, (box.zmin + box.zmax) / 2)
            let radius = max(box.xmax - box.xmin, max(box.ymax - box.ymin, box.zmax - box.zmin)) / 2
            let offset = (from.x - centre.0, from.y - centre.1, from.z - centre.2)
            let b = offset.0 * ray.0 + offset.1 * ray.1 + offset.2 * ray.2
            let c = offset.0 * offset.0 + offset.1 * offset.1 + offset.2 * offset.2 - radius * radius
            let discriminant = b * b - length2 * c
            if discriminant < 0 { continue }
            var t = (-b - discriminant.squareRoot()) / length2
            if t < 0 { t = (-b + discriminant.squareRoot()) / length2 }
            if t >= 0 && t < nearest {
                nearest = t
                picked = index
            }
        }
        return picked
    }
}
