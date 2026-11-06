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

/** \brief  SuperClass for 3D WindowControllers
*
* The class is implemented in Swift: Window3DController.swift is its
* implementation (@objc @implementation), with the window level presets in
* Window3DController+WindowLevel.swift, the colour and opacity tables in
* Window3DController+ColorTables.swift and its own full screen in
* Window3DController+FullScreen.swift. This interface declares it to
* Objective-C, which still subclasses it (VRController, SRController); it has
* no instance variables: the outlets and the state the subclasses share are
* properties.
*/


#import <Foundation/Foundation.h>
// ColorTransferView, OpacityTransferView and NSFullScreenWindow are Swift: their
// headers bring in Horos-Swift.h, which declares ROIVolumeController, a
// subclass of this class. They are imported after the interface,
// which the generated header needs complete.
@class ColorTransferView;
@class OpacityTransferView;
@class NSFullScreenWindow;
#import "OSIWindowController.h"


@class ROIVolume;
@class ViewerController;
@class DCMPix;



/** \brief Base Window Controller for 3D viewers */

@interface Window3DController : OSIWindowController <NSWindowDelegate>

// The outlets of the window level, colour table and opacity sheets that the
// subclasses fill themselves (VR.xib connects them). The window level sheet's
// own fields and the colour table editor are private to the class.
@property (nonatomic, retain) IBOutlet NSWindow *addWLWWWindow;
/// The name field of the new window level preset. Its getter is not -newName,
/// a name of the new family, which would hand its caller a retained field.
@property (nonatomic, retain, getter=horos_newName) IBOutlet NSTextField *newName;
@property (nonatomic, retain) IBOutlet NSTextField *wl;
@property (nonatomic, retain) IBOutlet NSTextField *ww;
@property (nonatomic, retain) IBOutlet NSTextField *clutName;
@property (nonatomic, retain) IBOutlet NSWindow *addOpacityWindow;
@property (nonatomic, retain) IBOutlet NSTextField *OpacityName;
@property (nonatomic, retain) IBOutlet OpacityTransferView *OpacityView;

/// The name of the current window level preset, the current colour table and
/// the current opacity table, as the menus show them. The subclasses store
/// them through these accessors, which no subclass overrides.
@property (nonatomic, copy) NSString *horos_curWLWWMenu;
@property (nonatomic, copy) NSString *horos_curCLUTMenu;
@property (nonatomic, copy) NSString *horos_curOpacityMenu;
/// Whether the content is in the class's own full screen window, and that window.
@property (nonatomic, readonly) BOOL horos_FullScreenOn;
@property (nonatomic, readonly) NSWindow *horos_FullScreenWindow;
/// Set by the subclasses' -windowWillClose:; -windowWillClose answers it.
@property (nonatomic) BOOL horos_windowWillClose;

- (BOOL) windowWillClose;
- (void) sendMailImage: (NSImage*) im;
- (ViewerController*) blendingController;
- (id) view;
- (ViewerController*) viewer;

- (long) movieFrames;
- (void) setMovieFrame: (long) l;

- (void) print:(id) sender;
- (BOOL)is4D;

/// The viewer's own list, the very object it keeps: -[AppController FindViewer::]
/// and -FindRelatedViewers: compare it by identity. A mutable array, as
/// OSIWindowController declares it, so that a Swift override returns the object
/// itself rather than a bridged copy.
- (NSMutableArray*) pixList;
- (NSArray*) fileList;

- (void) load3DState;

- (NSArray*) roiVolumes;
- (void) hideROIVolume: (id) v;
- (void) displayROIVolume: (id) v;

@end

/// The class's own full screen: the content view moved into a borderless window
/// that covers the main screen, and back.
@interface Window3DController (FullScreen)
- (void) offFullScreen;
- (IBAction) fullScreenMenu: (id) sender;
@end

/// The window level presets: the sheet that sets the level and width by hand
/// and the one that names a new preset (WLWW3 preference).
@interface Window3DController (WindowLevelPresets)
- (void) setWLWW: (float) wl : (float) ww;
- (void) getWLWW: (float*) wl : (float*) ww;
- (IBAction) endSetWLWW: (id) sender;
- (IBAction) SetWLWW: (id) sender;
- (IBAction) endNameWLWW: (id) sender;
- (IBAction) updateSetWLWW: (id) sender;
- (void) deleteWLWW: (NSWindow *) sheet returnCode: (int) returnCode contextInfo: (void*) contextInfo;
- (NSPopUpButton*) wlwwPopup;
@end

/// The colour tables (CLUT preference) and the opacity tables (OPACITY
/// preference), their menus and their editors.
@interface Window3DController (ColorTablePresets)
- (IBAction) AddCLUT: (id) sender;
- (IBAction) clutAction: (id) sender;
- (IBAction) endCLUT: (id) sender;
- (void) ApplyCLUT: (id) sender;
- (void) ApplyCLUTString: (NSString*) str;			// Overridden in children for now.
- (void) deleteCLUT: (NSWindow*) sheet returnCode: (int) returnCode contextInfo: (void*) contextInfo;
- (void) UpdateCLUTMenu: (NSNotification*) note;
- (void) CLUTChanged: (NSNotification*) note;
- (NSPopUpButton*) clutPopup;
- (void) ApplyOpacity: (id) sender;
- (IBAction) endOpacity: (id) sender;
- (void) deleteOpacity: (NSWindow*) sheet returnCode: (int) returnCode contextInfo: (void*) contextInfo;
- (NSPopUpButton*) OpacityPopup;
- (void) ApplyOpacityString: (NSString*) str;
@end



// VRController.h defines HOROS_WINDOW3D_DEFER_SWIFT_IMPORTS around its import of
// this header: a Swift class subclasses VRController too, and these
// headers must not bring in the generated interface before VRController's is
// complete. VRController.h imports them itself after its interface.
#ifndef HOROS_WINDOW3D_DEFER_SWIFT_IMPORTS
#import "ColorTransferView.h"
#import "OpacityTransferView.h"
#import "NSFullScreenWindow.h"
#endif
