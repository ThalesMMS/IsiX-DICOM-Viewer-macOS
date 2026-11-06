//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The renderer, render window and interactor of a surface view, and its
// camera (IsiXVTKScene.h).

#import "IsiXVTKSceneInternal.hpp"
#import "IsiXVTKSceneOverlay.hpp"
#import "IsiXVTKVolumePresentation.hpp"
#import "IsiXVTKVolumeInteraction.hpp"
#include "IsiXVTKFramebufferCapture.hpp"
#include "IsiXVTKSurfaceExport.hpp"

#import <objc/message.h>

#include <vtkActor.h>
#include <vtkActorCollection.h>
#include <vtkAppendPolyData.h>
#include <vtkCallbackCommand.h>
#include <vtkCamera.h>
#include <vtkCellPicker.h>
#include <vtkCommand.h>
#include <vtkIVExporter.h>
#include <vtkMatrix4x4.h>
#include <vtkOBJExporter.h>
#include <vtkPolyData.h>
#include <vtkPolyDataMapper.h>
#include <vtkRIBExporter.h>
#include <vtkRenderWindow.h>
#include <vtkRenderer.h>
#include <vtkSTLWriter.h>
#include <vtkTextActor.h>
#include <vtkTransform.h>
#include <vtkTransformFilter.h>
#include <vtkVRMLExporter.h>

/// Runs a setter's `body` in the guard, logging a failure.
template <typename Body>
static inline void IsiXVTKSceneSet(const char *operation, std::initializer_list<vtkObject *> objects, Body &&body)
{
    NSError *error = nil;
    if (!IsiXVTKGuard(&error, operation, objects, [&]() -> NSError * { body(); return nil; }))
        IsiXVTKLogFailure(error);
}

@interface IsiXVTKCamera ()
- (instancetype)initWithCamera:(vtkCamera *)camera;
@end

@implementation IsiXVTKCamera
{
    vtkSmartPointer<vtkCamera> _camera;
}

- (instancetype)initWithCamera:(vtkCamera *)camera
{
    if ((self = [super init])) _camera = camera;
    return self;
}

static IsiXVTKPoint IsiXVTKPointOf(const double *p) { return {p[0], p[1], p[2]}; }

- (IsiXVTKPoint)position
{
    IsiXVTKPoint point = {0, 0, 0};
    IsiXVTKSceneSet("cameraPosition", {_camera}, [&] { point = IsiXVTKPointOf(_camera->GetPosition()); });
    return point;
}

- (void)setPosition:(IsiXVTKPoint)p
{
    IsiXVTKSceneSet("setCameraPosition", {_camera}, [&] { _camera->SetPosition(p.x, p.y, p.z); });
}

- (IsiXVTKPoint)focalPoint
{
    IsiXVTKPoint point = {0, 0, 0};
    IsiXVTKSceneSet("cameraFocalPoint", {_camera}, [&] { point = IsiXVTKPointOf(_camera->GetFocalPoint()); });
    return point;
}

- (void)setFocalPoint:(IsiXVTKPoint)p
{
    IsiXVTKSceneSet("setCameraFocalPoint", {_camera}, [&] { _camera->SetFocalPoint(p.x, p.y, p.z); });
}

- (IsiXVTKPoint)viewUp
{
    IsiXVTKPoint point = {0, 0, 0};
    IsiXVTKSceneSet("cameraViewUp", {_camera}, [&] { point = IsiXVTKPointOf(_camera->GetViewUp()); });
    return point;
}

- (void)setViewUp:(IsiXVTKPoint)p
{
    IsiXVTKSceneSet("setCameraViewUp", {_camera}, [&] { _camera->SetViewUp(p.x, p.y, p.z); });
}

- (IsiXVTKPoint)viewPlaneNormal
{
    IsiXVTKPoint point = {0, 0, 0};
    IsiXVTKSceneSet("cameraViewPlaneNormal", {_camera}, [&] { point = IsiXVTKPointOf(_camera->GetViewPlaneNormal()); });
    return point;
}

#define ISIX_VTK_CAMERA_SCALAR(getter, setter, Get, Set)                                         \
    -(double)getter                                                                              \
    {                                                                                            \
        double value = 0;                                                                        \
        IsiXVTKSceneSet(#getter, {_camera}, [&] { value = _camera->Get(); });                    \
        return value;                                                                            \
    }                                                                                            \
    -(void)setter : (double)value                                                                \
    {                                                                                            \
        IsiXVTKSceneSet(#setter, {_camera}, [&] { _camera->Set(value); });                       \
    }

ISIX_VTK_CAMERA_SCALAR(distance, setDistance, GetDistance, SetDistance)
ISIX_VTK_CAMERA_SCALAR(viewAngle, setViewAngle, GetViewAngle, SetViewAngle)
ISIX_VTK_CAMERA_SCALAR(eyeAngle, setEyeAngle, GetEyeAngle, SetEyeAngle)
ISIX_VTK_CAMERA_SCALAR(parallelScale, setParallelScale, GetParallelScale, SetParallelScale)

#undef ISIX_VTK_CAMERA_SCALAR

- (BOOL)parallelProjection
{
    BOOL parallel = NO;
    IsiXVTKSceneSet("parallelProjection", {_camera}, [&] { parallel = _camera->GetParallelProjection() != 0; });
    return parallel;
}

- (void)setParallelProjection:(BOOL)parallel
{
    IsiXVTKSceneSet("setParallelProjection", {_camera}, [&] { _camera->SetParallelProjection(parallel); });
}

- (void)getClippingRangeNear:(double *)near far:(double *)far
{
    IsiXVTKSceneSet("clippingRange", {_camera}, [&] {
        double range[2];
        _camera->GetClippingRange(range);
        if (near) *near = range[0];
        if (far) *far = range[1];
    });
}

- (void)getViewTransform:(double *)rowMajor
{
    IsiXVTKSceneSet("viewTransform", {_camera}, [&] {
        vtkMatrix4x4 *matrix = _camera->GetViewTransformMatrix();
        for (int r = 0; r < 4; r++)
            for (int c = 0; c < 4; c++) rowMajor[4 * r + c] = matrix->GetElement(r, c);
    });
}

#define ISIX_VTK_CAMERA_MOVE(name, Call)                                                         \
    -(void)name : (double)value                                                                  \
    {                                                                                            \
        IsiXVTKSceneSet(#name, {_camera}, [&] { _camera->Call(value); });                        \
    }

ISIX_VTK_CAMERA_MOVE(azimuth, Azimuth)
ISIX_VTK_CAMERA_MOVE(elevation, Elevation)
ISIX_VTK_CAMERA_MOVE(yaw, Yaw)
ISIX_VTK_CAMERA_MOVE(pitch, Pitch)
ISIX_VTK_CAMERA_MOVE(roll, Roll)
ISIX_VTK_CAMERA_MOVE(setRoll, SetRoll)
ISIX_VTK_CAMERA_MOVE(dolly, Dolly)
ISIX_VTK_CAMERA_MOVE(zoom, Zoom)

#undef ISIX_VTK_CAMERA_MOVE

- (void)computeViewPlaneNormal
{
    IsiXVTKSceneSet("computeViewPlaneNormal", {_camera}, [&] { _camera->ComputeViewPlaneNormal(); });
}

- (void)orthogonalizeViewUp
{
    IsiXVTKSceneSet("orthogonalizeViewUp", {_camera}, [&] { _camera->OrthogonalizeViewUp(); });
}

@end

/// The interactor's events, by IsiXVTKMouseEvent.
static unsigned long IsiXVTKEventId(IsiXVTKMouseEvent event)
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

@implementation IsiXVTKScene
{
    vtkSmartPointer<vtkRenderer> _renderer;
    vtkSmartPointer<HorosVRRenderWindow> _window;
    vtkSmartPointer<HorosVRInteractor> _interactor;
    unsigned long _endTag;
    void (^_renderEnded)(void);
}

+ (instancetype)sceneWithError:(NSError **)error
{
    return [[self alloc] initWithError:error];
}

- (instancetype)initWithError:(NSError **)error
{
    if (!(self = [super init])) return nil;
    BOOL built = IsiXVTKGuard(error, "scene", {}, [&]() -> NSError * {
        _renderer = vtkSmartPointer<HorosVRRenderer>::New();
        _window = vtkSmartPointer<HorosVRRenderWindow>::New();
        _window->AddRenderer(_renderer);
        _interactor = vtkSmartPointer<HorosVRInteractor>::New();
        _interactor->SetRenderer(_renderer);

        // The handler after each render. The observer holds the scene
        // unretained: the scene removes it before it goes.
        vtkSmartPointer<vtkCallbackCommand> end = vtkSmartPointer<vtkCallbackCommand>::New();
        end->SetClientData((__bridge void *)self);
        end->SetCallback([](vtkObject *, unsigned long, void *context, void *) {
            IsiXVTKScene *scene = (__bridge IsiXVTKScene *)context;
            if (scene->_renderEnded) scene->_renderEnded();
        });
        _endTag = _renderer->AddObserver(vtkCommand::EndEvent, end);
        return nil;
    });
    return built ? self : nil;
}

+ (instancetype)sceneOfView:(id)view
{
    // -renderer of VRView, which this adapter does not import.
    SEL rendererSelector = NSSelectorFromString(@"renderer");
    if (![view respondsToSelector:rendererSelector]) return nil;
    vtkRenderer *renderer = ((vtkRenderer * (*)(id, SEL)) objc_msgSend)(view, rendererSelector);
    if (!renderer) return nil;
    IsiXVTKScene *scene = [[IsiXVTKScene alloc] initBorrowing:renderer];
    return scene;
}

- (instancetype)initBorrowing:(vtkRenderer *)renderer
{
    if ((self = [super init])) _renderer = renderer;
    return self;
}

- (void)dealloc
{
    _renderEnded = nil;
    if (!_window) return;
    IsiXVTKSceneSet("sceneDealloc", {}, [&] {
        _renderer->RemoveObserver(_endTag);
        _window->SetEyePresenter(nil);
        _window->SetPresenter(nil);
        _window->RemoveRenderer(_renderer);
    });
}

- (const void *)rendererIdentity { return _renderer.GetPointer(); }
- (void *)vtkRenderer { return _renderer.GetPointer(); }
- (void *)vtkRenderWindow { return _window.GetPointer(); }

- (void)setPresenter:(id<IsiXVTKFramePresenter>)presenter
{
    if (!_window) return;
    IsiXVTKSceneSet("setPresenter", {_window}, [&] { _window->SetPresenter(presenter); });
}

- (void)setStereoMode:(NSInteger)mode eyePresenter:(id<IsiXVTKFramePresenter>)eye
{
    if (!_window) return;
    IsiXVTKSceneSet("setStereoMode", {_window}, [&] { HorosSetStereoMode(_window, mode, eye); });
}

- (BOOL)stereoRender
{
    BOOL stereo = NO;
    if (_window) IsiXVTKSceneSet("stereoRender", {_window}, [&] { stereo = _window->GetStereoRender() != 0; });
    return stereo;
}

- (void)setRenderEndHandler:(void (^)(void))handler
{
    _renderEnded = [handler copy];
}

- (void)setDeltaTransform:(double (*)(double))transform
{
    if (_interactor) _interactor->SetDeltaTransform(transform);
}

- (NSInteger)width
{
    NSInteger width = 0;
    if (_window) IsiXVTKSceneSet("width", {_window}, [&] { width = _window->GetSize()[0]; });
    return width;
}

- (NSInteger)height
{
    NSInteger height = 0;
    if (_window) IsiXVTKSceneSet("height", {_window}, [&] { height = _window->GetSize()[1]; });
    return height;
}

- (void)setWidth:(NSInteger)width height:(NSInteger)height
{
    if (!_window) return;
    IsiXVTKSceneSet("setSize", {_window}, [&] {
        int *current = _window->GetSize();
        if (current[0] != width || current[1] != height) _window->SetSize((int)width, (int)height);
    });
}

- (NSInteger)dpi
{
    NSInteger dpi = 0;
    if (_window) IsiXVTKSceneSet("dpi", {_window}, [&] { dpi = _window->GetDPI(); });
    return dpi;
}

- (void)setDpi:(NSInteger)dpi
{
    if (!_window) return;
    IsiXVTKSceneSet("setDPI", {_window}, [&] {
        if (_window->GetDPI() != dpi) _window->SetDPI((int)dpi);
    });
}

- (BOOL)renderWithError:(NSError **)error
{
    if (!_window) return YES;
    // No error observer: a render touches every actor of the scene, and VTK
    // logs what they report itself.
    return IsiXVTKGuard(error, "render", {}, [&]() -> NSError * {
        _window->Render();
        return nil;
    });
}

- (void)addActor:(IsiXVTKActor *)actor
{
    IsiXVTKSceneSet("addActor", {_renderer}, [&] { _renderer->AddActor([actor actor]); });
}

- (void)removeActor:(IsiXVTKActor *)actor
{
    IsiXVTKSceneSet("removeActor", {_renderer}, [&] { _renderer->RemoveActor([actor actor]); });
}

- (BOOL)containsActor:(IsiXVTKActor *)actor
{
    BOOL present = NO;
    IsiXVTKSceneSet("containsActor", {_renderer}, [&] { present = _renderer->GetActors()->IsItemPresent([actor actor]) != 0; });
    return present;
}

- (void)addActorPointer:(void *)actor
{
    IsiXVTKSceneSet("addActor", {_renderer}, [&] { _renderer->AddActor(static_cast<vtkActor *>(actor)); });
}

- (void)removeActorPointer:(void *)actor
{
    IsiXVTKSceneSet("removeActor", {_renderer}, [&] { _renderer->RemoveActor(static_cast<vtkActor *>(actor)); });
}

- (void)addText:(IsiXVTKTextActor *)text
{
    IsiXVTKSceneSet("addText", {_renderer}, [&] { _renderer->AddViewProp([text textActor]); });
}

- (void)removeText:(IsiXVTKTextActor *)text
{
    IsiXVTKSceneSet("removeText", {_renderer}, [&] { _renderer->RemoveViewProp([text textActor]); });
}

- (void)removeAllViewProps
{
    IsiXVTKSceneSet("removeAllViewProps", {_renderer}, [&] { _renderer->RemoveAllViewProps(); });
}

- (void)setBackgroundRed:(double)red green:(double)green blue:(double)blue
{
    IsiXVTKSceneSet("setBackground", {_renderer}, [&] { _renderer->SetBackground(red, green, blue); });
}

- (IsiXVTKCamera *)camera
{
    vtkCamera *camera = nullptr;
    IsiXVTKSceneSet("camera", {_renderer}, [&] { camera = _renderer->GetActiveCamera(); });
    return [[IsiXVTKCamera alloc] initWithCamera:camera];
}

- (void)useNewCamera
{
    IsiXVTKSceneSet("useNewCamera", {_renderer}, [&] {
        _renderer->SetActiveCamera(vtkSmartPointer<vtkCamera>::New());
    });
}

- (void)resetCamera
{
    IsiXVTKSceneSet("resetCamera", {_renderer}, [&] { _renderer->ResetCamera(); });
}

- (void)resetCameraClippingRange
{
    IsiXVTKSceneSet("resetCameraClippingRange", {_renderer}, [&] { _renderer->ResetCameraClippingRange(); });
}

- (void)updateLightsToFollowCamera
{
    IsiXVTKSceneSet("updateLights", {_renderer}, [&] { _renderer->UpdateLightsGeometryToFollowCamera(); });
}

- (void)setEventX:(int)x y:(int)y control:(BOOL)control shift:(BOOL)shift repeat:(int)repeat
{
    if (_interactor) _interactor->SetEventInformation(x, y, control ? 1 : 0, shift ? 1 : 0, 0, repeat);
}

- (void)setAltKey:(BOOL)alt
{
    if (_interactor) _interactor->SetAltKey(alt ? 1 : 0);
}

- (void)invokeEvent:(IsiXVTKMouseEvent)event
{
    if (!_interactor) return;
    IsiXVTKSceneSet("invokeEvent", {_interactor, _renderer}, [&] { _interactor->InvokeEvent(IsiXVTKEventId(event), nullptr); });
}

- (BOOL)lightFollowsCamera
{
    return _interactor && _interactor->GetLightFollowCamera();
}

- (IsiXVTKPoint)displayPointOfWorld:(IsiXVTKPoint)world
{
    IsiXVTKPoint display = {0, 0, 0};
    IsiXVTKSceneSet("displayPoint", {_renderer}, [&] {
        double d[3];
        HorosVRInteractor::ComputeWorldToDisplay(_renderer, world.x, world.y, world.z, d);
        display = {d[0], d[1], d[2]};
    });
    return display;
}

- (IsiXVTKPoint)worldPointOfDisplayX:(double)x y:(double)y z:(double)z
{
    IsiXVTKPoint world = {0, 0, 0};
    IsiXVTKSceneSet("worldPoint", {_renderer}, [&] {
        double w[4];
        HorosVRInteractor::ComputeDisplayToWorld(_renderer, x, y, z, w);
        world = {w[0], w[1], w[2]};
    });
    return world;
}

- (BOOL)pickActors:(NSArray<IsiXVTKActor *> *)actors x:(double)x y:(double)y tolerance:(double)tolerance
             world:(IsiXVTKPoint *)world
{
    BOOL hit = NO;
    NSError *error = nil;
    BOOL picked = IsiXVTKGuard(&error, "pick", {_renderer}, [&]() -> NSError * {
        std::vector<int> wasPickable;
        for (IsiXVTKActor *actor in actors) {
            wasPickable.push_back([actor actor]->GetPickable());
            [actor actor]->PickableOn();
        }
        vtkSmartPointer<vtkCellPicker> picker = vtkSmartPointer<vtkCellPicker>::New();
        picker->SetTolerance(tolerance);
        hit = picker->Pick(x, y, 0.0, _renderer) != 0;
        double position[3];
        picker->GetPickPosition(position);
        if (world) *world = {position[0], position[1], position[2]};
        size_t index = 0;
        for (IsiXVTKActor *actor in actors) [actor actor]->SetPickable(wasPickable[index++]);
        return nil;
    });
    if (!picked) IsiXVTKLogFailure(error);
    return picked && hit;
}

- (IsiXVTKOverlayFrame *)overlayFrameWithCube:(BOOL)cube picked:(IsiXVTKActor *)picked error:(NSError **)error
{
    std::vector<vtkActor2D *> shown = IsiXVTKVisibleActors2D(_renderer);
    IsiXVTKOverlayFrame *frame = IsiXVTKReadOverlayFrame(_renderer, shown, cube, nullptr, picked ? [picked actor] : nullptr);
    if (!frame && error) *error = IsiXVTKFailure(IsiXVTKErrorCodeUnavailable, @"no 2D layer to draw", "overlayFrame");
    return frame;
}

- (uint8_t *)copyFrameRGBWidth:(long *)width height:(long *)height stereo:(BOOL)stereo
{
    unsigned char *buffer = nullptr;
    *width = *height = 0;
    if (!_window) return nullptr;
    IsiXVTKSceneSet("copyFrame", {_window}, [&] {
        buffer = stereo ? HorosCopyVRStereoFramebuffer(_window, _window, width, height, 1)
                        : HorosCopyVRFramebuffer(_window, width, height);
    });
    return buffer;
}

- (BOOL)exportFormat:(IsiXVTKSceneFormat)format toPath:(NSString *)path error:(NSError **)error
{
    if (!_window) {
        if (error) *error = IsiXVTKFailure(IsiXVTKErrorCodeUnavailable, @"no render window", "export");
        return NO;
    }
    return IsiXVTKGuard(error, "export", {}, [&]() -> NSError * {
        NSString *prefix = path.stringByDeletingPathExtension;
        switch (format) {
            case IsiXVTKSceneFormatRIB: {
                auto exporter = vtkSmartPointer<vtkRIBExporter>::New();
                exporter->SetRenderWindow(_window);
                exporter->SetFilePrefix(prefix.UTF8String);
                IsiXVTKErrorCapture capture({exporter.Get()}, "export");
                exporter->Write();
                if (NSError *failure = capture.Error()) return failure;
                break;
            }
            case IsiXVTKSceneFormatVRML: {
                auto exporter = vtkSmartPointer<vtkVRMLExporter>::New();
                exporter->SetRenderWindow(_window);
                exporter->SetFileName(path.UTF8String);
                IsiXVTKErrorCapture capture({exporter.Get()}, "export");
                exporter->Write();
                if (NSError *failure = capture.Error()) return failure;
                break;
            }
            case IsiXVTKSceneFormatInventor: {
                auto exporter = vtkSmartPointer<vtkIVExporter>::New();
                exporter->SetRenderWindow(_window);
                exporter->SetFileName(path.UTF8String);
                IsiXVTKErrorCapture capture({exporter.Get()}, "export");
                exporter->Write();
                if (NSError *failure = capture.Error()) return failure;
                break;
            }
            case IsiXVTKSceneFormatOBJ: {
                auto exporter = vtkSmartPointer<vtkOBJExporter>::New();
                exporter->SetRenderWindow(_window);
                exporter->SetFilePrefix(prefix.UTF8String);
                IsiXVTKErrorCapture capture({exporter.Get()}, "export");
                exporter->Write();
                if (NSError *failure = capture.Error()) return failure;
                break;
            }
            default:
                return IsiXVTKFailure(IsiXVTKErrorCodeInvalidArgument, @"no such scene format", "export");
        }
        return nil;
    });
}

+ (BOOL)writeSTLOfActors:(NSArray<IsiXVTKActor *> *)actors toPath:(NSString *)path error:(NSError **)error
{
    return IsiXVTKGuard(error, "writeSTL", {}, [&]() -> NSError * {
        std::vector<vtkActor *> surfaces;
        for (IsiXVTKActor *item in actors) surfaces.push_back([item actor]);
        vtkSmartPointer<vtkPolyData> result = HorosSurfaceExportGeometry(surfaces.data(), (int)surfaces.size());
        auto writer = vtkSmartPointer<vtkSTLWriter>::New();
        writer->SetInputData(result);
        writer->SetFileName(path.UTF8String);
        IsiXVTKErrorCapture capture({writer.Get()}, "writeSTL");
        writer->Write();
        if (NSError *failure = capture.Error()) return failure;
        return nil;
    });
}

@end
