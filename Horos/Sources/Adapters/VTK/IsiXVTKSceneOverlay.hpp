//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The C++ entry to IsiXVTKOverlayFrame, for the Objective-C++ that holds a
// renderer itself (the volume rendering view): the frame of the 2D actors
// it was handed, the cube, its crop box and its picked point.

#pragma once

#ifndef __cplusplus
#error "IsiXVTKSceneOverlay.hpp is for Objective-C++"
#endif

#import "IsiXVTKSceneOverlay.h"

#include <vector>

class vtkRenderer;
class vtkActor;
class vtkActor2D;
class HorosBoxWidget;

NS_ASSUME_NONNULL_BEGIN

/// The 2D layer of `renderer`'s last render: `shown`, the cube with `cube`,
/// `box` when it is enabled, the outline of `picked`. Nil when the renderer
/// has no window of a size, or when VTK fails (logged).
IsiXVTKOverlayFrame *_Nullable IsiXVTKReadOverlayFrame(vtkRenderer *_Nullable renderer,
                                                       const std::vector<vtkActor2D *> &shown, bool cube,
                                                       HorosBoxWidget *_Nullable box, vtkActor *_Nullable picked);

/// The renderer's visible 2D actors, each prop's own included.
std::vector<vtkActor2D *> IsiXVTKVisibleActors2D(vtkRenderer *_Nullable renderer);

NS_ASSUME_NONNULL_END
