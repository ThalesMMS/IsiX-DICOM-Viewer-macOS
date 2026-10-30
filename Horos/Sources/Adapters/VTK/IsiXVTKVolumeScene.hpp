//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The C++ entry to IsiXVTKVolumeScene, for the Objective-C++ that holds the
// VTK objects.

#pragma once

#ifndef __cplusplus
#error "IsiXVTKVolumeScene.hpp is for Objective-C++"
#endif

#import "IsiXVTKVolumeScene.h"

class vtkRenderer;
class vtkRenderWindow;
class vtkCamera;
class vtkHorosFixedPointVolumeRayCastMapper;
class vtkVolume;
class vtkVolumeProperty;
class vtkColorTransferFunction;
class vtkPiecewiseFunction;
class vtkImageImport;

/// The objects of one volume of a 3D view, any of which may be missing (a
/// call that needs a missing one fails with IsiXVTKErrorCodeUnavailable). The
/// camera is the view's own: a view may render through a renderer it shares.
///
/// The scene borrows the objects: it is made for one call, during which the
/// view keeps them, and must not outlive them. Holding a reference cost each
/// frame a garbage collection pass when the scene let it go (the renderer, the
/// mapper and the volume take part in VTK's collection): a twentieth of the
/// render's time in Debug.
struct IsiXVTKVolumeSceneObjects
{
    vtkRenderer *renderer = nullptr;
    vtkCamera *camera = nullptr;
    vtkRenderWindow *window = nullptr;
    vtkHorosFixedPointVolumeRayCastMapper *mapper = nullptr;
    vtkVolume *volume = nullptr;
    vtkVolumeProperty *property = nullptr;
    vtkColorTransferFunction *colour = nullptr;
    vtkPiecewiseFunction *opacity = nullptr;
    vtkImageImport *importer = nullptr;
};

/// The scene of `objects`.
IsiXVTKVolumeScene *IsiXVTKMakeVolumeScene(const IsiXVTKVolumeSceneObjects &objects);
