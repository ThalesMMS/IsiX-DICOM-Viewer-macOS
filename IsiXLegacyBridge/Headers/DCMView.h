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

// DCMView of the legacy plugin SDK, kept by IsiXLegacyBridge, in two roles.
//
// - The image pane of a viewer of the application ([viewerController
//   imageView]): what a plugin reads and sets through it, the image shown,
//   its pixels and ROIs and the window level. It stands for the
//   application's view and is in no window; the application draws the image
//   and takes its events (see Notifications.h for drawing over it and for
//   its clicks).
// - A view of the plugin's own windows and nibs: an NSView that shows the
//   images it is given (-setPixels:files:rois:firstImage:level:reset:), with
//   a window level, flips and the outlines of its ROIs, drawn with Core
//   Graphics. A subclass draws over the image in -subDrawRect:, in the
//   image's pixels, and takes the mouse as any NSView does.

#import "IsiXLegacyBridgeDefines.h"

@class IsiXLegacyDCMPix, IsiXLegacyViewerController, IsiXLegacyViewerSession;

// Tools.
typedef NS_ENUM(short, ToolMode)
{
    tWL                         =   0,
    tTranslate,                 //  1
    tZoom,                      //  2
    tRotate,                    //  3
    tNext,                      //  4
    tMesure,                    //  5
    tROI,                       //  6
    t3DRotate,                  //  7
    tCross,                     //  8
    tOval,                      //  9
    tOPolygon,                  //  10
    tCPolygon,                  //  11
    tAngle ,                    //  12
    tText,                      //  13
    tArrow,                     //  14
    tPencil,                    //  15
    t3Dpoint,                   //  16
    t3DCut,                     //  17
    tCamera3D,                  //  18
    t2DPoint,                   //  19
    tPlain,                     //  20
    tBonesRemoval,              //  21
    tWLBlended,                 //  22
    tRepulsor,                  //  23
    tLayerROI,                  //  24
    tROISelector,               //  25
    tAxis,                      //  26
    tDynAngle,                  //  27
    tCurvedROI,                 //  28
    tTAGT                       //  29
};

ISIX_LEGACY_CLASS(DCMView)
@interface IsiXLegacyDCMView : NSView

/// A view of the plugin's own, sized for images of rows x columns.
- (id) initWithFrame: (NSRect) frame imageRows: (int) rows imageColumns: (int) columns;

/// The images the view shows (DCMPix), the files they came from, one list of
/// ROIs per image, the image shown first; reset takes the window level of
/// that image.
- (void) setPixels: (NSMutableArray*) pixels files: (NSArray*) files rois: (NSMutableArray*) rois firstImage: (short) firstImage level: (char) level reset: (BOOL) reset;
- (void) setDCM: (NSMutableArray*) pixels :(NSArray*) files :(NSMutableArray*) rois :(short) firstImage :(char) type :(BOOL) reset;

/// The index of the image shown, in the series' order.
- (short) curImage;
- (void) setIndex: (short) index;
- (void) setIndexWithReset: (short) index :(BOOL) sizeToFit;
- (IsiXLegacyDCMPix*) curDCM;
- (NSMutableArray*) dcmPixList;
- (NSMutableArray*) dcmRoiList;
- (NSArray*) dcmFilesList;
/// The ROIs of the image shown.
- (NSMutableArray*) curRoiList;
- (void) getWLWW: (float*) wl :(float*) ww;
- (void) setWLWW: (float) wl :(float) ww;
- (double) pixelSpacingX;
- (double) pixelSpacingY;
/// YES for the pane of a viewer of the application.
- (BOOL) is2DViewer;
- (IsiXLegacyViewerController*) windowController;
/// Gives the viewer the ROIs the plugin changed, as needsDisplayUpdate does.
- (void) roiSet;
/// Selects every ROI of the image shown.
- (IBAction) selectAll: (id) sender;
/// A pixel position of this view's image as a pixel position of otherView's
/// image, through the patient coordinates of both.
- (NSPoint) ConvertFromGL2GL: (NSPoint) a toView: (IsiXLegacyDCMView*) otherView;

// A view of the plugin's own.

@property(nonatomic) BOOL xFlipped, yFlipped;
/// NO: the images are shown in the order they were given.
@property(readonly) BOOL flippedData;
/// A point of the view as a pixel position of the image shown (the centre of
/// the first pixel at (0.5, 0.5)), and back.
- (NSPoint) ConvertFromNSView2GL: (NSPoint) a;
- (NSPoint) ConvertFromGL2NSView: (NSPoint) a;
/// What the view shows, as an image of its size.
- (NSImage*) nsimage;
- (NSImage*) nsimage: (BOOL) originalSize;
/// Called after the image and the ROIs are drawn, with the current context's
/// user space in the image's pixels (the centre of the first pixel at
/// (0.5, 0.5), y down the rows). Subclasses draw here; the view draws nothing.
- (void) subDrawRect: (NSRect) aRect;

@end

@compatibility_alias DCMView IsiXLegacyDCMView;
