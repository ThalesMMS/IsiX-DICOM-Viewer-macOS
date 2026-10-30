/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

// What DCMPix keeps in Objective-C: the names it exports to C, the 12-bit
// fill (AppController hands out an NSInvocation, which Swift cannot call), the
// ThickSlabController's rendering (the main actor's class in Swift; the slab
// has always been asked for from wherever the picture is made) and the path of
// an image of the Bonjour shared database. DCMPix itself is implemented in
// Swift (DCMPix.swift).

#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class DCMPix;
@class ThickSlabController;

NS_ASSUME_NONNULL_BEGIN

/// The local file of an image of the Bonjour shared database, copied here, or nil.
FOUNDATION_EXPORT NSString * _Nullable HorosDCMPixLocalPathForBonjourImage(NSManagedObjectID * _Nullable imageID);

/// The volume rendering of `count` images from `source` through the window, by
/// the controller: its RGBA picture.
FOUNDATION_EXPORT unsigned char * _Nullable HorosDCMPixRenderThickSlab(ThickSlabController * _Nullable slab, float * _Nullable source,
                                                                     long count, float level, float width);

@interface DCMPix (CAPI)

/// The 12-bit display's picture of `source`, when this image has one and the
/// display can show it.
- (void) horos_fill12BitBufferFrom:(float * _Nullable) source;

@end

NS_ASSUME_NONNULL_END
