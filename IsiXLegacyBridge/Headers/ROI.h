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

// ROI of the legacy plugin SDK, kept by IsiXLegacyBridge. A ROI read from a
// viewer stands for the application's ROI: setting its name, comments, mode,
// points or text box, rotating or moving it changes the application's ROI at
// once. A ROI the plugin creates joins the viewer when it is added to a list
// of -[ViewerController roiList] and the viewer is updated, or at the end of
// the command, or, outside a command, on the next turn of the run loop after
// the plugin posts "roiChange" for it. Points, rotate and roiMove work on
// lines, rectangles, ovals, polygons and polylines. A brush ROI the plugin
// creates from a mask (initWithTexture:...) joins the viewer the same way;
// its mask is not read back. Colours and layers are not part of it: a colour
// set is kept, and the application draws the ROI in its own.

#import "IsiXLegacyBridgeDefines.h"
#import "DCMView.h"
#import "MyPoint.h"

@class IsiXLegacyDCMPix, IsiXLegacyROIState, IsiXLegacyViewerSession;

enum
{
    ROI_sleep = 0,
    ROI_drawing = 1,
    ROI_selected = 2,
    ROI_selectedModify = 3
};

ISIX_LEGACY_CLASS(ROI)
@interface IsiXLegacyROI : NSObject

@property(nonatomic, copy) NSString *name;
@property(nonatomic, retain) NSString *comments;
@property(readonly) ToolMode type;
@property(nonatomic, setter=setROIMode:) long ROImode;
/// The points of the ROI: for a rectangle and an oval, the outline, read only.
@property(nonatomic, retain) NSMutableArray *points;
/// A rectangle's origin and size, an oval's centre and radii, a 2D point's position.
@property(nonatomic, setter=setROIRect:) NSRect rect;
@property(nonatomic, retain) IsiXLegacyDCMPix *pix;
@property(nonatomic, assign) IsiXLegacyDCMView *curView;
@property(nonatomic) BOOL displayTextualData;
@property double pixelSpacingX, pixelSpacingY;
@property NSPoint imageOrigin;
@property BOOL locked;
/// The application's statistics, when the ROI is in a viewer.
@property(readonly) float min, max, mean;

- (void) setROIMode: (long) mode;
- (void) setROIRect: (NSRect) rect;

+ (void) setDefaultName: (NSString*) n;
+ (NSString*) defaultName;
- (void) setDefaultName: (NSString*) n;
- (NSString*) defaultName;

- (id) initWithType: (ToolMode) itype :(float) ipixelSpacing :(NSPoint) iimageOrigin;
- (id) initWithType: (ToolMode) itype :(float) ipixelSpacingx :(float) ipixelSpacingy :(NSPoint) iimageOrigin;
/// A brush ROI from a mask of tWidth x tHeight bytes, non-zero inside, whose
/// first byte is the pixel (posX, posY) of the image. The kit keeps a copy.
- (id) initWithTexture: (unsigned char*) tBuff textWidth: (int) tWidth textHeight: (int) tHeight textName: (NSString*) tName
             positionX: (int) posX positionY: (int) posY
              spacingX: (float) ipixelSpacingx spacingY: (float) ipixelSpacingy imageOrigin: (NSPoint) iimageOrigin;
/// Crops a brush ROI's mask to its painted pixels; YES when none is painted.
- (BOOL) reduceTextureIfPossible;
@property(readonly) int textureWidth, textureHeight;
@property(readonly) int textureUpLeftCornerX, textureUpLeftCornerY, textureDownRightCornerX, textureDownRightCornerY;
@property(readonly) unsigned char *textureBuffer;
/// Kept; the application draws the ROI in its own colour.
@property(nonatomic, setter=setColor:) RGBColor rgbcolor;
- (void) setColor: (RGBColor) color;
@property double sliceThickness;

/// In cm², 0 without pixel spacing.
- (float) roiArea;
- (NSPoint) centroid;
/// The length of a line in cm (in pixels without pixel spacing); pixels receives it in pixels.
- (float) MesureLength: (float*) pixels;
- (float) Length: (NSPoint) mesureA :(NSPoint) mesureB;
- (float) LengthFrom: (NSPoint) mesureA to:(NSPoint) mesureB inPixel: (BOOL) inPixel;

- (NSPoint) pointAtIndex: (NSUInteger) index;
- (void) setPoint: (NSPoint) point atIndex: (NSUInteger) index;
- (void) addPoint: (NSPoint) point;
- (NSMutableArray*) splinePoints;

- (void) roiMove: (NSPoint) offset;
- (void) roiMove: (NSPoint) offset :(BOOL) sendNotification;
/// Turns the ROI by angle degrees about center; a rectangle or an oval becomes a polygon.
- (void) rotate: (float) angle :(NSPoint) center;
- (BOOL) valid;

@end

@compatibility_alias ROI IsiXLegacyROI;
