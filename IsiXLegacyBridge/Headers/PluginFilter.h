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

// PluginFilter of the legacy plugin SDK, kept by IsiXLegacyBridge: the base class
// of a legacy plugin. Each menu title of the plugin becomes a command of the
// IsiX plugin API in the menu of its type (imageFilter and fusionFilter: the
// viewer's image filters; roiTool: the ROI tools; Database: the database
// window; other: the plugins menu); running it sets viewerController to the
// frontmost viewer and calls -filterImage: with the title. A result other than
// 0 is shown to the user as an error.

#import "IsiXLegacyBridgeDefines.h"
#import "DCMPix.h"
#import "ViewerController.h"
#import "DCMView.h"
#import "MyPoint.h"
#import "ROI.h"

ISIX_LEGACY_CLASS(PluginFilter)
@interface IsiXLegacyPluginFilter : NSObject
{
    IsiXLegacyViewerController* viewerController;   // Current (frontmost and active) 2D viewer containing an image serie
}

+ (IsiXLegacyPluginFilter *) filter;

// FUNCTIONS TO SUBCLASS

/** This function is called to apply your plugin */
- (long) filterImage: (NSString*) menuName;
/** This function is called once, when IsiX loads the plugin. */
- (void) initPlugin;
/** This function is called before IsiX quits. */
- (void) willUnload;
- (BOOL) isCertifiedForMedicalImaging;
/** Called once after initPlugin; the menus are made from the menu titles. */
- (void) setMenus;

// UTILITY FUNCTIONS

/** The open 2D viewers, as ViewerController objects. */
- (NSArray*) viewerControllersList;
/** A new 2D viewer with a copy of the current series (grayscale images). */
- (IsiXLegacyViewerController*) duplicateCurrent2DViewerWindow;

/** Sets viewerController; returns 0. */
- (long) prepareFilter: (IsiXLegacyViewerController*) vC;

@end

/** What a subclass may answer, as the legacy application asked it. */
@interface IsiXLegacyPluginFilter (IsiXLegacyEventHandling)

/** A mouse event (left button down, dragged, up) or a key of a viewer's image,
    before the viewer acts on it; return YES and the viewer does nothing else
    with it. Not implemented by PluginFilter: only a subclass that answers it
    is asked. */
- (BOOL) handleEvent: (NSEvent*) event forViewer: (IsiXLegacyViewerController*) controller;

@end

@compatibility_alias PluginFilter IsiXLegacyPluginFilter;
