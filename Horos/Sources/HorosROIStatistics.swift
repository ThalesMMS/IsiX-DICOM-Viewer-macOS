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
import IsiXROI

/// The implementation of HorosROIStatistics, declared in HorosROIStatistics.h:
/// the class a plugin built for the former SDK asks for the median of the
/// intensities inside a ROI. The median is the one the ROI's own statistics
/// take (ROIPixelStatistics, in IsiXROI).
@objc @implementation extension HorosROIStatistics {
    @objc(medianOfValues:count:)
    class func median(ofValues values: UnsafePointer<Float>?, count: Int) -> Double {
        ROIPixelStatistics.median(of: ROIPixelSamples(values: values, count: count))
    }
}
