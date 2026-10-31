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




#import <Cocoa/Cocoa.h>
#import <CoreData/CoreData.h>
#import "DCMPix.h"				// An object containing an image, including pixels values
#import "ViewerController.h"	// An object representing a 2D Viewer window
#import "DCMView.h"				// An object representing the 2D pane, contained in a 2D Viewer window
#import "MyPoint.h"				// An object representing a point
#import "ROI.h"					// An object representing a ROI


@class ViewerController;

/** \brief Base class for plugins

 The class is implemented in Swift: PluginFilter.swift is its implementation
 (@objc @implementation). This interface declares it to Objective-C, so that the
 runtime knows it as an Objective-C class and a plugin built for Horos or OsiriX,
 whose principal class is an Objective-C subclass, keeps +filter, -init and the
 methods it overrides, all sent as Objective-C messages. */
@interface PluginFilter : NSObject

/** Current (frontmost and active) 2D viewer containing an image serie, as
    -prepareFilter: was given it. */
@property (nonatomic, retain) ViewerController *viewerController;

/** [[self alloc] init]; -init calls -initPlugin. */
+ (PluginFilter *)filter NS_SWIFT_NAME(filter());

// FUNCTIONS TO SUBCLASS

/** This function is called to apply your plugin */
- (long) filterImage: (NSString*) menuName;

/** This function is the entry point of Pre-Process plugins */
- (long) processFiles: (NSMutableArray*) files;

/** This function is the entry point of Report plugins
* action = @"dateReport"	-> return NSDate date of creation or modification of the report, nil if no report available
* action = @"deleteReport"	-> return nil, delete the report
* action = @"openReport"   -> return nil, open and display the report, create a new one if no report available
*/
- (id) report: (NSManagedObject*) study action:(NSString*) action;

/** This function is called at startup, if you need to do some memory allocation, etc. */
- (void) initPlugin;

/** This function is called if the application needs to kill the current running plugin, to install an update, for example. */
- (void) willUnload;

/** This function is called if the application needs to display a warning to the user about a non-certified plugin. */
- (BOOL) isCertifiedForMedicalImaging;

/** Opportunity for plugins to make Menu changes if necessary */
- (void)setMenus;

// UTILITY FUNCTIONS

/** The 2D viewers open in the application, as ViewerController objects. */
- (NSArray*) viewerControllersList;

/** Create a new 2D window, containing a copy of the current series */
- (ViewerController*) duplicateCurrent2DViewerWindow NS_SWIFT_UI_ACTOR;

// Following stubs are to be subclassed by report filters.
/** Stub is to be subclassed by report filters */
- (id)reportDateForStudy: (NSManagedObject*)study;
/** Stub is to be subclassed by report filters */
- (BOOL)deleteReportForStudy: (NSManagedObject*)study;
/** Stub is to be subclassed by report filters */
- (BOOL)createReportForStudy: (NSManagedObject*)study;

/** PRIVATE FUNCTIONS - DON'T SUBCLASS OR MODIFY */
- (long) prepareFilter:(ViewerController*) vC NS_SWIFT_NAME(prepareFilter(_:));

@end

// The optional messages of a plugin's principal class: no class implements
// them, and the viewers, the browser and the web portal ask first whether a
// plugin answers them.

@class WebPortalConnection, WebPortalUser;

@protocol HorosPluginFilterMessages <NSObject>

@optional

/** Called to pass the plugin all sorts of events sent to a DCMView.  */

-(BOOL)handleEvent:(NSEvent*)event forViewer:(id)controller;
-(NSArray*)toolbarAllowedIdentifiersForViewer:(id)controller;
-(NSToolbarItem*)toolbarItemForItemIdentifier:(NSString*) identifier forViewer:(id)controller;

-(BOOL)handleEvent:(NSEvent*)event forVRViewer:(id)controller;
-(NSArray*)toolbarAllowedIdentifiersForVRViewer:(id)controller;
-(NSToolbarItem*)toolbarItemForItemIdentifier:(NSString*) identifier forVRViewer:(id)controller;

-(NSArray*)toolbarAllowedIdentifiersForBrowserController:(id)controller;
-(NSToolbarItem*)toolbarItemForItemIdentifier:(NSString*) identifier forBrowserController:(id)controller;

- (BOOL)isPasswordProtected:(NSString *)path forConnection:(WebPortalConnection *)wpc;
- (NSData *)httpResponseForPath:(NSString *)path forConnection:(WebPortalConnection *)wpc;
- (WebPortalUser *)authenticateConnection:(WebPortalConnection *)wpc parameters:(NSDictionary *)params;

@end
