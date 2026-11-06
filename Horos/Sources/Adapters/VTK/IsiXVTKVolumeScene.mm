//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import "IsiXVTKVolumeScene.hpp"
#import "IsiXVTKInternal.hpp"

#include "vtkHorosFixedPointVolumeRayCastMapper.h"
#include <vtkCamera.h>
#include <vtkColorTransferFunction.h>
#include <vtkFixedPointRayCastImage.h>
#include <vtkImageData.h>
#include <vtkImageImport.h>
#include <vtkLight.h>
#include <vtkLightCollection.h>
#include <vtkMatrix4x4.h>
#include <vtkPiecewiseFunction.h>
#include <vtkRenderWindow.h>
#include <vtkRenderer.h>
#include <vtkVolume.h>
#include <vtkVolumeProperty.h>

#include <vector>

@implementation IsiXVTKComponentTable

- (instancetype)initWithComponent:(NSInteger)component weight:(double)weight shift:(float)shift scale:(float)scale
                             size:(NSInteger)size opacity:(NSData *)opacity colour:(NSData *)colour
{
    if ((self = [super init])) {
        _component = component;
        _weight = weight;
        _shift = shift;
        _scale = scale;
        _size = size;
        _opacity = opacity;
        _colour = colour;
    }
    return self;
}

@end

@implementation IsiXVTKVolumeScene
{
    IsiXVTKVolumeSceneObjects _objects;
}

- (instancetype)initWithObjects:(const IsiXVTKVolumeSceneObjects &)objects
{
    if ((self = [super init])) {
        _objects = objects;
    }
    return self;
}

- (BOOL)hasRenderer { return _objects.renderer != nullptr; }
- (BOOL)hasCamera { return _objects.camera != nullptr; }
- (BOOL)hasMapper { return _objects.mapper != nullptr; }
- (BOOL)hasVolume { return _objects.volume != nullptr; }
- (BOOL)hasProperty { return _objects.property != nullptr; }
- (BOOL)hasColourFunction { return _objects.colour != nullptr; }
- (BOOL)hasOpacityFunction { return _objects.opacity != nullptr; }
- (BOOL)hasImporter { return _objects.importer != nullptr; }

static NSError *IsiXVTKMissing(const char *what, const char *operation)
{
    return IsiXVTKFailure(IsiXVTKErrorCodeUnavailable, [NSString stringWithFormat:@"The 3D view has no %s yet.", what], operation);
}

- (BOOL)readCamera:(IsiXVTKCameraState *)state error:(NSError *__autoreleasing *)error
{
    vtkCamera *camera = _objects.camera;
    vtkRenderWindow *window = _objects.window;
    return IsiXVTKGuard(error, "IsiXVTKVolumeScene readCamera", {camera, window}, [&]() -> NSError * {
        if (!camera) return IsiXVTKMissing("camera", "IsiXVTKVolumeScene readCamera");
        *state = IsiXVTKCameraState();
        camera->GetPosition(state->position);
        camera->GetFocalPoint(state->focalPoint);
        camera->GetViewUp(state->viewUp);
        state->parallelProjection = camera->GetParallelProjection() ? YES : NO;
        state->parallelScale = camera->GetParallelScale();
        state->viewAngle = camera->GetViewAngle();
        state->eyeAngle = camera->GetEyeAngle();
        state->leftEye = camera->GetLeftEye() ? YES : NO;
        camera->GetWindowCenter(state->windowCenter);
        camera->GetClippingRange(state->clippingRange);
        state->stereoRender = window && window->GetStereoRender() ? YES : NO;
        return nil;
    });
}

- (BOOL)readSampling:(IsiXVTKVolumeSampling *)sampling error:(NSError *__autoreleasing *)error
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = _objects.mapper;
    vtkVolumeProperty *property = _objects.property;
    return IsiXVTKGuard(error, "IsiXVTKVolumeScene readSampling", {mapper, property}, [&]() -> NSError * {
        if (!property) return IsiXVTKMissing("volume property", "IsiXVTKVolumeScene readSampling");
        *sampling = IsiXVTKVolumeSampling();
        sampling->shade = property->GetShade() ? YES : NO;
        sampling->ambient = property->GetAmbient();
        sampling->diffuse = property->GetDiffuse();
        sampling->specular = property->GetSpecular();
        sampling->specularPower = property->GetSpecularPower();
        for (int c = 0; c < 4; ++c) sampling->componentWeight[c] = property->GetComponentWeight(c);
        if (mapper) {
            sampling->sampleDistance = mapper->GetSampleDistance();
            sampling->minimumImageSampleDistance = mapper->GetMinimumImageSampleDistance();
            sampling->cropping = mapper->GetCropping() ? YES : NO;
            sampling->croppingSubvolume = mapper->GetCroppingRegionFlags() == VTK_CROP_SUBVOLUME ? YES : NO;
            mapper->GetCroppingRegionPlanes(sampling->croppingRegionPlanes);
            if (vtkImageData *input = vtkImageData::SafeDownCast(mapper->GetInput())) {
                sampling->hasInput = YES;
                input->GetOrigin(sampling->inputOrigin);
                input->GetSpacing(sampling->inputSpacing);
            }
        }
        return nil;
    });
}

- (BOOL)readPlacement:(IsiXVTKVolumePlacement *)placement error:(NSError *__autoreleasing *)error
{
    vtkImageImport *importer = _objects.importer;
    vtkVolume *volume = _objects.volume;
    return IsiXVTKGuard(error, "IsiXVTKVolumeScene readPlacement", {importer, volume}, [&]() -> NSError * {
        if (!volume) return IsiXVTKMissing("volume", "IsiXVTKVolumeScene readPlacement");
        *placement = IsiXVTKVolumePlacement();
        if (vtkImageData *output = importer ? importer->GetOutput() : nullptr) {
            placement->hasImporterOutput = YES;
            output->GetOrigin(placement->origin);
            output->GetSpacing(placement->spacing);
        }
        vtkMatrix4x4 *matrix = volume->GetMatrix();
        for (int row = 0; row < 4; ++row)
            for (int column = 0; column < 4; ++column) placement->matrix[4 * row + column] = matrix->GetElement(row, column);
        return nil;
    });
}

- (BOOL)enumerateLightsUsingBlock:(void (NS_NOESCAPE ^)(BOOL, double, const double *))block error:(NSError *__autoreleasing *)error
{
    vtkRenderer *renderer = _objects.renderer;
    return IsiXVTKGuard(error, "IsiXVTKVolumeScene enumerateLights", {renderer}, [&]() -> NSError * {
        if (!renderer) return nil;
        vtkCollectionSimpleIterator it;
        vtkLight *light = nullptr;
        vtkLightCollection *lights = renderer->GetLights();
        for (lights->InitTraversal(it); (light = lights->GetNextLight(it)); ) {
            double colour[3];
            light->GetAmbientColor(colour);
            block(light->GetSwitch() ? YES : NO, light->GetIntensity(), colour);
        }
        return nil;
    });
}

- (IsiXVTKGeometryRefusal)prepareGeometryAcceptingClippingPlanes:(BOOL)accept error:(NSError *__autoreleasing *)error
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = _objects.mapper;
    vtkRenderer *renderer = _objects.renderer;
    vtkVolume *volume = _objects.volume;
    IsiXVTKGeometryRefusal refusal = IsiXVTKGeometryRefusalAccepted;
    BOOL ran = IsiXVTKGuard(error, "IsiXVTKVolumeScene prepareGeometry", {mapper, renderer, volume}, [&]() -> NSError * {
        if (!mapper || !renderer || !volume) return IsiXVTKMissing("volume", "IsiXVTKVolumeScene prepareGeometry");
        if (!mapper->PrepareMPRGeometry(renderer, volume, accept)) refusal = (IsiXVTKGeometryRefusal)mapper->GetGeometryRefusal();
        return nil;
    });
    if (ran) {
        if (error) *error = nil;
    } else refusal = IsiXVTKGeometryRefusalNoInput;
    return refusal;
}

- (IsiXVTKGeometryRefusal)lastGeometryRefusal
{
    return _objects.mapper ? (IsiXVTKGeometryRefusal)_objects.mapper->GetGeometryRefusal() : IsiXVTKGeometryRefusalNoInput;
}

- (NSData *)voxelClippingPlanesWithError:(NSError *__autoreleasing *)error
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = _objects.mapper;
    NSData *planes = nil;
    IsiXVTKGuard(error, "IsiXVTKVolumeScene voxelClippingPlanes", {mapper}, [&]() -> NSError * {
        const float *values = nullptr;
        int count = mapper ? mapper->GetVoxelClippingPlanes(&values) : 0;
        planes = count > 0 && values ? [NSData dataWithBytes:values length:(NSUInteger)count * 4 * sizeof(float)] : [NSData data];
        return nil;
    });
    return planes;
}

- (NSData *)geometryDepthWithWorldUnitsPerMillimetre:(double)factor error:(NSError *__autoreleasing *)error
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = _objects.mapper;
    vtkRenderer *renderer = _objects.renderer;
    NSData *depth = nil;
    IsiXVTKGuard(error, "IsiXVTKVolumeScene geometryDepth", {mapper, renderer}, [&]() -> NSError * {
        if (!mapper || !renderer) return IsiXVTKMissing("volume", "IsiXVTKVolumeScene geometryDepth");
        std::vector<float> values = mapper->CaptureGeometryDepth(renderer, factor);
        depth = values.empty() ? [NSData data] : [NSData dataWithBytes:values.data() length:values.size() * sizeof(float)];
        return nil;
    });
    return depth;
}

static IsiXVTKRayCastImageInfo IsiXVTKImageInfo(vtkFixedPointRayCastImage *image)
{
    IsiXVTKRayCastImageInfo info = {};
    int *memory = image->GetImageMemorySize(), *viewport = image->GetImageViewportSize();
    int *origin = image->GetImageOrigin(), *used = image->GetImageInUseSize();
    info.memoryWidth = memory[0]; info.memoryHeight = memory[1];
    info.viewportWidth = viewport[0]; info.viewportHeight = viewport[1];
    info.originX = origin[0]; info.originY = origin[1];
    info.usedWidth = used[0]; info.usedHeight = used[1];
    return info;
}

- (BOOL)readRayCastImage:(IsiXVTKRayCastImageInfo *)info error:(NSError *__autoreleasing *)error
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = _objects.mapper;
    return IsiXVTKGuard(error, "IsiXVTKVolumeScene readRayCastImage", {mapper}, [&]() -> NSError * {
        if (!mapper || !mapper->GetRayCastImage()) return IsiXVTKMissing("volume", "IsiXVTKVolumeScene readRayCastImage");
        *info = IsiXVTKImageInfo(mapper->GetRayCastImage());
        return nil;
    });
}

- (BOOL)accessRayCastImage:(void (NS_NOESCAPE ^)(uint16_t *, IsiXVTKRayCastImageInfo))block error:(NSError *__autoreleasing *)error
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = _objects.mapper;
    return IsiXVTKGuard(error, "IsiXVTKVolumeScene accessRayCastImage", {mapper}, [&]() -> NSError * {
        vtkFixedPointRayCastImage *image = mapper ? mapper->GetRayCastImage() : nullptr;
        if (!image) return IsiXVTKMissing("volume", "IsiXVTKVolumeScene accessRayCastImage");
        block(image->GetImage(), IsiXVTKImageInfo(image));
        return nil;
    });
}

- (BOOL)initializeVolumeTablesWithError:(NSError *__autoreleasing *)error
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = _objects.mapper;
    vtkRenderer *renderer = _objects.renderer;
    vtkVolume *volume = _objects.volume;
    return IsiXVTKGuard(error, "IsiXVTKVolumeScene initializeVolumeTables", {mapper, renderer, volume}, [&]() -> NSError * {
        if (!mapper || !renderer || !volume) return IsiXVTKMissing("volume", "IsiXVTKVolumeScene initializeVolumeTables");
        mapper->PerVolumeInitialization(renderer, volume);
        return nil;
    });
}

- (NSArray<IsiXVTKComponentTable *> *)componentTablesWithError:(NSError *__autoreleasing *)error
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = _objects.mapper;
    vtkVolumeProperty *property = _objects.property;
    NSMutableArray<IsiXVTKComponentTable *> *tables = nil;
    BOOL read = IsiXVTKGuard(error, "IsiXVTKVolumeScene componentTables", {mapper, property}, [&]() -> NSError * {
        if (!mapper || !property) return IsiXVTKMissing("volume", "IsiXVTKVolumeScene componentTables");
        float *shift = mapper->GetTableShift(), *scale = mapper->GetTableScale();
        tables = [NSMutableArray arrayWithCapacity:4];
        for (int c = 0; c < 4; ++c) {
            int size = mapper->GetTableSize(c);
            unsigned short *opacity = mapper->GetScalarOpacityTable(c), *colour = mapper->GetColorTable(c);
            BOOL ready = size > 0 && opacity && colour;
            [tables addObject:[[IsiXVTKComponentTable alloc]
                initWithComponent:c weight:property->GetComponentWeight(c) shift:shift[c] scale:scale[c] size:size
                          opacity:ready ? [NSData dataWithBytes:opacity length:(NSUInteger)size * sizeof(unsigned short)] : nil
                           colour:ready ? [NSData dataWithBytes:colour length:(NSUInteger)size * 3 * sizeof(unsigned short)] : nil]];
        }
        return nil;
    });
    return read ? tables : nil;
}

/// `count` × `width` doubles that `evaluate` fills, with VTK's errors for
/// `objects` captured; nil with the error for a count VTK cannot take.
template <typename Evaluate>
static NSData *IsiXVTKTable(NSError *__autoreleasing *error, const char *operation,
                            std::initializer_list<vtkObject *> objects, NSInteger count, int width, Evaluate &&evaluate)
{
    if (count <= 0 || count > (1 << 24)) {
        if (error) *error = IsiXVTKFailure(IsiXVTKErrorCodeInvalidArgument, @"A table needs between 1 and 2^24 entries.", operation);
        return nil;
    }
    NSMutableData *values = [NSMutableData dataWithLength:(NSUInteger)count * width * sizeof(double)];
    BOOL made = IsiXVTKGuard(error, operation, objects, [&]() -> NSError * {
        return evaluate((double *)values.mutableBytes, (int)count);
    });
    return made ? values : nil;
}

- (NSData *)componentColourTable:(NSInteger)component from:(double)from to:(double)to count:(NSInteger)count
                           error:(NSError *__autoreleasing *)error
{
    const char *operation = "IsiXVTKVolumeScene componentColourTable";
    vtkVolumeProperty *property = _objects.property;
    return IsiXVTKTable(error, operation, {property}, count, 3, [&](double *values, int entries) -> NSError * {
        if (!property) return IsiXVTKMissing("volume property", operation);
        if (component < 0 || component > 3)
            return IsiXVTKFailure(IsiXVTKErrorCodeInvalidArgument, @"The volume has no such component.", operation);
        property->GetRGBTransferFunction((int)component)->GetTable(from, to, entries, values);
        return nil;
    });
}

- (NSData *)componentOpacityTable:(NSInteger)component from:(double)from to:(double)to count:(NSInteger)count
                            error:(NSError *__autoreleasing *)error
{
    const char *operation = "IsiXVTKVolumeScene componentOpacityTable";
    vtkVolumeProperty *property = _objects.property;
    return IsiXVTKTable(error, operation, {property}, count, 1, [&](double *values, int entries) -> NSError * {
        if (!property) return IsiXVTKMissing("volume property", operation);
        if (component < 0 || component > 3)
            return IsiXVTKFailure(IsiXVTKErrorCodeInvalidArgument, @"The volume has no such component.", operation);
        property->GetScalarOpacity((int)component)->GetTable(from, to, entries, values);
        return nil;
    });
}

- (NSData *)colourTableFrom:(double)from to:(double)to count:(NSInteger)count error:(NSError *__autoreleasing *)error
{
    const char *operation = "IsiXVTKVolumeScene colourTable";
    vtkColorTransferFunction *function = _objects.colour;
    return IsiXVTKTable(error, operation, {function}, count, 3, [&](double *values, int entries) -> NSError * {
        if (!function) return IsiXVTKMissing("colour function", operation);
        function->GetTable(from, to, entries, values);
        return nil;
    });
}

- (NSData *)opacityTableFrom:(double)from to:(double)to count:(NSInteger)count error:(NSError *__autoreleasing *)error
{
    const char *operation = "IsiXVTKVolumeScene opacityTable";
    vtkPiecewiseFunction *function = _objects.opacity;
    return IsiXVTKTable(error, operation, {function}, count, 1, [&](double *values, int entries) -> NSError * {
        if (!function) return IsiXVTKMissing("opacity function", operation);
        function->GetTable(from, to, entries, values);
        return nil;
    });
}

@end

IsiXVTKVolumeScene *IsiXVTKMakeVolumeScene(const IsiXVTKVolumeSceneObjects &objects)
{
    return [[IsiXVTKVolumeScene alloc] initWithObjects:objects];
}
