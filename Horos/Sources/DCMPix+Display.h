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

// The display image of DCMPix is implemented in Swift (DCMPix+Display.swift,
// DCMPix+DisplaySource.swift): the 8-bit picture through the window, its
// polarity and shutter, what it is made from (the thick slab, the convolution,
// the MPR's display plane), the pictures made of it, the change to grey or
// colour, and the windows a frame offers before anyone sets one. Objective-C
// callers see it here. Swift sees the extensions themselves, so the bridging
// header leaves this out.

#import "DCMPix.h"

@class ThickSlabController;

#ifndef HOROS_BRIDGING_HEADER
@interface DCMPix (Display)

/// MONOCHROME1 presentation polarity, independent of calibrated fImage values.
@property(nonatomic) BOOL displayInverted;
// Database/workspace WL stays in the historical sign domain; pixels and live
// WL use calibrated values. These adapters are their only boundary.
- (float) storedWindowLevelForCalibratedLevel:(float) level;
- (float) calibratedWindowLevelForStoredLevel:(float) level;

@property char* baseAddr;
@property unsigned char* LUT12baseAddr;

- (float) getPixelValueX: (long) x Y:(long) y;  /**< Get the pixel for a point with x,y coordinates */

/** Determine if a point is inside a polygon
 * @param x is the NSPoint to check.
 * @param  poly is a pointer to an array of NSPoints.
 * @param count is the number of
 * points in the polygon.
 */
+ (BOOL) IsPoint:(NSPoint) x inPolygon:(NSPoint*) poly size:(int) count;

- (void) compute8bitRepresentation;
- (void) changeWLWW:(float)newWL :(float)newWW;  /**< Change window level to window width to the new values */

- (BOOL) thickSlabVRActivated; /**< Activate Thick Slab VR */

/** convert to Black and White.
 * @param mode values: 0 Use Red Channel, 1 use Green Channel 2 use Blue Channel  3 Merge and use RGB
 */
- (void) ConvertToBW:(long) mode;

/** convert to RGB.
 * @param mode values: 0 create Red Channel, 1 create Green Channel 2 create Blue Channel  3 create all channels
 * @param  cwl  = window level to use
 * @param cww = window width to use
 */
- (void) ConvertToRGB:(long) mode :(long) cwl :(long) cww;

- (void) setBlackIndex:(int) i;
+ (NSImage*) resizeIfNecessary:(NSImage*) currentImage dcmPix: (DCMPix*) dcmPix;

- (void) setConvolutionKernel:(float*)val :(short) size :(float) norm;
- (void) applyConvolutionOnSourceImage;
- (float*) kernel;
- (void) applyShutter;
- (float) normalization;
- (short) kernelsize;

/** create an NSImage from the current pix
 * @param newWW  window width to use
 * @param newWL window level to use;
 */
- (NSImage*) generateThumbnailImageWithWW: (float)newWW WL: (float)newWL;
- (void) allocate8bitRepresentation;

/** create an NSImage from the current pix using the current ww/wl. Full size*/
- (NSImage*) image;

/** Releases the current NSImage */
- (void) kill8bitsImage;

- (void) checkImageAvailble:(float)newWW :(float)newWL;

/** Window Center/Width as the file stores them, or nil when it stores none
    that is usable. Never computed and never guessed. */
- (id) dicomPreviewWindow;
/** The window this frame's own intensities suggest: sampled, with the
    background the corners agree on and the extreme percentiles excluded.
    Reads the decoded buffer; writes nothing, so measurements are unchanged.
    Returns nil when the frame has too few usable samples to guess from. */
- (id) automaticPreviewWindow;
/** The range this frame's own values actually occupy, from its minimum and
    maximum. Used when the sampled calculation has too few usable samples to
    guess from - a uniform or nearly uniform frame - and before the stored bit
    range, which describes what the file could contain rather than what it does. */
- (id) frameRangePreviewWindow;
/** The range the stored bits can represent, after rescale: the last resort. */
- (id) storedRangePreviewWindow;
/** YES for a frame with colour samples, which has no scalar intensity to window. */
- (BOOL) isColorPreviewFrame;

/** Compute the float pointer for the image data */
- (float*) computefImage;
/** The same pixels without the presentation convolution: what a measurement reads. */
- (float*) computefImageForMeasurement;
/** What is drawn: computefImage, with the MPR's cubic display plane in place of fImage when
    this pix has one. Measurement and export keep computefImage / computefImageForMeasurement. */
- (float*) computefImageForDisplay;
/** The MPR's cubic display plane: `pwidth * pheight` floats, or nil. Only drawn. */
@property (nonatomic, retain) NSData *horosMPRDisplayPixels;

/** The thick slab of a grey image, in a new buffer (nil for the volume rendering modes). */
- (float*) computeThickSlab;
/** The thick slab of a colour image, in a new buffer. */
- (float*) computeThickSlabRGB;
/** The image through the convolution, in a new buffer; src is freed unless it is fImage. */
- (float*) applyConvolutionOnImage:(float*) src RGB:(BOOL) color;

/** Sets the ThickSlabController */
- (void) setThickSlabController:( ThickSlabController*) ts;


/** Sets the fixed8bitsWLWW flag */
- (void) setFixed8bitsWLWW:(BOOL) f;

@end
#endif
