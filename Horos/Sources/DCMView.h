/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/

// DCMView is implemented in Swift (DCMView.swift and its extensions), and the
// generated interface, Horos-Swift.h, declares the class under the same name,
// selectors and properties. This header keeps <Horos/DCMView.h> for the tools,
// the constants, the globals and the C functions the class exported, and names
// the class. It does not import the generated interface: the headers of
// ViewerController and other classes read it before declaring their own class,
// which the generated interface extends. A file that sends DCMView's messages
// imports Horos-Swift.h. DCMView+CAPI.m defines the globals and the functions
// and implements the methods Swift cannot declare.

#ifndef DCMVIEW_H_INCLUDED
#define DCMVIEW_H_INCLUDED

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>

#import "N3Geometry.h"

#include "options.h"

#define STAT_UPDATE					0.6f
#define IMAGE_COUNT					1
#define IMAGE_DEPTH					32

// Tools.

// WARNING: If you add or modify this list, check ViewerController.m, DCMView.h and HotKey Pref Pane

typedef NS_ENUM(short, ToolMode)
{
    tWL							=	0,
    tTranslate,					//	1
    tZoom,						//	2
    tRotate,					//	3
    tNext,						//	4
    tMesure,					//	5
    tROI,						//	6
	t3DRotate,					//	7
	tCross,						//	8
	tOval,						//	9
	tOPolygon,					//	10
	tCPolygon,					//	11
	tAngle ,					//	12
	tText,						//	13
	tArrow,						//	14
	tPencil,					//	15
	t3Dpoint,					//	16
	t3DCut,						//	17
	tCamera3D,					//	18
	t2DPoint,					//	19
	tPlain,						//	20
	tBonesRemoval,				//	21
	tWLBlended,					//  22
	tRepulsor,					//  23
	tLayerROI,					//	24
	tROISelector,				//	25
	tAxis,						//	26 
	tDynAngle,					//	27
	tCurvedROI,					//	28
    tTAGT                       //  29
    ////////////////////////////////
    //tBall,                      //  30
    //tOvalAngle                  //  31
};

extern NSString * const HorosPasteboardType;
extern NSString * const HorosPasteboardTypePlugin;

#ifndef NS_SWIFT_UI_ACTOR
#define NS_SWIFT_UI_ACTOR
#endif
// Display settings of the views, read and set on the main thread.
extern NS_SWIFT_UI_ACTOR int CLUTBARS, ANNOTATIONS, SOFTWAREINTERPOLATION_MAX, DISPLAYCROSSREFERENCELINES;

enum { annotNone = 0, annotGraphics, annotBase, annotFull };
enum { barHide = 0, barOrigin, barFused, barBoth };
enum { syncroOFF = 0, syncroABS = 1, syncroREL = 2, syncroLOC = 3, syncroRatio = 4};

typedef enum {DCMViewTextAlignLeft, DCMViewTextAlignCenter, DCMViewTextAlignRight} DCMViewTextAlign;
/** Which of the view's fonts a string is drawn in. */
typedef enum {DCMViewMainFont, DCMViewLabelFont} DCMViewFontKind;

@class HorosAnnotationBox, HorosAnnotationText;
@class DCMPix;
@class DCMView;
@class ROI;
@class OrthogonalMPRController;
@class DICOMExport;
@class DicomImage, DicomSeries, DicomStudy;

// Implemented in Swift (DCMView+Capture.swift).
@class DCMExportPlugin;

// Defined in DCMView+CAPI.m. The views read and set them on the main thread.
/// The synchronization mode of the 2D viewers (syncroOFF, syncroABS, ...).
extern NS_SWIFT_UI_ACTOR short syncro;
extern NS_SWIFT_UI_ACTOR BOOL gDontListenToSyncMessage;
extern NS_SWIFT_UI_ACTOR BOOL OVERFLOWLINES;
extern NS_SWIFT_UI_ACTOR int MAXNUMBEROF32BITVIEWERS;

#ifdef __cplusplus
extern "C" {
#endif

/// The intersection of two planes, defined in DCMView+CAPI.m.
short intersect3D_2Planes(float *Pn1, float *Pv1, float *Pn2, float *Pv2, float *u, float *iP);

#ifdef __cplusplus
}
#endif

#ifndef __cplusplus
// For Swift and Objective-C only: VRView.mm defines a C++ function of the same
// name as intersect3D_SegmentPlane, which a C declaration would clash with.

/// Whether a segment crosses a rectangle, defined in DCMView+CAPI.m.
BOOL lineIntersectsRect(NSPoint lineStarts, NSPoint lineEnds, NSRect rect);

/// The intersection of a segment and a plane, defined in DCMView+CAPI.m.
int intersect3D_SegmentPlane(float *P0, float *P1, float *Pnormal, float *Ppoint, float *resultPt);
#endif

#endif
