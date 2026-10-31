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

// How a 2D view blends the series fused over it: the mode of the alpha ramp,
// the blending factor the Fusion slider shows and the factor a drag started
// from. The view keeps the fused view and the alpha table it fills from here.

/// The blend of a view's fused series.
public struct FusionBlend: Sendable, Equatable {
    /// The factor's bound on either side: -setBlendingFactor: keeps it within ±256.
    public static let factorLimit: Float = 256

    /// The shape of the alpha ramp (ViewTransform.alphaTable): 0 the linear
    /// ramp, 1 and 2 the V shapes, 3 and 4 the logarithmic ones, 5 flat.
    public var mode: Int
    /// The blending factor. Written as it is by the drags and the scroll,
    /// which then hand it to -setBlendingFactor:, which bounds it.
    public var factor: Float
    /// The factor when the drag that changes it started.
    public var factorAtDragStart: Float

    public init(mode: Int = 0, factor: Float = 0.5, factorAtDragStart: Float = 0) {
        self.mode = mode
        self.factor = factor
        self.factorAtDragStart = factorAtDragStart
    }

    /// `factor` within ±256; a value that is not a number stays as it is.
    public static func bounded(_ factor: Float) -> Float {
        var bounded = factor
        if bounded < -factorLimit { bounded = -factorLimit }
        if bounded > factorLimit { bounded = factorLimit }
        return bounded
    }

    /// Sets the factor within ±256, as -setBlendingFactor: does, and returns it.
    @discardableResult
    public mutating func setBoundedFactor(_ value: Float) -> Float {
        factor = Self.bounded(value)
        return factor
    }

    /// Marks where a drag of the factor starts.
    public mutating func beginDrag() {
        factorAtDragStart = factor
    }

    /// The alpha table of the fused series for the factor `alpha`, in this mode.
    public func alphaTable(alpha: Float) -> [UInt8] {
        ViewTransform.alphaTable(mode: mode, alpha: alpha)
    }

    /// Where a view shows its image: its pan, its rotation in degrees and its flips.
    public struct Placement: Sendable, Equatable {
        public var origin: CGPoint
        public var rotation: Float
        public var xFlipped: Bool
        public var yFlipped: Bool

        public init(origin: CGPoint, rotation: Float, xFlipped: Bool, yFlipped: Bool) {
            self.origin = origin
            self.rotation = rotation
            self.xFlipped = xFlipped
            self.yFlipped = yFlipped
        }

        /// The pan in pixels of the image at full resolution (`scaleRatio`
        /// the inverse of the view's scale), unflipped and turned back.
        func unturnedOrigin(scaleRatio: Float, deg2rad: Double) -> CGPoint {
            var point = origin
            point.x *= CGFloat(scaleRatio)
            point.y *= CGFloat(scaleRatio)
            if xFlipped { point.x = -point.x }
            if yFlipped { point.y = -point.y }
            return ImagePlaneCoordinates.rotate(point, around: .zero, angle: Float(Double(-rotation) * deg2rad))
        }
    }

    /// The offset of the fused image over the image when -mergeFused renders
    /// both at the image's full resolution: the difference of their pans,
    /// with y pointing down.
    public static func mergeOffset(image: Placement, fused: Placement, scaleRatio: Float, deg2rad: Double) -> CGPoint {
        var offset = fused.unturnedOrigin(scaleRatio: scaleRatio, deg2rad: deg2rad)
        let imageOrigin = image.unturnedOrigin(scaleRatio: scaleRatio, deg2rad: deg2rad)
        offset.x -= imageOrigin.x
        offset.y -= imageOrigin.y
        offset.y = -offset.y
        return offset
    }
}
