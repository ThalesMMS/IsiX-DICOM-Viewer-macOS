//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The region growing filters of ITK, from a seed in an IsiXITKVolume: connected
// threshold, neighborhood connected and confidence connected, each giving 255
// inside the grown region, cast to one byte per voxel. Which filter and which
// parameters is the app's decision (IsiXSegmentation); this only runs ITK.
// Only Objective-C and C types here.

#import <Foundation/Foundation.h>
#import "IsiXITKVolume.h"

NS_ASSUME_NONNULL_BEGIN

/// The ITK filter that grows the region.
typedef NS_ENUM(NSInteger, IsiXITKRegionGrowingFilter) {
    /// itk::ConnectedThresholdImageFilter: lower, upper.
    IsiXITKRegionGrowingFilterConnectedThreshold = 0,
    /// itk::NeighborhoodConnectedImageFilter: lower, upper, radius (every axis).
    IsiXITKRegionGrowingFilterNeighborhoodConnected = 1,
    /// itk::ConfidenceConnectedImageFilter: multiplier, iterations, radius (the initial neighbourhood).
    IsiXITKRegionGrowingFilterConfidenceConnected = 2,
};

/// A filter and its parameters; the fields the filter does not take are ignored.
typedef struct IsiXITKRegionGrowingParameters {
    IsiXITKRegionGrowingFilter filter;
    float lower;
    float upper;
    int radius;
    float multiplier;
    int iterations;
} IsiXITKRegionGrowingParameters;

/// The grown region: one byte per voxel of the volume, 255 inside, 0 outside,
/// x fastest. The bytes are ITK's and live as long as the mask.
@interface IsiXITKMask : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property (readonly) uint8_t *bytes;
@property (readonly) NSInteger width;
@property (readonly) NSInteger height;
@property (readonly) NSInteger depth;
@end

@interface IsiXITKRegionGrowing : NSObject

/// Grows the region of `volume` from the voxel (`x`, `y`, `z`) with `parameters`.
+ (nullable IsiXITKMask *)growVolume:(IsiXITKVolume *)volume
                              seedX:(long)x
                                  y:(long)y
                                  z:(long)z
                         parameters:(IsiXITKRegionGrowingParameters)parameters
                              error:(NSError **)error
    NS_SWIFT_NAME(grow(_:seedX:y:z:parameters:));

@end

NS_ASSUME_NONNULL_END
