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
// DCMAttributeTag of the legacy DCM framework, kept by IsiXLegacyBridge: a
// tag, by group and element, by "GGGG,EEEE" or by its keyword. Keywords are
// those of the DICOM dictionary, in either spelling the framework took
// (PatientsName or PatientName); the kit knows the attributes plugins use.

#import "IsiXLegacyBridgeDefines.h"

ISIX_LEGACY_CLASS(DCMAttributeTag)
@interface IsiXLegacyDCMAttributeTag : NSObject <NSCopying>

@property(readonly) int group;
@property(readonly) int element;
@property(readonly) NSString* name;
@property(readonly) NSString* vr;
/// "GGGG,EEEE", in upper case hexadecimal.
@property(readonly) NSString* stringValue;
@property(readonly) long longValue;
@property(readonly) BOOL isPrivate;

/// nil when the kit does not know the keyword.
+ (instancetype) tagWithName: (NSString*) name;
/// "GGGG,EEEE" or "(GGGG,EEEE)"; nil when it is not one.
+ (instancetype) tagWithTagString: (NSString*) tagString;
+ (instancetype) tagWithGroup: (int) group element: (int) element;
- (instancetype) initWithGroup: (int) group element: (int) element;
- (BOOL) isEqualToTag: (IsiXLegacyDCMAttributeTag*) tag;

@end

@compatibility_alias DCMAttributeTag IsiXLegacyDCMAttributeTag;
