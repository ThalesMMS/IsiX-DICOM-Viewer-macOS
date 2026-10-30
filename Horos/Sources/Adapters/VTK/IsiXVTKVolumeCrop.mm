//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The volume rendering view's crop: the box widget over the volume, its
// callback onto the ray casters, and the planes a camera keeps and gives back
// (IsiXVTKVolumeView.h).

#import "IsiXVTKVolumeViewInternal.hpp"

#include <vtkDoubleArray.h>
#include <vtkPlane.h>
#include <vtkPlaneCollection.h>
#include <vtkPlanes.h>
#include <vtkPoints.h>
#include <vtkPolyData.h>
#include <vtkTransform.h>
#include <vtkVolume.h>
#include <vtkVolumeMapper.h>

void IsiXVTKCropCallback::Execute(vtkObject *caller, unsigned long, void *)
{
    HorosBoxWidget *widget = reinterpret_cast<HorosBoxWidget*>(caller);

    vtkVolume *volume = (vtkVolume*) widget->GetProp3D();

    vtkPlanes *planes = vtkPlanes::New();
    widget->GetPlanes(planes);

    // The volume has a mapper once the view installs its engine. Before that,
    // the box keeps the crop, and the engine's installation runs this callback
    // again on the mapper it installs.
    vtkVolumeMapper *mapper = volume ? (vtkVolumeMapper*) volume->GetMapper() : NULL;
    if( mapper)
        mapper->SetClippingPlanes(planes);

    if( this->BlendingVolume)
    {
        mapper = (vtkVolumeMapper*) this->BlendingVolume->GetMapper();
        if( mapper)
            mapper->SetClippingPlanes(planes);
    }

    planes->Delete();

    widget->SetHandleSize( 0.005);
}

@implementation IsiXVTKVolumeView (IsiXVTKVolumeCrop)

- (void)placeCropBox
{
    HorosBoxWidget *box = _o->croppingBox;
    if (!box) return;
    IsiXVTKVolumeRun("placeCropBox", {}, [&] { box->PlaceWidget(); });
}

- (BOOL)cropBoxEnabled
{
    HorosBoxWidget *box = _o->croppingBox;
    return box && box->GetEnabled();
}

- (void)setCropBoxEnabled:(BOOL)enabled
{
    HorosBoxWidget *box = _o->croppingBox;
    if (!box) return;
    IsiXVTKVolumeRun("setCropBoxEnabled", {}, [&] {
        if (enabled) box->On();
        else box->Off();
    });
}

- (void)hideCropBox
{
    HorosBoxWidget *box = _o->croppingBox;
    if (!box) return;
    IsiXVTKVolumeRun("hideCropBox", {}, [&] {
        if( box->GetEnabled()) box->Off();
    });
}

- (void)setCropBoxHandleSize:(double)size
{
    HorosBoxWidget *box = _o->croppingBox;
    if (!box) return;
    IsiXVTKVolumeRun("setCropBoxHandleSize", {}, [&] { box->SetHandleSize( size); });
}

- (void)executeCropCallback
{
    IsiXVTKVolumeViewObjects *o = _o;
    if (!o->cropcallback) return;
    IsiXVTKVolumeRun("executeCropCallback", {}, [&] { o->cropcallback->Execute( o->croppingBox, 0, nullptr); });
}

- (BOOL)getCroppingBox:(double *)a
{
    IsiXVTKVolumeViewObjects *o = _o;
    vtkVolume *volume = o->volume;
    HorosBoxWidget *croppingBox = o->croppingBox;
    if( volume == nullptr) return NO;
    if( croppingBox == nullptr) return NO;

    BOOL valid = NO;
    IsiXVTKVolumeRun("croppingBox", {}, [&] {
        vtkVolumeMapper *mapper = (vtkVolumeMapper*) volume->GetMapper();
        if( !mapper) return;

        // cropping box
        vtkPolyData *pd = vtkPolyData::New();
        croppingBox->GetPolyData(pd);

        vtkTransform *Transform = vtkTransform::New();
        Transform->SetMatrix(volume->GetUserMatrix());
        Transform->Push();
        Transform->Inverse();

        double min[3], max[3], pointA[3];

        for( int i = 0 ; i < 8; i++)
        {
            pd->GetPoint( i, pointA);

            Transform->TransformPoint( pointA, pointA);

            if( i == 0)
            {
                min[ 0] = pointA[ 0];
                min[ 1] = pointA[ 1];
                min[ 2] = pointA[ 2];
                max[ 0] = pointA[ 0];
                max[ 1] = pointA[ 1];
                max[ 2] = pointA[ 2];
            }
            else
            {
                if( pointA[ 0] < min[ 0]) min[ 0] = pointA[ 0];
                if( pointA[ 1] < min[ 1]) min[ 1] = pointA[ 1];
                if( pointA[ 2] < min[ 2]) min[ 2] = pointA[ 2];

                if( pointA[ 0] > max[ 0]) max[ 0] = pointA[ 0];
                if( pointA[ 1] > max[ 1]) max[ 1] = pointA[ 1];
                if( pointA[ 2] > max[ 2]) max[ 2] = pointA[ 2];
            }
        }

        a[ 0] = min[ 0];
        a[ 2] = min[ 1];
        a[ 4] = min[ 2];

        a[ 1] = max[ 0];
        a[ 3] = max[ 1];
        a[ 5] = max[ 2];

        double origin[3];
        volume->GetPosition(origin);	//GetOrigin

        a[0] -= origin[0];		a[1] -= origin[0];
        a[2] -= origin[1];		a[3] -= origin[1];
        a[4] -= origin[2];		a[5] -= origin[2];

        double temp;
        if((a[0]) > (a[1]))
        {temp = a[0]; a[0] = a[1]; a[1] = temp;}

        if((a[2]) > (a[3]))
        {temp = a[2]; a[2] = a[3]; a[3] = temp;}

        if((a[4]) > (a[5]))
        {temp = a[4]; a[4] = a[5]; a[5] = temp;}

        pd->Delete();
        Transform->Delete();

        valid = YES;
    });
    return valid;
}

- (BOOL)getAppliedCropOrigins:(double *)origins normals:(double *)normals bounds:(double *)bounds
{
    IsiXVTKVolumeViewObjects *o = _o;
    BOOL six = NO;
    IsiXVTKVolumeRun("appliedCrop", {}, [&] {
        vtkPlaneCollection *crop = o->volume && o->volume->GetMapper() ? o->volume->GetMapper()->GetClippingPlanes() : NULL;
        if( crop == NULL || crop->GetNumberOfItems() != 6)
            return;

        for( int i = 0; i < 6; i++)
        {
            vtkPlane *plane = crop->GetItem( i);
            for( int axis = 0; axis < 3; axis++)
            {
                origins[ 3 * i + axis] = plane->GetOrigin()[ axis];
                normals[ 3 * i + axis] = plane->GetNormal()[ axis];
            }
        }
        double *b = o->volume->GetBounds();
        for( int i = 0; i < 6; i++) bounds[ i] = b[ i];
        six = YES;
    });
    return six;
}

- (void)setCropBoxTransform:(const double *)matrix
{
    HorosBoxWidget *box = _o->croppingBox;
    if (!box) return;
    IsiXVTKVolumeRun("setCropBoxTransform", {}, [&] {
        vtkTransform *transform = vtkTransform::New();
        transform->SetMatrix( matrix);
        box->SetTransform( transform);
        transform->Delete();
    });
}

- (int)getCameraCropOrigins:(double *)origins normals:(double *)normals
{
    IsiXVTKVolumeViewObjects *o = _o;
    HorosBoxWidget *croppingBox = o->croppingBox;
    if (!croppingBox) return -1;
    int planeCount = 0;
    IsiXVTKVolumeRun("cameraCrop", {}, [&] {
        vtkPlanes *planes = vtkPlanes::New();
        croppingBox->GetPlanes(planes);

        // A saved or fly-through camera applies its planes to the mapper
        // while hiding the editing widget. Capture the rendered crop, not that
        // stale box.
        vtkPlaneCollection *appliedPlanes = o->volume && o->volume->GetMapper()
            ? o->volume->GetMapper()->GetClippingPlanes() : NULL;
        bool hasAppliedCrop = appliedPlanes && appliedPlanes->GetNumberOfItems() == 6;
        planeCount = hasAppliedCrop ? 6 : planes->GetNumberOfPlanes();

        for( int i = 0; i < planeCount && i < 6; i++)
        {
            vtkPlane *plane = hasAppliedCrop ? appliedPlanes->GetItem( i) : planes->GetPlane( i);

            double *origin = plane->GetOrigin();
            double *normal = plane->GetNormal();
            for( int axis = 0; axis < 3; axis++)
            {
                origins[ 3 * i + axis] = origin[ axis];
                normals[ 3 * i + axis] = normal[ axis];
            }
        }

        planes->Delete();
    });
    return planeCount;
}

- (void)setCropPlanesOrigins:(const double *)origins normals:(const double *)normalValues
{
    IsiXVTKVolumeViewObjects *o = _o;
    IsiXVTKVolumeRun("setCropPlanes", {}, [&] {
        vtkPlanes *planes = vtkPlanes::New();

        vtkPoints *pts = vtkPoints::New(VTK_DOUBLE);
        pts->SetNumberOfPoints(6);

        vtkDoubleArray *normals = vtkDoubleArray::New();
        normals->SetNumberOfComponents(3);
        normals->SetNumberOfTuples(6);

        // Set the normals and coordinate values
        for (int i=0; i<6; i++)
        {
            pts->SetPoint(i, origins[3*i], origins[3*i+1], origins[3*i+2]);
            normals->SetTuple3(i, normalValues[3*i], normalValues[3*i+1], normalValues[3*i+2]);
        }

        planes->SetPoints(pts);
        planes->SetNormals(normals);

        pts->Delete();
        normals->Delete();

        vtkVolumeMapper *mapper = o->volume ? (vtkVolumeMapper*) o->volume->GetMapper() : nullptr;
        if (mapper) mapper->SetClippingPlanes( planes);

        if( o->blendingVolume)
        {
            mapper = (vtkVolumeMapper*) o->blendingVolume->GetMapper();
            if (mapper) mapper->SetClippingPlanes( planes);
        }

        planes->Delete();

        if( o->croppingBox && o->croppingBox->GetEnabled())
            o->croppingBox->Off();
    });
}

@end
