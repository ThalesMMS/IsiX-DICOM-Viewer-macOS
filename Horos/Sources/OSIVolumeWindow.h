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

// OSIVolumeWindow, the plugin SDK's peer of a ViewerController, is implemented
// in Swift since #828 (Horos/Sources/OSIVolumeWindow.swift). This header keeps
// <Horos/OSIVolumeWindow.h>: it brings in the generated interface, which
// declares the same class name and selectors. Each instance is paired with a
// ViewerController, and provides a simplified interface to common tasks that
// are inherently difficult to do directly with a ViewerController.
// OSIVolumeWindow+Private.h keeps declaring the application's own methods.

#import <Cocoa/Cocoa.h>

@class OSIFloatVolumeData;

// -floatVolumeDataForDimensionsAndIndexes:, which Swift cannot implement: a
// variadic method. OSIVolumeWindow+CAPI.m implements it in a category. The
// class adopts this protocol, so that the method is declared wherever the
// generated interface is, even where this header was first read through the
// bridging header, and a caller passes its arguments as variadic ones.
@protocol OSIVolumeWindowVariadic <NSObject>
@optional

/** Returns the Volume Data for the given dimension coordinates, as
 floatVolumeDataForDimensions:indexes: does.

 @warning *Important:*  OsiriX allocates and deallocates memory at sometimes seemingly odd times, if the OSIFloatVolumeData all of a sudden is invalid, call this function again to try to get a new one

 @return The Volume Data for the dimension coordinates.
 @param firstDimension The first dimension name.
 @param ... First the index in the firstDimension as an NSNumber object, then a null-terminated list of alternating dimension names and indexes.
 */
- (OSIFloatVolumeData *)floatVolumeDataForDimensionsAndIndexes:(NSString *)firstDimension, ... NS_REQUIRES_NIL_TERMINATION;

@end

#import "OSIROIManager.h"

extern NSString* const OSIVolumeWindowDidCloseNotification;

extern NSString* const OSIVolumeWindowWillChangeDataNotification;
extern NSString* const OSIVolumeWindowDidChangeDataNotification;

@class OSIFloatVolumeData;
@class OSIROIManager;
@class ViewerController;

#ifdef HOROS_BRIDGING_HEADER
// Swift is compiling the class itself: headers it imports may only name it.
@class OSIVolumeWindow;
#else
#import "Horos-Swift.h"

// The same declaration, as a category of the class.
@interface OSIVolumeWindow (HorosVariadic)
- (OSIFloatVolumeData *)floatVolumeDataForDimensionsAndIndexes:(NSString *)firstDimension, ... NS_REQUIRES_NIL_TERMINATION;
@end
#endif
