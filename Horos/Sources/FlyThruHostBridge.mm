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

#import "FlyThruHostBridge.h"
#import "Camera.h"
#import "Spline3D.h"
#import "Piecewise3D.h"
#import "VRView.h"
#import "SRView.h"

@implementation FlyThruHostBridge

+ (Interpolation3D *)interpolationWithMethod:(int)interpolMeth
{
	Interpolation3D *function;

	if(interpolMeth == 1)
	{
		function = [[Spline3D alloc] init];
	}
	else
	{
		function = [[Piecewise3D alloc] init];
	}

	return [function autorelease];
}

+ (Camera *)cameraOfView:(id)view
{
	return [view camera];
}

+ (NSImage *)imageOfView:(id)view quality:(BOOL)quality
{
	return [view nsimage:quality];
}

+ (void)setCamera:(Camera *)camera ofView:(id)view
{
	[view setCamera: camera];
}

+ (void)setLowResolutionCamera:(Camera *)camera ofView:(id)view
{
	[(VRView *)view setLowResolutionCamera: camera];
}

+ (NSImage *)quicktimeImageOfView:(id)view renderingMode:(BOOL)renderingMode
{
	return [(VRView *)view nsimageQuicktime: renderingMode];
}

+ (NSImage *)quicktimeImageOfView:(id)view
{
	return [(SRView *)view nsimageQuicktime];
}

+ (void)setViewSizeToMatrix3DExportOfView:(id)view
{
	[view setViewSizeToMatrix3DExport];
}

+ (void)restoreViewSizeAfterMatrix3DExportOfView:(id)view
{
	[view restoreViewSizeAfterMatrix3DExport];
}

+ (unsigned char *)rawPixelsOfView:(id)view width:(long *)width height:(long *)height spp:(long *)spp bpp:(long *)bpp
{
	return [view getRawPixels:width :height :spp :bpp :YES :YES];
}

+ (void)getOrientation:(float *)o ofView:(id)view
{
	[view getOrientation: o];
}

+ (double)resolutionOfView:(id)view
{
	return [(VRView *)view getResolution];
}

@end
