/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/

#include "vtkHorosFixedPointVolumeRayCastMapper.h"

#include <vtkObjectFactory.h>
#include <vtkImageData.h>
#include <vtkAlgorithm.h>
#include <vtkRenderWindow.h>
#include <vtkRenderer.h>
#include <vtkCamera.h>
#include <vtkTimerLog.h>
#include <vtkFixedPointRayCastImage.h>
#include "vtkHorosFixedPointVolumeRayCastMIPHelper.h"
#include "VRRayCastZBufferGuard.h"

#include <math.h>
#include <cmath>

int dontRenderVolumeRenderingOsiriX = 0;

vtkStandardNewMacro(vtkHorosFixedPointVolumeRayCastMapper);

vtkHorosFixedPointVolumeRayCastMapper::vtkHorosFixedPointVolumeRayCastMapper()
{
    this->MIPHelper = vtkHorosFixedPointVolumeRayCastMIPHelper::New();
}

// The image is no longer drawn here, in OpenGL: the 3D view's renderer draws
// it with Metal after the render. What is kept is where VTK's display
// helper put it in depth: the nearest distance the rays start at, with
// geometry intermixed, or else the depth of the volume's centre - which VTK
// took for a normalised device coordinate.
void vtkHorosFixedPointVolumeRayCastMapper::DisplayRenderedImage( vtkRenderer *ren, vtkVolume   *vol )
{
    if( this->FinalColorWindow != 1.0 || this->FinalColorLevel != 0.5 )
    {
        this->ApplyFinalColorWindowLevel();
    }
    
    double deviceDepth;
    if ( this->IntermixIntersectingGeometry && this->MinimumViewDistance > 0.0 && this->MinimumViewDistance <= 1.0 )
    {
        deviceDepth = this->MinimumViewDistance * 2.0 - 1.0;
    }
    else
    {
        double *centre = vol->GetCenter();
        ren->SetWorldPoint( centre[0], centre[1], centre[2], 1.0 );
        ren->WorldToDisplay();
        deviceDepth = ren->GetDisplayPoint()[2];
    }
    this->ImageDepth = ( deviceDepth + 1.0 ) / 2.0;
    this->ImageDisplayed = true;
}


bool vtkHorosFixedPointVolumeRayCastMapper::PrepareMPRGeometry(vtkRenderer *ren, vtkVolume *vol, bool acceptClippingPlanes)
{
    this->LastGeometryRefusal = GeometryNoInput;
    vtkImageData *input = vtkImageData::SafeDownCast(this->GetInput());
    if (!input || !ren || !vol)
        return false;
    this->GetInputAlgorithm()->UpdateWholeExtent();

    // Use the host's requested LOD, independent of previous CPU render timings.
    this->ImageSampleDistance = this->MinimumImageSampleDistance;
    int width, height;
    ren->GetTiledSize(&width, &height);
    this->LastGeometryRefusal = GeometryNoViewport;
    if (width <= 0 || height <= 0 || this->ImageSampleDistance <= 0)
        return false;
    this->RayCastImage->SetImageSampleDistance(this->ImageSampleDistance);
    this->RayCastImage->SetImageViewportSize(
        static_cast<int>(width / this->ImageSampleDistance),
        static_cast<int>(height / this->ImageSampleDistance));

    double origin[3], spacing[3];
    int extent[6];
    input->GetOrigin(origin);
    input->GetSpacing(spacing);
    input->GetExtent(extent);
    // restoreCamera installs six planes even for the uncropped volume.
    // Accept those, but use the CPU if any plane cuts into the voxel centres,
    // unless the caller clips its rays against the planes as VTK does.
    for (int planeIndex = 0; !acceptClippingPlanes && planeIndex < this->GetNumberOfClippingPlanes(); ++planeIndex)
    {
        double plane[4];
        this->GetClippingPlaneInDataCoords(vol->GetMatrix(), planeIndex, plane);
        for (int corner = 0; corner < 8; ++corner)
        {
            double distance = plane[3];
            for (int axis = 0; axis < 3; ++axis)
                distance += plane[axis] * (origin[axis] + spacing[axis] *
                    extent[2 * axis + ((corner >> axis) & 1)]);
            if (distance < -1e-4)
            {
                this->LastGeometryRefusal = GeometryClippingPlane;
                return false;
            }
        }
    }
    this->ComputeMatrices(origin, spacing, extent, ren, vol);
    this->RenderWindow = ren->GetRenderWindow();
    this->UpdateCroppingRegions();
    // Keep row bounds allocated so switching back to the CPU remains valid.
    // No transfer tables, gradients, ray casting, or texture presentation here.
    // No row bounds: an abort request, or a volume outside the frustum - which
    // VTK's own bounds, seeded at the image edges, never report.
    if (this->ComputeRowBounds(ren, 1, 1, extent) == 0)
    {
        this->LastGeometryRefusal = GeometryNoRows;
        return false;
    }
    // The voxel-space matrices and clipping planes each ray is cast with, as
    // the CPU render sets them up just before casting.
    this->InitializeRayInfo(vol);
    this->LastGeometryRefusal = GeometryAccepted;
    return true;
}

std::vector<float> vtkHorosFixedPointVolumeRayCastMapper::CaptureGeometryDepth(vtkRenderer *ren, double worldUnitsPerMillimetre)
{
    this->CaptureZBuffer(ren);
    this->SanitizeRayCastZBuffer();
    vtkFixedPointRayCastImage *image = this->RayCastImage;
    if (!image->GetUseZBuffer()) return {};

    int *size = image->GetImageInUseSize();
    vtkCamera *camera = ren->GetActiveCamera();
    const double *range = camera->GetClippingRange();
    const double near = range[0], far = range[1];
    std::vector<float> depth(static_cast<size_t>(size[0]) * size[1], INFINITY);
    for (int y = 0; y < size[1]; ++y)
        for (int x = 0; x < size[0]; ++x)
        {
            // VTK's capture and lookup account for image origin and LOD.
            // Convert its OpenGL depth to camera distance before changing units;
            // Metal's composite camera can have a different clipping range.
            double z = image->GetZBufferValue(x, y);
            if (z >= 0 && z < 1)
            {
                double distance = camera->GetParallelProjection() ? near + z * (far - near)
                    : near * far / (far - z * (far - near));
                depth[static_cast<size_t>(size[1] - 1 - y) * size[0] + x] = distance / worldUnitsPerMillimetre;
            }
        }
    return depth;
}

void vtkHorosFixedPointVolumeRayCastMapper::Render( vtkRenderer *ren, vtkVolume *vol )
{
  this->Timer->StartTimer();
  this->ImageDisplayed = false;

  if (!dontRenderVolumeRenderingOsiriX)
    {
    this->ExternalImageValid = this->RenderImage &&
      this->RenderImage(this->RenderImageContext, this, ren, vol);
    }
  if (this->ExternalImageValid)
    {
    this->DisplayRenderedImage(ren, vol);
    this->Timer->StopTimer();
    this->TimeToDraw = this->Timer->GetElapsedTime();
    return;
    }

  // Since we are passing in a value of 0 for the multiRender flag
  // (this is a single render pass - not part of a multipass AMR render)
  // then we know the origin, spacing, and extent values will not
  // be used so just initialize everything to 0. No need to check
  // the return value of the PerImageInitialization method - since this
  // is not a multirender it will always return 1.
  double dummyOrigin[3]  = {0.0, 0.0, 0.0};
  double dummySpacing[3] = {0.0, 0.0, 0.0};
  int dummyExtent[6] = {0, 0, 0, 0, 0, 0};
  this->PerImageInitialization( ren, vol, 0,
				dummyOrigin,
				dummySpacing,
				dummyExtent );

  this->PerVolumeInitialization( ren, vol );
  this->UpdateFullDepthOpacityTable();

  vtkRenderWindow *renWin=ren->GetRenderWindow();

  if ( renWin && renWin->CheckAbortStatus() )
    {
    this->AbortRender();
    return;
    }

  this->PerSubVolumeInitialization( ren, vol, 0 );
  if ( renWin && renWin->CheckAbortStatus() )
    {
    this->AbortRender();
    return;
    }

  this->SanitizeRayCastZBuffer();

  if( dontRenderVolumeRenderingOsiriX == 0)
	this->RenderSubVolume();

  if ( renWin && renWin->CheckAbortStatus() )
    {
    this->AbortRender();
    return;
    }

  this->DisplayRenderedImage( ren, vol );

  this->Timer->StopTimer();
  this->TimeToDraw = this->Timer->GetElapsedTime();
  // If we've increased the sample distance, account for that in the stored time. Since we
  // don't get linear performance improvement, use a factor of .66
  this->StoreRenderTime( ren, vol,
			 this->TimeToDraw *
			 this->ImageSampleDistance *
			 this->ImageSampleDistance *
			 ( 1.0 + 0.66*
			   (this->SampleDistance - this->OldSampleDistance) /
			   this->OldSampleDistance ) );

  this->SampleDistance = this->OldSampleDistance;
}

void vtkHorosFixedPointVolumeRayCastMapper::UpdateFullDepthOpacityTable()
{
    if (!this->FullDepthCapture || !this->CurrentScalars ||
        this->CurrentScalars->GetNumberOfComponents() != 1 ||
        this->TableScale[0] <= 0)
        return;

    // The caster indexes by (voxel + shift) * scale. Undo that lookup map
    // here so imageInFullDepthWidth decodes the stored voxel word, including
    // when the input range does not start at zero. A one-time identity table
    // is lost when VTK changes its ray step or transfer-function parameters.
    for (int i = 0; i < this->TableSize[0]; ++i)
    {
        double value = i / double(this->TableScale[0]) - this->TableShift[0];
        this->ScalarOpacityTable[0][i] = static_cast<unsigned short>(
            std::round(std::fmin(65535.0, std::fmax(0.0, value))));
    }
}

void vtkHorosFixedPointVolumeRayCastMapper::SanitizeRayCastZBuffer()
{
    vtkFixedPointRayCastImage *image = this->GetRayCastImage();
    if (!image || !image->GetUseZBuffer())
    {
        return;
    }
    int size[2] = {0, 0};
    image->GetZBufferSize(size);
    if (!HorosRayCastZBufferIsUsable(1, image->GetZBuffer(), size[0], size[1]))
    {
        image->UseZBufferOff();
    }
}
