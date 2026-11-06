//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The outline of an 8-bit mask (a brush ROI, a slice of a grown region), traced
// by VTK: the iso-line at 127.5, the middle of the 0/255 range, which lies on
// the pixels' boundaries, then VTK's connectivity filter (twice, as the app has
// always run it) keeping the largest region or all of them. The points come
// back in VTK's coordinates (pixel centres); in which order they make a
// polygon, and how many are kept, is the app's (IsiXSegmentation's
// ContourTracing). Only Objective-C and C types here.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The VTK filter that traces the iso-line.
typedef NS_ENUM(NSInteger, IsiXVTKContourTracer) {
    /// vtkMarchingSquares (the outline of a brush ROI).
    IsiXVTKContourTracerMarchingSquares = 0,
    /// vtkContourFilter (the polygons of a grown region).
    IsiXVTKContourTracerContourFilter = 1,
};

@interface IsiXVTKContour : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// The outline of the `width` x `height` bytes of `mask` (x fastest).
+ (nullable IsiXVTKContour *)traceMask:(const uint8_t *)mask
                                 width:(NSInteger)width
                                height:(NSInteger)height
                                tracer:(IsiXVTKContourTracer)tracer
                         largestRegion:(BOOL)largestRegion
                                 error:(NSError **)error
    NS_SWIFT_NAME(trace(_:width:height:tracer:largestRegion:));

/// The number of lines of the outline.
@property (readonly) NSInteger lineCount;
/// The number of points read: the first `lineCount` points of the outline, or
/// fewer when it has fewer.
@property (readonly) NSInteger pointCount;
/// The x and y of point `index` (below pointCount).
- (double)xAtIndex:(NSInteger)index NS_SWIFT_NAME(x(at:));
- (double)yAtIndex:(NSInteger)index NS_SWIFT_NAME(y(at:));

@end

NS_ASSUME_NONNULL_END
