//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Reads a render's 2D layer into values (IsiXVTKSceneOverlay.h).

#import "IsiXVTKSceneOverlay.hpp"
#import "IsiXVTKInternal.hpp"
#import "IsiXVTKVolumeInteraction.hpp"

#include <vtkActor.h>
#include <vtkActor2D.h>
#include <vtkActor2DCollection.h>
#include <vtkAlgorithm.h>
#include <vtkCamera.h>
#include <vtkCellArray.h>
#include <vtkCoordinate.h>
#include <vtkMatrix4x4.h>
#include <vtkNew.h>
#include <vtkPolyData.h>
#include <vtkPolyDataMapper2D.h>
#include <vtkPropCollection.h>
#include <vtkProperty2D.h>
#include <vtkRenderWindow.h>
#include <vtkRenderer.h>
#include <vtkTextActor.h>
#include <vtkTextProperty.h>

#include <vector>

@interface IsiXVTKOverlayText ()
@property (nonatomic, readwrite, copy) NSString *text, *fontFamily;
@property (nonatomic, readwrite) double fontSize, red, green, blue, opacity;
@property (nonatomic, readwrite) BOOL bold;
@property (nonatomic, readwrite) NSInteger anchorX, anchorY, justification, verticalJustification;
@end

@implementation IsiXVTKOverlayText
@end

@interface IsiXVTKOverlayShape ()
@property (nonatomic, readwrite) double red, green, blue, opacity, lineWidth, pointSize;
@property (nonatomic, readwrite, copy) NSArray<NSData *> *polygons, *lines, *vertices;
@end

@implementation IsiXVTKOverlayShape
@end

@interface IsiXVTKOverlayFrame ()
@property (nonatomic, readwrite) NSInteger width, height;
@property (nonatomic, readwrite) double dpi;
@property (nonatomic, readwrite, copy) NSArray *items;
@property (nonatomic, readwrite, copy, nullable) NSArray<NSNumber *> *cubeRotation;
@property (nonatomic, readwrite, copy, nullable) NSData *pickedCorners;
@end

@implementation IsiXVTKOverlayFrame
{
    /// The crop box, registered while the frame lives.
    HorosBoxWidget *_box;
@public
    /// Whether the renderer had visible 2D actors, drawable or not.
    BOOL _anyShown;
}

- (void)dealloc
{
    if (_box) _box->UnRegister(nullptr);
}

- (void)setBox:(HorosBoxWidget *)box
{
    if (box) box->Register(nullptr);
    if (_box) _box->UnRegister(nullptr);
    _box = box;
}

- (BOOL)hasBox
{
    return _box != nullptr;
}

- (void)drawBoxOnCanvas:(id<IsiXVTKLineCanvas>)canvas
{
    if (!_box) return;
    IsiXVTKGuard(NULL, "drawBox", {_box}, [&]() -> NSError * {
        _box->Draw(canvas);
        return nil;
    });
}

- (BOOL)isEmpty
{
    return !_anyShown && !self.cubeRotation && !self.pickedCorners && !_box;
}

@end

std::vector<vtkActor2D *> IsiXVTKVisibleActors2D(vtkRenderer *renderer)
{
    std::vector<vtkActor2D *> shown;
    if (!renderer) return shown;
    IsiXVTKGuard(NULL, "visibleActors2D", {renderer}, [&]() -> NSError * {
        vtkNew<vtkActor2DCollection> actors;
        vtkPropCollection *props = renderer->GetViewProps();
        vtkCollectionSimpleIterator iterator;
        for (props->InitTraversal(iterator); vtkProp *prop = props->GetNextProp(iterator);)
            prop->GetActors2D(actors);
        actors->InitTraversal();
        while (vtkActor2D *actor = actors->GetNextActor2D())
            if (actor->GetVisibility()) shown.push_back(actor);
        return nil;
    });
    return shown;
}

/// The points of each cell of `cells`, offset by `origin`.
static NSArray<NSData *> *IsiXVTKOverlayCells(vtkPolyData *data, vtkCellArray *cells, const int *origin)
{
    if (!cells || cells->GetNumberOfCells() == 0) return @[];
    NSMutableArray<NSData *> *result = [NSMutableArray arrayWithCapacity:(NSUInteger)cells->GetNumberOfCells()];
    vtkIdType count;
    const vtkIdType *ids;
    std::vector<double> points;
    for (cells->InitTraversal(); cells->GetNextCell(count, ids);) {
        points.clear();
        for (vtkIdType k = 0; k < count; k++) {
            double p[3];
            data->GetPoint(ids[k], p);
            points.push_back(origin[0] + p[0]);
            points.push_back(origin[1] + p[1]);
        }
        [result addObject:[NSData dataWithBytes:points.data() length:points.size() * sizeof(double)]];
    }
    return result;
}

IsiXVTKOverlayFrame *IsiXVTKReadOverlayFrame(vtkRenderer *renderer, const std::vector<vtkActor2D *> &shown, bool cube,
                                             HorosBoxWidget *box, vtkActor *picked)
{
    vtkRenderWindow *window = renderer ? renderer->GetRenderWindow() : nullptr;
    if (!window) return nil;
    IsiXVTKOverlayFrame *frame = [[IsiXVTKOverlayFrame alloc] init];
    NSError *error = nil;
    BOOL read = IsiXVTKGuard(&error, "overlayFrame", {renderer, window}, [&]() -> NSError * {
        int *size = window->GetSize();
        frame.width = size[0];
        frame.height = size[1];
        frame.dpi = window->GetDPI();
        if (frame.width <= 0 || frame.height <= 0) return IsiXVTKFailure(IsiXVTKErrorCodeUnavailable, @"the window has no size", "overlayFrame");

        vtkCamera *camera = renderer->GetActiveCamera();
        if (cube && camera) {
            vtkMatrix4x4 *view = camera->GetViewTransformMatrix();
            NSMutableArray<NSNumber *> *matrix = [NSMutableArray arrayWithCapacity:16];
            for (int r = 0; r < 4; r++)
                for (int c = 0; c < 4; c++) [matrix addObject:@(view->GetElement(r, c))];
            frame.cubeRotation = matrix;
        }

        if (box && box->GetEnabled()) [frame setBox:box];

        // The picked prop's bounds, as vtkInteractorStyle outlined them.
        if (picked) {
            double *bounds = picked->GetBounds(), corners[8][3];
            for (int i = 0; i < 8; i++)
                HorosVRInteractor::ComputeWorldToDisplay(renderer, bounds[i & 1], bounds[2 + ((i >> 1) & 1)],
                                                         bounds[4 + ((i >> 2) & 1)], corners[i]);
            frame.pickedCorners = [NSData dataWithBytes:corners length:sizeof(corners)];
        }

        frame->_anyShown = !shown.empty();
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:shown.size()];
        for (vtkActor2D *actor : shown) {
            if (vtkTextActor *text = vtkTextActor::SafeDownCast(actor)) {
                const char *input = text->GetInput();
                if (input == nullptr) continue;
                vtkTextProperty *property = text->GetTextProperty();
                double colour[3];
                property->GetColor(colour);
                int *anchor = text->GetPositionCoordinate()->GetComputedDisplayValue(renderer);
                const char *family = property->GetFontFamilyAsString();
                IsiXVTKOverlayText *item = [[IsiXVTKOverlayText alloc] init];
                item.text = [NSString stringWithUTF8String:input] ?: @"";
                item.fontFamily = family ? [NSString stringWithUTF8String:family] : @"Arial";
                item.fontSize = property->GetFontSize();
                item.bold = property->GetBold() != 0;
                item.red = colour[0];
                item.green = colour[1];
                item.blue = colour[2];
                item.opacity = property->GetOpacity();
                item.anchorX = anchor[0];
                item.anchorY = anchor[1];
                item.justification = property->GetJustification();
                item.verticalJustification = property->GetVerticalJustification();
                [items addObject:item];
                continue;
            }

            vtkPolyDataMapper2D *mapper = vtkPolyDataMapper2D::SafeDownCast(actor->GetMapper());
            if (mapper == nullptr) continue;
            if (mapper->GetInputAlgorithm()) mapper->GetInputAlgorithm()->Update();
            vtkPolyData *data = mapper->GetInput();
            if (data == nullptr || data->GetNumberOfPoints() == 0) continue;
            int *origin = actor->GetPositionCoordinate()->GetComputedDisplayValue(renderer);
            vtkProperty2D *property = actor->GetProperty();
            double colour[3];
            property->GetColor(colour);
            IsiXVTKOverlayShape *item = [[IsiXVTKOverlayShape alloc] init];
            item.red = colour[0];
            item.green = colour[1];
            item.blue = colour[2];
            item.opacity = property->GetOpacity();
            item.lineWidth = property->GetLineWidth();
            item.pointSize = property->GetPointSize();
            item.polygons = IsiXVTKOverlayCells(data, data->GetPolys(), origin);
            item.lines = IsiXVTKOverlayCells(data, data->GetLines(), origin);
            item.vertices = IsiXVTKOverlayCells(data, data->GetVerts(), origin);
            [items addObject:item];
        }
        frame.items = items;
        return nil;
    });
    if (!read) {
        if (error.code != IsiXVTKErrorCodeUnavailable) NSLog(@"---- VTK adapter: the 2D layer is not read: %@", error);
        return nil;
    }
    return frame;
}
