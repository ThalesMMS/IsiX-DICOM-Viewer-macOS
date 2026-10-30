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
// DCMObject of the legacy DCM framework, kept by IsiXLegacyBridge: a DICOM
// dataset read from a file or made by the plugin, and written to a file.
// The kit reads and writes uncompressed little endian files (explicit or
// implicit VR); sequences are read past and not kept; compressed pixel data
// is kept as read, undecoded. A file the plugin writes reaches the database
// when the plugin adds it (-[BrowserController addFilesToDatabase:]).

#import "IsiXLegacyBridgeDefines.h"
#import "DCMAttribute.h"
#import "DCMAttributeTag.h"
#import "DCMPixelDataAttribute.h"
#import "DCMTransferSyntax.h"
#import "DCMCalendarDate.h"

ISIX_LEGACY_CLASS(DCMObject)
@interface IsiXLegacyDCMObject : NSObject <NSCopying>

/// The attributes by "GGGG,EEEE".
@property(readonly) NSMutableDictionary* attributes;
@property(retain) IsiXLegacyDCMTransferSyntax* transferSyntax;

+ (instancetype) objectWithContentsOfFile: (NSString*) file decodingPixelData: (BOOL) decodePixelData;
+ (instancetype) objectWithData: (NSData*) data decodingPixelData: (BOOL) decodePixelData;
- (instancetype) initWithContentsOfFile: (NSString*) file decodingPixelData: (BOOL) decodePixelData;
- (instancetype) initWithData: (NSData*) data decodingPixelData: (BOOL) decodePixelData;
+ (BOOL) isDICOM: (NSData*) data;
/// An empty Secondary Capture Image of new UIDs: SOP Class, Instance,
/// Study and Series UIDs, today's dates, and the pixel module for these
/// bits per sample (8, 16, or 32), samples per pixel and frames.
+ (instancetype) secondaryCaptureObjectWithBitDepth: (int) depth samplesPerPixel: (int) spp numberOfFrames: (int) frames;
+ (instancetype) objectFromObject: (IsiXLegacyDCMObject*) object;

- (IsiXLegacyDCMAttribute*) attributeForTag: (IsiXLegacyDCMAttributeTag*) tag;
- (IsiXLegacyDCMAttribute*) attributeWithName: (NSString*) name;
- (id) attributeValueWithName: (NSString*) name;
- (NSArray*) attributeArrayWithName: (NSString*) name;
/// A value by "GGGG,EEEE" or by keyword.
- (id) attributeValueForKey: (NSString*) key;
- (void) setAttribute: (IsiXLegacyDCMAttribute*) attribute;
- (void) setAttributeValues: (NSMutableArray*) values forName: (NSString*) name;
- (void) setAttributeValues: (NSMutableArray*) values forKey: (NSString*) key;
- (void) removeAttribute: (IsiXLegacyDCMAttribute*) attribute;
- (void) removeAttributeForTag: (IsiXLegacyDCMAttributeTag*) tag;
- (BOOL) isNeedToCompress;

/// Writes the object; YES when it was written. `quality` is not used: the
/// kit writes uncompressed files.
- (BOOL) writeToFile: (NSString*) path withTransferSyntax: (IsiXLegacyDCMTransferSyntax*) ts quality: (int) quality atomically: (BOOL) atomically;
- (BOOL) writeToFile: (NSString*) path withTransferSyntax: (IsiXLegacyDCMTransferSyntax*) ts quality: (int) quality AET: (NSString*) aet atomically: (BOOL) atomically;
- (NSData*) writeDatasetWithTransferSyntax: (IsiXLegacyDCMTransferSyntax*) ts quality: (int) quality;

@end

@compatibility_alias DCMObject IsiXLegacyDCMObject;
