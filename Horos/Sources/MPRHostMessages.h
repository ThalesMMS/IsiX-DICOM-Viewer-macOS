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
// it cannot import, declared as a protocol in plain Objective-C.
//
// A VRView: VRView adopts HorosMPRVRViewMessages in VRView+CAPI.m, whose methods are
// VRView's own: a message sent through the protocol is the message the former
// Objective-C sent, to the same object.

#import <Cocoa/Cocoa.h>
#import "DCMView.h"

@class Camera;
@class DCMPix;
@class DICOMExport;

/// -[VRView ...], as VRView.swift and its extensions declare them.
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
- (NSArray *) mprVoxelToWorldTransform;

// What the MPR's Metal planes read of the hidden VRView, as VRView+VolumeHost.swift
// declares and documents them.
- (NSString *)horosMPRGeometryRefusalWidth:(long *)width height:(long *)height;
- (BOOL)horosMPRVolumeMetal;
- (void)horosSetMPRVolumeMetal:(BOOL)on;
- (NSString *)horosMPRVolumeMetalReasonDrawn:(BOOL *)drawn;
- (NSDictionary *)horosMPRColourTables;
- (NSString *)horosMPRFusedGeometryRefusalWidth:(long *)width height:(long *)height;
- (NSDictionary *)horosMPRFusedVolume;

@end

#ifdef __cplusplus
extern "C" {
#endif

/// Set by the MPR and CPR views before a VRView render, reset by the VRView;
/// defined in MPRDCMView+CAPI.m.
extern NS_SWIFT_UI_ACTOR unsigned int minimumStep;

/// arePlanesParallel() of MPRDCMView+CAPI.m, which stays exported under its
/// own name. The MPR and CPR views call it through this wrapper, declared when
/// CPRMPRDCMView.m still had a static function of the same name.
BOOL HorosMPRArePlanesParallel(float *Pn1, float *Pn2);

#ifdef __cplusplus
}
#endif
