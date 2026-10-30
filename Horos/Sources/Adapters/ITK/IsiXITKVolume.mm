//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import "IsiXITKInternal.hpp"

#include <itkMultiThreaderBase.h>

@implementation IsiXITKVolume
{
    IsiXITKFloatImporter::Pointer _importer;
    id _owner;
}

- (instancetype)initWithVoxels:(float *)voxels width:(NSInteger)width height:(NSInteger)height depth:(NSInteger)depth
                        origin:(const double *)origin spacing:(const double *)spacing owner:(id)owner error:(NSError **)error
{
    self = [super init];
    if (!self) return nil;
    if (!voxels || !origin || !spacing || width < 0 || height < 0 || depth < 0) {
        if (error) *error = IsiXITKFailure(IsiXITKErrorCodeInvalidArgument, @"no voxels, origin or spacing, or a negative size",
                                           "IsiXITKVolume init");
        return nil;
    }
    _width = width;
    _height = height;
    _depth = depth;
    _owner = owner;
    BOOL imported = IsiXITKGuard(error, "IsiXITKVolume init", [&]() -> NSError * {
        itk::MultiThreaderBase::SetGlobalDefaultNumberOfThreads((itk::ThreadIdType)NSProcessInfo.processInfo.processorCount);

        IsiXITKFloatImporter::SizeType size;
        size[0] = (itk::SizeValueType)width;
        size[1] = (itk::SizeValueType)height;
        size[2] = (itk::SizeValueType)depth;
        IsiXITKFloatImporter::IndexType start;
        start.Fill(0);
        IsiXITKFloatImporter::RegionType region;
        region.SetIndex(start);
        region.SetSize(size);

        IsiXITKFloatImporter::Pointer importer = IsiXITKFloatImporter::New();
        importer->SetRegion(region);
        importer->SetOrigin(origin);
        importer->SetSpacing(spacing);
        // The voxels stay the app's: the filter never frees them.
        importer->SetImportPointer(voxels, size[0] * size[1] * size[2], false);
        self->_importer = importer;
        return nil;
    });
    return imported ? self : nil;
}

- (IsiXITKFloatImporter *)importer
{
    return _importer.GetPointer();
}

- (BOOL)setOrigin:(const double *)origin error:(NSError **)error
{
    if (!origin) {
        if (error) *error = IsiXITKFailure(IsiXITKErrorCodeInvalidArgument, @"no origin", "IsiXITKVolume setOrigin");
        return NO;
    }
    return IsiXITKGuard(error, "IsiXITKVolume setOrigin", [&]() -> NSError * {
        self->_importer->SetOrigin(origin);
        return nil;
    });
}

- (void)getOrigin:(double *)origin
{
    const IsiXITKFloatImporter::OriginType &value = _importer->GetOrigin();
    for (int axis = 0; axis < 3; axis++) origin[axis] = value[axis];
}

- (void)getSpacing:(double *)spacing
{
    const IsiXITKFloatImporter::SpacingType &value = _importer->GetSpacing();
    for (int axis = 0; axis < 3; axis++) spacing[axis] = value[axis];
}

@end
