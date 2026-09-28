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

// The C part of OSIROIMask, which is implemented in Swift since #719
// (Horos/Sources/OSIROIMask.swift): the exported constant, the C functions and
// the NSValue category (it boxes the structs with @encode) do not migrate.

#import "OSIROIMask.h"

__attribute__((used)) const OSIROIMaskRun OSIROIMaskRunZero = {{0.0, 0.0}, 0, 0, 1.0};

NSComparisonResult OSIROIMaskCompareRunValues(NSValue *maskRun1Value, NSValue *maskRun2Value, void *context)
{
    OSIROIMaskRun maskRun1 = [maskRun1Value OSIROIMaskRunValue];
    OSIROIMaskRun maskRun2 = [maskRun2Value OSIROIMaskRunValue];

    return OSIROIMaskCompareRun(maskRun1, maskRun2);
}


NSComparisonResult OSIROIMaskCompareRun(OSIROIMaskRun maskRun1, OSIROIMaskRun maskRun2)
{
    if (maskRun1.depthIndex < maskRun2.depthIndex) {
        return NSOrderedAscending;
    } else if (maskRun1.depthIndex > maskRun2.depthIndex) {
        return NSOrderedDescending;
    }

    if (maskRun1.heightIndex < maskRun2.heightIndex) {
        return NSOrderedAscending;
    } else if (maskRun1.heightIndex > maskRun2.heightIndex) {
        return NSOrderedDescending;
    }

    if (maskRun1.widthRange.location < maskRun2.widthRange.location) {
        return NSOrderedAscending;
    } else if (maskRun1.widthRange.location > maskRun2.widthRange.location) {
        return NSOrderedDescending;
    }

    return NSOrderedSame;
}

int OSIROIMaskQSortCompareRun(const void *voidMaskRun1, const void *voidMaskRun2)
{
    const OSIROIMaskRun* maskRun1 = voidMaskRun1;
    const OSIROIMaskRun* maskRun2 = voidMaskRun2;

    if (maskRun1->depthIndex < maskRun2->depthIndex) {
        return NSOrderedAscending;
    } else if (maskRun1->depthIndex > maskRun2->depthIndex) {
        return NSOrderedDescending;
    }

    if (maskRun1->heightIndex < maskRun2->heightIndex) {
        return NSOrderedAscending;
    } else if (maskRun1->heightIndex > maskRun2->heightIndex) {
        return NSOrderedDescending;
    }

    if (maskRun1->widthRange.location < maskRun2->widthRange.location) {
        return NSOrderedAscending;
    } else if (maskRun1->widthRange.location > maskRun2->widthRange.location) {
        return NSOrderedDescending;
    }

    return NSOrderedSame;

}

BOOL OSIROIMaskRunsOverlap(OSIROIMaskRun maskRun1, OSIROIMaskRun maskRun2)
{
    if (maskRun1.depthIndex == maskRun2.depthIndex && maskRun1.heightIndex == maskRun2.heightIndex) {
        return NSIntersectionRange(maskRun1.widthRange, maskRun2.widthRange).length != 0;
    }

    return NO;
}

BOOL OSIROIMaskRunsAbut(OSIROIMaskRun maskRun1, OSIROIMaskRun maskRun2)
{
    if (maskRun1.depthIndex == maskRun2.depthIndex && maskRun1.heightIndex == maskRun2.heightIndex) {
        if (NSMaxRange(maskRun1.widthRange) == maskRun2.widthRange.location ||
            NSMaxRange(maskRun2.widthRange) == maskRun1.widthRange.location) {
            return YES;
        }
    }
    return NO;
}

BOOL OSIROIMaskIndexInRun(OSIROIMaskIndex maskIndex, OSIROIMaskRun maskRun)
{
	if (maskIndex.y != maskRun.heightIndex || maskIndex.z != maskRun.depthIndex) {
		return NO;
	}
	if (NSLocationInRange(maskIndex.x, maskRun.widthRange)) {
		return YES;
	} else {
		return NO;
	}
}

NSArray *OSIROIMaskIndexesInRun(OSIROIMaskRun maskRun)
{
	NSMutableArray *indexes;
	NSUInteger i;
	OSIROIMaskIndex index;

	indexes = [NSMutableArray array];
	index.y = maskRun.heightIndex;
	index.z = maskRun.depthIndex;

	for (i = maskRun.widthRange.location; i < NSMaxRange(maskRun.widthRange); i++) {
		index.x = i;
		[indexes addObject:[NSValue valueWithOSIROIMaskIndex:index]];
	}
	return indexes;
}

@implementation NSValue (OSIMaskRun)

+ (NSValue *)valueWithOSIROIMaskRun:(OSIROIMaskRun)volumeRun
{
	return [NSValue valueWithBytes:&volumeRun objCType:@encode(OSIROIMaskRun)];
}

- (OSIROIMaskRun)OSIROIMaskRunValue
{
	OSIROIMaskRun run;
    assert(strcmp([self objCType], @encode(OSIROIMaskRun)) == 0);
    [self getValue:&run];
    return run;
}

+ (NSValue *)valueWithOSIROIMaskIndex:(OSIROIMaskIndex)maskIndex
{
	return [NSValue valueWithBytes:&maskIndex objCType:@encode(OSIROIMaskIndex)];
}

- (OSIROIMaskIndex)OSIROIMaskIndexValue
{
	OSIROIMaskIndex index;
    assert(strcmp([self objCType], @encode(OSIROIMaskIndex)) == 0);
    [self getValue:&index];
    return index;
}

@end
