/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// The intensities inside a ROI, one `Float` per pixel, as the image hands
/// them over. The samples are borrowed: the caller keeps them alive and owns
/// them while the statistics are taken.
@objc(IsiXROIPixelSamples)
public final class ROIPixelSamples: NSObject {
    public let values: UnsafePointer<Float>?
    public let count: Int

    @objc(initWithValues:count:)
    public init(values: UnsafePointer<Float>?, count: Int) {
        self.values = values
        self.count = max(count, 0)
    }

    /// The samples as a buffer; empty when there are none.
    public var buffer: UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: values, count: values == nil ? 0 : count)
    }
}

/// Mean, sum, standard deviation, extremes, higher moments and median of the
/// intensities inside a ROI, as the ROI's label, the ROI manager and the
/// exports show them.
///
/// Sums run in `Double` and are handed back as `Float`, as they always were;
/// the deviation is the sample deviation (n - 1).
@objc(IsiXROIPixelStatistics)
public final class ROIPixelStatistics: NSObject {
    @objc public let count: Int
    @objc public let mean: Float
    @objc public let total: Float
    /// Zero for zero or one finite sample; NaN when a non-finite sample made the sum invalid.
    @objc public let deviation: Float
    /// Zero when there are no samples.
    @objc public let minimum: Float
    @objc public let maximum: Float
    /// Zero unless asked for.
    @objc public let skewness: Float
    @objc public let kurtosis: Float

    /// Takes the statistics of `samples`. The deviation pass runs only when
    /// `deviation` is asked for, the higher moments only with `higherMoments`.
    @objc(initWithSamples:deviation:higherMoments:)
    public init(samples: ROIPixelSamples, deviation wantsDeviation: Bool, higherMoments: Bool) {
        // The loops index the raw pointer: they run over every pixel of the
        // ROI, and a buffer's checked subscript is a call in a Debug build.
        let count = samples.buffer.count
        let values = samples.values ?? UnsafePointer(bitPattern: MemoryLayout<Float>.alignment)!
        var total = 0.0
        // Every sample is a Float, so the extremes compare as Floats: the same
        // answer as comparing their Double values.
        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude
        var i = 0
        while i < count {
            let value = values[i]
            total += Double(value)
            if value < minimum { minimum = value }
            if maximum < value { maximum = value }
            i += 1
        }
        let mean = count != 0 ? total / Double(count) : 0

        var deviation: Float = 0
        if wantsDeviation {
            var squares = 0.0
            i = 0
            while i < count {
                let delta = mean - Double(values[i])
                squares = squares.addingProduct(delta, delta)
                i += 1
            }
            // Keep the variance in double until after the square root: an
            // intermediate Float overflow or underflow must not corrupt a
            // representable deviation. One or no finite sample has no spread;
            // a non-finite sample keeps the result invalid.
            deviation = count > 1 ? Float((squares / Double(count - 1)).squareRoot()) : (squares.isFinite ? 0 : .nan)
        }

        self.count = count
        self.mean = Float(mean)
        self.total = Float(total)
        self.deviation = deviation
        self.minimum = minimum == .greatestFiniteMagnitude ? 0 : minimum
        self.maximum = maximum == -.greatestFiniteMagnitude ? 0 : maximum
        self.skewness = higherMoments ? Float(ROIPixelStatistics.skewness(of: samples, mean: mean)) : 0
        self.kurtosis = higherMoments ? Float(ROIPixelStatistics.kurtosis(of: samples, mean: mean)) : 0
    }

    /// The central moment of `order`, divided by n - 1; 0 for order 1.
    @objc(momentOfSamples:mean:order:)
    public static func moment(of samples: ROIPixelSamples, mean: Double, order: Int32) -> Double {
        guard let values = samples.values, order != 1 else { return 0 }
        let exponent = Double(order)
        var sum = 0.0
        var i = 0
        while i < samples.count {
            sum += pow(Double(values[i]) - mean, exponent)
            i += 1
        }
        return sum / Double(samples.count - 1)
    }

    /// The third central moment over the cube of the deviation.
    @objc(skewnessOfSamples:mean:)
    public static func skewness(of samples: ROIPixelSamples, mean: Double) -> Double {
        guard samples.values != nil, samples.count >= 2 else { return 0 }
        let m3 = moment(of: samples, mean: mean, order: 3)
        let sm2 = moment(of: samples, mean: mean, order: 2).squareRoot()
        return m3 / (sm2 * sm2 * sm2)
    }

    /// The fourth central moment over the fourth power of the deviation, less
    /// 3 so that a Gaussian has none.
    @objc(kurtosisOfSamples:mean:)
    public static func kurtosis(of samples: ROIPixelSamples, mean: Double) -> Double {
        guard samples.values != nil, samples.count >= 2 else { return 0 }
        let m4 = moment(of: samples, mean: mean, order: 4)
        let sm2 = moment(of: samples, mean: mean, order: 2).squareRoot()
        return (m4 / (sm2 * sm2 * sm2 * sm2)) - 3.0
    }

    /// The median of the finite samples; NaN when there is none. The samples
    /// are left in their order.
    @objc(medianOfSamples:)
    public static func median(of samples: ROIPixelSamples) -> Double {
        let finite = samples.buffer.filter { $0.isFinite }.sorted()
        guard !finite.isEmpty else { return .nan }
        let middle = finite.count / 2
        if finite.count % 2 == 1 { return Double(finite[middle]) }
        // Promote before adding so two large finite Float values cannot overflow.
        return (Double(finite[middle - 1]) + Double(finite[middle])) / 2
    }
}
