//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import "IsiXITKRegionGrowing.h"
#import "IsiXITKInternal.hpp"

#include <itkCastImageFilter.h>
#include <itkConfidenceConnectedImageFilter.h>
#include <itkConnectedThresholdImageFilter.h>
#include <itkNeighborhoodConnectedImageFilter.h>

using IsiXITKCaster = itk::CastImageFilter<IsiXITKFloatImage, IsiXITKByteImage>;
using IsiXITKConnectedThreshold = itk::ConnectedThresholdImageFilter<IsiXITKFloatImage, IsiXITKFloatImage>;
using IsiXITKNeighborhoodConnected = itk::NeighborhoodConnectedImageFilter<IsiXITKFloatImage, IsiXITKFloatImage>;
using IsiXITKConfidenceConnected = itk::ConfidenceConnectedImageFilter<IsiXITKFloatImage, IsiXITKFloatImage>;

@implementation IsiXITKMask
{
    IsiXITKByteImage::Pointer _image;
}

- (instancetype)initWithImage:(IsiXITKByteImage::Pointer)image
{
    self = [super init];
    if (self) {
        _image = image;
        const IsiXITKByteImage::SizeType &size = image->GetLargestPossibleRegion().GetSize();
        _width = (NSInteger)size[0];
        _height = (NSInteger)size[1];
        _depth = (NSInteger)size[2];
    }
    return self;
}

- (uint8_t *)bytes
{
    return _image->GetBufferPointer();
}

@end

@implementation IsiXITKRegionGrowing

+ (IsiXITKMask *)growVolume:(IsiXITKVolume *)volume seedX:(long)x y:(long)y z:(long)z
                 parameters:(IsiXITKRegionGrowingParameters)parameters error:(NSError **)error
{
    IsiXITKMask *mask = nil;
    IsiXITKGuard(error, "IsiXITKRegionGrowing grow", [&]() -> NSError * {
        IsiXITKFloatImporter *importer = [volume importer];
        if (!importer) return IsiXITKFailure(IsiXITKErrorCodeInvalidArgument, @"no volume", "IsiXITKRegionGrowing grow");

        IsiXITKFloatImage::IndexType seed;
        seed[0] = x;
        seed[1] = y;
        seed[2] = z;

        // The filters live until the cast is up to date: an image does not
        // keep the filter that makes it.
        IsiXITKCaster::Pointer caster = IsiXITKCaster::New();
        IsiXITKConnectedThreshold::Pointer threshold;
        IsiXITKNeighborhoodConnected::Pointer neighborhood;
        IsiXITKConfidenceConnected::Pointer confidence;
        // The filter and its parameters, then the volume brought up to date
        // and set as its input, and the filter's floats cast to bytes.
        switch (parameters.filter) {
            case IsiXITKRegionGrowingFilterConnectedThreshold: {
                IsiXITKConnectedThreshold *filter = (threshold = IsiXITKConnectedThreshold::New()).GetPointer();
                filter->SetLower(parameters.lower);
                filter->SetUpper(parameters.upper);
                filter->SetReplaceValue(255);
                filter->SetSeed(seed);
                importer->Update();
                filter->SetInput(importer->GetOutput());
                caster->SetInput(filter->GetOutput());
                break;
            }
            case IsiXITKRegionGrowingFilterNeighborhoodConnected: {
                IsiXITKNeighborhoodConnected *filter = (neighborhood = IsiXITKNeighborhoodConnected::New()).GetPointer();
                filter->SetLower(parameters.lower);
                filter->SetUpper(parameters.upper);
                IsiXITKFloatImage::SizeType radius;
                radius[0] = parameters.radius;
                radius[1] = parameters.radius;
                radius[2] = parameters.radius;
                filter->SetRadius(radius);
                filter->SetReplaceValue(255);
                filter->SetSeed(seed);
                importer->Update();
                filter->SetInput(importer->GetOutput());
                caster->SetInput(filter->GetOutput());
                break;
            }
            case IsiXITKRegionGrowingFilterConfidenceConnected: {
                IsiXITKConfidenceConnected *filter = (confidence = IsiXITKConfidenceConnected::New()).GetPointer();
                filter->SetMultiplier(parameters.multiplier);
                filter->SetNumberOfIterations(parameters.iterations);
                filter->SetInitialNeighborhoodRadius(parameters.radius);
                filter->SetReplaceValue(255);
                filter->SetSeed(seed);
                importer->Update();
                filter->SetInput(importer->GetOutput());
                caster->SetInput(filter->GetOutput());
                break;
            }
            default:
                return IsiXITKFailure(IsiXITKErrorCodeInvalidArgument, @"no such filter", "IsiXITKRegionGrowing grow");
        }

        caster->Update();
        IsiXITKByteImage::Pointer image = caster->GetOutput();
        if (!image || !image->GetBufferPointer())
            return IsiXITKFailure(IsiXITKErrorCodeEmptyResult, @"the filter gave no image", "IsiXITKRegionGrowing grow");
        mask = [[IsiXITKMask alloc] initWithImage:image];
        return nil;
    });
    return mask;
}

@end
