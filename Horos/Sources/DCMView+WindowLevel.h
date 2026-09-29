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

// The "ww/wl" methods of DCMView are implemented in Swift since #834
// (DCMView+WindowLevel.swift and
// DCMView+WindowLevel+Coordinates.swift): a Swift extension of the class, which stays
// Objective-C, with the same selectors. DCMView.h imports this header, so that
// whoever imports it, plugins included, still sees them. The declarations are
// the former ones, in a category, and not the generated interface: DCMView.h
// is imported by headers before their own interface (BrowserController.h, by
// PreviewView.h), and Horos-Swift.h, through the bridging header, needs those
// interfaces complete.

#import "DCMView.h"
@class DCMPix, ROI;

// Under the bridging header, Swift is compiling the extension itself.
#ifndef HOROS_BRIDGING_HEADER
@interface DCMView (WindowLevel)

@property(readonly) double pixelSpacing, pixelSpacingX, pixelSpacingY;
+ (void) computePETBlendingCLUT;
+ (float) angleBetweenVector: (float*) v1 andVector: (float*) v2;
+ (double) angleBetweenVectorD: (double*) v1 andVectorD: (double*) v2;
+ (float) pbase_Plane: (float*) point :(float*) planeOrigin :(float*) planeVector :(float*) pointProjection;
+ (short)syncro;
+ (void)setSyncro:(short) s;
- (int) findPlaneAndPoint:(float*) pt :(float*) location;
- (int) findPlaneForPoint:(float*) pt localPoint:(float*) location distanceWithPlane: (float*) distanceResult;
- (int) findPlaneForPoint:(float*) pt preferParallelTo:(float*)parto localPoint:(float*) location distanceWithPlane: (float*) distanceResult;
- (int) findPlaneForPoint:(float*)pt preferParallelTo:(float*)parto localPoint:(float*)location distanceWithPlane:(float*)distanceResult preferImageType:(NSString*)preferredImageType;
- (void) subtract:(DCMView*) bV;
- (void) subtract:(DCMView*) bV absolute:(BOOL) abs;
- (void) multiply:(DCMView*) bV;
- (short)syncro;
- (void)setSyncro:(short) s;
- (void) prepareToRelease;
- (NSPoint) ConvertFromNSView2GL:(NSPoint) a;
- (NSPoint) ConvertFromView2GL:(NSPoint) a;
- (NSPoint) ConvertFromUpLeftView2GL:(NSPoint) a;
- (NSPoint) ConvertFromGL2View:(NSPoint) a;
- (NSPoint) ConvertFromGL2NSView:(NSPoint) a;
- (NSPoint) ConvertFromGL2Screen:(NSPoint) a;
- (NSPoint) ConvertFromGL2GL:(NSPoint) a toView:(DCMView*) otherView;
- (void) setWLWW:(float) wl :(float) ww;
- (void)discretelySetWLWW:(float)wl :(float)ww;
- (void) getWLWW:(float*) wl :(float*) ww;
- (void) getThickSlabThickness:(float*) thickness location:(float*) location;
- (void) setCLUT:( unsigned char*) r :(unsigned char*) g :(unsigned char*) b;
- (void) sendSyncMessage:(short) inc;
- (void) setFusion:(short) mode :(short) stacks;
- (NSPoint) rotatePoint:(NSPoint) a;
- (IBAction) alwaysSyncMenu:(id) sender;
- (void) getCLUT:( unsigned char**) r : (unsigned char**) g : (unsigned char**) b;
- (void) sync:(NSNotification*)note;
- (void) drawTextualData:(NSRect) size :(long) annotations;
- (void) drawTextualData:(NSRect) size annotationsLevel:(long) annotations fullText: (BOOL) fullText onlyOrientation: (BOOL) onlyOrientation;
- (void) roiChange:(NSNotification*)note;
- (void) roiSelected:(NSNotification*) note;
- (void) updateImage;
- (void) annotMenu:(id) sender;
- (void)getOrientationText:(char *) orientation : (float *) vector :(BOOL) inv;
- (void) invalidateReferenceLines;
- (NSPoint) positionWithoutRotation: (NSPoint) tPt;
- (void) drawOrientation:(NSRect) size;
+ (NSArray*)cleanedOutDcmPixArray:(NSArray*)input; // filters the input array of DCMPix by returning only the pix with the most common ImageType in the input array

@end
#endif
