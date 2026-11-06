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

/// How grayscale values in modality units, as plugins compute them, are
/// stored in a DICOM file the application can read again: signed 16-bit
/// samples and a Rescale Slope, the intercept 0.
public enum DerivedImageEncoding {
    /// The samples and the slope that give back `values`: exactly when every
    /// value is whole and from -32768 to 32767, the slope then 1; otherwise
    /// the largest magnitude is scaled to 32767, so each value comes back
    /// within half a step of the slope. With `slopeDecimals`, the slope is
    /// rounded up to that many decimals, as the file will write it, and the
    /// samples are those of the rounded slope. Values that are not finite
    /// are stored as 0.
    public static func signed16(_ values: [Float], slopeDecimals: Int? = nil) -> (samples: [Int16], slope: Double) {
        let finite = values.filter(\.isFinite)
        let whole = finite.allSatisfy { $0 == $0.rounded() && $0 >= -32768 && $0 <= 32767 }
        if whole {
            return (values.map { $0.isFinite ? Int16($0) : 0 }, 1)
        }
        let largest = finite.map { abs(Double($0)) }.max() ?? 0
        var slope = largest > 0 ? largest / 32767 : 1
        if let slopeDecimals {
            let scale = pow(10, Double(slopeDecimals))
            slope = max((slope * scale).rounded(.up), 1) / scale
        }
        let samples = values.map { value -> Int16 in
            guard value.isFinite else { return 0 }
            let scaled = (Double(value) / slope).rounded()
            return Int16(max(-32768, min(32767, scaled)))
        }
        return (samples, slope)
    }
}
