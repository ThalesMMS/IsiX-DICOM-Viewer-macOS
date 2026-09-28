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

// ThickSlabController is Swift. ThickSlabVR.h includes VTK's C++ headers and
// cannot reach Swift: this Objective-C++ helper forwards to the view as the
// former Objective-C did; its header is plain Objective-C.

#import <Cocoa/Cocoa.h>

@interface ThickSlabHostBridge : NSObject

+ (void)setImageData:(long)w :(long)h :(long)c :(float)sX :(float)sY :(float)t :(BOOL)flip ofView:(id)view;
+ (unsigned char *)renderSlabOfView:(id)view;
+ (void)setWLWW:(float)l :(float)w ofView:(id)view;
+ (void)setBlendingWLWW:(float)l :(float)w ofView:(id)view;
+ (void)setImageSource:(float *)i :(long)c ofView:(id)view;
+ (void)setFlip:(BOOL)f ofView:(id)view;
+ (void)setCLUT:(unsigned char *)r :(unsigned char *)g :(unsigned char *)b ofView:(id)view;
+ (void)setBlendingCLUT:(unsigned char *)r :(unsigned char *)g :(unsigned char *)b ofView:(id)view;
+ (void)setLowQuality:(BOOL)q ofView:(id)view;
+ (void)setOpacity:(NSArray *)array ofView:(id)view;
+ (void)setImageBlendingSource:(float *)i ofView:(id)view;
+ (NSData *)compositeTablesOfView:(id)view;
+ (BOOL)flipOfView:(id)view;

@end
