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

// ViewerController of the legacy plugin SDK, kept by IsiXLegacyBridge: a 2D
// viewer of the application, as the plugin API gives it. Its images (pixList),
// their ROIs (roiList), the image and phase shown and the window level; the
// pixels and ROIs a plugin changes reach the viewer with needsDisplayUpdate,
// and at the end of each command; outside a command, a ROI the plugin adds to
// a list and announces with the "roiChange" notification, as the legacy
// application expected, reaches it on the next turn of the run loop. fileList
// gives the database's images (DicomImage) when the plugin declares
// database.read, and otherwise dictionaries with the slice, the phase and the
// SOP Instance UID. Its
// windows and its events are not part of it.

#import "IsiXLegacyBridgeDefines.h"
#import "DCMView.h"
#import "DCMPix.h"
#import "ROI.h"
#import "MyPoint.h"

#define MAX4D 500

ISIX_LEGACY_CLASS(ViewerController)
@interface IsiXLegacyViewerController : NSObject

/** The open 2D viewers, frontmost first. */
+ (NSMutableArray*) getDisplayed2DViewers;
+ (NSMutableArray*) get2DViewers;
+ (IsiXLegacyViewerController*) frontMostDisplayed2DViewer;

- (IsiXLegacyDCMView*) imageView;
/** The images of the phase shown, or of phase i. */
- (NSMutableArray*) pixList;
- (NSMutableArray*) pixList: (long) i;
/** One list of ROIs per image of the phase shown, or of phase i. */
- (NSMutableArray*) roiList;
- (NSMutableArray*) roiList: (long) i;
- (NSMutableArray*) fileList;
- (NSMutableArray*) fileList: (long) i;
/** Every image of the phase in one buffer, when they all have one size. */
- (float*) volumePtr;
- (float*) volumePtr: (long) i;

/** Gives the viewer the pixels and ROIs the plugin changed, and redraws it. */
- (void) needsDisplayUpdate;

- (short) maxMovieIndex;
- (short) curMovieIndex;
- (short) getNumberOfImages;
- (void) setImageIndex: (long) i;
/** Shows phase i of a 4D series. */
- (void) setMovieIndex: (short) i;
- (BOOL) isDataVolumic;

- (float) curWW;
- (float) curWL;
- (void) setWL: (float) wl WW: (float) ww;

/** No wait window is shown; these keep the legacy calls valid. */
- (id) startWaitWindow: (NSString*) message;
- (id) startWaitProgressWindow: (NSString*) message :(long) max;
- (void) waitIncrementBy: (id) waitWindow :(long) val;
- (void) endWaitWindow: (id) waitWindow;

- (IsiXLegacyMyPoint*) newPoint: (float) x :(float) y NS_RETURNS_NOT_RETAINED;
/** A ROI for the image shown, not yet in the viewer: add it to a list of roiList. */
- (IsiXLegacyROI*) newROI: (ToolMode) type NS_RETURNS_NOT_RETAINED;
- (void) selectROI: (IsiXLegacyROI*) roi deselectingOther: (BOOL) deselectOther;
- (void) deselectAllROIs;
- (void) deleteROI: (IsiXLegacyROI*) roi;
- (BOOL) containsROI: (IsiXLegacyROI*) roi;
- (NSMutableArray*) roisWithName: (NSString*) name;
- (void) deleteSeriesROIwithName: (NSString*) name;
- (void) renameSeriesROIwithName: (NSString*) oldName newName: (NSString*) newName;

/** A new viewer with these images, each a copy of an image of this viewer
    whose pixels the plugin computed (Float32, one sample per pixel). */
- (IsiXLegacyViewerController*) newWindow: (NSMutableArray*) pixList :(NSMutableArray*) fileList :(NSData*) volumeData NS_RETURNS_NOT_RETAINED;
/** The viewer's window while a command runs on it, to attach sheets to. */
- (NSWindow*) window;

/** Fusion is not part of the kit: no viewer is blended with this one. */
- (IsiXLegacyViewerController*) blendingController;
- (IsiXLegacyViewerController*) blendedWindow;

@end

@class IsiXLegacyDicomStudy, IsiXLegacyDicomSeries;

/// The study and series of the database a viewer shows, when the plugin
/// declares database.read; nil otherwise.
@interface IsiXLegacyViewerController (IsiXLegacyDatabase)
- (IsiXLegacyDicomStudy*) currentStudy;
- (IsiXLegacyDicomSeries*) currentSeries;
@end

/// The image shown written as a DICOM file of a derived series of its study,
/// one series per name: @{@"file": path}, for +[BrowserController addFiles:...].
/// Only the image in memory (screenCapture 0, allViewers NO); a capture of
/// the viewer as drawn gives nil. Needs database.read and database.import.
@interface IsiXLegacyViewerController (IsiXLegacyExport)
- (NSDictionary*) exportDICOMFileInt: (int) screenCapture withName: (NSString*) name allViewers: (BOOL) allViewers;
- (NSDictionary*) exportDICOMFileInt: (int) screenCapture withName: (NSString*) name;
/// Nothing to do: the application's viewer keeps its slider in step.
- (void) adjustSlider;
@end

@compatibility_alias ViewerController IsiXLegacyViewerController;
