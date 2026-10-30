//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// ITK's resampling of an IsiXITKVolume through an affine transform, onto the
// grid the app chooses (IsiXSegmentation's AffineResampleGrid), with ITK's
// default (linear) interpolation. Only Objective-C and C types here.

#import <Foundation/Foundation.h>
#import "IsiXITKVolume.h"

NS_ASSUME_NONNULL_BEGIN

@interface IsiXITKResampler : NSObject

/// Resamples `volume` through the itk::AffineTransform<double, 3> of the 12
/// `parameters` (the matrix by rows, then the translation) onto the grid of
/// `size` voxels (three integers) from `origin` with `spacing` (three doubles
/// each); voxels the transform takes outside the volume get `defaultValue`.
/// Copies the first `length` bytes of the result to `output`.
+ (BOOL)resampleVolume:(IsiXITKVolume *)volume
            parameters:(const double *)parameters
                origin:(const double *)origin
               spacing:(const double *)spacing
                  size:(const NSInteger *)size
          defaultValue:(float)defaultValue
                  into:(float *)output
                length:(size_t)length
                 error:(NSError **)error
    NS_SWIFT_NAME(resample(_:parameters:origin:spacing:size:defaultValue:into:length:));

@end

NS_ASSUME_NONNULL_END
