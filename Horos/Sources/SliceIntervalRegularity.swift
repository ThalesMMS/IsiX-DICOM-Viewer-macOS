//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import IsiXImaging

/// Whether a stack of slices is spaced regularly enough for 3D and measurements:
/// the rule is IsiXImaging's SliceSpacingRegularity. This class keeps the
/// Objective-C name and selectors plugins were built against.
@objc(HorosSliceIntervalRegularity)
public final class SliceIntervalRegularity: NSObject {
    /// The intervals along the normal, as the warning reports them.
    @objc public let minimumInterval: Double
    @objc public let maximumInterval: Double
    @objc public let meanInterval: Double
    /// The largest distance of a slice from the uniform grid, in mm.
    @objc public let largestGridDeviation: Double
    @objc public let isIrregular: Bool

    init(_ rule: SliceSpacingRegularity) {
        minimumInterval = rule.minimumInterval
        maximumInterval = rule.maximumInterval
        meanInterval = rule.meanInterval
        largestGridDeviation = rule.largestGridDeviation
        isIrregular = rule.isIrregular
    }

    /// `origins` holds x, y, z of each slice in stack order; `normal` the slice
    /// normal (rows x columns); `pixelSpacing` the smallest in-plane spacing.
    @objc(regularityOfOrigins:normal:pixelSpacing:)
    public static func regularity(origins: [NSNumber], normal: [NSNumber], pixelSpacing: Double) -> SliceIntervalRegularity {
        regularity(origins: origins.map(\.doubleValue), normal: normal.map(\.doubleValue), pixelSpacing: pixelSpacing)
    }

    static func regularity(origins: [Double], normal: [Double], pixelSpacing: Double) -> SliceIntervalRegularity {
        SliceIntervalRegularity(SliceSpacingRegularity(origins: origins, normal: normal, pixelSpacing: pixelSpacing))
    }
}
