//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The volume rendering view's camera and its renderer's coordinates
// (IsiXVTKVolumeView.h): each call is one of the view's calls to vtkCamera or
// vtkRenderer, without a camera or renderer a call that does nothing.

#import "IsiXVTKVolumeViewInternal.hpp"

#include <cmath>
#include <vtkCamera.h>
#include <vtkMath.h>
#include <vtkMatrix4x4.h>
#include <vtkRenderer.h>
#include <vtkTransform.h>

#define ISIX_CAMERA(operation, body)                                                             \
    vtkCamera *aCamera = _o->aCamera;                                                            \
    if (!aCamera) return;                                                                        \
    IsiXVTKVolumeRun(operation, {}, [&] { body; })

#define ISIX_CAMERA_VALUE(type, initial, operation, expression)                                  \
    vtkCamera *aCamera = _o->aCamera;                                                            \
    type value = initial;                                                                        \
    if (!aCamera) return value;                                                                  \
    IsiXVTKVolumeRun(operation, {}, [&] { value = expression; });                                \
    return value

#define ISIX_RENDERER(operation, body)                                                           \
    vtkRenderer *aRenderer = _o->aRenderer;                                                      \
    if (!aRenderer) return;                                                                      \
    IsiXVTKVolumeRun(operation, {}, [&] { body; })

@implementation IsiXVTKVolumeView (IsiXVTKVolumeCamera)

- (void)getCameraPosition:(double *)position { ISIX_CAMERA("cameraPosition", aCamera->GetPosition(position)); }
- (void)setCameraPosition:(const double *)position { ISIX_CAMERA("setCameraPosition", aCamera->SetPosition(position[0], position[1], position[2])); }
- (void)getCameraFocalPoint:(double *)focal { ISIX_CAMERA("cameraFocalPoint", aCamera->GetFocalPoint(focal)); }
- (void)setCameraFocalPoint:(const double *)focal { ISIX_CAMERA("setCameraFocalPoint", aCamera->SetFocalPoint(focal[0], focal[1], focal[2])); }
- (void)getCameraViewUp:(double *)viewUp { ISIX_CAMERA("cameraViewUp", aCamera->GetViewUp(viewUp)); }
- (void)setCameraViewUp:(const double *)viewUp { ISIX_CAMERA("setCameraViewUp", aCamera->SetViewUp(viewUp[0], viewUp[1], viewUp[2])); }
- (void)getCameraViewPlaneNormal:(double *)normal { ISIX_CAMERA("cameraViewPlaneNormal", aCamera->GetViewPlaneNormal(normal)); }
- (void)getCameraDirectionOfProjection:(double *)direction { ISIX_CAMERA("cameraDirectionOfProjection", aCamera->GetDirectionOfProjection(direction)); }

- (BOOL)getCameraViewUp:(double *)viewUp directionOfProjection:(double *)direction
{
    vtkCamera *aCamera = _o->aCamera;
    if (!aCamera) return NO;
    IsiXVTKVolumeRun("cameraOrientation", {}, [&] {
        aCamera->GetViewUp(viewUp);
        aCamera->GetDirectionOfProjection(direction);
    });
    return YES;
}

- (void)getCameraWindowCenter:(double *)center { ISIX_CAMERA("cameraWindowCenter", aCamera->GetWindowCenter(center)); }
- (void)setCameraWindowCenterX:(double)x y:(double)y { ISIX_CAMERA("setCameraWindowCenter", aCamera->SetWindowCenter(x, y)); }
- (void)getCameraClippingRange:(double *)range { ISIX_CAMERA("cameraClippingRange", aCamera->GetClippingRange(range)); }
- (void)setCameraClippingRangeNear:(double)near far:(double)far { ISIX_CAMERA("setCameraClippingRange", aCamera->SetClippingRange(near, far)); }

- (void)getCameraViewTransform:(double *)rowMajor
{
    ISIX_CAMERA("cameraViewTransform", {
        vtkMatrix4x4 *matrix = aCamera->GetViewTransformMatrix();
        for (int r = 0; r < 4; r++)
            for (int c = 0; c < 4; c++) rowMajor[4 * r + c] = matrix->GetElement(r, c);
    });
}

- (double)cameraDistance { ISIX_CAMERA_VALUE(double, 0, "cameraDistance", aCamera->GetDistance()); }
- (void)setCameraDistance:(double)distance { ISIX_CAMERA("setCameraDistance", aCamera->SetDistance(distance)); }
- (double)cameraParallelScale { ISIX_CAMERA_VALUE(double, 0, "cameraParallelScale", aCamera->GetParallelScale()); }
- (void)setCameraParallelScale:(double)scale { ISIX_CAMERA("setCameraParallelScale", aCamera->SetParallelScale(scale)); }
- (double)cameraViewAngle { ISIX_CAMERA_VALUE(double, 30, "cameraViewAngle", aCamera->GetViewAngle()); }
- (void)setCameraViewAngle:(double)angle { ISIX_CAMERA("setCameraViewAngle", aCamera->SetViewAngle(angle)); }
- (double)cameraEyeAngle { ISIX_CAMERA_VALUE(double, 0, "cameraEyeAngle", aCamera->GetEyeAngle()); }
- (void)setCameraEyeAngle:(double)angle { ISIX_CAMERA("setCameraEyeAngle", aCamera->SetEyeAngle(angle)); }
- (BOOL)cameraParallelProjection { ISIX_CAMERA_VALUE(BOOL, NO, "cameraParallelProjection", aCamera->GetParallelProjection() != 0); }
- (void)setCameraParallelProjection:(BOOL)parallel { ISIX_CAMERA("setCameraParallelProjection", aCamera->SetParallelProjection(parallel)); }
- (double)cameraRoll { ISIX_CAMERA_VALUE(double, 0, "cameraRoll", aCamera->GetRoll()); }
- (void)setCameraRoll:(double)degrees { ISIX_CAMERA("setCameraRoll", aCamera->SetRoll(degrees)); }

- (void)cameraAzimuth:(double)degrees { ISIX_CAMERA("cameraAzimuth", aCamera->Azimuth(degrees)); }
- (void)cameraElevation:(double)degrees { ISIX_CAMERA("cameraElevation", aCamera->Elevation(degrees)); }
- (void)cameraYaw:(double)degrees { ISIX_CAMERA("cameraYaw", aCamera->Yaw(degrees)); }
- (void)cameraPitch:(double)degrees { ISIX_CAMERA("cameraPitch", aCamera->Pitch(degrees)); }
- (void)cameraRoll:(double)degrees { ISIX_CAMERA("cameraRollBy", aCamera->Roll(degrees)); }
- (void)cameraDolly:(double)factor { ISIX_CAMERA("cameraDolly", aCamera->Dolly(factor)); }
- (void)cameraZoom:(double)factor { ISIX_CAMERA("cameraZoom", aCamera->Zoom(factor)); }
- (void)cameraComputeViewPlaneNormal { ISIX_CAMERA("cameraComputeViewPlaneNormal", aCamera->ComputeViewPlaneNormal()); }
- (void)cameraOrthogonalizeViewUp { ISIX_CAMERA("cameraOrthogonalizeViewUp", aCamera->OrthogonalizeViewUp()); }

- (void)cameraTranslateX:(double)x y:(double)y z:(double)z
{
    ISIX_CAMERA("cameraTranslate", {
        vtkTransform *back = vtkTransform::New();
        back->Translate( x, y, z);
        aCamera->ApplyTransform( back);
        back->Delete();
    });
}

- (void)cameraViewTransformPoint:(const double *)point into:(double *)result
{
    ISIX_CAMERA("cameraViewTransformPoint", aCamera->GetViewTransformMatrix()->MultiplyPoint( point, result));
}

- (void)cameraInverseViewTransformPoint:(const double *)point into:(double *)result
{
    ISIX_CAMERA("cameraInverseViewTransformPoint", {
        vtkMatrix4x4 *cameraToWorld = vtkMatrix4x4::New();
        vtkMatrix4x4::Invert( aCamera->GetViewTransformMatrix(), cameraToWorld);
        cameraToWorld->MultiplyPoint( point, result);
        cameraToWorld->Delete();
    });
}

- (BOOL)copyCameraFromHandle:(void *)handle
{
    vtkCamera *aCamera = _o->aCamera;
    vtkCamera *aVtkCamera = (vtkCamera *)handle;
    if (aCamera == nullptr || aVtkCamera == nullptr) return NO;
    BOOL copied = NO;
    IsiXVTKVolumeRun("copyCamera", {}, [&] {
        double pos[3], focal[3], vUp[3], parallelScale;
        aVtkCamera->GetPosition(pos);
        aVtkCamera->GetFocalPoint(focal);
        aVtkCamera->GetViewUp(vUp);
        parallelScale = aVtkCamera->GetParallelScale();

        double currentPos[3], currentFocal[3], currentVUp[3], currentParallelScale;
        aCamera->GetPosition(currentPos);
        aCamera->GetFocalPoint(currentFocal);
        aCamera->GetViewUp(currentVUp);
        currentParallelScale = aCamera->GetParallelScale();

        if(currentPos[0]==pos[0] && currentPos[1]==pos[1] && currentPos[2]==pos[2]
           && currentFocal[0]==focal[0] && currentFocal[1]==focal[1] && currentFocal[2]==focal[2]
           && currentVUp[0]==vUp[0] && currentVUp[1]==vUp[1] && currentVUp[2]==vUp[2]
           && currentParallelScale==parallelScale
           && aCamera->GetViewAngle()==aVtkCamera->GetViewAngle())
            return;

        double clippingRange[2];
        aVtkCamera->GetClippingRange(clippingRange);
        double viewAngle, eyeAngle;
        viewAngle = aVtkCamera->GetViewAngle();
        eyeAngle = aVtkCamera->GetEyeAngle();

        aCamera->SetPosition(pos);
        aCamera->SetFocalPoint(focal);
        aCamera->SetViewUp(vUp);
        aCamera->SetClippingRange(clippingRange);
        aCamera->SetViewAngle(viewAngle);
        aCamera->SetEyeAngle(eyeAngle);
        aCamera->SetParallelScale(parallelScale);

        aCamera->SetParallelProjection(aVtkCamera->GetParallelProjection());
        copied = YES;
    });
    return copied;
}

- (void)resetCamera { ISIX_RENDERER("resetCamera", aRenderer->ResetCamera()); }
- (void)resetCameraClippingRange { ISIX_RENDERER("resetCameraClippingRange", aRenderer->ResetCameraClippingRange()); }
- (void)updateLightsToFollowCamera { ISIX_RENDERER("updateLights", aRenderer->UpdateLightsGeometryToFollowCamera()); }

// vtkRenderer::ResetCamera() puts the view angle back to 30 degrees, which is
// how each projection mode has always ended up after its reset. An angle chosen
// since then is kept; when the camera is fitted to the volume again, it is
// moved to frame the volume as it would at 30 degrees.
- (void)resetCameraKeepingViewAngle:(double)chosenViewAngle keep:(BOOL)keep fit:(BOOL)fit
{
    vtkCamera *aCamera = _o->aCamera;
    ISIX_RENDERER("resetCamera", {
        aRenderer->ResetCamera();
        if (keep && aCamera && chosenViewAngle != aCamera->GetViewAngle())
        {
            double defaultAngle = aCamera->GetViewAngle();
            aCamera->SetViewAngle( chosenViewAngle);
            if( fit)
                aCamera->Dolly( sin( vtkMath::RadiansFromDegrees( chosenViewAngle / 2)) / sin( vtkMath::RadiansFromDegrees( defaultAngle / 2)));
            aRenderer->ResetCameraClippingRange();
        }
    });
}

- (void)worldPointOfDisplayX:(double)x y:(double)y z:(double)z into:(double *)world
{
    ISIX_RENDERER("displayToWorld", {
        aRenderer->SetDisplayPoint( x, y, z);
        aRenderer->DisplayToWorld();
        aRenderer->GetWorldPoint( world);
    });
}

- (void)displayPointOfWorldX:(double)x y:(double)y z:(double)z w:(double)w into:(double *)display
{
    ISIX_RENDERER("worldToDisplay", {
        aRenderer->SetWorldPoint( x, y, z, w);
        aRenderer->WorldToDisplay();
        aRenderer->GetDisplayPoint( display);
    });
}

- (void)getViewport:(double *)viewport
{
    ISIX_RENDERER("viewport", {
        double *v = aRenderer->GetViewport();
        for (int i = 0; i < 4; i++) viewport[i] = v[i];
    });
}

@end

#undef ISIX_CAMERA
#undef ISIX_CAMERA_VALUE
#undef ISIX_RENDERER
