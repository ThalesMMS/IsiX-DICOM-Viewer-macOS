/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)

 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.

 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.

 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.

 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html

 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
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

// DCMPix of the legacy plugin SDK, kept by IsiXLegacyBridge: one image of a
// viewer. Its pixels (fImage) are a copy the plugin owns, read from the
// application on first use; -[ViewerController needsDisplayUpdate] gives the
// changed ones back to the viewer. Geometry and attributes come from the
// plugin API; the database objects behind an image are not part of it.

#import "IsiXLegacyBridgeDefines.h"

@class IsiXLegacyROI, IsiXLegacyViewerSession, IsiXLegacyDicomImage, IsiXLegacyDicomSeries;

ISIX_LEGACY_CLASS(DCMPix)
@interface IsiXLegacyDCMPix : NSObject <NSCopying>

/// Float32 samples in modality units, or ARGB bytes when isRGB: pwidth *
/// pheight of them, row by row, valid while the viewer is open. Setting it
/// makes the image use the caller's buffer, which the caller keeps.
@property(setter=setfImage:) float* fImage;
@property(nonatomic) long pwidth, pheight;
@property(readonly) BOOL isRGB;
@property double pixelSpacingX, pixelSpacingY;
@property(readonly) double pixelRatio;
@property(readonly) double originX, originY, originZ;
@property double sliceLocation, sliceThickness, sliceInterval;
@property(readonly) float ww, wl, fullww, fullwl;
@property(nonatomic) float slope, offset, savedWW, savedWL;
@property (nonatomic) float minValueOfSeries, maxValueOfSeries;
@property long frameNo;
@property(setter=setID:) long ID;
@property(getter=Tot, setter=setTot:) long Tot;
@property(retain) NSString *repetitiontime, *echotime;
@property(retain) NSString *modalityString;
@property(readonly) BOOL SUVConverted;

/// The nine cosines: row direction, column direction and normal.
- (void) orientation: (float*) c;
- (void) orientationDouble: (double*) c;
- (void) origin: (float*) o;
- (void) originDouble: (double*) o;

- (float) getPixelValueX: (long) x Y:(long) y;
- (void) changeWLWW: (float) newWL :(float) newWW;
- (void) computePixMinPixMax;
- (void) CheckLoad;
- (void) compute8bitRepresentation;

/// The application's statistics of a ROI of this viewer, measured on this image.
- (void) computeROI: (IsiXLegacyROI*) roi :(float *) mean :(float *) total :(float *) dev :(float *) min :(float *) max;

/// The patient coordinates of a pixel position: with pixelCenter (the
/// default), the centre of the first pixel is at (0.5, 0.5), as ROI points are.
- (void) convertPixX: (float) x pixY: (float) y toDICOMCoords: (float*) d;
- (void) convertPixX: (float) x pixY: (float) y toDICOMCoords: (float*) d pixelCenter: (BOOL) pixelCenter;
- (void) convertPixDoubleX: (double) x pixY: (double) y toDICOMCoords: (double*) d pixelCenter: (BOOL) pixelCenter;

+ (NSPoint) originCorrectedAccordingToOrientation: (IsiXLegacyDCMPix*) pix;

@end

/// The image of the database behind a viewer's image, when the plugin
/// declares database.read (IsiXLegacyDCMPix+Database.m); nil otherwise.
@interface IsiXLegacyDCMPix (IsiXLegacyDatabase)
/// The image's file, for reading: the database's.
- (NSString*) sourceFile;
- (NSString*) srcFile;
- (IsiXLegacyDicomImage*) imageObj;
- (IsiXLegacyDicomSeries*) seriesObj;

@end

@interface IsiXLegacyDCMPix (IsiXLegacyROIValues)

/// The values of the pixels inside the ROI, from the plugin's copy of the
/// image: those whose centre lies inside its outline, or set in a brush ROI's
/// mask; with their column and row in locations, two floats each, when it is
/// not NULL. Both are allocated with malloc; the caller frees them.
- (float*) getROIValue: (long*) numberOfValues :(IsiXLegacyROI*) roi :(float**) locations;

@end

@compatibility_alias DCMPix IsiXLegacyDCMPix;
