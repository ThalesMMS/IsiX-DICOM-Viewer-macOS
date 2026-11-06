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

// The geometry of DCMPix is implemented in Swift (DCMPix+Geometry.swift):
// its orientation, the conversions between pixel, patient and slice
// coordinates, and the images it renders turned, merged and copied.
// Objective-C callers see it here. Swift sees the extension itself, so the
// bridging header leaves this out.

#import <Accelerate/Accelerate.h>
#import "DCMPix.h"

#ifndef HOROS_BRIDGING_HEADER
@interface DCMPix (Geometry)

- (BOOL) identicalOrientationTo:(DCMPix*) c;

- (void)orientationDouble:(double*) c;
- (void)setOrientationDouble:(double*) c;

/** A pointer to the orientation.  9 values in length. 3 for each axis. */
- (void) orientation:(float*) c;

/** Sets the orientation.  9 values in length. 3 for each axis. */
- (void) setOrientation:(float*) c;

- (BOOL) is3DPlane;

/** The orientation of the image flipped and turned by `rotation` degrees in a view. */
- (void) orientationCorrected:(float*) correctedOrientation rotation:(float) rotation xFlipped: (BOOL) xFlipped yFlipped: (BOOL) yFlipped;

/** Utility methods to convert user supplied pixel coords to DICOM patient coords float d[3] (in mm)
 * using current slice location and orientation
 */
- (void) convertPixX: (float) x pixY: (float) y toDICOMCoords: (float*) d;
- (void) convertPixX: (float) x pixY: (float) y toDICOMCoords: (float*) d pixelCenter: (BOOL) pixelCenter;

- (void) getSliceCenter3DCoords: (float*) center;

/** Utility methods to convert user supplied pixel coords to DICOM patient coords double d[3] (in mm)
 * using current slice location and orientation
 */
- (void) convertPixDoubleX: (double) x pixY: (double) y toDICOMCoords: (double*) d;
- (void) convertPixDoubleX: (double) x pixY: (double) y toDICOMCoords: (double*) d pixelCenter: (BOOL) pixelCenter;

/** convert DICOM coordinated to slice coordinates */
- (void) convertDICOMCoords: (float*) dc toSliceCoords: (float*) sc;
- (void) convertDICOMCoords: (float*) dc toSliceCoords: (float*) sc pixelCenter:(BOOL) pixelCenter;

/** convert DICOM coordinated to slice coordinates */
- (void) convertDICOMCoordsDouble: (double*) dc toSliceCoords: (double*) sc;
- (void) convertDICOMCoordsDouble: (double*) dc toSliceCoords: (double*) sc pixelCenter:(BOOL) pixelCenter;

/** Return index & sliceCoords */
+(int) nearestSliceInPixelList: (NSArray*)pixlist withDICOMCoords: (float*)dc sliceCoords: (float*) sc;

- (NSRect) rectCoordinates;
+ (NSPoint) originDeltaBetween:(DCMPix*) pix1 And:(DCMPix*) pix2;
+ (NSPoint) originCorrectedAccordingToOrientation: (DCMPix*) pix1;
+ (NSPoint) rotatePoint:(NSPoint)pt aroundPoint:(NSPoint)c angle:(float)a;

- (DCMPix*) renderWithRotation:(float) r scale:(float) scale xFlipped:(BOOL) xF yFlipped: (BOOL) yF;
- (DCMPix*) renderWithRotation:(float) r scale:(float) scale xFlipped:(BOOL) xF yFlipped: (BOOL) yF backgroundOffset: (float) bgO;
- (NSRect) usefulRectWithRotation:(float) r scale:(float) scale xFlipped:(BOOL) xF yFlipped: (BOOL) yF;
- (DCMPix*) mergeWithDCMPix:(DCMPix*) o offset:(NSPoint) oo;
- (DCMPix*) renderInRectSize:(NSSize) rectSize atPosition:(NSPoint) oo rotation:(float) r scale:(float) scale xFlipped:(BOOL) xF yFlipped: (BOOL) yF;
- (DCMPix*) renderInRectSize:(NSSize) rectSize atPosition:(NSPoint) oo rotation:(float) r scale:(float) scale xFlipped:(BOOL) xF yFlipped: (BOOL) yF smartCrop: (BOOL) smartCrop;
- (NSImage*) renderNSImageInRectSize:(NSSize) rectSize atPosition:(NSPoint) oo rotation:(float) r scale:(float) scale xFlipped:(BOOL) xF yFlipped: (BOOL) yF;

/** Copies src into dst at oo, over the background b (opaque) or where src is more than 900 above it (transparent). */
- (void) drawImage: (vImage_Buffer*) src inImage: (vImage_Buffer*) dst offset:(NSPoint) oo background:(float) b transparency: (BOOL) t;
- (void) drawImage: (vImage_Buffer*) src inImage: (vImage_Buffer*) dst offset:(NSPoint) oo background:(float) b;

@end
#endif
