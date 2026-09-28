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

// DicomImage, the Core Data entity class of an image, is implemented in Swift
// since #721 (Horos/Sources/DicomImage.swift), with the NSData (OsiriX)
// category. This header keeps <Horos/DicomImage.h>: it brings in the generated
// interface, which declares the same class name and selectors, and keeps the C
// functions of the SOP Instance UID encoding (DicomImage+CAPI.m) and
// OsirixDicomImageSizeUnknown.

#import <Cocoa/Cocoa.h>

NSString* sopInstanceUIDDecode( unsigned char *r, int length);
void* sopInstanceUIDEncode( NSString *sopuid);

#define OsirixDicomImageSizeUnknown INT_MAX

@class DCMSequenceAttribute, DicomSeries, DICOMExport;

#if defined(HOROS_BRIDGING_HEADER)
// Swift is compiling the class itself: headers it imports may only name it.
@class DicomImage;

// N2LogStackTrace(@"%@", message), in DicomImage+CAPI.m: Swift cannot call
// the variadic function.
extern void DicomImageLogStackTrace(NSString* message);
#elif __has_include("Horos-Swift.h")
// Named before the generated interface: the bridging header it imports reaches
// headers that use the class while this one is still being read.
@class DicomImage;
#import "Horos-Swift.h"
#else
// A target without Swift, the Decompress helper: DCMPix.m, DicomFile.mm and
// the headers it shares with the app (SRAnnotation.h) name DicomImage there,
// as they did, without its implementation.

@interface NSData (OsiriX)
- (BOOL) isEqualToSopInstanceUID:(NSData*) sopInstanceUID;
@end

/** \brief  Core Data Entity for an image (frame) */

@interface DicomImage : NSManagedObject

@property(retain) NSNumber* numberOfFrames;

@property(nonatomic, retain) NSString* comment;
@property(nonatomic, retain) NSString* comment2;
@property(nonatomic, retain) NSString* comment3;
@property(nonatomic, retain) NSString* comment4;
@property(nonatomic, retain) NSData* compressedSopInstanceUID;
@property(nonatomic, retain) NSDate* date;
@property(nonatomic, retain) NSNumber* frameID;
@property(nonatomic, retain) NSNumber* instanceNumber;
@property(nonatomic, retain) NSNumber* importedFile;
@property(nonatomic, retain) NSNumber* pathNumber;
@property(nonatomic, retain) NSString* pathString;
@property(nonatomic, retain) NSNumber* rotationAngle;
@property(nonatomic, retain) NSNumber* scale;
@property(nonatomic, retain) NSNumber* sliceLocation;
@property(nonatomic, retain) NSString* stateText;
@property(nonatomic, retain) NSString* storedExtension;
@property(nonatomic, retain) NSString* storedFileType;
@property(nonatomic, retain) NSNumber* storedHeight;
@property(nonatomic, retain) NSNumber* storedInDatabaseFolder;
@property(nonatomic, retain) NSNumber* storedIsKeyImage;
@property(nonatomic, retain) NSString* storedModality;
@property(nonatomic, retain) NSNumber* storedMountedVolume __deprecated;
@property(nonatomic, retain) NSNumber* storedNumberOfFrames;
@property(nonatomic, retain) NSNumber* storedNumberOfSeries;
@property(nonatomic, retain) NSNumber* storedWidth;
@property(nonatomic, retain) NSNumber* windowLevel;
@property(nonatomic, retain) NSNumber* windowWidth;
@property(nonatomic, retain) NSNumber* xFlipped;
@property(nonatomic, retain) NSNumber* xOffset;
@property(nonatomic, retain) NSNumber* yFlipped;
@property(nonatomic, retain) NSNumber* yOffset;
@property(nonatomic, retain) NSNumber* zoom;
@property(nonatomic, retain) DicomSeries* series;

- (NSNumber*) isImageStorage;
+ (NSData*) sopInstanceUIDEncodeString:(NSString*) s;
- (NSString*) uniqueFilename;
- (NSSet*) paths;
- (NSString*) completePath;
- (NSString*) completePathResolved;
#ifndef OSIRIX_LIGHT
- (DCMSequenceAttribute*) graphicAnnotationSequence;
#endif
- (NSImage*) image;
- (NSImage*) thumbnail;
- (NSImage*) imageAsScreenCapture:(NSRect)frame;
- (NSDictionary*) imageAsDICOMScreenCapture:(DICOMExport*) exporter;
- (NSImage*) thumbnailIfAlreadyAvailable;
- (void) setThumbnail:(NSImage*)image;
- (NSString*) completePathWithDownload:(BOOL) download supportNonLocalDatabase: (BOOL) supportNonLocalDatabase;
+ (NSString*) completePathForLocalPath:(NSString*) path directory:(NSString*) directory;
- (NSString*) SRFilenameForFrame: (int) frameNo;
- (NSString*) SRPathForFrame: (int) frameNo;
- (NSString*) SRPath;
- (NSString*) sopInstanceUID;
@property(nonatomic, retain) NSString* modality;

- (NSString*) path;
- (NSString*) extension;
- (NSNumber*) height;
- (NSNumber*) width;

- (NSNumber*) isKeyImage;
- (void) setIsKeyImage:(NSNumber*) f;

+ (NSMutableArray*) dicomImagesInObjects:(NSArray*)objects;

@end
#endif
