//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A prop a 3D view's renderer shows or stops showing: the surface of an ROI
// volume in the volume rendering. The renderer and the prop stay their
// owners'; they cross this header as opaque pointers (a vtkRenderer and a
// vtkProp), and every call into VTK goes through the adapter's guard.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IsiXVTKRendererProps : NSObject

/// vtkRenderer::AddActor: `renderer` shows `prop` (again, if it already did).
+ (BOOL)addProp:(void *)prop toRenderer:(void *)renderer error:(NSError **)error;
/// vtkRenderer::RemoveActor: `renderer` stops showing `prop`.
+ (BOOL)removeProp:(void *)prop fromRenderer:(void *)renderer error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
