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

#import "DCMPix.h"
#import "DCMPix+CAPI.h"
#import "AppController.h"
#import "ThickSlabController.h"
#import "BrowserController.h"
#import "DicomDatabase.h"

NSString * const DCMPixAnnotationPatientNamePrefix = @"\x1EPatientName\x1E";

NSString *HorosDCMPixLocalPathForBonjourImage(NSManagedObjectID *imageID)
{
    if( [NSThread isMainThread])
        return [[BrowserController currentBrowser] getLocalDCMPath: [[[BrowserController currentBrowser] database] objectWithID: imageID] :0];

    // On a private-queue context of the shared database, on its queue.
    DicomDatabase *database = [[[BrowserController currentBrowser] database] privateQueueIndependentDatabase];
    __block NSString *path = nil;
    [database performBlockAndWait:^{
        path = [[[BrowserController currentBrowser] getLocalDCMPath: [database objectWithID: imageID] :0] retain];
    }];
    return [path autorelease];
}

unsigned char *HorosDCMPixRenderThickSlab(ThickSlabController *slab, float *source, long count, float level, float width)
{
    [slab setImageSource: source :count];
    [slab setWLWW: level :width];
    return [slab renderSlab];
}

@implementation DCMPix (CAPI)

- (void) horos_fill12BitBufferFrom:(float*) source
{
#ifdef OSIRIX_VIEWER
    if( self.isLUT12Bit && [AppController canDisplay12Bit])
    {
        NSInvocation *fill12BitBufferInvocation = [AppController fill12BitBufferInvocation];
        DCMPix *pix = self;
        float *transferFunctionPtr = self.transferFunctionPtr;
        [fill12BitBufferInvocation setArgument: &pix atIndex: 2];
        NSValue *srcNSValue = [NSValue valueWithPointer: source];
        [fill12BitBufferInvocation setArgument: &srcNSValue atIndex: 3];
        [fill12BitBufferInvocation setArgument: &transferFunctionPtr atIndex: 4];
        [fill12BitBufferInvocation invoke];
    }
#endif
}

@end

// Swift's storage of these objects (DCMPix.swift).
@interface DCMPix (UnbridgedStorage)
- (NSArray*) horos_seriesList;
- (void) horos_setSeriesList:(NSArray*) list position:(NSInteger) position;
- (NSData*) horos_transferTable;
- (void) setHoros_transferTable:(NSData*) table;
@end

@implementation DCMPix (Unbridged)

- (NSData*) transferFunction
{
    return [self horos_transferTable];
}

- (void) setTransferFunction:(NSData*) table
{
    [self setHoros_transferTable: table];
}

- (NSArray*) pixArray
{
    return [self horos_seriesList];
}

- (void) setArrayPix:(NSArray*) array :(NSInteger) i
{
    [self horos_setSeriesList: array position: i];
}

@end
