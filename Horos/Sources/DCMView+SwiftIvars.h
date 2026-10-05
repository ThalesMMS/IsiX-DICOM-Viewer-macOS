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

// What the Swift subclasses of DCMView (MPRDCMView, OrthogonalMPRView and its subclasses,
// the CPR views) read and write of the class that stays
// Objective-C. Swift cannot see instance variables, so the ones the former
// Objective-C subclasses used directly are reached through these accessors,
// implemented in DCMView+SwiftIvars.m. A write through one of them is a write
// of the ivar, as before: it does not run the property's setter
// (-setRotation:, -setScaleValue:, -setCurrentTool: have side effects).
// This header is for the bridging header only: it is not part of the SDK.

#import "DCMView.h"

@interface DCMView (SwiftIvars)

/// rotation, written without -setRotation:.
@property float horos_rotation;
/// scaleValue, written without -setScaleValue:.
@property float horos_scaleValue;
/// currentTool, written without -setCurrentTool:.
@property ToolMode horos_currentTool;
/// drawingROI.
@property BOOL horos_drawingROI;
/// scrollMode, of the image scroll drag.
@property long horos_scrollMode;
/// start and previous, the drag's first and last points.
@property NSPoint horos_start;
@property NSPoint horos_previous;
/// blendingFactor, written without -setBlendingFactor: (the PET-CT view sends
/// that one to its controller).
@property float horos_blendingFactor;
/// blendingFactorStart, the factor when the blending drag began (the
/// orthogonal MPR views).
@property float horos_blendingFactorStart;
/// annotationType, written without -setAnnotationType: (CPRTransverseView).
@property int horos_annotationType;
/// cursor, which the property only reads; the setter retains the new cursor
/// and releases the old one, as the views did (the CPR views; the endoscopy
/// MPR view sets the rotate-axis cursor over its focal handle).
@property(retain) NSCursor *horos_cursor;

/// The other ivars the Swift blocks of DCMView.m (#834) read and write: a
/// write is a write of the ivar, without retaining or releasing an object; an
/// array ivar is reached through a pointer to its first element.
/// blendingView, which Swift names horos_blending.
@property(nonatomic, assign) DCMView *horos_blendingView;
@property BOOL horos_flippedData;
@property int horos_volumicData;
@property BOOL horos_volumicSeries;
@property BOOL horos_mouseDraggedForROIUndo;
@property BOOL horos_colorTransfer;
@property unsigned char * horos_colorBuf;
@property(readonly) unsigned char *horos_redTable;
@property(readonly) unsigned char *horos_greenTable;
@property(readonly) unsigned char *horos_blueTable;
@property(readonly) float *horos_sliceFromTo;
@property(readonly) float *horos_sliceFromToS;
@property(readonly) float *horos_sliceFromToE;
@property(readonly) float *horos_sliceFromTo2;
@property float horos_sliceFromToThickness;
@property(readonly) float *horos_sliceVector;
@property(readonly) float *horos_slicePoint3D;
@property float horos_syncRelativeDiff;
@property long horos_syncSeriesIndex;
@property short horos_thickSlabMode;
@property short horos_thickSlabStacks;
@property(nonatomic, assign) NSMutableArray *horos_dcmPixList;
@property(nonatomic, assign) NSArray *horos_dcmFilesList;
@property(nonatomic, assign) NSMutableArray *horos_dcmRoiList;
@property(nonatomic, assign) NSMutableArray *horos_curRoiList;
@property char horos_listType;
@property short horos_curImage;
@property short horos_startImage;
@property ToolMode horos_currentMouseEventTool;
@property BOOL horos_mouseDragging;
@property NSPoint horos_originStart;
@property float horos_startWW;
@property float horos_curWW;
@property float horos_startMin;
@property float horos_startMax;
@property float horos_startWL;
@property float horos_curWL;
@property float horos_bdstartWW;
@property float horos_bdstartMin;
@property float horos_bdstartMax;
@property float horos_bdstartWL;
@property BOOL horos_curWLWWSUVConverted;
@property float horos_curWLWWSUVFactor;
@property double horos_resizeTotal;
@property float horos_startScaleValue;
@property float horos_rotationStart;
@property NSPoint horos_origin;
@property short horos_crossMove;
@property(nonatomic, assign) NSMatrix *horos_matrix;
@property BOOL horos_xFlipped;
@property BOOL horos_yFlipped;
@property NSSize horos_stringSize;
@property(nonatomic, assign) NSString *horos_stringID;
@property float horos_mouseXPos;
@property float horos_mouseYPos;
@property float horos_pixelMouseValue;
@property long horos_pixelMouseValueR;
@property long horos_pixelMouseValueG;
@property long horos_pixelMouseValueB;
@property float horos_blendingMouseXPos;
@property float horos_blendingMouseYPos;
@property float horos_blendingPixelMouseValue;
@property long horos_blendingPixelMouseValueR;
@property long horos_blendingPixelMouseValueG;
@property long horos_blendingPixelMouseValueB;
@property BOOL horos_isKeyView;
@property BOOL horos__dragInProgress;
@property(nonatomic, assign) NSTimer *horos__mouseDownTimer;
@property BOOL horos__hasChanged;
@property int horos_repulsorRadius;
@property NSPoint horos_repulsorPosition;
@property(nonatomic, assign) NSEvent *horos_lengthClickEvent;
@property BOOL horos_replayingLengthDrag;
@property NSPoint horos_ROISelectorStartPoint;
@property NSPoint horos_ROISelectorEndPoint;
@property(nonatomic, assign) NSMutableArray *horos_ROISelectorSelectedROIList;
@property BOOL horos_syncOnLocationImpossible;
@property int horos_resampledBaseAddrSize;
@property NSRect horos_drawingFrameRect;
@property NSRect horos_screenCaptureRect;
@property BOOL horos_exceptionDisplayed;
@property BOOL horos_COPYSETTINGSINSERIES;
@property int horos_avoidRecursiveSync;
@property BOOL horos_avoidChangeWLWWRecursive;
@property float horos_studyColorR;
@property float horos_studyColorG;
@property float horos_studyColorB;
@property NSUInteger horos_studyDateIndex;
@property(nonatomic, assign) HorosAnnotationBox *horos_studyDateBox;
@property(nonatomic, assign) NSArray *horos_cleanedOutDcmPixArray;

@end

/// The file-scope statics and globals of DCMView.m that the Swift blocks (#834)
/// use, implemented in DCMView.m, where they are visible.
@interface DCMView (SwiftStatics)
@property(class, readonly) double horos_static_deg2rad;
@property(class) unsigned char *horos_static_PETredTable;
@property(class) unsigned char *horos_static_PETgreenTable;
@property(class) unsigned char *horos_static_PETblueTable;
@property(class) BOOL horos_static_avoidSetWLWWRentry;
@property(class, nonatomic, assign) NSDictionary *horos_static__hotKeyDictionary;
@property(class, nonatomic, assign) NSDictionary *horos_static__hotKeyModifiersDictionary;
@property(class, nonatomic, assign) NSRecursiveLock *horos_static_drawLock;
@property(class) short horos_static_syncro;
@property(class) BOOL horos_static_gDontListenToSyncMessage;
@end

/// Methods DCMView.m implements without declaring them in DCMView.h, which the
/// Swift blocks (#834) send.
@interface DCMView (SwiftPrivateMethods)
- (BOOL) eventToPlugins: (NSEvent*) event;
- (void) reapplyWindowLevel;
- (BOOL) isKeyImage;
- (void) horosDrawAnnotationBox:(HorosAnnotationBox*) box bounds:(NSRect) r;
- (BOOL) shouldIgnoreHiddenCursorEvent:(NSEvent*) event;
- (BOOL) horosShiftLensWantedWithFlags:(NSEventModifierFlags) flags;
-(void) mouseMovedInView: (NSPoint) eventLocationInWindow;
@end

#ifdef __cplusplus
extern "C" {
#endif

/// The intersection of two planes, defined in DCMView.m.
short intersect3D_2Planes(float *Pn1, float *Pv1, float *Pn2, float *Pv2, float *u, float *iP);

/// Set by the MPR and CPR views before a VRView render, reset by the VRView;
/// defined in MPRDCMView+CAPI.m.
extern NS_SWIFT_UI_ACTOR unsigned int minimumStep;

/// arePlanesParallel() of MPRDCMView+CAPI.m, which stays exported under its
/// own name. The MPR and CPR views call it through this wrapper, declared when
/// CPRMPRDCMView.m still had a static function of the same name.
BOOL HorosMPRArePlanesParallel(float *Pn1, float *Pn2);

/// Whether a CPR view fills the window, and the split positions it restores;
/// shared by the four CPR views, defined in CPRMPRDCMView+CAPI.m.
/// Main thread only.
extern NS_SWIFT_UI_ACTOR BOOL frameZoomed;
extern NS_SWIFT_UI_ACTOR int splitPosition[3];

#ifdef __cplusplus
}
#endif

#ifndef __cplusplus
// For Swift and Objective-C only: VRView.mm defines a C++ function of the same
// name as intersect3D_SegmentPlane, which a C declaration would clash with.

/// Whether a segment crosses a rectangle, defined in DCMView.m.
BOOL lineIntersectsRect(NSPoint lineStarts, NSPoint lineEnds, NSRect rect);

/// The intersection of a segment and a plane, defined in DCMView.m.
int intersect3D_SegmentPlane(float *P0, float *P1, float *Pnormal, float *Ppoint, float *resultPt);
#endif

