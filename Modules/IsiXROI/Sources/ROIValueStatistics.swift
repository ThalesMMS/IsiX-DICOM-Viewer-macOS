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

import Foundation

/// The statistics of the pixel values under the ROIs that make a volume, as
/// the 2D viewer reports them with the volume: lowest and highest value, mean,
/// sum and standard deviation.
///
/// The sums run in double. Each value's squared distance to the mean is
/// rounded to Float before it is added, as the viewer always computed it, and
/// the deviation divides by n - 1 (one value gives NaN, as before).
public struct ROIValueStatistics: Equatable, Sendable {
    public let min: Double
    public let max: Double
    public let mean: Double
    public let total: Double
    public let deviation: Double

    public init(min: Double, max: Double, mean: Double, total: Double, deviation: Double) {
        self.min = min
        self.max = max
        self.mean = mean
        self.total = total
        self.deviation = deviation
    }

    /// The statistics of `values`; nil for none.
    public static func of(_ values: UnsafeBufferPointer<Float>) -> ROIValueStatistics? {
        guard let first = values.first else { return nil }

        var total = 0.0
        for value in values { total += Double(value) }
        let mean = total / Double(values.count)

        var deviation = 0.0
        var low = first, high = first
        for value in values {
            var distance = Float(mean - Double(value))
            distance *= distance
            deviation += Double(distance)
            if value < low { low = value }
            if value > high { high = value }
        }
        deviation = (deviation / Double(values.count - 1)).squareRoot()

        return ROIValueStatistics(min: Double(low), max: Double(high), mean: mean, total: total, deviation: deviation)
    }
}

/// The contour points of a volume's ROIs, handed to the surface renderer.
public enum ROIVolumePoints {
    /// The renderer is given at most about this many points.
    public static let displayLimit = 7000

    /// The indices of the points kept: every n-th from the first, n being
    /// `count / displayLimit`, once there are more than twice the limit; nil
    /// keeps them all.
    public static func keptIndices(count: Int) -> StrideTo<Int>? {
        guard count > displayLimit * 2 else { return nil }
        let step = count / displayLimit
        guard step > 1 else { return nil }
        return stride(from: 0, to: count, by: step)
    }
}
