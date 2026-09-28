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

/// Additional statistics over the same intensity samples used by DCMPix.
@objc(HorosROIStatistics)
public final class ROIStatistics: NSObject {
    /// Ignores non-finite samples. NaN means no finite samples were available.
    /// The caller retains ownership and the input order/content is unchanged.
    @objc(medianOfValues:count:)
    public static func median(of values: UnsafePointer<Float>?, count: Int) -> Double {
        guard let values, count > 0 else { return .nan }
        let finite = UnsafeBufferPointer(start: values, count: count).filter { $0.isFinite }.sorted()
        guard !finite.isEmpty else { return .nan }
        let middle = finite.count / 2
        if finite.count % 2 == 1 { return Double(finite[middle]) }
        // Promote before adding so two large finite Float values cannot overflow.
        return (Double(finite[middle - 1]) + Double(finite[middle])) / 2
    }
}
