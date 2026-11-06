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
// The query nodes of the legacy plugin SDK, kept by IsiXLegacyBridge: C-FINDs
// of studies and of their series through the plugin API (IsiXNetwork), on a
// node the user configured in Locations with Query/Retrieve on. The
// application opens the association, with the node's TLS settings. A query
// is made on the calling thread and returns when the node answered.
// Retrieving (move:) is not part of the kit.

#import "DCMTKServiceClassUser.h"

#import "DCMCalendarDate.h"

ISIX_LEGACY_CLASS(DCMTKQueryNode)
@interface IsiXLegacyDCMTKQueryNode : IsiXLegacyDCMTKServiceClassUser

/// `dataset` is accepted for the legacy signature and must be NULL: the
/// attributes of a node come from its query.
+ (id) queryNodeWithDataset: (void*) dataset
                 callingAET: (NSString*) myAET
                  calledAET: (NSString*) theirAET
                   hostname: (NSString*) hostname
                       port: (int) port
             transferSyntax: (int) transferSyntax
                compression: (float) compression
            extraParameters: (NSDictionary*) extraParameters;

- (id) initWithDataset: (void*) dataset
            callingAET: (NSString*) myAET
             calledAET: (NSString*) theirAET
              hostname: (NSString*) hostname
                  port: (int) port
        transferSyntax: (int) transferSyntax
           compression: (float) compression
       extraParameters: (NSDictionary*) extraParameters;

@property (readonly) BOOL lastQuerySucceeded;

- (NSString*) uid;
- (BOOL) isDistant;
- (NSString*) theDescription;
- (NSString*) name;
- (NSString*) patientID;
- (NSString*) accessionNumber;
- (NSString*) referringPhysician;
- (NSString*) performingPhysician;
- (NSString*) institutionName;
- (IsiXLegacyDCMCalendarDate*) date;
- (IsiXLegacyDCMCalendarDate*) time;
- (NSString*) modality;
- (NSNumber*) numberImages;
- (NSArray*) children;
- (void) setChildren: (NSArray*) c;
- (void) purgeChildren;
/// `values`: dictionaries with "name" (PatientsName, PatientID,
/// AccessionNumber, StudyInstanceUID, StudyDescription, StudyDate, modality)
/// and "value"; a date is a DCMCalendarDate, an NSDate or "YYYYMMDD-YYYYMMDD".
/// The matches become the node's children.
- (void) queryWithValues: (NSArray*) values;
- (void) setShowErrorMessage: (BOOL) m;
- (BOOL) showErrorMessage;

@end

/// The root of a query: its children are studies.
ISIX_LEGACY_CLASS(DCMTKRootQueryNode)
@interface IsiXLegacyDCMTKRootQueryNode : IsiXLegacyDCMTKQueryNode
@end

/// A study of a query: its children are its series.
ISIX_LEGACY_CLASS(DCMTKStudyQueryNode)
@interface IsiXLegacyDCMTKStudyQueryNode : IsiXLegacyDCMTKQueryNode
- (NSString*) studyInstanceUID;
- (NSString*) studyName;
- (NSNumber*) numberOfImages;
- (NSDate*) dateOfBirth;
- (NSNumber*) noFiles;
@end

ISIX_LEGACY_CLASS(DCMTKSeriesQueryNode)
@interface IsiXLegacyDCMTKSeriesQueryNode : IsiXLegacyDCMTKQueryNode
@property (assign) IsiXLegacyDCMTKStudyQueryNode* study;
- (NSString*) studyInstanceUID;
- (NSString*) seriesInstanceUID;
@end

@compatibility_alias DCMTKQueryNode IsiXLegacyDCMTKQueryNode;
@compatibility_alias DCMTKRootQueryNode IsiXLegacyDCMTKRootQueryNode;
@compatibility_alias DCMTKStudyQueryNode IsiXLegacyDCMTKStudyQueryNode;
@compatibility_alias DCMTKSeriesQueryNode IsiXLegacyDCMTKSeriesQueryNode;
