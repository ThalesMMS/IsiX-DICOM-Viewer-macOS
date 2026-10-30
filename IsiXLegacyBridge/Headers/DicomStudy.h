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
// DicomStudy of the legacy plugin SDK, kept by IsiXLegacyBridge: a study of
// the database, read through the plugin API (IsiXDatabase). The comments,
// stateText, reportURL and lockedStudy are set through the plugin API; the
// other attributes are read only.

#import "IsiXLegacyDatabaseObject.h"

@class IsiXLegacyDicomSeries, IsiXLegacyDicomImage;

ISIX_LEGACY_CLASS(DicomStudy)
@interface IsiXLegacyDicomStudy : IsiXLegacyDatabaseObject

@property(nonatomic, retain, readonly) NSString* accessionNumber;
@property(nonatomic, retain) NSString* comment;
@property(nonatomic, retain) NSString* comment2;
@property(nonatomic, retain) NSString* comment3;
@property(nonatomic, retain) NSString* comment4;
@property(nonatomic, retain, readonly) NSDate* date;
@property(nonatomic, retain, readonly) NSDate* dateAdded;
@property(nonatomic, retain, readonly) NSDate* dateOfBirth;
@property(nonatomic, retain, readonly) NSNumber* hasDICOM;
@property(nonatomic, retain, readonly) NSString* id;
@property(nonatomic, retain, readonly) NSString* institutionName;
@property(nonatomic, retain) NSNumber* lockedStudy;
@property(nonatomic, retain, readonly) NSString* modality;
@property(nonatomic, retain, readonly) NSString* name;
@property(nonatomic, retain, readonly) NSNumber* numberOfImages;
@property(nonatomic, retain, readonly) NSString* patientID;
@property(nonatomic, retain, readonly) NSString* patientSex;
@property(nonatomic, retain, readonly) NSString* patientUID;
@property(nonatomic, retain, readonly) NSString* performingPhysician;
@property(nonatomic, retain, readonly) NSString* referringPhysician;
/// A web address, or the path of the report's file.
@property(nonatomic, retain) NSString* reportURL;
/// An index of +[BrowserController statesArray]: 0 empty, 1 unread,
/// 2 reviewed, 3 dictated, 4 validated.
@property(nonatomic, retain) NSNumber* stateText;
@property(nonatomic, retain, readonly) NSString* studyInstanceUID;
@property(nonatomic, retain, readonly) NSString* studyName;
/// The study's series, as DicomSeries.
@property(nonatomic, retain, readonly) NSSet* series;
/// The albums that hold the study, as DicomAlbum.
@property(nonatomic, retain, readonly) NSSet* albums;

/// Whether a series is shown: not one of the application's own SR series.
+ (BOOL) displaySeriesWithSOPClassUID: (NSString*) uid andSeriesDescription: (NSString*) description;
- (NSSet*) images;
- (NSSet*) keyImages;
- (NSSet*) paths;
- (NSNumber*) noFiles;
- (NSString*) modalities;
/// The series of images, without the application's own SR series.
- (NSArray*) imageSeries;
- (NSComparisonResult) compareName: (IsiXLegacyDicomStudy*) study;

@end

@compatibility_alias DicomStudy IsiXLegacyDicomStudy;
