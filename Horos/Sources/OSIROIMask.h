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

// OSIROIMask is implemented in Swift (Horos/Sources/OSIROIMask.swift).
// This header keeps <Horos/OSIROIMask.h>: it brings in the generated interface,
// which declares the same class name and selectors. The structs, the C functions,
// OSIROIMaskRunZero and the NSValue category below stay in Objective-C, in
// OSIROIMask+CAPI.m.

#import <Cocoa/Cocoa.h>
#import "N3Geometry.h"

@class OSIFloatVolumeData;

/** A structure used to describe a single run length of a mask.
 
 */

struct OSIROIMaskRun {
	NSRange widthRange;
    NSUInteger heightIndex;
    NSUInteger depthIndex;
    float intensity;
};
typedef struct OSIROIMaskRun OSIROIMaskRun;

extern const OSIROIMaskRun OSIROIMaskRunZero;

/** A structure used to describe a single point in a mask.
 
 */

struct OSIROIMaskIndex {
	NSUInteger x;
	NSUInteger y;
	NSUInteger z;
};
typedef struct OSIROIMaskIndex OSIROIMaskIndex;

CF_EXTERN_C_BEGIN

/** Returns YES if the `maskIndex` is withing the `maskRun`
 
 */
BOOL OSIROIMaskIndexInRun(OSIROIMaskIndex maskIndex, OSIROIMaskRun maskRun);
/** Returns an array of all the OSIROIMaskIndex structs in the `maskRun`.
 
 */
NSArray *OSIROIMaskIndexesInRun(OSIROIMaskRun maskRun); // should this be a function, or a class method on OSIROIMask?

/** Returns NSOrderedAscending if `maskRun2` is larger than `maskRun1`.
 
 */
NSComparisonResult OSIROIMaskCompareRunValues(NSValue *maskRun1, NSValue *maskRun2, void *context);

/** Returns a value larger than 0 if `maskRun2` is larger than `maskRun1`.
 
 */
NSComparisonResult OSIROIMaskCompareRun(OSIROIMaskRun maskRun1, OSIROIMaskRun maskRun2);

/** Returns YES if the two mask runs overlap, NO otherwise.
 
 */
BOOL OSIROIMaskRunsOverlap(OSIROIMaskRun maskRun1, OSIROIMaskRun maskRun2);

/** Returns YES if the two mask runs abut, NO otherwise.
 
 */
BOOL OSIROIMaskRunsAbut(OSIROIMaskRun maskRun1, OSIROIMaskRun maskRun2);


CF_EXTERN_C_END

/** NSValue methods to handle Mask types.
 
 */


@interface NSValue (OSIROIMaskRun)

///-----------------------------------
/// @name OSIROIMaskRun methods
///-----------------------------------

/** Creates and returns an NSValue object that contains a given OSIROIMaskRun structure.
 
 @return A new NSValue object that contains the value of volumeRun.
 @param volumeRun The value for the new object.
 */
+ (NSValue *)valueWithOSIROIMaskRun:(OSIROIMaskRun)volumeRun;

/** Returns an OSIROIMaskRun structure representation of the receiver.
 
 @return An OSIROIMaskRun structure representation of the receiver.
 */
- (OSIROIMaskRun)OSIROIMaskRunValue;

/** Creates and returns an NSValue object that contains a given OSIROIMaskIndex structure.
 
 @return A new NSValue object that contains the value of maskIndex.
 @param maskIndex The value for the new object.
 */
+ (NSValue *)valueWithOSIROIMaskIndex:(OSIROIMaskIndex)maskIndex;

/** Returns an OSIROIMaskIndex structure representation of the receiver.
 
 @return An OSIROIMaskIndex structure representation of the receiver.
 */
- (OSIROIMaskIndex)OSIROIMaskIndexValue;
@end

#ifdef HOROS_BRIDGING_HEADER
// Swift is compiling the class itself: headers it imports may only name it.
@class OSIROIMask;
#else
#import "Horos-Swift.h"
#endif
