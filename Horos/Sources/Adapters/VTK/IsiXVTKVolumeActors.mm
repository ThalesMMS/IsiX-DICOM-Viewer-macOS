//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The volume rendering view's 2D actors - the texts, the scissors' outline,
// the oval, the line and angle measurements - and its 3D points
// (IsiXVTKVolumeView.h). The view decides what they say and where; these are
// its calls to VTK.

#import "IsiXVTKVolumeViewInternal.hpp"

#include <algorithm>
#include <cmath>
#include <vtkActor.h>
#include <vtkActor2D.h>
#include <vtkCamera.h>
#include <vtkCellArray.h>
#include <vtkCoordinate.h>
#include <vtkMath.h>
#include <vtkPoints.h>
#include <vtkPolyData.h>
#include <vtkPolyDataMapper.h>
#include <vtkPolyDataMapper2D.h>
#include <vtkProperty.h>
#include <vtkProperty2D.h>
#include <vtkRegularPolygonSource.h>
#include <vtkRenderer.h>
#include <vtkSphereSource.h>
#include <vtkTextActor.h>
#include <vtkTextProperty.h>

// Projected measurements have no surface depth. Anchor them in the original
// parallel image plane and only display them when its viewing direction matches.
static bool HorosCaptureLineProjection(vtkRenderer *renderer, vtkCamera *camera,
    vtkPolyData *data, double world[2][3], double direction[3])
{
    if(!camera || !camera->GetParallelProjection() || !data || data->GetNumberOfPoints() != 2) return false;
    camera->GetDirectionOfProjection(direction);
    for(int i = 0; i < 2; ++i)
    {
        double point[3], value[4];
        data->GetPoint(i, point);
        renderer->SetDisplayPoint(point[0], point[1], 0);
        renderer->DisplayToWorld();
        renderer->GetWorldPoint(value);
        if(!std::isfinite(value[3]) || value[3] == 0) return false;
        for(int j = 0; j < 3; ++j)
        {
            world[i][j] = value[j] / value[3];
            if(!std::isfinite(world[i][j])) return false;
        }
    }
    return true;
}

static bool HorosUpdateLineProjection(vtkRenderer *renderer, vtkCamera *camera,
    vtkPolyData *data, vtkTextActor *text, const double world[2][3], const double direction[3])
{
    if(!camera || !camera->GetParallelProjection() || data->GetNumberOfPoints() != 2) return false;
    double current[3];
    camera->GetDirectionOfProjection(current);
    double dot = current[0]*direction[0] + current[1]*direction[1] + current[2]*direction[2];
    if(!std::isfinite(dot) || dot < 1.0 - 1e-8) return false;
    double points[2][3];
    for(int i = 0; i < 2; ++i)
    {
        renderer->SetWorldPoint(world[i][0], world[i][1], world[i][2], 1);
        renderer->WorldToDisplay();
        renderer->GetDisplayPoint(points[i]);
        if(!std::isfinite(points[i][0]) || !std::isfinite(points[i][1])) return false;
    }
    vtkPoints *pts = data->GetPoints();
    for(int i = 0; i < 2; ++i) pts->SetPoint(i, points[i][0], points[i][1], 0);
    pts->Modified();
    text->GetPositionCoordinate()->SetCoordinateSystemToViewport();
    if(points[0][0] > points[1][0]) text->SetPosition(points[0][0] + 3, points[0][1]);
    else text->SetPosition(points[1][0], points[1][1]);
    return true;
}

// 3D angle points live in patient millimetres. Reproject them after camera
// motion; the stored coordinates, and therefore the angle, do not change.
static bool HorosProjectPatientPoints(vtkRenderer *renderer, double factor,
    const double patient[][3], int count, double display[][3])
{
    if(!renderer || count <= 0 || !std::isfinite(factor) || factor == 0) return false;
    for(int i = 0; i < count; ++i)
    {
        renderer->SetWorldPoint(patient[i][0] * factor, patient[i][1] * factor,
            patient[i][2] * factor, 1);
        renderer->WorldToDisplay();
        renderer->GetDisplayPoint(display[i]);
        if(!std::isfinite(display[i][0]) || !std::isfinite(display[i][1])) return false;
    }
    return true;
}

static IsiXVTKStoredLine *IsiXVTKNewStoredLine(vtkPolyData *source, vtkTextActor *sourceText)
{
    IsiXVTKStoredLine *entry = new IsiXVTKStoredLine();
    entry->data = vtkPolyData::New();
    entry->data->DeepCopy(source);
    entry->mapper = vtkPolyDataMapper2D::New();
    entry->mapper->SetInputData(entry->data);
    entry->actor = vtkActor2D::New();
    entry->actor->GetPositionCoordinate()->SetCoordinateSystemToDisplay();
    entry->actor->SetMapper(entry->mapper);
    entry->actor->GetProperty()->SetPointSize(6);
    entry->actor->GetProperty()->SetLineWidth(2.5);
    entry->actor->GetProperty()->SetColor(0, 1, 1);
    entry->text = vtkTextActor::New();
    entry->text->SetTextScaleModeToNone();
    entry->text->SetInput(sourceText->GetInput());
    entry->text->GetTextProperty()->ShallowCopy(sourceText->GetTextProperty());
    entry->text->GetTextProperty()->SetColor(0, 1, 1);
    entry->text->GetPositionCoordinate()->SetCoordinateSystemToViewport();
    entry->text->SetPosition(sourceText->GetPosition());
    return entry;
}

static void IsiXVTKDeleteStoredLine(IsiXVTKStoredLine *entry)
{
    entry->text->Delete();
    entry->actor->Delete();
    entry->mapper->Delete();
    entry->data->Delete();
    delete entry;
}

/// A polyline through every point of `pts` and back to the first, as the
/// view's lines are drawn.
static vtkCellArray *IsiXVTKClosedCell(vtkPoints *pts)
{
    vtkCellArray *rect = vtkCellArray::New();
    rect->InsertNextCell( pts->GetNumberOfPoints()+1);
    for( int i = 0; i < pts->GetNumberOfPoints(); i++) rect->InsertCellPoint( i);
    rect->InsertCellPoint( 0);
    return rect;
}

/// Empties a polygon data of its points and lines.
static void IsiXVTKEmptyPolyData(vtkPolyData *data)
{
    vtkPoints *pts = vtkPoints::New();
    vtkCellArray *rect = vtkCellArray::New();
    data-> SetPoints( pts);		pts->Delete();
    data-> SetLines( rect);		rect->Delete();
}

@implementation IsiXVTKVolumeView (IsiXVTKVolumeActors)

- (BOOL)makeMeasurementActorsWithNotice:(NSString *)notice error:(NSError **)error
{
    IsiXVTKVolumeViewObjects *o = _o;
    return IsiXVTKVolumeTry(error, "makeMeasurementActors", {}, [&] {
        vtkRenderer *aRenderer = o->aRenderer;

        // 3D Cut ROI
        vtkPoints *pts = vtkPoints::New();
        vtkCellArray *rect = vtkCellArray::New();

        o->ROI3DData = vtkPolyData::New();
        o->ROI3DData-> SetPoints( pts);
        pts->Delete();
        o->ROI3DData-> SetLines( rect);
        rect->Delete();

        o->ROI3D = vtkPolyDataMapper2D::New();
        o->ROI3D->SetInputData( o->ROI3DData);

        o->ROI3DActor = vtkActor2D::New();
        o->ROI3DActor->GetPositionCoordinate()->SetCoordinateSystemToDisplay();
        o->ROI3DActor->SetMapper( o->ROI3D);
        o->ROI3DActor->GetProperty()->SetPointSize( 1);	//vtkProperty2D
        o->ROI3DActor->GetProperty()->SetLineWidth( 2);
        o->ROI3DActor->GetProperty()->SetColor(0.3,1,0);

        aRenderer->AddViewProp( o->ROI3DActor);

        // 2D Oval
        o->Oval2DData = vtkRegularPolygonSource::New();
        o->Oval2DData->SetNumberOfSides( 50);
        o->Oval2DData->SetRadius( 200);
        o->Oval2DData->SetCenter( 200, 200,0);
        o->Oval2DData->SetGeneratePolygon( 0);

        o->Oval2D = vtkPolyDataMapper2D::New();
        o->Oval2D->SetInputConnection( o->Oval2DData->GetOutputPort());
        o->Oval2D->Update();

        o->Oval2DActor = vtkActor2D::New();
        o->Oval2DActor->GetPositionCoordinate()->SetCoordinateSystemToDisplay();
        o->Oval2DActor->SetMapper( o->Oval2D);
        o->Oval2DActor->GetProperty()->SetPointSize( 6);	//vtkProperty2D
        o->Oval2DActor->GetProperty()->SetLineWidth( 2.5);
        o->Oval2DActor->GetProperty()->SetColor(1,1,0);

        o->Oval2DText = vtkTextActor::New();
        o->Oval2DText->SetInput( " ");
        o->Oval2DText->SetTextScaleModeToNone();
        o->Oval2DText->GetPositionCoordinate()->SetCoordinateSystemToViewport();
        o->Oval2DText->GetPositionCoordinate()->SetValue( 2., 2.);
        o->Oval2DText->GetTextProperty()->SetColor( 1.0, 1.0, 0.0);
        o->Oval2DText->GetTextProperty()->SetBold( true);
        o->Oval2DText->GetTextProperty()->SetShadow(true);
        o->Oval2DText->GetTextProperty()->SetShadowOffset(1, 1);

        // 2D Line
        pts = vtkPoints::New();
        rect = vtkCellArray::New();

        o->Line2DData = vtkPolyData::New();
        o->Line2DData-> SetPoints( pts);
        pts->Delete();
        o->Line2DData-> SetLines( rect);
        rect->Delete();

        o->Line2D = vtkPolyDataMapper2D::New();
        o->Line2D->SetInputData( o->Line2DData);

        o->Line2DActor = vtkActor2D::New();
        o->Line2DActor->GetPositionCoordinate()->SetCoordinateSystemToDisplay();
        o->Line2DActor->SetMapper( o->Line2D);
        o->Line2DActor->GetProperty()->SetPointSize( 6);	//vtkProperty2D
        o->Line2DActor->GetProperty()->SetLineWidth( 2.5);
        o->Line2DActor->GetProperty()->SetColor(1,1,0);

        o->Line2DText = vtkTextActor::New();
        o->Line2DText->SetInput( " ");
        o->Line2DText->SetTextScaleModeToNone();
        o->Line2DText->GetPositionCoordinate()->SetCoordinateSystemToViewport();
        o->Line2DText->GetPositionCoordinate()->SetValue( 2., 2.);
        o->Line2DText->GetTextProperty()->SetColor( 1.0, 1.0, 0.0);
        o->Line2DText->GetTextProperty()->SetBold( true);
        o->Line2DText->GetTextProperty()->SetShadow(true);
        o->Line2DText->GetTextProperty()->SetShadowOffset(1, 1);

        aRenderer->AddViewProp( o->Line2DActor);

        pts = vtkPoints::New();
        rect = vtkCellArray::New();
        o->Angle2DData = vtkPolyData::New();
        o->Angle2DData->SetPoints( pts);
        pts->Delete();
        o->Angle2DData->SetLines( rect);
        rect->Delete();
        o->Angle2D = vtkPolyDataMapper2D::New();
        o->Angle2D->SetInputData( o->Angle2DData);
        o->Angle2DActor = vtkActor2D::New();
        o->Angle2DActor->GetPositionCoordinate()->SetCoordinateSystemToDisplay();
        o->Angle2DActor->SetMapper( o->Angle2D);
        o->Angle2DActor->GetProperty()->SetPointSize( 6);
        o->Angle2DActor->GetProperty()->SetLineWidth( 2.5);
        o->Angle2DActor->GetProperty()->SetColor(1, 0.6, 0);
        o->Angle2DText = vtkTextActor::New();
        o->Angle2DText->SetInput( " ");
        o->Angle2DText->SetTextScaleModeToNone();
        o->Angle2DText->GetPositionCoordinate()->SetCoordinateSystemToViewport();
        o->Angle2DText->GetTextProperty()->SetColor( 1.0, 0.6, 0.0);
        o->Angle2DText->GetTextProperty()->SetBold( true);
        o->Angle2DText->GetTextProperty()->SetShadow(true);
        o->Angle2DText->GetTextProperty()->SetShadowOffset(1, 1);
        aRenderer->AddViewProp( o->Angle2DActor);

        o->lineMeasurementProjectionNotice = vtkTextActor::New();
        o->lineMeasurementProjectionNotice->SetInput([notice UTF8String]);
        o->lineMeasurementProjectionNotice->SetTextScaleModeToNone();
        o->lineMeasurementProjectionNotice->SetPosition(20, 40);
        o->lineMeasurementProjectionNotice->GetTextProperty()->SetColor(1, 1, 1);
        o->lineMeasurementProjectionNotice->SetVisibility(false);
        aRenderer->AddViewProp(o->lineMeasurementProjectionNotice);
    });
}

#pragma mark Texts

- (void)setWindowText:(const char *)text
{
    vtkTextActor *actor = _o->textWLWW;
    if (!actor) return;
    IsiXVTKVolumeRun("setWindowText", {}, [&] { actor->SetInput( text); });
}

- (void)placeWindowTextBelowTop:(double)offset
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->textWLWW) return;
    IsiXVTKVolumeRun("placeWindowText", {}, [&] {
        int *wsize = o->horosRenderWindow->GetSize();
        o->textWLWW->GetPositionCoordinate()->SetValue( 2., wsize[ 1]-offset);
    });
}

- (void)setOrientationText:(const char *)text atIndex:(int)index
{
    vtkTextActor *actor = index >= 0 && index < 5 ? _o->oText[index] : nullptr;
    if (!actor) return;
    IsiXVTKVolumeRun("setOrientationText", {}, [&] { actor->SetInput( text); });
}

- (void)showOrientationTexts:(BOOL)shown
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->aRenderer) return;
    IsiXVTKVolumeRun("showOrientationTexts", {}, [&] {
        for( long i = 0; i < 5; i++) {
            if (shown) o->aRenderer->AddViewProp( o->oText[ i]);
            else o->aRenderer->RemoveViewProp( o->oText[ i]);
        }
    });
}

- (void)showCornerText:(BOOL)shown
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->aRenderer || !o->textX) return;
    IsiXVTKVolumeRun("showCornerText", {}, [&] {
        if (shown) o->aRenderer->AddActor(o->textX);
        else o->aRenderer->RemoveActor(o->textX);
    });
}

- (void)removeOutline
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->aRenderer) return;
    IsiXVTKVolumeRun("removeOutline", {}, [&] { o->aRenderer->RemoveActor(o->outlineRect); });
}

- (void)setTextColourWhite:(BOOL)white
{
    IsiXVTKVolumeViewObjects *o = _o;
    double c = white ? 1 : 0;
    IsiXVTKVolumeRun("setTextColour", {}, [&] {
        o->textWLWW->GetTextProperty()->SetColor(c,c,c);
        for( int i = 0 ; i < 5 ; i++) o->oText[ i]->GetTextProperty()->SetColor(c,c,c);
        if( o->textX)
            o->textX->GetTextProperty()->SetColor(c,c,c);
        if( o->textTilt)
            o->textTilt->GetTextProperty()->SetColor(c,c,c);
    });
}

#pragma mark The scissors' outline

- (void)setScissorsOutline:(const double *)points count:(long)count
{
    vtkPolyData *data = _o->ROI3DData;
    if (!data) return;
    IsiXVTKVolumeRun("setScissorsOutline", {}, [&] {
        if (count == 0) {
            // Delete current ROI
            IsiXVTKEmptyPolyData(data);
            return;
        }
        vtkPoints *pts = vtkPoints::New();
        for( long i = 0; i < count; i++)
            pts->InsertPoint( pts->GetNumberOfPoints(), points[2*i], points[2*i+1], 0);

        vtkCellArray *rect = IsiXVTKClosedCell(pts);

        data->SetVerts( rect);
        data->SetLines( rect);		rect->Delete();
        data->SetPoints( pts);		pts->Delete();
    });
}

- (long)scissorsPointCount
{
    vtkPolyData *data = _o->ROI3DData;
    long count = 0;
    if (!data) return count;
    IsiXVTKVolumeRun("scissorsPointCount", {}, [&] { count = data->GetPoints()->GetNumberOfPoints(); });
    return count;
}

- (void)getScissorsPoints:(double *)points
{
    vtkPolyData *data = _o->ROI3DData;
    if (!data) return;
    IsiXVTKVolumeRun("scissorsPoints", {}, [&] {
        vtkPoints *roiPts = data->GetPoints();
        for( long tt = 0; tt < roiPts->GetNumberOfPoints(); tt++)
        {
            double point2D[ 3];
            roiPts->GetPoint( tt, point2D);
            points[2*tt] = point2D[0];
            points[2*tt+1] = point2D[1];
        }
    });
}

#pragma mark The oval

- (void)showOvalWithCenterX:(double)x y:(double)y radius:(double)radius
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->Oval2DData) return;
    IsiXVTKVolumeRun("showOval", {}, [&] {
        o->Oval2DData->SetRadius( radius);
        o->Oval2DData->SetCenter( x, y, 0);

        o->aRenderer->AddViewProp( o->Oval2DActor);
    });
}

- (void)hideOval
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->aRenderer) return;
    IsiXVTKVolumeRun("hideOval", {}, [&] {
        o->aRenderer->RemoveActor( o->Oval2DText);
        o->aRenderer->RemoveViewProp( o->Oval2DActor);
    });
}

- (void)placeOvalText:(const char *)text x:(double)x y:(double)y
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->Oval2DText) return;
    IsiXVTKVolumeRun("placeOvalText", {}, [&] {
        o->Oval2DText->GetPositionCoordinate()->SetCoordinateSystemToViewport();
        o->Oval2DText->GetPositionCoordinate()->SetValue( x, y);
        o->Oval2DText->SetInput( text);
        o->aRenderer->AddActor( o->Oval2DText);
    });
}

- (void)removeOvalText
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->aRenderer) return;
    IsiXVTKVolumeRun("removeOvalText", {}, [&] { o->aRenderer->RemoveActor( o->Oval2DText); });
}

#pragma mark The line

- (long)activeLinePointCount
{
    vtkPolyData *data = _o->Line2DData;
    long count = 0;
    if (!data) return count;
    IsiXVTKVolumeRun("linePointCount", {}, [&] { count = data->GetPoints()->GetNumberOfPoints(); });
    return count;
}

- (BOOL)activeLineVisible
{
    vtkActor2D *actor = _o->Line2DActor;
    return actor && actor->GetVisibility();
}

- (void)getActiveLinePoint:(long)index into:(double *)point
{
    vtkPolyData *data = _o->Line2DData;
    if (!data) return;
    IsiXVTKVolumeRun("linePoint", {}, [&] { data->GetPoints()->GetPoint( index, point); });
}

- (void)clearActiveLine
{
    vtkPolyData *data = _o->Line2DData;
    if (!data) return;
    IsiXVTKVolumeRun("clearLine", {}, [&] { IsiXVTKEmptyPolyData(data); });
}

- (void)appendActiveLinePointX:(double)x y:(double)y
{
    vtkPolyData *data = _o->Line2DData;
    if (!data) return;
    IsiXVTKVolumeRun("appendLinePoint", {}, [&] {
        vtkPoints *pts = data->GetPoints();
        pts->InsertPoint( pts->GetNumberOfPoints(), x, y, 0);

        vtkCellArray *rect = IsiXVTKClosedCell(pts);

        data->SetVerts( rect);
        data->SetLines( rect);		rect->Delete();
    });
}

- (void)commitActiveLinePoints
{
    vtkPolyData *data = _o->Line2DData;
    if (!data) return;
    IsiXVTKVolumeRun("commitLinePoints", {}, [&] {
        vtkPoints *pts = data->GetPoints();
        pts->Modified(); // SetPoint/InsertPoint do not invalidate VTK point buffers.
        data->SetPoints( pts);
    });
}

- (void)moveLastActiveLinePointX:(double)x y:(double)y
{
    vtkPolyData *data = _o->Line2DData;
    if (!data) return;
    IsiXVTKVolumeRun("moveLinePoint", {}, [&] {
        vtkPoints *pts = data->GetPoints();
        pts->SetPoint( pts->GetNumberOfPoints()-1, x, y, 0);

        vtkCellArray *rect = IsiXVTKClosedCell(pts);

        data->SetVerts( rect);
        data->SetLines( rect);		rect->Delete();

        pts->Modified(); // SetPoint/InsertPoint do not invalidate VTK point buffers.
        data->SetPoints( pts);
    });
}

- (void)swapActiveLineEndpoints
{
    vtkPolyData *data = _o->Line2DData;
    if (!data) return;
    IsiXVTKVolumeRun("swapLineEndpoints", {}, [&] {
        vtkPoints *pts = data->GetPoints();
        double endpoints[2][3];
        pts->GetPoint(0, endpoints[0]);
        pts->GetPoint(1, endpoints[1]);
        pts->SetPoint(0, endpoints[1]);
        pts->SetPoint(1, endpoints[0]);
        pts->Modified();
    });
}

- (void)placeActiveLineText:(const char *)text x:(double)x y:(double)y
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->Line2DText) return;
    IsiXVTKVolumeRun("placeLineText", {}, [&] {
        o->Line2DText->GetPositionCoordinate()->SetCoordinateSystemToViewport();
        o->Line2DText->GetPositionCoordinate()->SetValue( x, y);
        o->Line2DText->SetInput( text);
        o->aRenderer->AddActor(o->Line2DText);
    });
}

- (void)removeActiveLineText
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->aRenderer) return;
    IsiXVTKVolumeRun("removeLineText", {}, [&] { o->aRenderer->RemoveActor(o->Line2DText); });
}

- (void)captureLineProjection
{
    IsiXVTKVolumeViewObjects *o = _o;
    IsiXVTKVolumeRun("captureLineProjection", {}, [&] {
        o->lineMeasurementHasProjection = HorosCaptureLineProjection(o->aRenderer, o->aCamera, o->Line2DData,
            o->lineMeasurementWorld, o->lineMeasurementDirection);
    });
}

- (BOOL)updateLineProjectionsWasVisible:(BOOL *)wasVisible visible:(BOOL *)visibleOut length:(double *)length
{
    IsiXVTKVolumeViewObjects *o = _o;
    if(!o->aRenderer || !o->Line2DData) return NO;
    IsiXVTKVolumeRun("updateLineProjections", {}, [&] {
        if(o->Line2DData->GetNumberOfPoints() != 2) o->lineMeasurementHasProjection = false;
        BOOL visible = o->lineMeasurementHasProjection && HorosUpdateLineProjection(o->aRenderer, o->aCamera,
            o->Line2DData, o->Line2DText, o->lineMeasurementWorld, o->lineMeasurementDirection);
        *wasVisible = o->Line2DActor->GetVisibility() != 0;
        *visibleOut = visible;
        o->Line2DActor->SetVisibility(visible);
        o->Line2DText->SetVisibility(visible);
        if(visible)
        {
            o->aRenderer->AddViewProp(o->Line2DText);
            *length = sqrt(vtkMath::Distance2BetweenPoints(o->lineMeasurementWorld[0], o->lineMeasurementWorld[1]));
        }
        else *length = 0;
        BOOL hidden = o->lineMeasurementHasProjection && !visible;
        for(IsiXVTKStoredLine *entry : o->storedLines)
        {
            BOOL entryVisible = HorosUpdateLineProjection(o->aRenderer, o->aCamera, entry->data, entry->text, entry->world, entry->direction);
            entry->actor->SetVisibility(entryVisible);
            entry->text->SetVisibility(entryVisible);
            hidden |= !entryVisible;
        }
        if(o->lineMeasurementProjectionNotice) o->lineMeasurementProjectionNotice->SetVisibility(hidden);
    });
    return YES;
}

- (BOOL)storeActiveLine
{
    IsiXVTKVolumeViewObjects *o = _o;
    if(!o->lineMeasurementHasProjection || !o->Line2DData) return NO;
    BOOL stored = NO;
    IsiXVTKVolumeRun("storeLine", {}, [&] {
        if(o->Line2DData->GetNumberOfPoints() != 2) return;
        if(vtkMath::Distance2BetweenPoints(o->lineMeasurementWorld[0], o->lineMeasurementWorld[1]) <= 0) return;
        IsiXVTKStoredLine *entry = IsiXVTKNewStoredLine(o->Line2DData, o->Line2DText);
        memcpy(entry->world, o->lineMeasurementWorld, sizeof(o->lineMeasurementWorld));
        memcpy(entry->direction, o->lineMeasurementDirection, sizeof(o->lineMeasurementDirection));
        o->storedLines.push_back(entry);
        o->aRenderer->AddViewProp(entry->actor);
        o->aRenderer->AddViewProp(entry->text);
        stored = YES;
    });
    return stored;
}

- (void)clearStoredLines
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o) return;
    IsiXVTKVolumeRun("clearStoredLines", {}, [&] {
        for(IsiXVTKStoredLine *entry : o->storedLines)
        {
            if (o->aRenderer) {
                o->aRenderer->RemoveViewProp(entry->actor);
                o->aRenderer->RemoveViewProp(entry->text);
            }
        }
        for(IsiXVTKStoredLine *entry : o->storedLines) IsiXVTKDeleteStoredLine(entry);
        o->storedLines.clear();
    });
}

- (long)storedLineCount
{
    return (long)_o->storedLines.size();
}

- (double)storedLineLengthAtIndex:(long)index
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (index < 0 || index >= (long)o->storedLines.size()) return 0;
    IsiXVTKStoredLine *entry = o->storedLines[index];
    return sqrt(vtkMath::Distance2BetweenPoints(entry->world[0], entry->world[1]));
}

- (void)setStoredLineText:(const char *)text atIndex:(long)index
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (index < 0 || index >= (long)o->storedLines.size()) return;
    IsiXVTKStoredLine *entry = o->storedLines[index];
    IsiXVTKVolumeRun("setStoredLineText", {}, [&] { entry->text->SetInput(text); });
}

- (BOOL)storedLineVisibleAtIndex:(long)index
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (index < 0 || index >= (long)o->storedLines.size()) return NO;
    return o->storedLines[index]->actor->GetVisibility() != 0;
}

- (BOOL)getStoredLineAtIndex:(long)index first:(double *)first second:(double *)second
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (index < 0 || index >= (long)o->storedLines.size()) return NO;
    vtkPolyData *data = o->storedLines[index]->data;
    if(!data || data->GetNumberOfPoints() != 2) return NO;
    data->GetPoint(0, first);
    data->GetPoint(1, second);
    return YES;
}

- (void)reactivateStoredLineAtIndex:(long)index
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (index < 0 || index >= (long)o->storedLines.size()) return;
    IsiXVTKStoredLine *entry = o->storedLines[index];
    [self storeActiveLine];
    IsiXVTKVolumeRun("reactivateStoredLine", {}, [&] {
        o->Line2DData->DeepCopy(entry->data);
        memcpy(o->lineMeasurementWorld, entry->world, sizeof(o->lineMeasurementWorld));
        memcpy(o->lineMeasurementDirection, entry->direction, sizeof(o->lineMeasurementDirection));
        o->lineMeasurementHasProjection = true;
        o->aRenderer->RemoveViewProp(entry->actor);
        o->aRenderer->RemoveViewProp(entry->text);
    });
    o->storedLines.erase(o->storedLines.begin() + index);
    IsiXVTKVolumeRun("reactivateStoredLine", {}, [&] { IsiXVTKDeleteStoredLine(entry); });
}

/// A line's two points moved by `map`, as the viewport resizes; a line of
/// another count emptied.
static void IsiXVTKRemapLine(vtkPolyData *Line2DData, vtkTextActor *Line2DText, CGPoint (^map)(CGPoint))
{
    if( Line2DData)
    {
        vtkPoints *pts = Line2DData->GetPoints();

        if( pts->GetNumberOfPoints() == 2)
        {
            double pt1[ 3];
            pts->GetPoint( 0, pt1);

            double pt2[ 3];
            pts->GetPoint( 1, pt2);

            pts = vtkPoints::New();
            vtkCellArray *rect = vtkCellArray::New();
            Line2DData-> SetPoints( pts);		pts->Delete();
            Line2DData-> SetLines( rect);		rect->Delete();

            pts = Line2DData->GetPoints();

            // Line points are VTK display pixels. Preserve their projected world
            // positions as the parallel camera's viewport changes, also for export.
            CGPoint p1 = map(CGPointMake(pt1[0], pt1[1]));
            CGPoint p2 = map(CGPointMake(pt2[0], pt2[1]));
            pts->InsertPoint(0, p1.x, p1.y, 0);
            pts->InsertPoint(1, p2.x, p2.y, 0);
            rect = IsiXVTKClosedCell(pts);

            Line2DData->SetVerts( rect);
            Line2DData->SetLines( rect);		rect->Delete();

            pts->Modified(); // SetPoint/InsertPoint do not invalidate VTK point buffers.
            Line2DData->SetPoints( pts);

            // Move the text

            pts->GetPoint( 0, pt1);
            pts->GetPoint( 1, pt2);

            Line2DText->GetPositionCoordinate()->SetCoordinateSystemToViewport();
            if( pt1[ 0] > pt2[ 0]) Line2DText->GetPositionCoordinate()->SetValue( pt1[0] + 3, pt1[ 1]);
            else Line2DText->GetPositionCoordinate()->SetValue( pt2[0], pt2[ 1]);
        }
        else
        {
            // Delete
            IsiXVTKEmptyPolyData(Line2DData);
        }
    }
}

- (void)remapLinePoints:(CGPoint (^)(CGPoint))map
{
    IsiXVTKVolumeViewObjects *o = _o;
    IsiXVTKVolumeRun("remapLinePoints", {}, [&] {
        IsiXVTKRemapLine(o->Line2DData, o->Line2DText, map);
        for(IsiXVTKStoredLine *entry : o->storedLines)
            IsiXVTKRemapLine(entry->data, entry->text, map);
    });
}

#pragma mark The angle

- (BOOL)hasAngleActors
{
    IsiXVTKVolumeViewObjects *o = _o;
    return o->aRenderer && o->Angle2DData && o->Angle2DActor && o->Angle2DText;
}

- (BOOL)projectPatientPoints:(const double *)patient count:(int)count factor:(double)factor into:(double *)display
{
    IsiXVTKVolumeViewObjects *o = _o;
    BOOL projected = NO;
    IsiXVTKVolumeRun("projectPatientPoints", {}, [&] {
        projected = HorosProjectPatientPoints(o->aRenderer, factor, (const double (*)[3])patient, count, (double (*)[3])display);
    });
    return projected;
}

- (void)showAngleDisplayPoints:(const double *)display count:(int)count text:(const char *)text visible:(BOOL)visible
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (![self hasAngleActors]) return;
    IsiXVTKVolumeRun("showAngle", {}, [&] {
        vtkPoints *pts = vtkPoints::New();
        vtkCellArray *lines = vtkCellArray::New();
        if(visible)
        {
            for(int i = 0; i < count; i++)
                pts->InsertNextPoint(display[3*i], display[3*i+1], 0);
            if(count >= 2)
            {
                lines->InsertNextCell(count);
                for(int i = 0; i < count; i++)
                    lines->InsertCellPoint(i);
            }
            if(text)
            {
                o->Angle2DText->SetInput(text);
                o->Angle2DText->GetPositionCoordinate()->SetCoordinateSystemToViewport();
                o->Angle2DText->SetPosition(display[3] + 3, display[4]);
                o->aRenderer->AddViewProp(o->Angle2DText);
                o->Angle2DText->SetVisibility(true);
            }
            else
                o->Angle2DText->SetVisibility(false);
        }
        if(!visible)
            o->Angle2DText->SetVisibility(false);
        o->Angle2DData->SetPoints(pts);
        o->Angle2DData->SetLines(lines);
        pts->Modified();
        pts->Delete();
        lines->Delete();
        o->Angle2DActor->SetVisibility(visible);
        if(visible) o->aRenderer->AddViewProp(o->Angle2DActor);
    });
}

#pragma mark The 3D points

- (void *)makePointSphereX:(double)x y:(double)y z:(double)z radius:(double)radius red:(double)red
                     green:(double)green blue:(double)blue
{
    vtkActor *sphereActor = nullptr;
    IsiXVTKVolumeRun("makePointSphere", {}, [&] {
        //Sphere
        vtkSphereSource *sphereSource = vtkSphereSource::New();
        sphereSource->SetRadius(radius);
        sphereSource->SetCenter(x, y, z);
        //Mapper
        vtkPolyDataMapper *mapper = vtkPolyDataMapper::New();
        mapper->SetInputConnection(sphereSource->GetOutputPort());
        mapper->Update();
        //Actor
        sphereActor = vtkActor::New();
        sphereActor->SetMapper(mapper);
        mapper->Delete();

        sphereActor->GetProperty()->SetColor(red,green,blue);
        sphereActor->DragableOn();
        sphereActor->PickableOn();
        sphereSource->Delete();
    });
    return sphereActor;
}

- (void)addPointActor:(void *)actor
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->aRenderer || !actor) return;
    IsiXVTKVolumeRun("addPointActor", {}, [&] { o->aRenderer->AddActor((vtkActor *)actor); });
}

- (void)removePointActor:(void *)actor
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->aRenderer || !actor) return;
    IsiXVTKVolumeRun("removePointActor", {}, [&] { o->aRenderer->RemoveActor((vtkActor *)actor); });
}

- (void)deletePointActor:(void *)actor
{
    if (!actor) return;
    IsiXVTKVolumeRun("deletePointActor", {}, [&] { ((vtkActor *)actor)->Delete(); });
}

- (void)setPointActor:(void *)actor red:(double)red green:(double)green blue:(double)blue
{
    if (!actor) return;
    IsiXVTKVolumeRun("setPointColour", {}, [&] { ((vtkActor *)actor)->GetProperty()->SetColor(red, green, blue); });
}

- (void)setPointActor:(void *)handle centerX:(double)x y:(double)y z:(double)z radius:(double)radius
{
    vtkActor *actor = (vtkActor *)handle;
    if (!actor) return;
    IsiXVTKVolumeRun("setPointSphere", {}, [&] {
        //Sphere
        vtkSphereSource *sphereSource = vtkSphereSource::New();
        sphereSource->SetRadius(radius);
        sphereSource->SetCenter(x, y, z);
        //Mapper
        vtkPolyDataMapper *mapper = vtkPolyDataMapper::New();
        mapper->SetInputConnection(sphereSource->GetOutputPort());
        mapper->Update();
        //Actor
        actor->SetMapper(mapper);
        mapper->Delete();

        sphereSource->Delete();
    });
}

// What vtkPropPicker gave the 'p' key among the 3D points: the one nearest
// the viewer along the ray under the mouse, spheres being what they are.
- (void *)pickPointAmong:(NSArray<NSValue *> *)actors x:(double)x y:(double)y
{
    IsiXVTKVolumeViewObjects *o = _o;
    vtkActor *picked = nullptr;
    if (!o->aRenderer) return picked;
    IsiXVTKVolumeRun("pickPoint", {}, [&] {
        double nearest = INFINITY, from[4], to[4];
        HorosVRInteractor::ComputeDisplayToWorld( o->aRenderer, x, y, 0, from);
        HorosVRInteractor::ComputeDisplayToWorld( o->aRenderer, x, y, 1, to);
        double ray[3] = { to[0] - from[0], to[1] - from[1], to[2] - from[2] };
        double length2 = ray[0]*ray[0] + ray[1]*ray[1] + ray[2]*ray[2];
        if( length2 > 0)
        {
            for( NSValue *value in actors)
            {
                vtkActor *actor = (vtkActor *) [value pointerValue];
                if( actor == nullptr || actor->GetVisibility() == 0 || actor->GetPickable() == 0) continue;
                double *bounds = actor->GetBounds();
                double centre[3] = { (bounds[0] + bounds[1]) / 2, (bounds[2] + bounds[3]) / 2, (bounds[4] + bounds[5]) / 2 };
                double radius = std::max( bounds[1] - bounds[0], std::max( bounds[3] - bounds[2], bounds[5] - bounds[4])) / 2;
                double offset[3] = { from[0] - centre[0], from[1] - centre[1], from[2] - centre[2] };
                double b = offset[0]*ray[0] + offset[1]*ray[1] + offset[2]*ray[2];
                double c = offset[0]*offset[0] + offset[1]*offset[1] + offset[2]*offset[2] - radius * radius;
                double discriminant = b * b - length2 * c;
                if( discriminant < 0) continue;
                double t = ( -b - sqrt( discriminant)) / length2;
                if( t < 0) t = ( -b + sqrt( discriminant)) / length2;
                if( t >= 0 && t < nearest) { nearest = t; picked = actor; }
            }
        }
    });
    return picked;
}

@end
