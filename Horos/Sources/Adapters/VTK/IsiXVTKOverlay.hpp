//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The C++ entry to IsiXVTKOverlayObserver, for the Objective-C++ that holds
// the renderer.

#pragma once

#ifndef __cplusplus
#error "IsiXVTKOverlay.hpp is for Objective-C++"
#endif

#import "IsiXVTKOverlay.h"

#include <vector>

class vtkRenderer;
class vtkActor2D;

/// Starts drawing `renderer`'s 2D actors outside VTK's render: when a render
/// starts (after the observers already there), every visible 2D actor of its
/// props, assemblies included, is hidden from VTK; when it ends they are
/// visible again and `draw` receives them. Nil, with the error, when VTK
/// refuses the observers. A method rather than a function: its NSError
/// argument would be named differently by the ARC adapter and by callers
/// compiled without ARC.
NS_ASSUME_NONNULL_BEGIN

@interface IsiXVTKOverlayObserver (IsiXVTKRenderer)
+ (nullable instancetype)observerOfRenderer:(vtkRenderer *)renderer
                                       draw:(void (^)(const std::vector<vtkActor2D *> &shown))draw
                                      error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
