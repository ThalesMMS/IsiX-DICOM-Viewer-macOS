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

NS_ASSUME_NONNULL_BEGIN

/// The messages CLUTOpacityView (Swift) sends to its VRView outlet and to the
/// outlet's VRController. VRView.h and VRController.h are C++, which Swift
/// cannot import, so these are sent from Objective-C++. A nil view is a no-op,
/// as messaging nil was.
@interface CLUTOpacityViewVRBridge : NSObject

/// -[VRView setAdvancedCLUT:lowResolution:]
+ (void)setAdvancedCLUT:(NSMutableDictionary *)clut lowResolution:(BOOL)lowRes ofVRView:(nullable NSView *)vrView;
/// -[VRView getWLWW::]
+ (void)getWL:(float *)wl ww:(float *)ww ofVRView:(nullable NSView *)vrView;
/// -[VRView setWLWW::]
+ (void)setWL:(float)wl ww:(float)ww ofVRView:(nullable NSView *)vrView;
/// -[VRView squareView:]
+ (void)squareVRView:(nullable NSView *)vrView sender:(nullable id)sender;
/// -[[VRView controller] setCurCLUTMenu:]
+ (void)setCurCLUTMenu:(nullable NSString *)name ofVRView:(nullable NSView *)vrView;
/// -[[[VRView controller] clutOpacityDrawer] close]
+ (void)closeCLUTOpacityDrawerOfVRView:(nullable NSView *)vrView;

@end

NS_ASSUME_NONNULL_END
