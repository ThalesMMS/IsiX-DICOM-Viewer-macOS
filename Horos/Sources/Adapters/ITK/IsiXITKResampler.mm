//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import "IsiXITKResampler.h"
#import "IsiXITKInternal.hpp"

#include <itkAffineTransform.h>
#include <itkResampleImageFilter.h>

#include <cstring>

using IsiXITKAffineTransform = itk::AffineTransform<double, 3>;
using IsiXITKResampleFilter = itk::ResampleImageFilter<IsiXITKFloatImage, IsiXITKFloatImage>;

@implementation IsiXITKResampler

+ (BOOL)resampleVolume:(IsiXITKVolume *)volume parameters:(const double *)parameters origin:(const double *)origin
               spacing:(const double *)spacing size:(const NSInteger *)size defaultValue:(float)defaultValue
                  into:(float *)output length:(size_t)length error:(NSError **)error
{
    if (!parameters || !origin || !spacing || !size || !output || size[0] < 0 || size[1] < 0 || size[2] < 0) {
        if (error) *error = IsiXITKFailure(IsiXITKErrorCodeInvalidArgument, @"no parameters, grid or output, or a negative size",
                                           "IsiXITKResampler resample");
        return NO;
    }
    return IsiXITKGuard(error, "IsiXITKResampler resample", [&]() -> NSError * {
        IsiXITKFloatImporter *importer = [volume importer];
        if (!importer) return IsiXITKFailure(IsiXITKErrorCodeInvalidArgument, @"no volume", "IsiXITKResampler resample");

        IsiXITKAffineTransform::Pointer transform = IsiXITKAffineTransform::New();
        IsiXITKAffineTransform::ParametersType values(transform->GetNumberOfParameters());
        for (unsigned int index = 0; index < transform->GetNumberOfParameters(); index++) values[index] = parameters[index];
        transform->SetParameters(values);

        IsiXITKResampleFilter::Pointer resample = IsiXITKResampleFilter::New();
        resample->SetTransform(transform);
        resample->SetInput(importer->GetOutput());
        resample->SetDefaultPixelValue(defaultValue);
        resample->SetOutputSpacing(spacing);
        resample->SetOutputOrigin(origin);
        IsiXITKFloatImage::SizeType grid;
        grid[0] = (itk::SizeValueType)size[0];
        grid[1] = (itk::SizeValueType)size[1];
        grid[2] = (itk::SizeValueType)size[2];
        resample->SetSize(grid);

        resample->Update();

        const float *result = resample->GetOutput()->GetBufferPointer();
        size_t available = (size_t)size[0] * (size_t)size[1] * (size_t)size[2] * sizeof(float);
        if (!result || length > available)
            return IsiXITKFailure(IsiXITKErrorCodeEmptyResult, @"the resampled volume is smaller than asked", "IsiXITKResampler resample");
        memcpy(output, result, length);
        return nil;
    });
}

@end
