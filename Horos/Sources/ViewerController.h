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

// ViewerController is implemented in Swift (ViewerController.swift and the
// ViewerController+*.swift files). This header keeps <Horos/ViewerController.h>:
// what goes with the class (constants, the global flags, the plugin drag
// destination) and, outside Swift, the generated interface of the class,
// which declares the same class name and selectors, and the categories still
// written in Objective-C. Its superclass, OSIWindowController, stays in
// Objective-C.

#define MAX4D 500

@class HorosFormView;

#import <Cocoa/Cocoa.h>
#import <AppKit/AppKit.h>

#import "DCMView.h" // added for ToolMode enum
#import "OSIWindowController.h"

// Plugins may build against an SDK that predates this macro.
#ifndef NS_SWIFT_NONISOLATED
#define NS_SWIFT_NONISOLATED
#endif

@class DCMView;
@class HorosMPROpenDecision;
@class OpacityTransferView;
@class ColorTransferView;
@class MyPoint;
@class ROI;
@class HorosVolumeLengthROI;
@class DCMPix;
@class ThickSlabController;
@class StudyView;
@class SeriesView;
@class ImageView;
@class DICOMExport;
@class KeyObjectPopupController;
@class VRController;
@class OrthogonalMPRViewer;
@class OrthogonalMPRPETCTViewer;
@class SRController;
@class EndoscopyViewer;
@class MPRController;
@class CPRController;
@class ViewerController;
@class ToolbarPanelController;

#define ToolsMenuIconSize NSMakeSize(28.0, 28.0)

@interface NSObject(AppPluginDraggingDestination)
- (BOOL)performPluginDragOperation:(id <NSDraggingInfo>)sender destination:(ViewerController*)vc;
@end

#ifndef NS_SWIFT_UI_ACTOR
#define NS_SWIFT_UI_ACTOR
#endif
// Set and read by the viewers, on the main thread.
extern NS_SWIFT_UI_ACTOR BOOL SyncButtonBehaviorIsBetweenStudies;

enum
{
	eSagittalPos = 0,		// 0
	eSagittalNeg,			// 1
	eCoronalPos,			// 2
	eCoronalNeg,			// 3
	eAxialPos,				// 4
	eAxialNeg				// 5
};


#if defined(HOROS_BRIDGING_HEADER)
// Swift is compiling the class itself, or the generated interface is being
// read: the headers it imports may only name the class.
#elif defined(HOROS_DEFER_SWIFT_INTERFACE)
// VRController.h imports this header before its own interface and
// Horos-Swift.h after it: the generated interface declares a Swift subclass
// of VRController, which needs that interface complete.
#else
#if __has_include("Horos-Swift.h")
#import "Horos-Swift.h"
#endif

// What stays in Objective-C: ViewerController+CAPI.h.
#import "ViewerController+CAPI.h"

// The blocks of methods implemented in Swift.
#import "ViewerController+Toolbar.h"
#import "ViewerController+RetrieveAndView.h"
#import "ViewerController+Convolution.h"
#import "ViewerController+Blending.h"
#import "ViewerController+ImagePipeline.h"
#import "ViewerController+Navigation.h"
#import "ViewerController+Reconstruction.h"
#import "ViewerController+KeyImages.h"
#import "ViewerController+Windows.h"
#import "ViewerController+Menus.h"
#import "ViewerController+ROI.h"
#import "ViewerController+Export.h"
#import "ViewerController+SeriesOperations.h"
#import "ViewerController+ROITools.h"
#import "ViewerController+SeriesList.h"
#endif
