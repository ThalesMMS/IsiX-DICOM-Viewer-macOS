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

// The fly-thru classes are Swift. What they send to the 3D views and to the
// interpolation functions is declared in VRView.h, SRView.h, Spline3D.h and
// Piecewise3D.h, which include VTK's C++ headers and cannot reach Swift. This
// Objective-C++ helper sends those messages exactly as the former Objective-C
// did; its header is plain Objective-C.

#import <Cocoa/Cocoa.h>

@class Camera;
@class Interpolation3D;

@interface FlyThruHostBridge : NSObject

/// [[Spline3D alloc] init] for method 1, [[Piecewise3D alloc] init] otherwise.
+ (Interpolation3D *)interpolationWithMethod:(int)interpolMeth;

/// [view camera], the view being a VRView or an SRView.
+ (Camera *)cameraOfView:(id)view;
/// [view nsimage:quality].
+ (NSImage *)imageOfView:(id)view quality:(BOOL)quality;
/// [view setCamera:camera].
+ (void)setCamera:(Camera *)camera ofView:(id)view;
/// [view setLowResolutionCamera:camera], a VRView.
+ (void)setLowResolutionCamera:(Camera *)camera ofView:(id)view;
/// [view nsimageQuicktime:renderingMode], a VRView.
+ (NSImage *)quicktimeImageOfView:(id)view renderingMode:(BOOL)renderingMode;
/// [view nsimageQuicktime], an SRView.
+ (NSImage *)quicktimeImageOfView:(id)view;
/// [view setViewSizeToMatrix3DExport].
+ (void)setViewSizeToMatrix3DExportOfView:(id)view NS_SWIFT_NAME(setViewSizeToMatrix3DExport(ofView:));
/// [view restoreViewSizeAfterMatrix3DExport].
+ (void)restoreViewSizeAfterMatrix3DExportOfView:(id)view NS_SWIFT_NAME(restoreViewSizeAfterMatrix3DExport(ofView:));

/// [view getRawPixels:width :height :spp :bpp :YES :YES], malloc'ed.
+ (unsigned char *)rawPixelsOfView:(id)view width:(long *)width height:(long *)height spp:(long *)spp bpp:(long *)bpp;
/// [view getOrientation:o].
+ (void)getOrientation:(float *)o ofView:(id)view;
/// [view getResolution], a VRView.
+ (double)resolutionOfView:(id)view;

@end
