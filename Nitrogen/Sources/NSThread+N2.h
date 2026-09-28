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

// NSThread (N2) is implemented in Swift since #710
// (Nitrogen/Sources/NSThread+N2.swift). This header keeps <Horos/NSThread+N2.h>:
// it declares the NSThread*Key constants, defined in NSThread+N2+CAPI.m, and
// brings in the generated interface, whose Swift extension declares the same
// selectors.

#import <Cocoa/Cocoa.h>

extern NSString* const NSThreadNameKey;
extern NSString* const NSThreadUniqueIdKey;
extern NSString* const NSThreadIsCancelledKey;
extern NSString* const NSThreadSupportsCancelKey;
extern NSString* const NSThreadSupportsBackgroundingKey;
extern NSString* const NSThreadStatusKey;
extern NSString* const NSThreadProgressKey;
extern NSString* const NSThreadProgressDetailsKey;
extern NSString* const NSThreadSubthreadsAwareProgressKey;

#if defined(HOROS_BRIDGING_HEADER)
// Swift is compiling the extension itself.
#elif __has_include("Horos-Swift.h")
#import "Horos-Swift.h"
#else
// A target without Swift, the Decompress helper: DCMPix.m names these
// selectors there, as it did before, without their implementation. The
// category is not called (N2) here, so that only the generated interface
// answers for the former category's members.
@interface NSThread (N2WithoutSwift)

+(NSThread*)performBlockInBackground:(void(^)(void))block;

-(NSString*)uniqueId;
-(void)setUniqueId:(NSString*)uniqueId;

//-(BOOL)isCancelled;
-(void)setIsCancelled:(BOOL)isCancelled;

-(void)enterOperation;
-(void)enterOperationIgnoringLowerLevels;
-(void)enterOperationWithRange:(CGFloat)rangeLoc :(CGFloat)rangeLen;
-(void)exitOperation;
-(void)enterSubthreadWithRange:(CGFloat)rangeLoc :(CGFloat)rangeLen __deprecated;
-(void)exitSubthread __deprecated;

-(BOOL)supportsCancel;
-(void)setSupportsCancel:(BOOL)supportsCancel;

-(BOOL)supportsBackgrounding;
-(void)setSupportsBackgrounding:(BOOL)supportsBackgrounding;

-(NSString*)status;
-(void)setStatus:(NSString*)status;

-(CGFloat)progress;
-(void)setProgress:(CGFloat)progress;

-(NSString*)progressDetails;
-(void)setProgressDetails:(NSString*)progressDetails;

-(CGFloat)subthreadsAwareProgress;

@end
#endif
