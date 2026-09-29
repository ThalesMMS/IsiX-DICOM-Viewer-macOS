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
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

// What OSIVolumeWindow.swift cannot declare: the exported notification names,
// the variadic -floatVolumeDataForDimensionsAndIndexes:, and the -init that
// refuses to make a volume window without a viewer (a Swift initializer cannot
// return nil after the object exists).

#import "OSIVolumeWindow.h"
#import "OSIFloatVolumeData.h"

__attribute__((used)) NSString* const OSIVolumeWindowDidCloseNotification = @"OSIVolumeWindowDidCloseNotification";

__attribute__((used)) NSString* const OSIVolumeWindowWillChangeDataNotification = @"OSIVolumeWindowWillChangeDataNotification";
__attribute__((used)) NSString* const OSIVolumeWindowDidChangeDataNotification = @"OSIVolumeWindowDidChangeDataNotification";

@implementation OSIVolumeWindow (HorosVariadic)

// don't call this!
// The generated interface marks -init unavailable, since the Swift class
// declares only -initWithViewerController:; this one replaces the stub Swift
// emits, which would trap.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
- (id)init
{
	assert(0);
	[self autorelease];
	self = nil;
	return self;
}
#pragma clang diagnostic pop

- (OSIFloatVolumeData *)floatVolumeDataForDimensionsAndIndexes:(NSString *)firstDimenstion, ...
{
	NSMutableArray *dimensions;
	NSMutableArray *indexes;
	id dimension;
	id index;
	
	if (firstDimenstion) {
		dimensions = [NSMutableArray array];
		indexes = [NSMutableArray array];
		
		va_list args;
		va_start(args, firstDimenstion);
		dimension = firstDimenstion;
		index = va_arg(args, id);
		assert([dimension isKindOfClass:[NSString class]]);
		assert(index);
		assert([index isKindOfClass:[NSNumber class]]);
		
		[dimensions addObject:dimension];
		[indexes addObject:index];
		while ( (dimension = va_arg(args, id)) ) {
			index = va_arg(args, id);
			assert([dimension isKindOfClass:[NSString class]]);
			assert(index);
			assert([index isKindOfClass:[NSNumber class]]);
			
			[dimensions addObject:dimension];
			[indexes addObject:index];
		}
		va_end(args);
		
		return [self floatVolumeDataForDimensions:dimensions indexes:indexes];
	} else {
        assert(0);
		return nil;
	}
}

@end
