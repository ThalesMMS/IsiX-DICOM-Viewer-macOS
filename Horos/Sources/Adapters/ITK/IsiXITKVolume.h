//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A volume of 32-bit floats as ITK sees it: ITK's import filter over voxels the
// app holds, with the size, origin and spacing ITK places them at. The region
// growing (IsiXITKRegionGrowing.h) and the resampling (IsiXITKResampler.h) run
// on it. Only Objective-C and C types here.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IsiXITKVolume : NSObject

/// The volume of `width` x `height` x `depth` floats at `voxels`, x fastest,
/// with the first voxel at `origin` and `spacing` between voxels (three
/// doubles each). ITK reads the voxels where they are: they must outlive the
/// volume, which keeps `owner` (an object that holds them, or nil) for that.
/// Sets ITK's default number of threads to the processor count.
- (nullable instancetype)initWithVoxels:(float *)voxels
                                  width:(NSInteger)width
                                 height:(NSInteger)height
                                  depth:(NSInteger)depth
                                 origin:(const double *)origin
                                spacing:(const double *)spacing
                                  owner:(nullable id)owner
                                  error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (readonly) NSInteger width;
@property (readonly) NSInteger height;
@property (readonly) NSInteger depth;

/// Places the first voxel at `origin` (three doubles) from now on.
- (BOOL)setOrigin:(const double *)origin error:(NSError **)error;

/// Where ITK places the first voxel, into `origin` (three doubles).
- (void)getOrigin:(double *)origin;

/// ITK's spacing between voxels, into `spacing` (three doubles).
- (void)getSpacing:(double *)spacing;

@end

NS_ASSUME_NONNULL_END
