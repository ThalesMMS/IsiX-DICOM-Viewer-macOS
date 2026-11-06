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
// DicomSeries of the legacy plugin SDK, kept by IsiXLegacyBridge: a series
// of the database, read through the plugin API (IsiXDatabase). The comments
// and stateText are set through the plugin API.

#import "IsiXLegacyDatabaseObject.h"

@class IsiXLegacyDicomStudy;

ISIX_LEGACY_CLASS(DicomSeries)
@interface IsiXLegacyDicomSeries : IsiXLegacyDatabaseObject

@property(nonatomic, retain) NSString* comment;
@property(nonatomic, retain) NSString* comment2;
@property(nonatomic, retain) NSString* comment3;
@property(nonatomic, retain) NSString* comment4;
@property(nonatomic, retain, readonly) NSDate* date;
/// The Series Number.
@property(nonatomic, retain, readonly) NSNumber* id;
@property(nonatomic, retain, readonly) NSString* modality;
@property(nonatomic, retain, readonly) NSString* name;
@property(nonatomic, retain, readonly) NSNumber* numberOfImages;
@property(nonatomic, retain, readonly) NSString* seriesDescription;
@property(nonatomic, retain, readonly) NSString* seriesDICOMUID;
@property(nonatomic, retain, readonly) NSString* seriesInstanceUID;
@property(nonatomic, retain, readonly) NSString* seriesSOPClassUID;
@property(nonatomic, retain) NSNumber* stateText;
/// The series' images, as DicomImage: one per frame of a multi-frame file.
@property(nonatomic, retain, readonly) NSSet* images;
@property(nonatomic, retain, readonly) IsiXLegacyDicomStudy* study;

- (NSSet*) paths;
- (NSSet*) keyImages;
/// The images by instance number and frame.
- (NSArray*) sortedImages;
- (NSArray*) sortDescriptorsForImages;
- (NSNumber*) noFilesExcludingMultiFrames;
- (NSNumber*) rawNoFiles;
- (NSComparisonResult) compareName: (IsiXLegacyDicomSeries*) series;

@end

@compatibility_alias DicomSeries IsiXLegacyDicomSeries;
