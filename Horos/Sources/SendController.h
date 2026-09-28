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

//Abstract class for generalized control of DICOM sending.

// SendController is implemented in Swift since #716
// (Horos/Sources/SendController.swift). This header keeps
// <Horos/SendController.h>: it brings in the generated interface, which
// declares the same class name and selectors. The transfer syntax codes and
// server types stay here.

#import <Cocoa/Cocoa.h>
#import "DicomDatabase.h"

enum TransferSyntaxCodes
{
	SendExplicitLittleEndian = 0, 
	SendJPEG2000Lossless = 1, 
	SendJPEG2000Lossy10 = 2,  
	SendJPEG2000Lossy20 = 3, 
	SendJPEG2000Lossy50 = 4, 
	SendJPEGLossless = 5,  
	SendJPEGLossy9 = 6, 
	SendJPEGLossy8 = 7, 
	SendJPEGLossy7 = 8, 
	SendImplicitLittleEndian = 9, 
	SendRLE = 10, 
	SendExplicitBigEndian = 11, 
	SendBZip = 12,
    SendJPEGLSLossless = 13, 
	SendJPEGLSLossy10 = 14,  
	SendJPEGLSLossy20 = 15, 
	SendJPEGLSLossy50 = 16
};


enum SendServerType { osirixServer, offisServer };

@class Wait;
@class DCMTKStoreSCU;

#if defined(HOROS_BRIDGING_HEADER)
// Swift is compiling the class itself: headers it imports may only name it.
@class SendController;
#elif __has_include("Horos-Swift.h")
#import "Horos-Swift.h"
#else
// A target without Swift, the DCM framework: DCMNetServiceDelegate.m imports
// this header for the transfer syntax codes above. The interface is the former
// one, without its instance variables.
/** \brief Window Controller for DICOM Send */
@interface SendController : NSWindowController

+ (void) sendFiles:(NSArray *)files;
+ (void) sendFiles:(NSArray *)files toNode: (NSDictionary*) node;
+ (void) sendFiles:(NSArray *)files toNode: (NSDictionary*) node usingSyntax: (int) syntax;
- (void) sendDICOMFilesOffis:(NSDictionary *) dict;
+ (int) sendControllerObjects;
- (id)initWithFiles:(NSArray *)files;
- (id)serverAtIndex:(int)index;
- (id)server;
- (NSString *)numberFiles;
- (void)setNumberFiles:(NSString *)numberFiles;
- (IBAction) endSelectServer:(id) sender;
- (int)keyImageIndex;
- (void)setKeyImageIndex:(int)index;
- (void)releaseSelfWhenDone:(id)sender;
- (IBAction)selectServer: (id)sender;
- (void) sendToNode: (NSDictionary*) node;
- (void) sendToNode: (NSDictionary*) node objects:(NSArray*) objects;
- (void) updateDestinationPopup:(NSNotification*) note;

@end
#endif
