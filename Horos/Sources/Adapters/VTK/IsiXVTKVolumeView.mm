//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The volume rendering view's VTK objects: their life, the window and the
// render, the interactor, the 2D layer and the Metal hook
// (IsiXVTKVolumeView.h).

#import "IsiXVTKVolumeViewInternal.hpp"
#include "IsiXVTKFramebufferCapture.hpp"

#import "vtkHorosFixedPointVolumeRayCastMapper.h"

#include <algorithm>
#include <vtkActor.h>
#include <vtkActor2D.h>
#include <vtkCallbackCommand.h>
#include <vtkCamera.h>
#include <vtkColorTransferFunction.h>
#include <vtkCommand.h>
#include <vtkImageImport.h>
#include <vtkOutlineFilter.h>
#include <vtkPiecewiseFunction.h>
#include <vtkPlaneCollection.h>
#include <vtkPolyData.h>
#include <vtkPolyDataMapper.h>
#include <vtkPolyDataMapper2D.h>
#include <vtkRegularPolygonSource.h>
#include <vtkTextActor.h>
#include <vtkVolume.h>
#include <vtkVolumeProperty.h>

// The ray caster's switch, defined with the mapper
// (vtkHorosFixedPointVolumeRayCastMapper.cxx).
extern int dontRenderVolumeRenderingOsiriX;

/// The interactor's events, by IsiXVTKMouseEvent.
static unsigned long IsiXVTKVolumeEventId(IsiXVTKMouseEvent event)
{
    switch (event) {
        case IsiXVTKMouseEventLeftButtonPress: return vtkCommand::LeftButtonPressEvent;
        case IsiXVTKMouseEventLeftButtonRelease: return vtkCommand::LeftButtonReleaseEvent;
        case IsiXVTKMouseEventRightButtonPress: return vtkCommand::RightButtonPressEvent;
        case IsiXVTKMouseEventRightButtonRelease: return vtkCommand::RightButtonReleaseEvent;
        case IsiXVTKMouseEventMiddleButtonPress: return vtkCommand::MiddleButtonPressEvent;
        case IsiXVTKMouseEventMiddleButtonRelease: return vtkCommand::MiddleButtonReleaseEvent;
        case IsiXVTKMouseEventMove: return vtkCommand::MouseMoveEvent;
        case IsiXVTKMouseEventWheelForward: return vtkCommand::MouseWheelForwardEvent;
        case IsiXVTKMouseEventWheelBackward: return vtkCommand::MouseWheelBackwardEvent;
    }
    return vtkCommand::NoEvent;
}

bool IsiXVTKVolumeViewRenderMetal(void *context, vtkHorosFixedPointVolumeRayCastMapper *mapper,
                                  vtkRenderer *renderer, vtkVolume *volume)
{
    IsiXVTKVolumeView *view = (__bridge IsiXVTKVolumeView *)context;
    IsiXVTKVolumeViewObjects *o = view ? view->_o : nullptr;
    if (!o || !view->_metalImageRenderer) return false;
    // A fused series has its own mapper and volume, drawn after the image's.
    BOOL fused = o->blendingVolume && volume == o->blendingVolume && mapper == o->blendingVolumeMapper;
    if (renderer != o->aRenderer || (volume != o->volume && !fused)) return false;
    o->renderingMapper = mapper;
    o->renderingVolume = volume;
    o->renderingRenderer = renderer;
    BOOL drawn = view->_metalImageRenderer(view, fused);
    o->renderingMapper = nullptr;
    o->renderingVolume = nullptr;
    o->renderingRenderer = nullptr;
    return drawn;
}

@implementation IsiXVTKVolumeView

+ (instancetype)volumeViewWithError:(NSError **)error
{
    IsiXVTKVolumeView *view = [[self alloc] initPrivately];
    if (!IsiXVTKVolumeTry(error, "volumeView", {}, [&] {
        // VTK renders through a window of its own that draws nothing; the
        // frame is Metal's, in a layer of the view.
        view->_o->horosRenderer = HorosVRRenderer::New();
        view->_o->horosRenderWindow = HorosVRRenderWindow::New();
        view->_o->horosRenderWindow->AddRenderer(view->_o->horosRenderer);
    }))
        return nil;
    return view;
}

- (instancetype)initPrivately
{
    if ((self = [super init])) _o = new IsiXVTKVolumeViewObjects();
    return self;
}

- (void)dealloc
{
    [self releasePipeline];
    [self releasePresentation];
    delete _o;
}

- (void)releasePipeline
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o) return;
    IsiXVTKVolumeRun("releasePipeline", {}, [&] {
        if (o->lineMeasurementRenderObserver && o->aRenderer) o->aRenderer->RemoveObserver(o->lineMeasurementRenderObserver);
        o->lineMeasurementRenderObserver = 0;
    });
    _renderStartHandler = nil;
    [self releaseFusion];
    IsiXVTKVolumeRun("releasePipeline", {}, [&] {
        if (o->opacityTransferFunction) o->opacityTransferFunction->Delete();
        o->opacityTransferFunction = nullptr;
        if (o->volumeProperty) o->volumeProperty->Delete();
        o->volumeProperty = nullptr;
    });
    [self forgetOverlay];
    IsiXVTKVolumeRun("releasePipeline", {}, [&] {
        if (o->heldCrop) o->heldCrop->UnRegister(nullptr);
        o->heldCrop = nullptr;
        if (o->volumeMapper) o->volumeMapper->Delete();
        o->volumeMapper = nullptr;
        if (o->red) o->red->Delete();
        if (o->green) o->green->Delete();
        if (o->blue) o->blue->Delete();
        o->red = o->green = o->blue = nullptr;
        if (o->volume) o->volume->Delete();
        o->volume = nullptr;
        if (o->outlineData) o->outlineData->Delete();
        if (o->mapOutline) o->mapOutline->Delete();
        if (o->outlineRect) o->outlineRect->Delete();
        o->outlineData = nullptr;
        o->mapOutline = nullptr;
        o->outlineRect = nullptr;
        if (o->croppingBox) {
            o->croppingBox->InvokeEvent(vtkCommand::EndEvent, nullptr);
            o->croppingBox->RemoveObserver(o->cropcallback);
            o->croppingBox->Delete();
        }
        o->croppingBox = nullptr;
        if (o->cropcallback) o->cropcallback->Delete();
        o->cropcallback = nullptr;
        if (o->horosInteractor) o->horosInteractor->Delete();
        o->horosInteractor = nullptr;
        if (o->textWLWW) o->textWLWW->Delete();
        if (o->textX) o->textX->Delete();
        if (o->textTilt) o->textTilt->Delete();
        o->textWLWW = o->textX = o->textTilt = nullptr;
        for (int i = 0; i < 5; i++) {
            if (o->oText[i]) o->oText[i]->Delete();
            o->oText[i] = nullptr;
        }
        if (o->colorTransferFunction) o->colorTransferFunction->Delete();
        o->colorTransferFunction = nullptr;
        if (o->reader) o->reader->Delete();
        o->reader = nullptr;
        if (o->aCamera) o->aCamera->Delete();
        o->aCamera = nullptr;
        if (o->Oval2DData) o->Oval2DData->Delete();
        if (o->Oval2D) o->Oval2D->Delete();
        if (o->Oval2DActor) o->Oval2DActor->Delete();
        if (o->Oval2DText) o->Oval2DText->Delete();
        o->Oval2DData = nullptr;
        o->Oval2D = nullptr;
        o->Oval2DActor = nullptr;
        o->Oval2DText = nullptr;
        if (o->ROI3DData) o->ROI3DData->Delete();
        if (o->ROI3D) o->ROI3D->Delete();
        if (o->ROI3DActor) o->ROI3DActor->Delete();
        o->ROI3DData = nullptr;
        o->ROI3D = nullptr;
        o->ROI3DActor = nullptr;
    });
    [self clearStoredLines];
    IsiXVTKVolumeRun("releasePipeline", {}, [&] {
        if (o->lineMeasurementProjectionNotice) o->lineMeasurementProjectionNotice->Delete();
        o->lineMeasurementProjectionNotice = nullptr;
        if (o->Line2DData) o->Line2DData->Delete();
        if (o->Line2D) o->Line2D->Delete();
        if (o->Line2DActor) o->Line2DActor->Delete();
        if (o->Line2DText) o->Line2DText->Delete();
        o->Line2DData = nullptr;
        o->Line2D = nullptr;
        o->Line2DActor = nullptr;
        o->Line2DText = nullptr;
        if (o->Angle2DData) o->Angle2DData->Delete();
        if (o->Angle2D) o->Angle2D->Delete();
        if (o->Angle2DActor) o->Angle2DActor->Delete();
        if (o->Angle2DText) o->Angle2DText->Delete();
        o->Angle2DData = nullptr;
        o->Angle2D = nullptr;
        o->Angle2DActor = nullptr;
        o->Angle2DText = nullptr;
    });
}

- (void)releasePresentation
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o || !o->horosRenderWindow) return;
    IsiXVTKVolumeRun("releasePresentation", {}, [&] {
        o->horosRenderWindow->SetEyePresenter(nil);
        o->horosRenderWindow->SetPresenter(nil);
        o->horosRenderWindow->RemoveRenderer(o->horosRenderer);
        o->horosRenderer->Delete();
        o->horosRenderWindow->Delete();
    });
    o->horosRenderer = nullptr;
    o->horosRenderWindow = nullptr;
    o->aRenderer = nullptr;
}

#pragma mark Handles

- (void *)rendererHandle { return _o->horosRenderer; }
- (void *)renderWindowHandle { return _o->horosRenderWindow; }
- (void *)cameraHandle { return _o->aCamera; }
- (void *)volumeHandle { return _o->volume; }

- (BOOL)hasRenderer { return _o->aRenderer != nullptr; }
- (BOOL)hasCamera { return _o->aCamera != nullptr; }
- (BOOL)hasVolume { return _o->volume != nullptr; }
- (BOOL)hasVolumeMapper { return _o->volumeMapper != nullptr; }
- (BOOL)hasBlendingVolume { return _o->blendingVolume != nullptr; }
- (BOOL)hasBlendingMapper { return _o->blendingVolumeMapper != nullptr; }
- (BOOL)hasCropBox { return _o->croppingBox != nullptr; }
- (BOOL)hasProperty { return _o->volumeProperty != nullptr; }
- (BOOL)hasColourFunction { return _o->colorTransferFunction != nullptr; }
- (BOOL)hasOpacityFunction { return _o->opacityTransferFunction != nullptr; }
- (BOOL)hasWindowText { return _o->textWLWW != nullptr; }
- (BOOL)hasCornerText { return _o->textX != nullptr; }

- (BOOL)volumeHasMapper
{
    IsiXVTKVolumeViewObjects *o = _o;
    BOOL has = NO;
    IsiXVTKVolumeRun("volumeHasMapper", {}, [&] { has = o->volume && o->volume->GetMapper() != nullptr; });
    return has;
}

#pragma mark The window and the render

- (void)useOwnRenderer
{
    _o->aRenderer = _o->horosRenderer;
}

- (void)setPresenter:(id<IsiXVTKFramePresenter>)presenter
{
    IsiXVTKVolumeViewObjects *o = _o;
    IsiXVTKVolumeRun("setPresenter", {o->horosRenderWindow}, [&] { o->horosRenderWindow->SetPresenter(presenter); });
}

- (void)setStereoMode:(NSInteger)mode eyePresenter:(id<IsiXVTKFramePresenter>)eye
{
    IsiXVTKVolumeViewObjects *o = _o;
    IsiXVTKVolumeRun("setStereoMode", {o->horosRenderWindow}, [&] { HorosSetStereoMode(o->horosRenderWindow, mode, eye); });
}

- (void)setWindowWidth:(int)width height:(int)height dpi:(long)dpi
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->horosRenderWindow) return;
    IsiXVTKVolumeRun("setWindowSize", {}, [&] {
        int *current = o->horosRenderWindow->GetSize();
        if (current[0] != width || current[1] != height) o->horosRenderWindow->SetSize(width, height);
        // For text actors, as vtkCocoaGLView set it.
        if (o->horosRenderWindow->GetDPI() != dpi) o->horosRenderWindow->SetDPI((int)dpi);
    });
}

- (void)getWindowWidth:(int *)width height:(int *)height
{
    IsiXVTKVolumeViewObjects *o = _o;
    *width = *height = 0;
    if (!o->horosRenderWindow) return;
    IsiXVTKVolumeRun("windowSize", {}, [&] {
        int *size = o->horosRenderWindow->GetSize();
        *width = size[0];
        *height = size[1];
    });
}

- (void)setRendererDraws:(BOOL)draws
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->aRenderer) return;
    IsiXVTKVolumeRun("setDraw", {}, [&] { o->aRenderer->SetDraw(draws ? 1 : 0); });
}

- (void)setBackgroundRed:(double)red green:(double)green blue:(double)blue
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->aRenderer) return;
    IsiXVTKVolumeRun("setBackground", {}, [&] { o->aRenderer->SetBackground(red, green, blue); });
}

- (BOOL)renderWindowWithError:(NSError **)error
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->horosRenderWindow) return YES;
    // Exceptions only: what VTK reports goes to its output window, as it did,
    // and the frame stands.
    return IsiXVTKVolumeTry(error, "render", {}, [&] { o->horosRenderWindow->Render(); });
}

- (void)castVolumeImageFused:(BOOL)fused
{
    IsiXVTKVolumeViewObjects *o = _o;
    vtkHorosFixedPointVolumeRayCastMapper *mapper = fused ? o->blendingVolumeMapper : o->volumeMapper;
    vtkVolume *volume = fused ? o->blendingVolume : o->volume;
    if (!mapper) return;
    IsiXVTKVolumeRun("castVolumeImage", {mapper}, [&] {
        o->aRenderer->SetDraw(0);
        dontRenderVolumeRenderingOsiriX = 0;
        mapper->SetIntermixIntersectingGeometry(0);
        mapper->Render(o->aRenderer, volume);
        dontRenderVolumeRenderingOsiriX = 1;
    });
}

- (unsigned char *)copyFrameRGBWidth:(long *)width height:(long *)height stereo:(BOOL)stereo
{
    IsiXVTKVolumeViewObjects *o = _o;
    unsigned char *frame = nullptr;
    IsiXVTKVolumeRun("copyFrameRGB", {}, [&] {
        // Two pictures, one an eye, side by side as the original stereo exported them.
        if (stereo)
            frame = HorosCopyVRStereoFramebuffer(o->horosRenderWindow, o->horosRenderWindow, width, height, 1);
        else
            frame = HorosCopyVRFramebuffer(o->horosRenderWindow, width, height);
    });
    return frame;
}

+ (BOOL)volumeRenderingSuppressed
{
    return dontRenderVolumeRenderingOsiriX != 0;
}

+ (void)setVolumeRenderingSuppressed:(BOOL)suppressed
{
    dontRenderVolumeRenderingOsiriX = suppressed ? 1 : 0;
}

- (void)setMetalImageRenderer:(IsiXVTKMetalImageRenderer)renderer
{
    _metalImageRenderer = [renderer copy];
}

- (IsiXVTKVolumeScene *)renderingScene
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->renderingMapper) return nil;
    // The mapper and volume being rendered: the snapshots read the view's own.
    IsiXVTKVolumeSceneObjects objects;
    objects.renderer = o->renderingRenderer;
    objects.camera = o->aCamera;
    objects.window = o->horosRenderWindow;
    objects.mapper = o->renderingMapper;
    objects.volume = o->renderingVolume;
    return IsiXVTKMakeVolumeScene(objects);
}

- (IsiXVTKVolumeScene *)volumeSceneFused:(BOOL)fused
{
    IsiXVTKVolumeViewObjects *o = _o;
    IsiXVTKVolumeSceneObjects objects;
    objects.renderer = o->aRenderer;
    objects.camera = o->aCamera;
    objects.window = o->horosRenderWindow;
    if (fused) {
        if (o->blendingVolume) {
            objects.mapper = o->blendingVolumeMapper;
            objects.volume = o->blendingVolume;
            objects.property = o->blendingVolumeProperty;
            objects.colour = o->blendingColorTransferFunction;
            objects.opacity = o->blendingOpacityTransferFunction;
            objects.importer = o->blendingReader;
        }
    } else {
        objects.mapper = o->volumeMapper;
        objects.volume = o->volume;
        objects.property = o->volumeProperty;
        objects.colour = o->colorTransferFunction;
        objects.opacity = o->opacityTransferFunction;
        objects.importer = o->reader;
    }
    return IsiXVTKMakeVolumeScene(objects);
}

#pragma mark The 2D layer

// The 2D layer without VTK drawing it: the text actors, the 2D actors and the
// orientation cube stay VTK objects that hold what to show, and the view's
// overlay draws them over the volume. IsiXVTKOverlayObserver hides them from
// VTK's render and hands them back after it.

- (BOOL)observeOverlayWithHandler:(void (^)(IsiXVTKVolumeView *))handler error:(NSError **)error
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (_overlay && o->overlayRenderer == o->aRenderer) return YES;
    [self forgetOverlay];
    _overlayHandler = [handler copy];
    __weak IsiXVTKVolumeView *weakSelf = self;
    _overlay = [IsiXVTKOverlayObserver observerOfRenderer:o->aRenderer draw:^(const std::vector<vtkActor2D *> &shown) {
        IsiXVTKVolumeView *view = weakSelf;
        if (!view || !view->_overlayHandler) return;
        view->_o->overlayShown = &shown;
        view->_overlayHandler(view);
        view->_o->overlayShown = nullptr;
    } error:error];
    o->overlayRenderer = _overlay ? o->aRenderer : nullptr;
    return _overlay != nil;
}

- (void)forgetOverlay
{
    [_overlay invalidate];
    _overlay = nil;
    _overlayHandler = nil;
    if (_o) _o->overlayRenderer = nullptr;
}

- (IsiXVTKOverlayFrame *)overlayFrameHidingOrientationLetters:(BOOL)hideLetters cube:(BOOL)cube picked:(void *)picked
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->overlayShown) return nil;
    std::vector<vtkActor2D *> shown = *o->overlayShown;
    // In stereo, the cube and the orientation letters go away, as they did
    // from the original stereo mode.
    if (hideLetters)
        shown.erase(std::remove_if(shown.begin(), shown.end(), [o](vtkActor2D *actor) {
            return std::find(o->oText, o->oText + 4, actor) != o->oText + 4;
        }), shown.end());
    return IsiXVTKReadOverlayFrame(o->aRenderer, shown, cube, o->croppingBox, (vtkActor *)picked);
}

- (void)observeRenderStartWithHandler:(void (^)(void))handler
{
    IsiXVTKVolumeViewObjects *o = _o;
    _renderStartHandler = [handler copy];
    if (!o->aRenderer || o->lineMeasurementRenderObserver) return;
    IsiXVTKVolumeRun("observeRenderStart", {o->aRenderer}, [&] {
        vtkCallbackCommand *callback = vtkCallbackCommand::New();
        callback->SetClientData((__bridge void *)self);
        callback->SetCallback([](vtkObject *, unsigned long, void *context, void *) {
            IsiXVTKVolumeView *view = (__bridge IsiXVTKVolumeView *)context;
            if (view->_renderStartHandler) view->_renderStartHandler();
        });
        o->lineMeasurementRenderObserver = o->aRenderer->AddObserver(vtkCommand::StartEvent, callback);
        callback->Delete();
    });
}

#pragma mark The interactor

- (void)setInteractorDeltaTransform:(double (*)(double))transform
{
    _o->deltaTransform = transform;
}

// The mouse interaction VTK's interactor did: the camera and the crop box.
- (HorosVRInteractor *)interactor
{
    IsiXVTKVolumeViewObjects *o = _o;
    IsiXVTKVolumeRun("interactor", {}, [&] {
        if (o->horosInteractor == nullptr) {
            o->horosInteractor = HorosVRInteractor::New();
            o->horosInteractor->SetDeltaTransform(o->deltaTransform);
        }
        o->horosInteractor->SetRenderer(o->aRenderer);
    });
    return o->horosInteractor;
}

- (BOOL)prepareInteractor
{
    return [self interactor] != nullptr;
}

- (void)setInteractorEventX:(int)x y:(int)y control:(int)control shift:(int)shift
{
    HorosVRInteractor *interactor = [self interactor];
    if (!interactor) return;
    IsiXVTKVolumeRun("setInteractorEvent", {}, [&] { interactor->SetEventInformation(x, y, control, shift); });
}

- (void)setInteractorEventX:(int)x y:(int)y control:(int)control shift:(int)shift repeat:(int)repeat alt:(BOOL)alt
{
    HorosVRInteractor *interactor = [self interactor];
    if (!interactor) return;
    IsiXVTKVolumeRun("setInteractorEvent", {}, [&] {
        interactor->SetEventInformation(x, y, control, shift, 0, repeat);
        interactor->SetAltKey(alt ? 1 : 0);
    });
}

- (void)invokeInteractorEvent:(IsiXVTKMouseEvent)event
{
    HorosVRInteractor *interactor = [self interactor];
    if (!interactor) return;
    IsiXVTKVolumeRun("invokeInteractorEvent", {}, [&] { interactor->InvokeEvent(IsiXVTKVolumeEventId(event), nullptr); });
}

- (void)setInteractorRotationPivot:(const double *)pivot
{
    HorosVRInteractor *interactor = [self interactor];
    if (!interactor) return;
    IsiXVTKVolumeRun("setRotationPivot", {}, [&] { interactor->SetRotationPivot(pivot); });
}

- (void)clearInteractorRotationPivot
{
    HorosVRInteractor *interactor = [self interactor];
    if (!interactor) return;
    IsiXVTKVolumeRun("clearRotationPivot", {}, [&] { interactor->ClearRotationPivot(); });
}

- (void)interactorWorldToDisplayX:(double)x y:(double)y z:(double)z display:(double *)display
{
    IsiXVTKVolumeViewObjects *o = _o;
    IsiXVTKVolumeRun("worldToDisplay", {}, [&] { HorosVRInteractor::ComputeWorldToDisplay(o->aRenderer, x, y, z, display); });
}

- (void)interactorDisplayToWorldX:(double)x y:(double)y z:(double)z world:(double *)world
{
    IsiXVTKVolumeViewObjects *o = _o;
    IsiXVTKVolumeRun("displayToWorld", {}, [&] { HorosVRInteractor::ComputeDisplayToWorld(o->aRenderer, x, y, z, world); });
}

- (void)updateLightsAfterPan
{
    IsiXVTKVolumeViewObjects *o = _o;
    HorosVRInteractor *interactor = [self interactor];
    IsiXVTKVolumeRun("updateLightsAfterPan", {}, [&] {
        if (interactor && interactor->GetLightFollowCamera())
            o->aRenderer->UpdateLightsGeometryToFollowCamera();
    });
}

@end
