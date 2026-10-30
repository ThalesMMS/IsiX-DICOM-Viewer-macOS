/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)

 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.

 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.

 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.

 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html

 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL

  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
// DicomImage of the legacy plugin SDK, kept by IsiXLegacyBridge: an image of
// the database (a frame of a file), read through the plugin API
// (IsiXDatabase). Its file is the database's, for reading; the comments and
// the key image are set through the plugin API.

#import "IsiXLegacyDatabaseObject.h"

@class IsiXLegacyDicomSeries;

ISIX_LEGACY_CLASS(DicomImage)
@interface IsiXLegacyDicomImage : IsiXLegacyDatabaseObject

@property(retain, readonly) NSNumber* numberOfFrames;
@property(nonatomic, retain) NSString* comment;
@property(nonatomic, retain) NSString* comment2;
@property(nonatomic, retain) NSString* comment3;
@property(nonatomic, retain) NSString* comment4;
@property(nonatomic, retain, readonly) NSDate* date;
@property(nonatomic, retain, readonly) NSNumber* frameID;
@property(nonatomic, retain, readonly) NSNumber* instanceNumber;
@property(nonatomic, retain, readonly) NSNumber* sliceLocation;
@property(nonatomic, retain) NSNumber* storedIsKeyImage;
@property(nonatomic, retain, readonly) NSString* modality;
@property(nonatomic, retain, readonly) IsiXLegacyDicomSeries* series;

- (NSString*) sopInstanceUID;
/// The image's file, for reading.
- (NSString*) completePath;
- (NSString*) completePathResolved;
- (NSString*) path;
- (NSString*) extension;
- (NSSet*) paths;
- (NSNumber*) height;
- (NSNumber*) width;
- (NSNumber*) isKeyImage;
- (void) setIsKeyImage: (NSNumber*) f;

/// The images of the objects: images, and the images of series and of studies.
+ (NSMutableArray*) dicomImagesInObjects: (NSArray*) objects;

@end

@compatibility_alias DicomImage IsiXLegacyDicomImage;
