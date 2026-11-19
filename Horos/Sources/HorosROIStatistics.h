/*
 Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)

 This file is free software: you can redistribute it and/or modify it under the
 terms of the GNU Lesser General Public License as published by the Free
 Software Foundation, version 3 of the License.

 It is distributed in the hope that it will be useful, but WITHOUT ANY
 WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.
 */

#import <Foundation/Foundation.h>

/** \brief The median of the intensities inside a ROI

The class the image asked for the one statistic of a ROI it did not compute
itself, which the executable exported and the plugin SDK then declared: a
plugin built for that SDK finds the class by name and sends it this message.
The statistics of a ROI are those of IsiXROIPixelStatistics now, which this
class asks.

HorosROIStatistics.swift implements the class (@objc @implementation).
*/
@interface HorosROIStatistics : NSObject

// The median of the finite values; NaN when there is none, no value or no
// count. The values stay the caller's, in their order.
+ (double)medianOfValues:(const float * _Nullable)values count:(NSInteger)count;

@end
