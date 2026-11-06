//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import "IsiXVTKRendererProps.h"
#import "IsiXVTKInternal.hpp"

#include <vtkProp.h>
#include <vtkRenderer.h>

#if !__has_feature(objc_arc)
#error "IsiXVTKRendererProps.mm is compiled with ARC"
#endif

@implementation IsiXVTKRendererProps

/// The renderer and the prop behind the pointers, checked to be what they say.
static NSError *IsiXVTKRendererAndProp(void *renderer, void *prop, const char *operation,
                                       vtkRenderer **outRenderer, vtkProp **outProp)
{
    if (!renderer || !prop)
        return IsiXVTKFailure(IsiXVTKErrorCodeUnavailable, @"No renderer or no prop", operation);
    vtkRenderer *aRenderer = vtkRenderer::SafeDownCast(static_cast<vtkObjectBase *>(renderer));
    vtkProp *aProp = vtkProp::SafeDownCast(static_cast<vtkObjectBase *>(prop));
    if (!aRenderer || !aProp)
        return IsiXVTKFailure(IsiXVTKErrorCodeInvalidArgument, @"Not a renderer and a prop", operation);
    *outRenderer = aRenderer;
    *outProp = aProp;
    return nil;
}

+ (BOOL)addProp:(void *)prop toRenderer:(void *)renderer error:(NSError **)error
{
    const char *operation = "IsiXVTKRendererProps addProp";
    vtkRenderer *aRenderer = nullptr;
    vtkProp *aProp = nullptr;
    if (NSError *refused = IsiXVTKRendererAndProp(renderer, prop, operation, &aRenderer, &aProp)) {
        if (error) *error = refused;
        return NO;
    }
    return IsiXVTKGuard(error, operation, {aRenderer, aProp}, [&]() -> NSError * {
        aRenderer->AddActor(aProp);
        return nil;
    });
}

+ (BOOL)removeProp:(void *)prop fromRenderer:(void *)renderer error:(NSError **)error
{
    const char *operation = "IsiXVTKRendererProps removeProp";
    vtkRenderer *aRenderer = nullptr;
    vtkProp *aProp = nullptr;
    if (NSError *refused = IsiXVTKRendererAndProp(renderer, prop, operation, &aRenderer, &aProp)) {
        if (error) *error = refused;
        return NO;
    }
    return IsiXVTKGuard(error, operation, {aRenderer, aProp}, [&]() -> NSError * {
        aRenderer->RemoveActor(aProp);
        return nil;
    });
}

@end
