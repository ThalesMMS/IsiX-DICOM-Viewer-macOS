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

// ROIVolumeManagerController is Swift. ROIVolume.h includes VTK's C++ headers
// and cannot reach Swift, nor can the Window3DController methods that take an
// ROIVolume. This Objective-C++ helper sends those messages as the former
// Objective-C did; its header is plain Objective-C.

#import <Cocoa/Cocoa.h>

@class Window3DController;

@interface ROIVolumeHostBridge : NSObject

// ROIVolume

/// [volume properties], the volume's mutable dictionary, typed so that Swift
/// does not bridge it to a copy.
+ (NSMutableDictionary *)propertiesOfVolume:(id)volume;
/// [volume setVisible:visible]
+ (void)setVisible:(BOOL)visible ofVolume:(id)volume;
/// [volume setRed:red]
+ (void)setRed:(float)red ofVolume:(id)volume;
/// [volume setGreen:green]
+ (void)setGreen:(float)green ofVolume:(id)volume;
/// [volume setBlue:blue]
+ (void)setBlue:(float)blue ofVolume:(id)volume;
/// [volume setOpacity:opacity]
+ (void)setOpacity:(float)opacity ofVolume:(id)volume;
/// [volume setTexture:texture]
+ (void)setTexture:(BOOL)texture ofVolume:(id)volume;

// Window3DController

/// [viewer displayROIVolume:volume]
+ (void)displayROIVolume:(id)volume inViewer:(Window3DController *)viewer;
/// [viewer hideROIVolume:volume]
+ (void)hideROIVolume:(id)volume inViewer:(Window3DController *)viewer;

@end
