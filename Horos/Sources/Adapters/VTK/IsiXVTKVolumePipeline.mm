//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The volume rendering view's pipeline: the importers, the ray casters, the
// properties and transfer functions of the volume and of a fused series, the
// full-depth capture and the preset previews' own pipeline
// (IsiXVTKVolumeView.h). The calls are the view's, in the view's order.

#import "IsiXVTKVolumeViewInternal.hpp"

#import "vtkHorosFixedPointVolumeRayCastMapper.h"
#include "../../VRImageImport.h"

#include <vtkActor.h>
#include <vtkActor2D.h>
#include <vtkCamera.h>
#include <vtkCellArray.h>
#include <vtkColorTransferFunction.h>
#include <vtkDoubleArray.h>
#include <vtkFixedPointRayCastImage.h>
#include <vtkImageData.h>
#include <vtkImageImport.h>
#include <vtkMatrix4x4.h>
#include <vtkOutlineFilter.h>
#include <vtkPiecewiseFunction.h>
#include <vtkPlane.h>
#include <vtkPlaneCollection.h>
#include <vtkPlanes.h>
#include <vtkPoints.h>
#include <vtkPolyData.h>
#include <vtkPolyDataMapper.h>
#include <vtkPolyDataMapper2D.h>
#include <vtkProperty.h>
#include <vtkRegularPolygonSource.h>
#include <vtkRenderWindow.h>
#include <vtkTextActor.h>
#include <vtkTextProperty.h>
#include <vtkTransform.h>
#include <vtkVolume.h>
#include <vtkVolumeProperty.h>

/// The matrix of a volume of `cosines`, the image's row, column and normal
/// directions in its columns.
static vtkMatrix4x4 *IsiXVTKVolumeMatrix(const float *cosines)
{
    vtkMatrix4x4 *matrice = vtkMatrix4x4::New();
    matrice->Element[0][0] = cosines[0];		matrice->Element[1][0] = cosines[1];		matrice->Element[2][0] = cosines[2];		matrice->Element[3][0] = 0;
    matrice->Element[0][1] = cosines[3];		matrice->Element[1][1] = cosines[4];		matrice->Element[2][1] = cosines[5];		matrice->Element[3][1] = 0;
    matrice->Element[0][2] = cosines[6];		matrice->Element[1][2] = cosines[7];		matrice->Element[2][2] = cosines[8];		matrice->Element[3][2] = 0;
    matrice->Element[0][3] = 0;					matrice->Element[1][3] = 0;					matrice->Element[2][3] = 0;					matrice->Element[3][3] = 1;
    return matrice;
}

@implementation IsiXVTKVolumeTransform
{
    vtkTransform *_transform;
}

- (instancetype)initWithVolume:(vtkVolume *)volume
{
    if ((self = [super init])) {
        _transform = vtkTransform::New();
        _transform->SetMatrix(volume->GetUserMatrix());
        _transform->Push();
    }
    return self;
}

- (void)dealloc
{
    _transform->Delete();
}

- (void)transformFloatPoint:(const float *)point into:(float *)result
{
    IsiXVTKVolumeRun("transformPoint", {}, [&] { _transform->TransformPoint(point, result); });
}

- (void)inverseTransformFloatPoint:(const float *)point into:(float *)result
{
    IsiXVTKVolumeRun("inverseTransformPoint", {}, [&] {
        _transform->Inverse();
        _transform->TransformPoint(point, result);
        _transform->Inverse();
    });
}

- (void)transformDoublePoint:(const double *)point into:(double *)result
{
    IsiXVTKVolumeRun("transformPoint", {}, [&] { _transform->TransformPoint(point, result); });
}

- (void)inverseTransformDoublePoint:(const double *)point into:(double *)result
{
    IsiXVTKVolumeRun("inverseTransformPoint", {}, [&] {
        _transform->Inverse();
        _transform->TransformPoint(point, result);
        _transform->Inverse();
    });
}

@end

@implementation IsiXVTKVolumeView (IsiXVTKVolumePipeline)

#pragma mark Importer

- (BOOL)importVolume:(void *)voxels rgb:(BOOL)rgb width:(long)width height:(long)height depth:(long)depth
               error:(NSError **)error
{
    IsiXVTKVolumeViewObjects *o = _o;
    return IsiXVTKGuard(error, "importVolume", {}, [&]() -> NSError * {
        o->reader = HorosVRImageImport::New();
        IsiXVTKErrorCapture capture({o->reader}, "importVolume");
        if (rgb) {
            o->reader->SetImportVoidPointer(voxels);
            o->reader->SetWholeExtent(0, width-1, 0, height-1, 0, depth-1);
            o->reader->SetDataExtentToWholeExtent();
            o->reader->SetDataScalarTypeToUnsignedChar();
            o->reader->SetNumberOfScalarComponents( 4);
        } else {
            o->reader->SetImportVoidPointer(voxels);
            o->reader->SetWholeExtent( 0, width-1, 0, height-1, 0, depth-1);
            o->reader->SetDataExtentToWholeExtent();
            o->reader->SetDataScalarTypeToUnsignedShort();
            o->reader->SetNumberOfScalarComponents( 1);
        }
        o->reader->Update();
        return capture.Error();
    });
}

- (void)setImportSpacingX:(double)x y:(double)y z:(double)z
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->reader) return;
    IsiXVTKVolumeRun("setImportSpacing", {o->reader}, [&] { o->reader->SetDataSpacing(x, y, z); });
}

- (void)setImportVoxels:(void *)voxels
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->reader) return;
    IsiXVTKVolumeRun("setImportVoxels", {o->reader}, [&] {
        o->reader->SetImportVoidPointer(voxels);
        o->reader->GetOutput()->Modified();
    });
}

- (void)markImportModified
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->reader) return;
    IsiXVTKVolumeRun("markImportModified", {o->reader}, [&] {
        o->reader->GetOutput()->Modified();
        o->reader->Modified();
    });
}

- (BOOL)updateImportWithError:(NSError **)error
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->reader) return YES;
    return IsiXVTKVolumeTry(error, "updateImport", {o->reader}, [&] { o->reader->Update(); });
}

#pragma mark Transfer functions and the volume

- (BOOL)makeTransferFunctionsRGB:(BOOL)rgb invertedPolarity:(BOOL)inverted opacityAdapter:(float)opacityAdapter
                           error:(NSError **)error
{
    IsiXVTKVolumeViewObjects *o = _o;
    return IsiXVTKVolumeTry(error, "makeTransferFunctions", {}, [&] {
        o->opacityTransferFunction = vtkPiecewiseFunction::New();
        o->opacityTransferFunction->AddPoint(0, 0);
        o->opacityTransferFunction->AddPoint(255., 1. / opacityAdapter);

        o->colorTransferFunction = vtkColorTransferFunction::New();

        if (inverted) {
            o->red = vtkColorTransferFunction::New();
            o->red->AddRGBPoint( 255, 1, 0, 0 );
            o->red->AddRGBPoint(   0, 0, 0, 0 );

            o->green = vtkColorTransferFunction::New();
            o->green->AddRGBPoint( 255, 0, 1, 0 );
            o->green->AddRGBPoint(   0, 0, 0, 0 );

            o->blue = vtkColorTransferFunction::New();
            o->blue->AddRGBPoint( 255, 0, 0, 1 );
            o->blue->AddRGBPoint(   0, 0, 0, 0 );
        } else {
            o->red = vtkColorTransferFunction::New();
            o->red->AddRGBPoint(   0, 0, 0, 0 );
            o->red->AddRGBPoint( 255, 1, 0, 0 );

            o->green = vtkColorTransferFunction::New();
            o->green->AddRGBPoint(   0, 0, 0, 0 );
            o->green->AddRGBPoint( 255, 0, 1, 0 );

            o->blue = vtkColorTransferFunction::New();
            o->blue->AddRGBPoint(   0, 0, 0, 0 );
            o->blue->AddRGBPoint( 255, 0, 0, 1 );
        }

        o->volumeProperty = vtkVolumeProperty::New();
        if (rgb) {
            o->volumeProperty->IndependentComponentsOn();

            o->volumeProperty->SetColor( 1,o->red);
            o->volumeProperty->SetColor( 2,o->green);
            o->volumeProperty->SetColor( 3,o->blue);

            o->volumeProperty->SetScalarOpacity( 1, o->opacityTransferFunction);
            o->volumeProperty->SetScalarOpacity( 2, o->opacityTransferFunction);
            o->volumeProperty->SetScalarOpacity( 3, o->opacityTransferFunction);

            o->volumeProperty->SetComponentWeight( 0, 0);
        } else {
            o->volumeProperty->SetColor( o->colorTransferFunction);
            o->volumeProperty->SetScalarOpacity( o->opacityTransferFunction);
        }
    });
}

- (BOOL)makeVolumeNearest:(BOOL)nearest cosines:(const float *)cosines factor:(float)factor
                  originX:(double)x y:(double)y z:(double)z error:(NSError **)error
{
    IsiXVTKVolumeViewObjects *o = _o;
    return IsiXVTKVolumeTry(error, "makeVolume", {}, [&] {
        if (nearest) o->volumeProperty->SetInterpolationTypeToNearest();
        else o->volumeProperty->SetInterpolationTypeToLinear();

        o->volume = vtkVolume::New();
        o->volume->SetProperty( o->volumeProperty);

        vtkMatrix4x4 *matrice = IsiXVTKVolumeMatrix(cosines);

        o->volume->SetPosition(	factor*x * matrice->Element[0][0] + factor*y * matrice->Element[1][0] + factor*z*matrice->Element[2][0],
                            factor*x * matrice->Element[0][1] + factor*y * matrice->Element[1][1] + factor*z*matrice->Element[2][1],
                            factor*x * matrice->Element[0][2] + factor*y * matrice->Element[1][2] + factor*z*matrice->Element[2][2]);
        o->volume->SetUserMatrix( matrice);
        matrice->Delete();

        o->volume->PickableOff();

        IsiXVTKErrorCapture capture({o->reader}, "makeVolume");
        o->outlineData = vtkOutlineFilter::New();
        o->outlineData->SetInputConnection(o->reader->GetOutputPort());
        o->outlineData->Update();

        o->mapOutline = vtkPolyDataMapper::New();
        o->mapOutline->SetInputConnection(o->outlineData->GetOutputPort());
        o->mapOutline->Update();

        o->outlineRect = vtkActor::New();
        o->outlineRect->SetMapper(o->mapOutline);
        o->outlineRect->GetProperty()->SetColor(0,1,0);
        o->outlineRect->GetProperty()->SetOpacity(0.5);
        o->outlineRect->SetUserMatrix( matrice);
        o->outlineRect->SetPosition(	factor*x * matrice->Element[0][0] + factor*y * matrice->Element[1][0] + factor*z*matrice->Element[2][0],
                                 factor*x * matrice->Element[0][1] + factor*y * matrice->Element[1][1] + factor*z*matrice->Element[2][1],
                                 factor*x * matrice->Element[0][2] + factor*y * matrice->Element[1][2] + factor*z*matrice->Element[2][2]);
        o->outlineRect->PickableOff();
        if (capture.Error()) IsiXVTKLogFailure(capture.Error());
    });
}

- (BOOL)makeCropBoxWithError:(NSError **)error
{
    IsiXVTKVolumeViewObjects *o = _o;
    HorosVRInteractor *interactor = [self interactor];
    return IsiXVTKVolumeTry(error, "makeCropBox", {}, [&] {
        o->croppingBox = HorosBoxWidget::New();

        o->croppingBox->GetHandleProperty()->SetColor(0, 1, 0);
        o->croppingBox->SetProp3D( o->volume);
        o->croppingBox->SetPlaceFactor( 1.0);
        o->croppingBox->SetHandleSize( 0.005);
        o->croppingBox->PlaceWidget();
        o->croppingBox->SetInteractor( interactor);
        o->croppingBox->SetRotationEnabled( true);
        o->croppingBox->SetInsideOut( true);
        o->croppingBox->OutlineCursorWiresOff();

        o->croppingBox->SetDefaultRenderer( o->aRenderer);

        o->cropcallback = IsiXVTKCropCallback::New();
        o->cropcallback->SetBlendingVolume( nullptr);
        o->croppingBox->AddObserver(vtkCommand::InteractionEvent, o->cropcallback);
    });
}

- (BOOL)makeTextsWithWindowText:(const char *)windowText corner:(BOOL)corner tilt:(NSString *)tilt error:(NSError **)error
{
    IsiXVTKVolumeViewObjects *o = _o;
    return IsiXVTKVolumeTry(error, "makeTexts", {}, [&] {
        o->textWLWW = vtkTextActor::New();
        o->textWLWW->SetInput( windowText);
        o->textWLWW->SetTextScaleModeToNone();												//vtkviewPort
        o->textWLWW->GetPositionCoordinate()->SetCoordinateSystemToDisplay();
        int *wsize = o->horosRenderWindow->GetSize();
        o->textWLWW->GetPositionCoordinate()->SetValue(2., wsize[1] - 2.);
        o->textWLWW->GetTextProperty()->SetShadow(true);
        o->textWLWW->GetTextProperty()->SetShadowOffset(1, 1);
        o->textWLWW->GetTextProperty()->SetVerticalJustificationToTop();

        o->aRenderer->AddViewProp(o->textWLWW);

        if (corner) {
            o->textX = vtkTextActor::New();
            o->textX->SetInput( "X ");
            o->textX->SetTextScaleModeToNone();
            o->textX->GetPositionCoordinate()->SetCoordinateSystemToViewport();
            o->textX->GetPositionCoordinate()->SetValue( 2., 2.);
            o->textX->GetTextProperty()->SetShadow(true);
            o->textX->GetTextProperty()->SetShadowOffset(1, 1);

            o->aRenderer->AddViewProp(o->textX);
        }

        // A series corrected for gantry tilt says so in the lower left corner.
        if (tilt) {
            o->textTilt = vtkTextActor::New();
            o->textTilt->SetInput( [tilt UTF8String]);
            o->textTilt->SetTextScaleModeToNone();
            o->textTilt->GetPositionCoordinate()->SetCoordinateSystemToViewport();
            o->textTilt->GetPositionCoordinate()->SetValue( 2., corner ? 20. : 2.);
            o->textTilt->GetTextProperty()->SetShadow(true);
            o->textTilt->GetTextProperty()->SetShadowOffset(1, 1);
            o->aRenderer->AddViewProp(o->textTilt);
        }

        for (long i = 0; i < 5; i++) {
            o->oText[ i] = vtkTextActor::New();
            o->oText[ i]->SetInput( "X ");
            o->oText[ i]->SetTextScaleModeToNone();
            o->oText[ i]->GetPositionCoordinate()->SetCoordinateSystemToNormalizedViewport();
            o->oText[ i]->GetTextProperty()->SetBold( true);
            o->oText[ i]->GetTextProperty()->SetShadow(true);
            o->oText[ i]->GetTextProperty()->SetShadowOffset(1, 1);

            o->aRenderer->AddViewProp( o->oText[ i]);
        }
        o->oText[ 0]->GetPositionCoordinate()->SetValue( 0.01, 0.5);
        o->oText[ 1]->GetPositionCoordinate()->SetValue( 0.99, 0.5);
        o->oText[ 1]->GetTextProperty()->SetJustificationToRight();

        o->oText[ 2]->GetPositionCoordinate()->SetValue( 0.5, 0.03);
        o->oText[ 2]->GetTextProperty()->SetVerticalJustificationToBottom();
        o->oText[ 3]->GetPositionCoordinate()->SetValue( 0.5, 0.97);
        o->oText[ 3]->GetTextProperty()->SetVerticalJustificationToTop();

        o->oText[ 4]->GetPositionCoordinate()->SetValue( 0.99, 0.01);
        o->oText[ 4]->GetTextProperty()->SetBold( false);
        o->oText[ 4]->GetTextProperty()->SetJustificationToRight();
    });
}

- (BOOL)makeCameraWithError:(NSError **)error
{
    IsiXVTKVolumeViewObjects *o = _o;
    return IsiXVTKVolumeTry(error, "makeCamera", {}, [&] {
        o->aCamera = vtkCamera::New();
        o->aCamera->SetViewUp (0, 1, 0);
        o->aCamera->SetFocalPoint (0, 0, 0);
        o->aCamera->SetPosition (0, 0, 1);
        o->aCamera->SetRoll(180);
        o->aCamera->SetParallelProjection( true);

        o->aCamera->Dolly(1.5);

        o->aRenderer->AddVolume( o->volume);

        o->aRenderer->SetActiveCamera(o->aCamera);
        o->aRenderer->ResetCamera();
    });
}

#pragma mark The ray casters

- (void *)mapperHandleCreatingIfNeeded
{
    IsiXVTKVolumeViewObjects *o = _o;
    IsiXVTKVolumeRun("mapper", {o->reader}, [&] {
        if (o->volumeMapper == nullptr) {
            o->volumeMapper = vtkHorosFixedPointVolumeRayCastMapper::New();
            o->volumeMapper->SetInputConnection(o->reader->GetOutputPort());
        }
        o->volumeMapper->Update();
    });
    return o->volumeMapper;
}

- (void)takeMapperHandle:(void *)handle
{
    IsiXVTKVolumeViewObjects *o = _o;
    vtkVolumeMapper *mapper = (vtkVolumeMapper *)handle;
    if (!mapper || mapper == (vtkVolumeMapper *)o->volumeMapper) return;
    IsiXVTKVolumeRun("setMapper", {}, [&] {
        if (o->volumeMapper) o->volumeMapper->Delete();
        o->volumeMapper = (vtkHorosFixedPointVolumeRayCastMapper *)mapper;
        o->volume->SetMapper( o->volumeMapper);
    });
}

- (void)takeVolumeHandle:(void *)handle
{
    IsiXVTKVolumeViewObjects *o = _o;
    IsiXVTKVolumeRun("setVolume", {}, [&] {
        if (o->volume) o->volume->Delete();
        o->volume = (vtkVolume *)handle;
    });
}

- (void)allocateVolumeMapper
{
    IsiXVTKVolumeViewObjects *o = _o;
    IsiXVTKVolumeRun("allocateVolumeMapper", {o->reader}, [&] {
        if (o->volumeMapper == nullptr) {
            o->volumeMapper = vtkHorosFixedPointVolumeRayCastMapper::New();
            o->volumeMapper->SetInputConnection(o->reader->GetOutputPort());
        }

        o->volumeMapper->SetImageRenderer(IsiXVTKVolumeViewRenderMetal, (__bridge void *)self);
        o->volumeMapper->Update();
        o->volume->SetMapper( o->volumeMapper);
    });
}

- (void)attachVolumeMapper
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->volume) return;
    IsiXVTKVolumeRun("attachVolumeMapper", {}, [&] { o->volume->SetMapper( o->volumeMapper); });
}

- (void)discardVolumeMapper
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->volumeMapper) return;
    IsiXVTKVolumeRun("discardVolumeMapper", {}, [&] {
        // Preset filters can update the source while a preview context is current.
        // Release context-owned VAOs before replacing the main volume mapper.
        o->volumeMapper->ReleaseGraphicsResources( o->aRenderer->GetRenderWindow());
        o->volumeMapper->Delete();
    });
    o->volumeMapper = nullptr;
}

#define ISIX_VOLUME_MAPPER_SET(name, mapperField, operation, Call, Type)                          \
    - (void)name:(Type)value                                                                      \
    {                                                                                             \
        vtkHorosFixedPointVolumeRayCastMapper *mapper = _o->mapperField;                          \
        if (!mapper) return;                                                                      \
        IsiXVTKVolumeRun(operation, {}, [&] { mapper->Call(value); });                            \
    }

ISIX_VOLUME_MAPPER_SET(setVolumeMinimumImageSampleDistance, volumeMapper, "setMinimumImageSampleDistance", SetMinimumImageSampleDistance, float)
ISIX_VOLUME_MAPPER_SET(setVolumeSampleDistance, volumeMapper, "setSampleDistance", SetSampleDistance, float)
ISIX_VOLUME_MAPPER_SET(setBlendingMinimumImageSampleDistance, blendingVolumeMapper, "setMinimumImageSampleDistance", SetMinimumImageSampleDistance, float)
ISIX_VOLUME_MAPPER_SET(setBlendingSampleDistance, blendingVolumeMapper, "setSampleDistance", SetSampleDistance, float)

#undef ISIX_VOLUME_MAPPER_SET

- (void)setVolumeAutoAdjustSampleDistances:(BOOL)adjust
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = _o->volumeMapper;
    if (!mapper) return;
    IsiXVTKVolumeRun("setAutoAdjustSampleDistances", {}, [&] { mapper->SetAutoAdjustSampleDistances(adjust ? 1 : 0); });
}

- (void)setBlendingAutoAdjustSampleDistances:(BOOL)adjust
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = _o->blendingVolumeMapper;
    if (!mapper) return;
    IsiXVTKVolumeRun("setAutoAdjustSampleDistances", {}, [&] { mapper->SetAutoAdjustSampleDistances(adjust ? 1 : 0); });
}

- (void)setVolumeMinimumImageSampleDistance:(float)minimum sampleDistance:(float)sample
                  maximumImageSampleDistance:(float)maximum
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = _o->volumeMapper;
    if (!mapper) return;
    IsiXVTKVolumeRun("setSampleDistances", {}, [&] {
        mapper->SetMinimumImageSampleDistance( minimum);
        mapper->SetSampleDistance( sample);
        mapper->SetMaximumImageSampleDistance( maximum);
    });
}

- (void)setBlendingMinimumImageSampleDistance:(float)minimum sampleDistance:(float)sample
                    maximumImageSampleDistance:(float)maximum
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = _o->blendingVolumeMapper;
    if (!mapper) return;
    IsiXVTKVolumeRun("setSampleDistances", {}, [&] {
        mapper->SetMinimumImageSampleDistance( minimum);
        mapper->SetSampleDistance( sample);
        mapper->SetMaximumImageSampleDistance( maximum);
    });
}

- (float)volumeMinimumImageSampleDistance
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = _o->volumeMapper;
    float distance = 0;
    if (!mapper) return distance;
    IsiXVTKVolumeRun("minimumImageSampleDistance", {}, [&] { distance = mapper->GetMinimumImageSampleDistance(); });
    return distance;
}

/// The view's modes by tag on a ray caster: 0 composite, 1 maximum, 2 and 3
/// minimum, 3 averaging (a mode of the Horos ray caster).
static void IsiXVTKSetBlendMode(vtkHorosFixedPointVolumeRayCastMapper *mapper, long modeID)
{
    switch (modeID) {
        case 0: //Volume
            mapper->SetBlendModeToComposite();
            break;

        case 1: //Max
            mapper->SetBlendModeToMaximumIntensity();
            break;

        case 2: //Min
        case 3: // Mean: a minimum-intensity blend that averages, a mode of the mapper
            mapper->SetBlendModeToMinimumIntensity();
            break;
    }

    mapper->SetMeanIntensity( modeID == 3);
}

- (void)setVolumeBlendMode:(long)mode
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = _o->volumeMapper;
    if (!mapper) return;
    IsiXVTKVolumeRun("setBlendMode", {}, [&] { IsiXVTKSetBlendMode(mapper, mode); });
}

- (void)setBlendingBlendMode:(long)mode
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = _o->blendingVolumeMapper;
    if (!mapper) return;
    IsiXVTKVolumeRun("setBlendMode", {}, [&] { IsiXVTKSetBlendMode(mapper, mode); });
}

- (BOOL)volumeBlendModeIsMaximumIntensity
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = _o->volumeMapper;
    BOOL maximum = NO;
    if (!mapper) return maximum;
    IsiXVTKVolumeRun("blendMode", {}, [&] { maximum = mapper->GetBlendMode() == vtkVolumeMapper::MAXIMUM_INTENSITY_BLEND; });
    return maximum;
}

- (IsiXVTKRayCastImageGeometry)rayCastImageInfoFused:(BOOL)fused
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = fused ? _o->blendingVolumeMapper : _o->volumeMapper;
    IsiXVTKRayCastImageGeometry info = {{0, 0}, {0, 0}, {0, 0}, 0};
    if (!mapper) return info;
    IsiXVTKVolumeRun("rayCastImage", {}, [&] {
        vtkFixedPointRayCastImage *image = mapper->GetRayCastImage();
        image->GetImageOrigin(info.origin);
        image->GetImageInUseSize(info.inUseSize);
        image->GetImageMemorySize(info.memorySize);
        info.sampleDistance = image->GetImageSampleDistance();
    });
    return info;
}

- (unsigned short *)rayCastImageFused:(BOOL)fused
{
    vtkHorosFixedPointVolumeRayCastMapper *mapper = fused ? _o->blendingVolumeMapper : _o->volumeMapper;
    unsigned short *image = nullptr;
    if (!mapper) return image;
    IsiXVTKVolumeRun("rayCastImage", {}, [&] { image = mapper->GetRayCastImage()->GetImage(); });
    return image;
}

#pragma mark Crop carried over

/// The crop in place - the box widget's or a saved camera's - on the volume's
/// ray caster.
static vtkPlaneCollection *IsiXVTKAppliedCrop(IsiXVTKVolumeViewObjects *o)
{
    return o->volume && o->volume->GetMapper() ? o->volume->GetMapper()->GetClippingPlanes() : nullptr;
}

- (void)holdAppliedCrop
{
    IsiXVTKVolumeViewObjects *o = _o;
    IsiXVTKVolumeRun("holdAppliedCrop", {}, [&] {
        if (o->heldCrop) o->heldCrop->UnRegister(nullptr);
        o->heldCrop = IsiXVTKAppliedCrop(o);
        if (o->heldCrop) o->heldCrop->Register(nullptr);
    });
}

- (BOOL)applyHeldCrop
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->heldCrop) return NO;
    IsiXVTKVolumeRun("applyHeldCrop", {}, [&] { [self applyCropPlanes:o->heldCrop]; });
    return YES;
}

- (void)releaseHeldCrop
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->heldCrop) return;
    IsiXVTKVolumeRun("releaseHeldCrop", {}, [&] { o->heldCrop->UnRegister(nullptr); });
    o->heldCrop = nullptr;
}

- (BOOL)reapplyAppliedCrop
{
    IsiXVTKVolumeViewObjects *o = _o;
    BOOL applied = NO;
    IsiXVTKVolumeRun("reapplyAppliedCrop", {}, [&] {
        vtkPlaneCollection *crop = IsiXVTKAppliedCrop(o);
        if (crop) {
            [self applyCropPlanes:crop];
            applied = YES;
        }
    });
    return applied;
}

#pragma mark The property and the transfer functions

- (void)setShadingAmbient:(float)ambient diffuse:(float)diffuse specular:(float)specular power:(float)power
{
    vtkVolumeProperty *property = _o->volumeProperty;
    if (!property) return;
    IsiXVTKVolumeRun("setShading", {}, [&] {
        property->SetAmbient(ambient);
        property->SetDiffuse(diffuse);
        property->SetSpecular(specular);
        property->SetSpecularPower(power);
    });
}

- (void)getShadingAmbient:(float *)ambient diffuse:(float *)diffuse specular:(float *)specular power:(float *)power
{
    vtkVolumeProperty *property = _o->volumeProperty;
    if (!property) return;
    IsiXVTKVolumeRun("shading", {}, [&] {
        *ambient = property->GetAmbient();
        *diffuse = property->GetDiffuse();
        *specular = property->GetSpecular();
        *power = property->GetSpecularPower();
    });
}

- (long)shade
{
    vtkVolumeProperty *property = _o->volumeProperty;
    long shade = 0;
    if (!property) return shade;
    IsiXVTKVolumeRun("shade", {}, [&] { shade = property->GetShade(); });
    return shade;
}

- (void)setShade:(long)shade
{
    vtkVolumeProperty *property = _o->volumeProperty;
    if (!property) return;
    IsiXVTKVolumeRun("setShade", {}, [&] { property->SetShade((int)shade); });
}

- (void)buildColourFromTable:(const double *)table start:(double)start end:(double)end
{
    vtkColorTransferFunction *colour = _o->colorTransferFunction;
    if (!colour) return;
    IsiXVTKVolumeRun("buildColour", {colour}, [&] { colour->BuildFunctionFromTable(start, end, 255, (double *)table); });
}

- (void)setRGBComponentsToColourFunction:(BOOL)colourFunction
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->volumeProperty) return;
    IsiXVTKVolumeRun("setRGBComponents", {}, [&] {
        if (colourFunction) {
            o->volumeProperty->SetColor( 1, o->colorTransferFunction);
            o->volumeProperty->SetColor( 2, o->colorTransferFunction);
            o->volumeProperty->SetColor( 3, o->colorTransferFunction);
        } else {
            o->volumeProperty->SetColor( 1,o->red);
            o->volumeProperty->SetColor( 2,o->green);
            o->volumeProperty->SetColor( 3,o->blue);
        }
    });
}

- (void)removeAllOpacityPoints
{
    vtkPiecewiseFunction *opacity = _o->opacityTransferFunction;
    if (!opacity) return;
    IsiXVTKVolumeRun("removeAllOpacityPoints", {}, [&] { opacity->RemoveAllPoints(); });
}

- (void)addOpacityPointAt:(double)x value:(double)value
{
    vtkPiecewiseFunction *opacity = _o->opacityTransferFunction;
    if (!opacity) return;
    IsiXVTKVolumeRun("addOpacityPoint", {}, [&] { opacity->AddPoint(x, value); });
}

- (void)addOpacitySegmentFrom:(double)x1 value:(double)v1 to:(double)x2 value:(double)v2
{
    vtkPiecewiseFunction *opacity = _o->opacityTransferFunction;
    if (!opacity) return;
    IsiXVTKVolumeRun("addOpacitySegment", {}, [&] { opacity->AddSegment(x1, v1, x2, v2); });
}

- (void)removeAllColourPoints
{
    vtkColorTransferFunction *colour = _o->colorTransferFunction;
    if (!colour) return;
    IsiXVTKVolumeRun("removeAllColourPoints", {}, [&] { colour->RemoveAllPoints(); });
}

- (void)addColourPointAt:(double)x red:(double)red green:(double)green blue:(double)blue
{
    vtkColorTransferFunction *colour = _o->colorTransferFunction;
    if (!colour) return;
    IsiXVTKVolumeRun("addColourPoint", {}, [&] { colour->AddRGBPoint(x, red, green, blue); });
}

- (double)opacityAt:(double)x
{
    vtkPiecewiseFunction *opacity = _o->opacityTransferFunction;
    double value = 0;
    if (!opacity) return value;
    IsiXVTKVolumeRun("opacity", {}, [&] { value = opacity->GetValue(x); });
    return value;
}

#pragma mark The volume's placement

- (void)getVolumeBounds:(double *)bounds
{
    vtkVolume *volume = _o->volume;
    if (!volume) return;
    IsiXVTKVolumeRun("volumeBounds", {}, [&] { volume->GetBounds(bounds); });
}

- (void)getVolumeCenter:(double *)center
{
    vtkVolume *volume = _o->volume;
    if (!volume) return;
    IsiXVTKVolumeRun("volumeCenter", {}, [&] {
        double *c = volume->GetCenter();
        center[0] = c[0];
        center[1] = c[1];
        center[2] = c[2];
    });
}

- (void)getVolumePosition:(double *)position fused:(BOOL)fused
{
    vtkVolume *volume = fused ? _o->blendingVolume : _o->volume;
    if (!volume) return;
    IsiXVTKVolumeRun("volumePosition", {}, [&] { volume->GetPosition(position); });
}

- (void)setBlendingPickable:(BOOL)pickable
{
    vtkVolume *volume = _o->blendingVolume;
    if (!volume) return;
    IsiXVTKVolumeRun("setPickable", {}, [&] { volume->SetPickable(pickable ? 1 : 0); });
}

- (IsiXVTKVolumeTransform *)userTransformFused:(BOOL)fused
{
    vtkVolume *volume = fused ? _o->blendingVolume : _o->volume;
    if (!volume) return nil;
    IsiXVTKVolumeTransform *transform = nil;
    IsiXVTKVolumeRun("userTransform", {}, [&] { transform = [[IsiXVTKVolumeTransform alloc] initWithVolume:volume]; });
    return transform;
}

- (NSArray<NSNumber *> *)voxelToWorldTransformWithFactor:(float)factor
{
    IsiXVTKVolumeViewObjects *o = _o;
    NSMutableArray *transform = nil;
    IsiXVTKVolumeRun("voxelToWorldTransform", {}, [&] {
        vtkImageData *input = o->reader ? o->reader->GetOutput() : nullptr;
        if (!input || !o->volume) return;
        double origin[3], spacing[3];
        input->GetOrigin(origin);
        input->GetSpacing(spacing);
        vtkMatrix4x4 *matrix = o->volume->GetMatrix();
        transform = [NSMutableArray arrayWithCapacity:16];
        for (int column = 0; column < 4; ++column)
            for (int row = 0; row < 4; ++row)
            {
                double value = row == 3 ? (column == 3 ? 1 : 0) :
                    (column < 3 ? matrix->GetElement(row, column) * spacing[column] :
                     matrix->GetElement(row, 3) + matrix->GetElement(row, 0) * origin[0] +
                     matrix->GetElement(row, 1) * origin[1] + matrix->GetElement(row, 2) * origin[2]) / factor;
                [transform addObject:@(value)];
            }
    });
    return transform;
}

#pragma mark The fused series

- (BOOL)fuseVoxels:(void *)voxels rgb:(BOOL)rgb width:(long)width height:(long)height depth:(long)depth
          spacingX:(double)sx y:(double)sy z:(double)sz error:(NSError **)error
{
    IsiXVTKVolumeViewObjects *o = _o;
    return IsiXVTKVolumeTry(error, "fuseVoxels", {}, [&] {
        o->blendingReader = HorosVRImageImport::New();
        IsiXVTKErrorCapture capture({o->blendingReader}, "fuseVoxels");
        o->blendingReader->SetWholeExtent(0, width-1, 0, height-1, 0, depth-1);
        o->blendingReader->SetDataExtentToWholeExtent();

        if (rgb) {
            o->blendingReader->SetDataScalarTypeToUnsignedChar();
            o->blendingReader->SetNumberOfScalarComponents( 4);
            o->blendingReader->SetImportVoidPointer( voxels );
        } else {
            o->blendingReader->SetNumberOfScalarComponents( 1);
            o->blendingReader->SetDataScalarTypeToUnsignedShort();
            o->blendingReader->SetImportVoidPointer( voxels );
        }

        o->blendingReader->Update();

        o->blendingReader->SetDataSpacing( sx, sy, sz);

        o->blendingColorTransferFunction = vtkColorTransferFunction::New();

        o->blendingOpacityTransferFunction = vtkPiecewiseFunction::New();
        if (capture.Error()) IsiXVTKLogFailure(capture.Error());
    });
}

- (void)makeBlendingPropertyRGB:(BOOL)rgb
{
    IsiXVTKVolumeViewObjects *o = _o;
    IsiXVTKVolumeRun("makeBlendingProperty", {}, [&] {
        o->blendingVolumeProperty = vtkVolumeProperty::New();

        if (rgb) {
            o->blendingVolumeProperty->IndependentComponentsOn();

            o->blendingVolumeProperty->SetColor( 1,o->red);
            o->blendingVolumeProperty->SetColor( 2,o->green);
            o->blendingVolumeProperty->SetColor( 3,o->blue);

            o->blendingVolumeProperty->SetScalarOpacity( 1, o->blendingOpacityTransferFunction);
            o->blendingVolumeProperty->SetScalarOpacity( 2, o->blendingOpacityTransferFunction);
            o->blendingVolumeProperty->SetScalarOpacity( 3, o->blendingOpacityTransferFunction);

            o->blendingVolumeProperty->SetComponentWeight( 0, 0);
        } else {
            o->blendingVolumeProperty->SetColor( o->blendingColorTransferFunction);
            o->blendingVolumeProperty->SetScalarOpacity( o->blendingOpacityTransferFunction);
        }
    });
}

- (void)makeBlendingVolume
{
    IsiXVTKVolumeViewObjects *o = _o;
    IsiXVTKVolumeRun("makeBlendingVolume", {}, [&] {
        o->blendingVolumeProperty->SetInterpolationTypeToLinear();

        o->blendingVolume = vtkVolume::New();
        o->blendingVolume->SetProperty( o->blendingVolumeProperty);
    });
}

- (BOOL)finishFusionWithCosines:(const float *)cosines factor:(float)factor originX:(double)x y:(double)y
                              z:(double)z error:(NSError **)error
{
    IsiXVTKVolumeViewObjects *o = _o;
    return IsiXVTKVolumeTry(error, "finishFusion", {}, [&] {
        vtkMatrix4x4 *matrice = IsiXVTKVolumeMatrix(cosines);

        o->blendingVolume->SetPosition(	factor*x * (matrice->Element[0][0]) + factor*y * (matrice->Element[1][0]) + factor*z*(matrice->Element[2][0]),
                                    factor*x * (matrice->Element[0][1]) + factor*y * (matrice->Element[1][1]) + factor*z*(matrice->Element[2][1]),
                                    factor*x * (matrice->Element[0][2]) + factor*y * (matrice->Element[1][2]) + factor*z*(matrice->Element[2][2]));
        o->blendingVolume->SetUserMatrix( matrice);
        matrice->Delete();

        if (o->cropcallback)
            o->cropcallback->SetBlendingVolume( o->blendingVolume);

        o->aRenderer->AddVolume( o->blendingVolume);
    });
}

- (void)attachBlendingMapper
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->blendingVolume) return;
    IsiXVTKVolumeRun("attachBlendingMapper", {o->blendingReader}, [&] {
        if (o->blendingVolumeMapper == nullptr) {
            o->blendingVolumeMapper = vtkHorosFixedPointVolumeRayCastMapper::New();
            o->blendingVolumeMapper->SetInputConnection(o->blendingReader->GetOutputPort());
            // The fused series ray-casts in Metal too; VTK composes its image
            // over the volume's.
            o->blendingVolumeMapper->SetImageRenderer(IsiXVTKVolumeViewRenderMetal, (__bridge void *)self);
        }
        o->blendingVolumeMapper->Update();

        o->blendingVolume->SetMapper( o->blendingVolumeMapper);
    });
}

- (void)discardBlendingMapper
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (o->blendingVolumeMapper)
        IsiXVTKVolumeRun("discardBlendingMapper", {}, [&] { o->blendingVolumeMapper->Delete(); });
    o->blendingVolumeMapper = nullptr;
}

- (void)setBlendingImportVoxels:(void *)voxels
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->blendingReader) return;
    IsiXVTKVolumeRun("setBlendingImportVoxels", {o->blendingReader}, [&] {
        o->blendingReader->SetImportVoidPointer( voxels);
        o->blendingReader->GetOutput()->Modified();
    });
}

- (void)updateBlendingImport
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->blendingReader) return;
    IsiXVTKVolumeRun("updateBlendingImport", {o->blendingReader}, [&] { o->blendingReader->Update(); });
}

- (void)replaceBlendingVoxels:(void *)voxels minimumImageSampleDistance:(float)minimum
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->blendingReader) return;
    IsiXVTKVolumeRun("replaceBlendingVoxels", {o->blendingReader}, [&] {
        o->blendingReader->SetImportVoidPointer( voxels);
        o->blendingReader->Update();

        // Force min/max recomputing
        if (o->blendingVolumeMapper) o->blendingVolumeMapper->Delete();
        o->blendingVolumeMapper = vtkHorosFixedPointVolumeRayCastMapper::New();
        o->blendingVolumeMapper->SetInputConnection(o->blendingReader->GetOutputPort());
        o->blendingVolumeMapper->SetMinimumImageSampleDistance( minimum);
        o->blendingVolumeMapper->Update();
        o->blendingVolume->SetMapper( o->blendingVolumeMapper);
    });
}

- (void)releaseFusion
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o || !o->blendingVolume) return;
    IsiXVTKVolumeRun("releaseFusion", {}, [&] {
        // The crop callback applies its planes to this volume's mapper
        // too; it must not reach the volume once it is deleted.
        if (o->cropcallback)
            o->cropcallback->SetBlendingVolume( nullptr);

        o->aRenderer->RemoveVolume( o->blendingVolume);

        o->blendingVolume->Delete();
        o->blendingVolume = nullptr;

        if (o->blendingVolumeMapper) o->blendingVolumeMapper->Delete();

        o->blendingVolumeMapper = nullptr;

        o->blendingOpacityTransferFunction->Delete();
        o->blendingVolumeProperty->Delete();
        o->blendingColorTransferFunction->Delete();
        o->blendingReader->Delete();
    });
    o->blendingOpacityTransferFunction = nullptr;
    o->blendingVolumeProperty = nullptr;
    o->blendingColorTransferFunction = nullptr;
    o->blendingReader = nullptr;
}

- (void)buildBlendingOpacityFromTable:(const double *)table start:(double)start end:(double)end
{
    vtkPiecewiseFunction *opacity = _o->blendingOpacityTransferFunction;
    if (!opacity) return;
    IsiXVTKVolumeRun("buildBlendingOpacity", {opacity}, [&] { opacity->BuildFunctionFromTable(start, end, 255, (double *)table); });
}

- (void)buildBlendingColourFromTable:(const double *)table start:(double)start end:(double)end
{
    vtkColorTransferFunction *colour = _o->blendingColorTransferFunction;
    if (!colour) return;
    IsiXVTKVolumeRun("buildBlendingColour", {colour}, [&] { colour->BuildFunctionFromTable(start, end, 255, (double *)table); });
}

#pragma mark Full-depth capture

- (void)prepareFullDepthWithRange:(IsiXVTKScalarRange)range blendingRange:(IsiXVTKScalarRange)blendingRange
                          volume:(BOOL *)volumeDone
{
    IsiXVTKVolumeViewObjects *o = _o;
    *volumeDone = NO;
    IsiXVTKVolumeRun("prepareFullDepth", {}, [&] {
        if (o->volumeMapper) {
            o->volumeMapper->SetIntermixIntersectingGeometry( 0);

            vtkPiecewiseFunction *tempOpacity = vtkPiecewiseFunction::New();

            tempOpacity->AddPoint(range.start, 0);
            tempOpacity->AddPoint(range.end, 1);

            o->volumeProperty->SetScalarOpacity( tempOpacity);
            o->volumeMapper->PerVolumeInitialization( o->aRenderer, o->volume);

            o->volumeMapper->SetFullDepthCapture( true);

            tempOpacity->Delete();

            *volumeDone = YES;
        }

        if (o->blendingVolumeMapper) {
            o->blendingVolumeMapper->SetIntermixIntersectingGeometry( 0);

            vtkPiecewiseFunction *tempOpacity = vtkPiecewiseFunction::New();

            tempOpacity->AddPoint(blendingRange.start, 0);
            tempOpacity->AddPoint(blendingRange.end, 1);

            o->blendingVolumeProperty->SetScalarOpacity( tempOpacity);
            o->blendingVolumeMapper->PerVolumeInitialization( o->aRenderer, o->blendingVolume);

            o->blendingVolumeMapper->SetFullDepthCapture( true);

            tempOpacity->Delete();
        }
    });
}

- (void)restoreFullDepth:(BOOL *)volumeDone
{
    IsiXVTKVolumeViewObjects *o = _o;
    *volumeDone = NO;
    IsiXVTKVolumeRun("restoreFullDepth", {}, [&] {
        if (o->volumeMapper) {
            o->volumeMapper->SetIntermixIntersectingGeometry( 1);
            o->volumeMapper->SetFullDepthCapture( false);

            o->volumeProperty->SetScalarOpacity( o->opacityTransferFunction);
            o->volumeMapper->PerVolumeInitialization( o->aRenderer, o->volume);

            *volumeDone = YES;
        }

        if (o->blendingVolumeMapper) {
            o->blendingVolumeMapper->SetIntermixIntersectingGeometry( 1);
            o->blendingVolumeMapper->SetFullDepthCapture( false);

            o->blendingVolumeProperty->SetScalarOpacity( o->blendingOpacityTransferFunction);
            o->blendingVolumeMapper->PerVolumeInitialization( o->aRenderer, o->blendingVolume);
        }
    });
}

#pragma mark The preset previews

// A preview of the 3D presets panel builds a pipeline of its own over the
// main view's voxels, as VRPresetPreview built it, and adopts the main
// view's ray caster's input afterwards.

- (BOOL)makePreviewImport:(void *)voxels rgb:(BOOL)rgb width:(long)width height:(long)height depth:(long)depth
                    error:(NSError **)error
{
    IsiXVTKVolumeViewObjects *o = _o;
    return IsiXVTKVolumeTry(error, "makePreviewImport", {}, [&] {
        o->reader = vtkImageImport::New();
        IsiXVTKErrorCapture capture({o->reader}, "makePreviewImport");
        o->reader->SetWholeExtent(0, width-1, 0, height-1, 0, depth-1);	//AVOID VTK BUG
        o->reader->SetDataExtentToWholeExtent();

        if (rgb) {
            o->reader->SetDataScalarTypeToUnsignedChar();
            o->reader->SetNumberOfScalarComponents( 4);
            o->reader->SetImportVoidPointer(voxels);
        } else {
            o->reader->SetDataScalarTypeToUnsignedShort();
            o->reader->SetNumberOfScalarComponents( 1);
            o->reader->SetImportVoidPointer(voxels);
        }
        o->reader->Update();
        if (capture.Error()) IsiXVTKLogFailure(capture.Error());
    });
}

- (BOOL)makePreviewTransferFunctionsRGB:(BOOL)rgb error:(NSError **)error
{
    IsiXVTKVolumeViewObjects *o = _o;
    return IsiXVTKVolumeTry(error, "makePreviewTransferFunctions", {}, [&] {
        o->opacityTransferFunction = vtkPiecewiseFunction::New();
        o->opacityTransferFunction->AddPoint(0, 0);
        o->opacityTransferFunction->AddPoint(255, 1);

        o->colorTransferFunction = vtkColorTransferFunction::New();

        o->red = vtkColorTransferFunction::New();
        o->red->AddRGBPoint(   0, 0, 0, 0 );
        o->red->AddRGBPoint( 255, 1, 0, 0 );

        o->green = vtkColorTransferFunction::New();
        o->green->AddRGBPoint(   0, 0, 0, 0 );
        o->green->AddRGBPoint( 255, 0, 1, 0 );

        o->blue = vtkColorTransferFunction::New();
        o->blue->AddRGBPoint(   0, 0, 0, 0 );
        o->blue->AddRGBPoint( 255, 0, 0, 1 );

        o->volumeProperty = vtkVolumeProperty::New();
        if (rgb) {
            o->volumeProperty->IndependentComponentsOn();

            o->volumeProperty->SetColor( 1,o->red);
            o->volumeProperty->SetColor( 2,o->green);
            o->volumeProperty->SetColor( 3,o->blue);

            o->volumeProperty->SetScalarOpacity( 1, o->opacityTransferFunction);
            o->volumeProperty->SetScalarOpacity( 2, o->opacityTransferFunction);
            o->volumeProperty->SetScalarOpacity( 3, o->opacityTransferFunction);

            o->volumeProperty->SetComponentWeight( 0, 0);
        } else {
            o->volumeProperty->SetColor( o->colorTransferFunction);
            o->volumeProperty->SetScalarOpacity( o->opacityTransferFunction);
        }
    });
}

- (BOOL)makePreviewVolumeNearest:(BOOL)nearest cosines:(const float *)cosines factor:(float)factor
                         originX:(double)x y:(double)y z:(double)z windowText:(const char *)windowText
                           error:(NSError **)error
{
    IsiXVTKVolumeViewObjects *o = _o;
    HorosVRInteractor *interactor = [self interactor];
    return IsiXVTKVolumeTry(error, "makePreviewVolume", {}, [&] {
        if (nearest) o->volumeProperty->SetInterpolationTypeToNearest();
        else o->volumeProperty->SetInterpolationTypeToLinear();

        o->volume = vtkVolume::New();
        o->volume->SetProperty( o->volumeProperty);

        vtkMatrix4x4 *matrice = IsiXVTKVolumeMatrix(cosines);

        o->volume->SetPosition(	factor*x * matrice->Element[0][0] + factor*y * matrice->Element[1][0] + factor*z*matrice->Element[2][0],
                            factor*x * matrice->Element[0][1] + factor*y * matrice->Element[1][1] + factor*z*matrice->Element[2][1],
                            factor*x * matrice->Element[0][2] + factor*y * matrice->Element[1][2] + factor*z*matrice->Element[2][2]);
        o->volume->SetUserMatrix( matrice);
        matrice->Delete();

        o->volume->PickableOff();

        o->outlineData = vtkOutlineFilter::New();
        o->outlineData->SetInputConnection(o->reader->GetOutputPort());

        o->mapOutline = vtkPolyDataMapper::New();
        o->mapOutline->SetInputConnection(o->outlineData->GetOutputPort());

        o->mapOutline->Update();

        o->outlineRect = vtkActor::New();
        o->outlineRect->SetMapper(o->mapOutline);
        o->outlineRect->GetProperty()->SetColor(0,1,0);
        o->outlineRect->GetProperty()->SetOpacity(0.5);
        o->outlineRect->PickableOff();

        o->croppingBox = HorosBoxWidget::New();

        o->croppingBox->GetHandleProperty()->SetColor(0, 1, 0);
        o->croppingBox->SetProp3D( o->volume);
        o->croppingBox->SetPlaceFactor( 1.0);
        o->croppingBox->SetHandleSize( 0.005);
        o->croppingBox->PlaceWidget();
        o->croppingBox->SetInteractor( interactor);
        o->croppingBox->SetRotationEnabled( false);
        o->croppingBox->SetInsideOut( true);
        o->croppingBox->OutlineCursorWiresOff();

        o->textWLWW = vtkTextActor::New();
        o->textWLWW->SetInput( windowText);
        o->textWLWW->SetTextScaleModeToNone();
        o->textWLWW->GetPositionCoordinate()->SetCoordinateSystemToDisplay();
        o->textWLWW->GetPositionCoordinate()->SetValue( 0,0);

        o->textX = vtkTextActor::New();

        for (long i = 0; i < 5; i++) {
            o->oText[ i]= vtkTextActor::New();
            o->oText[ i]->SetInput( "X");
            o->oText[ i]->SetTextScaleModeToNone();
            o->oText[ i]->GetPositionCoordinate()->SetCoordinateSystemToNormalizedViewport();
            o->oText[ i]->GetTextProperty()->SetFontSize( 16);
            o->oText[ i]->GetTextProperty()->SetBold( true);
        }

        o->aCamera = vtkCamera::New();
        o->aCamera->SetViewUp (0, 1, 0);
        o->aCamera->SetFocalPoint (0, 0, 0);
        o->aCamera->SetPosition (0, 0, 1);
        o->aCamera->SetRoll(180);
        o->aCamera->SetParallelProjection( true);

        o->aCamera->SetViewAngle( 30);

        o->aCamera->Dolly(1.5);

        o->aRenderer->SetActiveCamera(o->aCamera);
        o->aRenderer->ResetCamera();

        // 3D Cut ROI
        vtkPoints *pts = vtkPoints::New();
        vtkCellArray *rect = vtkCellArray::New();

        o->ROI3DData = vtkPolyData::New();
        o->ROI3DData-> SetPoints( pts);
        o->ROI3DData-> SetLines( rect);

        o->ROI3D = vtkPolyDataMapper2D::New();

        o->ROI3DActor = vtkActor2D::New();

        // Oval

        o->Oval2DData = vtkRegularPolygonSource::New();
        o->Oval2D = vtkPolyDataMapper2D::New();
        o->Oval2DActor = vtkActor2D::New();
        o->Oval2DText = vtkTextActor::New();

        //	2D Line

        o->Line2DData = vtkPolyData::New();
        o->Line2DData-> SetPoints( pts);
        pts->Delete();
        o->Line2DData-> SetLines( rect);
        rect->Delete();

        o->Line2D = vtkPolyDataMapper2D::New();
        o->Line2D->SetInputData( o->Line2DData);

        o->Line2DActor = vtkActor2D::New();
        o->Line2DActor->SetMapper( o->Line2D);

        o->Line2DText = vtkTextActor::New();
    });
}

// VTK's image display helper owns context-specific textures, shaders and VAOs.
// Share the input pipeline, not that rendering state, with another view.
- (BOOL)adoptPreviewMapperOf:(void *)sourceMapper
{
    IsiXVTKVolumeViewObjects *o = _o;
    vtkVolumeMapper *source = (vtkVolumeMapper *)sourceMapper;
    if (!source || source == (vtkVolumeMapper *)o->volumeMapper) return NO;
    BOOL metal = NO;
    IsiXVTKVolumeRun("adoptPreviewMapper", {}, [&] {
        vtkHorosFixedPointVolumeRayCastMapper *replacement = vtkHorosFixedPointVolumeRayCastMapper::New();
        replacement->SetInputConnection(source->GetInputConnection(0, 0));
        replacement->SetBlendMode(source->GetBlendMode());
        if (vtkFixedPointVolumeRayCastMapper *fixed = vtkFixedPointVolumeRayCastMapper::SafeDownCast(source)) {
            replacement->SetSampleDistance(fixed->GetSampleDistance());
            replacement->SetMinimumImageSampleDistance(fixed->GetMinimumImageSampleDistance());
            replacement->SetMaximumImageSampleDistance(fixed->GetMaximumImageSampleDistance());
            replacement->SetAutoAdjustSampleDistances(fixed->GetAutoAdjustSampleDistances());
        }
        if (o->volumeMapper) o->volumeMapper->Delete();
        o->volumeMapper = replacement;
        o->volume->SetMapper(o->volumeMapper);

        // Drawn with Metal, as the 3D view is: the view's hook, rendering
        // this preview's own camera, tables and shading.
        vtkHorosFixedPointVolumeRayCastMapper *horos = dynamic_cast<vtkHorosFixedPointVolumeRayCastMapper *>(source);
        if (horos && horos->GetImageRenderer()) {
            o->volumeMapper->SetImageRenderer(horos->GetImageRenderer(), (__bridge void *)self);
            metal = YES;
        }
    });
    return metal;
}

- (void)showVolume:(BOOL)shown
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->aRenderer || !o->volume) return;
    IsiXVTKVolumeRun("showVolume", {}, [&] {
        if (shown) o->aRenderer->AddVolume( o->volume);
        else o->aRenderer->RemoveVolume( o->volume);
    });
}

@end

@implementation IsiXVTKVolumeView (IsiXVTKVolumeCropPlanes)

// One crop on every mapper the view draws with: the image's, whichever engine
// is in use, and a fused series'. Copied into each mapper's own
// collection: VTK refills a mapper's collection in place, and a shared one
// would let one mapper's crop move the others'.
- (void)applyCropPlanes:(vtkPlaneCollection *)crop
{
    IsiXVTKVolumeViewObjects *o = _o;
    vtkPlanes *planes = vtkPlanes::New();
    vtkPoints *points = vtkPoints::New( VTK_DOUBLE);
    vtkDoubleArray *normals = vtkDoubleArray::New();
    normals->SetNumberOfComponents( 3);
    for( int i = 0; i < crop->GetNumberOfItems(); i++)
    {
        vtkPlane *plane = crop->GetItem( i);
        points->InsertNextPoint( plane->GetOrigin());
        normals->InsertNextTuple( plane->GetNormal());
    }
    planes->SetPoints( points);
    planes->SetNormals( normals);

    if( o->volumeMapper) o->volumeMapper->SetClippingPlanes( planes);
    if( o->blendingVolumeMapper) o->blendingVolumeMapper->SetClippingPlanes( planes);

    points->Delete();
    normals->Delete();
    planes->Delete();
}

@end
