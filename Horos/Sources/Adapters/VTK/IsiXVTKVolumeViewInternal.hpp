//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// What the files of IsiXVTKVolumeView share in C++: the VTK objects of a
// volume rendering view, held as the view held them (New and Delete, no
// smart pointers: a reference let go each frame cost a garbage collection pass
// in the render), and the guards of the adapter's calls.

#pragma once

#ifndef __cplusplus
#error "IsiXVTKVolumeViewInternal.hpp is for the Objective-C++ files of the VTK adapters"
#endif

#import "IsiXVTKVolumeView.h"
#import "IsiXVTKInternal.hpp"
#import "IsiXVTKOverlay.hpp"
#import "IsiXVTKSceneOverlay.hpp"
#import "IsiXVTKVolumeScene.hpp"
#include "IsiXVTKVolumeInteraction.hpp"
#include "IsiXVTKVolumePresentation.hpp"

#include <vector>
#include <vtkCommand.h>

class vtkActor;
class vtkActor2D;
class vtkCamera;
class vtkColorTransferFunction;
class vtkHorosFixedPointVolumeRayCastMapper;
class vtkImageImport;
class vtkOutlineFilter;
class vtkPiecewiseFunction;
class vtkPlaneCollection;
class vtkPolyData;
class vtkPolyDataMapper;
class vtkPolyDataMapper2D;
class vtkRegularPolygonSource;
class vtkRenderer;
class vtkTextActor;
class vtkVolume;
class vtkVolumeMapper;
class vtkVolumeProperty;

/// The crop box's callback: its planes onto the volume's ray caster and the
/// fused series'. The volume has a ray caster once the view installs its
/// engine; before that, the box keeps the crop, and the engine's installation
/// runs this callback again on the ray caster it installs.
class IsiXVTKCropCallback : public vtkCommand
{
public:
    static IsiXVTKCropCallback *New() { return new IsiXVTKCropCallback; }
    void SetBlendingVolume(vtkVolume *volume) { this->BlendingVolume = volume; }
    void Execute(vtkObject *caller, unsigned long, void *) override;

private:
    vtkVolume *BlendingVolume = nullptr;
};

/// A line measurement kept on screen after a new one starts: its own copy of
/// the line and text, and where it lies in the world.
struct IsiXVTKStoredLine
{
    vtkPolyData *data = nullptr;
    vtkPolyDataMapper2D *mapper = nullptr;
    vtkActor2D *actor = nullptr;
    vtkTextActor *text = nullptr;
    double world[2][3] = {{0, 0, 0}, {0, 0, 0}};
    double direction[3] = {0, 0, 0};
};

struct IsiXVTKVolumeViewObjects
{
    // The window and its renderer, made with the view.
    HorosVRRenderer *horosRenderer = nullptr;
    HorosVRRenderWindow *horosRenderWindow = nullptr;
    // The renderer the pipeline uses: nil until the volume is set.
    vtkRenderer *aRenderer = nullptr;
    vtkCamera *aCamera = nullptr;

    vtkImageImport *reader = nullptr;
    vtkHorosFixedPointVolumeRayCastMapper *volumeMapper = nullptr;
    vtkVolume *volume = nullptr;
    vtkVolumeProperty *volumeProperty = nullptr;
    vtkColorTransferFunction *colorTransferFunction = nullptr;
    vtkPiecewiseFunction *opacityTransferFunction = nullptr;
    vtkColorTransferFunction *red = nullptr, *green = nullptr, *blue = nullptr;

    vtkImageImport *blendingReader = nullptr;
    vtkHorosFixedPointVolumeRayCastMapper *blendingVolumeMapper = nullptr;
    vtkVolume *blendingVolume = nullptr;
    vtkVolumeProperty *blendingVolumeProperty = nullptr;
    vtkColorTransferFunction *blendingColorTransferFunction = nullptr;
    vtkPiecewiseFunction *blendingOpacityTransferFunction = nullptr;

    vtkOutlineFilter *outlineData = nullptr;
    vtkPolyDataMapper *mapOutline = nullptr;
    vtkActor *outlineRect = nullptr;

    HorosBoxWidget *croppingBox = nullptr;
    IsiXVTKCropCallback *cropcallback = nullptr;
    vtkPlaneCollection *heldCrop = nullptr;
    HorosVRInteractor *horosInteractor = nullptr;
    double (*deltaTransform)(double) = nullptr;

    vtkTextActor *textWLWW = nullptr, *textX = nullptr, *textTilt = nullptr;
    vtkTextActor *oText[5] = {nullptr, nullptr, nullptr, nullptr, nullptr};

    vtkPolyData *ROI3DData = nullptr;
    vtkPolyDataMapper2D *ROI3D = nullptr;
    vtkActor2D *ROI3DActor = nullptr;

    vtkRegularPolygonSource *Oval2DData = nullptr;
    vtkPolyDataMapper2D *Oval2D = nullptr;
    vtkActor2D *Oval2DActor = nullptr;
    vtkTextActor *Oval2DText = nullptr;

    vtkPolyData *Line2DData = nullptr;
    vtkPolyDataMapper2D *Line2D = nullptr;
    vtkActor2D *Line2DActor = nullptr;
    vtkTextActor *Line2DText = nullptr;
    std::vector<IsiXVTKStoredLine *> storedLines;
    double lineMeasurementWorld[2][3] = {{0, 0, 0}, {0, 0, 0}};
    double lineMeasurementDirection[3] = {0, 0, 0};
    bool lineMeasurementHasProjection = false;
    vtkTextActor *lineMeasurementProjectionNotice = nullptr;
    unsigned long lineMeasurementRenderObserver = 0;

    vtkPolyData *Angle2DData = nullptr;
    vtkPolyDataMapper2D *Angle2D = nullptr;
    vtkActor2D *Angle2DActor = nullptr;
    vtkTextActor *Angle2DText = nullptr;

    // The overlay's renderer, and the 2D actors of the render being drawn.
    vtkRenderer *overlayRenderer = nullptr;
    const std::vector<vtkActor2D *> *overlayShown = nullptr;

    // The mapper and volume being cast while the Metal hook runs.
    vtkHorosFixedPointVolumeRayCastMapper *renderingMapper = nullptr;
    vtkVolume *renderingVolume = nullptr;
    vtkRenderer *renderingRenderer = nullptr;
};

@interface IsiXVTKVolumeView ()
{
@public
    IsiXVTKVolumeViewObjects *_o;
    IsiXVTKOverlayObserver *_overlay;
    void (^_overlayHandler)(IsiXVTKVolumeView *);
    void (^_renderStartHandler)(void);
    IsiXVTKMetalImageRenderer _metalImageRenderer;
}
- (instancetype)initPrivately;
/// The interactor, made when first needed, with the renderer.
- (HorosVRInteractor *)interactor;
/// The crop collection onto every ray caster, each its own copy.
@end

@interface IsiXVTKVolumeView (IsiXVTKVolumeCropPlanes)
/// `crop` on every ray caster, each in a collection of its own
/// (IsiXVTKVolumePipeline.mm).
- (void)applyCropPlanes:(vtkPlaneCollection *)crop;
@end

@interface IsiXVTKVolumeTransform ()
- (instancetype)initWithVolume:(vtkVolume *)volume;
@end

/// The ray casters' image renderer: the view's Metal hook.
bool IsiXVTKVolumeViewRenderMetal(void *context, vtkHorosFixedPointVolumeRayCastMapper *mapper,
                                  vtkRenderer *renderer, vtkVolume *volume);

/// Logs a failure of a setter, which has no error to give back (IsiXVTKScene.mm).
void IsiXVTKLogFailure(NSError *error);

/// Runs `body` in the guard, logging a failure: for the calls that have no
/// error to give back. Errors VTK reports for `objects` are logged too.
template <typename Body>
static inline void IsiXVTKVolumeRun(const char *operation, std::initializer_list<vtkObject *> objects, Body &&body)
{
    NSError *error = nil;
    if (!IsiXVTKGuard(&error, operation, objects, [&]() -> NSError * { body(); return nil; }))
        IsiXVTKLogFailure(error);
}

/// Runs `body` in the guard, giving its failure back.
template <typename Body>
static inline BOOL IsiXVTKVolumeTry(NSError * __autoreleasing *error, const char *operation,
                                    std::initializer_list<vtkObject *> objects, Body &&body)
{
    return IsiXVTKGuard(error, operation, objects, [&]() -> NSError * { body(); return nil; });
}
