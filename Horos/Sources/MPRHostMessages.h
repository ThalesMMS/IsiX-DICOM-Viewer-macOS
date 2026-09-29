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
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

// The messages the Swift MPR (MPRController, MPRDCMView) sends to Objective-C
// it cannot import, declared as protocols in plain Objective-C.
//
// - A VRView: VRView.h includes VTK's C++ headers, which Swift cannot read.
//   VRView adopts HorosMPRVRViewMessages in VRHostBridge.h, whose methods are
//   VRView's own: a message sent through the protocol is the message the
//   former Objective-C sent, to the same object.
// - The MPR view's own bridge: MPRHostBridge.h declares a category of
//   MPRDCMView, a Swift class, which no header Swift reads can name. The
//   category adopts HorosMPRHostViewMessages.

#import <Cocoa/Cocoa.h>
#import "DCMView.h"

@class Camera;
@class DCMPix;
@class DICOMExport;

/// -[VRView ...], as VRView.h declares them.
@protocol HorosMPRVRViewMessages <NSObject>

@property (nonatomic) BOOL clipRangeActivated, keep3DRotateCentered, dontResetImage, bestRenderingMode;
@property (nonatomic) double clippingRangeThickness;
@property (nonatomic) float lowResLODFactor;
@property long renderingMode;
@property (nonatomic) int engine;
@property (readonly) NSArray* currentOpacityArray;
@property (retain) DICOMExport *exportDCM;
@property (retain) NSString *dcmSeriesString;

- (void) prepareFullDepthCapture;
- (void) restoreFullDepthCapture;
- (float*) imageInFullDepthWidth: (long*) w height:(long*) h isRGB:(BOOL*) isRGB;
- (float*) imageInFullDepthWidth: (long*) w height:(long*) h isRGB:(BOOL*) rgb blendingView:(BOOL) blendingView;
- (NSDictionary*) exportDCMCurrentImage;
- (void) endRenderImageWithBestQuality;
- (void) getShadingValues:(float*) ambient :(float*) diffuse :(float*) specular :(float*) specularpower;
- (void) setShadingValues:(float) ambient :(float) diffuse :(float) specular :(float) specularpower;
- (void) setBlendingWLWW:(float) iwl :(float) iww;
- (void) setOpacity:(NSArray*) array;
- (void) setLOD:(float)f;
- (void) setCurrentTool:(ToolMode) i;
- (ToolMode) _tool;
- (void) setWLWW:(float) wl :(float) ww;
- (void) getWLWW:(float*) wl :(float*) ww;
- (void) getBlendingWLWW:(float*) iwl :(float*) iww;
- (void) setCLUT:( unsigned char*) r : (unsigned char*) g : (unsigned char*) b;
- (IBAction) switchShading:(id) sender;
- (IBAction) resetImage:(id) sender;
- (void) setBlendingMode: (long) modeID;
- (void) setCamera: (Camera*) cam;
- (Camera*) cameraWithThumbnail:(BOOL) produceThumbnail;
- (void) getOrientation: (float*) o;
- (void) setMode: (long) modeID;
- (double) getResolution;
- (BOOL) getCosMatrix: (float *) cos;
- (void) getOrigin: (float *) origin windowCentered:(BOOL) wc sliceMiddle:(BOOL) sliceMiddle;
- (void) getOrigin: (float *) origin windowCentered:(BOOL) wc sliceMiddle:(BOOL) sliceMiddle blendedView:(BOOL) blendedView;
- (void) scrollInStack: (float) delta;
- (float) factor;
- (float) imageSampleDistance;
- (float) blendingImageSampleDistance;
- (void) setViewSizeToMatrix3DExport;
- (void) restoreViewSizeAfterMatrix3DExport;
- (void) render;
- (void) renderBlendedVolume;
- (void) setWindowCenter: (NSPoint) loc;
- (double) getClippingRangeThickness;
- (double) getClippingRangeThicknessInMm;
- (void) setClippingRangeThicknessInMm:(double) c;

@end

/// -[MPRDCMView horosMPR...] of MPRHostBridge.m; MPRHostBridge.h documents them.
@protocol HorosMPRHostViewMessages <NSObject>

- (float *)horosMPRCopyImageWidth:(long *)width height:(long *)height;
- (BOOL)horosMPRCopiedImageIsRGB;
- (float *)horosMPRTakeFusedImageWidth:(long *)width height:(long *)height;
- (void)horosMPRAttachDisplayPlaneTo:(DCMPix *)pix;
- (void)horosMPRVolumeRendered;

@end
