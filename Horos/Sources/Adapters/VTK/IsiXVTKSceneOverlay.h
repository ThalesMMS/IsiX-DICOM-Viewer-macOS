//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The 2D layer of a 3D view as values: what VTK's text actors and 2D actors
// hold, the orientation cube's rotation, the crop box and the corners of a
// picked prop, read after a render, in the renderer's display pixels from the
// bottom left. The view (Swift) draws them on its annotation overlay, as VTK
// drew them over the 3D picture. Objective-C and C types only.

#import <Foundation/Foundation.h>
#import "IsiXVTKFramePresenter.h"

NS_ASSUME_NONNULL_BEGIN

/// A vtkTextActor's string where VTK would put it.
@interface IsiXVTKOverlayText : NSObject
@property (nonatomic, readonly, copy) NSString *text;
/// The property's font family, Arial when it has none.
@property (nonatomic, readonly, copy) NSString *fontFamily;
/// In points; the view scales it by the window's DPI.
@property (nonatomic, readonly) double fontSize;
@property (nonatomic, readonly) BOOL bold;
@property (nonatomic, readonly) double red, green, blue, opacity;
/// The computed display position of the actor's position coordinate.
@property (nonatomic, readonly) NSInteger anchorX, anchorY;
/// VTK's justifications: 0 left (bottom), 1 centred, 2 right (top).
@property (nonatomic, readonly) NSInteger justification, verticalJustification;
@end

/// A 2D actor's polygon data, offset by the actor's display position.
@interface IsiXVTKOverlayShape : NSObject
@property (nonatomic, readonly) double red, green, blue, opacity;
@property (nonatomic, readonly) double lineWidth, pointSize;
/// Each cell's points, two doubles (x, y) a point: polygons, polylines, vertices.
@property (nonatomic, readonly, copy) NSArray<NSData *> *polygons, *lines, *vertices;
@end

/// One render's 2D layer.
@interface IsiXVTKOverlayFrame : NSObject
/// The render window's size in pixels and DPI.
@property (nonatomic, readonly) NSInteger width, height;
@property (nonatomic, readonly) double dpi;
/// The visible 2D actors in the renderer's order, each an IsiXVTKOverlayText
/// or an IsiXVTKOverlayShape.
@property (nonatomic, readonly, copy) NSArray *items;
/// The camera's view transform, sixteen NSNumbers row by row, when the cube is
/// drawn; nil otherwise.
@property (nonatomic, readonly, copy, nullable) NSArray<NSNumber *> *cubeRotation;
/// The eight corners of the picked prop's bounds in display pixels, three
/// doubles each, corner i at (x bit 0, y bit 1, z bit 2); nil without a pick.
@property (nonatomic, readonly, copy, nullable) NSData *pickedCorners;
/// Whether the frame has a crop box to draw.
@property (nonatomic, readonly) BOOL hasBox;
/// Draws the crop box on `canvas`, in display pixels.
- (void)drawBoxOnCanvas:(id<IsiXVTKLineCanvas>)canvas NS_SWIFT_NAME(drawBox(on:));
/// Whether the frame has nothing to draw: no visible 2D actor, cube, box or pick.
@property (nonatomic, readonly) BOOL isEmpty;
@end

NS_ASSUME_NONNULL_END
