//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// What the scene adapter's files share in C++: the VTK objects behind its
// Objective-C classes (IsiXVTKScene.h).

#pragma once

#ifndef __cplusplus
#error "IsiXVTKSceneInternal.hpp is for the Objective-C++ files of the VTK adapters"
#endif

#import "IsiXVTKScene.h"
#import "IsiXVTKInternal.hpp"

#include <vtkSmartPointer.h>
#include <vector>

class vtkActor;
class vtkObject;
class vtkRenderer;
class vtkTexture;
class vtkTextActor;

NS_ASSUME_NONNULL_BEGIN

@interface IsiXVTKActor ()
/// An actor of `actor`, which it registers, keeping `pipeline` (what builds
/// the actor's mapper input) alive with it.
- (instancetype)initWithActor:(vtkActor *)actor pipeline:(std::vector<vtkSmartPointer<vtkObject>>)pipeline;
- (vtkActor *)actor;
@end

@interface IsiXVTKTexture ()
- (vtkTexture *)texture;
@end

@interface IsiXVTKTextActor ()
- (vtkTextActor *)textActor;
@end

/// Logs a failure of a setter, which has no error to give back.
void IsiXVTKLogFailure(NSError *_Nullable error);

NS_ASSUME_NONNULL_END
