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

// The ROI half of DCMPix is implemented in Swift (DCMPix+ROIMeasure.swift and
// DCMPix+ROIFill.swift): Swift extensions of the class, which stays
// Objective-C, with the same selectors. DCMPix.h imports this header, so that
// whoever imports it still sees them. The declarations are the former ones, in
// a category, and not the generated interface: DCMPix.h is imported by headers
// before their own interface, and Horos-Swift.h, through the bridging header,
// needs those interfaces complete.

#import "DCMPix.h"

@class ROI;

// Under the bridging header, Swift is compiling the extensions themselves.
#ifndef HOROS_BRIDGING_HEADER
@interface DCMPix (ROI)

// Compute ROI data
/** Calculates the cofactor used Calcium scoring.
 * Depends on the threshold used for scoring
 * Threshold is usually 90 or 120 depending on whether the source is
 * Electron Beam or Multislice CT
 */
- (int)calciumCofactorForROI:(ROI *)roi threshold:(int)threshold;

/** returns calculated values for ROI:
 *  mean, total, deviation, min, max
 */
- (void) computeROI:(ROI*) roi :(float *)mean :(float *)total :(float *)dev :(float *)min :(float *)max :(float*) skewness :(float*) kurtosis;
- (void) computeROI:(ROI*) roi :(float *)mean :(float *)total :(float *)dev :(float *)min :(float *)max;

/** Fill a ROI with a value
 * @param roi  Selected ROI
 * @param newVal  The replacement value
 * @param minValue  Lower threshold
 * @param maxValue Upper threshold
 * @param outside  if YES replace outside the ROI
 * @param orientationStack
 * @param stackNo
 * @param restore
 * @param addition
 */
- (void) fillROI:(ROI*) roi newVal:(float) newVal minValue:(float) minValue maxValue:(float) maxValue outside:(BOOL) outside orientationStack:(long) orientationStack stackNo:(long) stackNo restore:(BOOL) restore addition:(BOOL) addition;
- (void) fillROI:(ROI*) roi newVal:(float) newVal minValue:(float) minValue maxValue:(float) maxValue outside:(BOOL) outside orientationStack:(long) orientationStack stackNo:(long) stackNo restore:(BOOL) restore addition:(BOOL) addition spline:(BOOL) spline;
- (void) fillROI:(ROI*) roi newVal :(float) newVal minValue :(float) minValue maxValue :(float) maxValue outside :(BOOL) outside orientationStack :(long) orientationStack stackNo :(long) stackNo restore :(BOOL) restore addition:(BOOL) addition spline:(BOOL) spline clipMin: (NSPoint) clipMin clipMax: (NSPoint) clipMax;

/** Fill a ROI with a value
 * @param roi  Selected ROI
 * @param newVal  The replacement value
 * @param minValue  lower threshold
 * @param maxValue  upper threshold
 * @param outside  if YES replace outside the ROI
 * @param orientationStack  ?
 * @param  stackNo
 * @param  restore
 */
- (void) fillROI:(ROI*) roi :(float) newVal :(float) minValue :(float) maxValue :(BOOL) outside :(long) orientationStack :(long) stackNo :(BOOL) restore;

/** Fill a ROI with a value
 * @param roi  Selected ROI
 * @param newVal  The replacement value
 * @param minValue  lower threshold
 * @param maxValue  upper threshold
 * @param outside  if YES replace outside the ROI
 * @param orientation
 * @param stackNo
 */
- (void) fillROI:(ROI*) roi :(float) newVal :(float) minValue :(float) maxValue :(BOOL) outside :(long) orientation :(long) stackNo;

/** Fill a ROI with a value.
 * @param roi Selected ROI
 * @param newVal  The replacement value
 * @param minValue  Lower threshold
 * @param maxValue  Upper threshold
 * @param outside  If YES replace outside the ROI
 */
- (void) fillROI:(ROI*) roi :(float) newVal :(float) minValue :(float) maxValue :(BOOL) outside;

- (unsigned char*) getMapFromPolygonROI:(ROI*) roi size:(NSSize*) size origin:(NSPoint*) origin; /**< Map from Polygon ROI */
+ (unsigned char*) getMapFromPolygonROI:(ROI*) roi size:(NSSize*) size origin:(NSPoint*) ROIorigin;

/** Is this Point (pt) in this ROI ? */
- (BOOL) isInROI:(ROI*) roi :(NSPoint) pt;

/** Returns a pointer with all pixels values contained in the current ROI
 * User must Free the pointer with the free() function
 * Returns reference number of pixels in numberOfValues
 * Returns a pointer to the pixel locations. Each point has the x position followed by the y position
 * Locations is malloced but not freed
 */
- (float*) getROIValue :(long*) numberOfValues :(ROI*) roi :(float**) locations;

/** Returns a pointer with all pixels values contained in the current ROI
 * User must Free the pointer with the free() function
 * Returns reference number of pixels in numberOfValues
 * Returns a pointer to the pixel locations. Each point has the x position followed by the y position
 * Locations is malloced but not freed
 */
- (float*) getLineROIValue :(long*) numberOfValues :(ROI*) roi;

/** Creates a DCMPix with the original values and places it in the restore cache*/
- (BOOL) prepareRestore;

/** Releases the restored DCMPix from the restoreCache */
- (void) freeRestore;

+ (double) moment: (float *) x length:(long) length mean: (double) mean order: (int) order;
+ (double) skewness: (float*) data length: (long) length mean: (double) mean;
+ (double) kurtosis: (float*) data length: (long) length mean: (double) mean;

/** The mask of an RT STRUCT contour on an image of width x height: the pixels
 * whose centre lies inside it, with an empty border. malloc'd; NULL for fewer
 * than three points, a point that is not finite or a contour off the image. */
+ (unsigned char *)getMapFromRTSTRUCTROI:(ROI *)roi width:(int)imageWidth height:(int)imageHeight size:(NSSize *)size origin:(NSPoint *)origin;

@end
#endif
