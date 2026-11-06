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
// The common part of the kit's DicomStudy, DicomSeries, DicomImage and
// DicomAlbum: an object of the application's database as the plugin API
// gives it, a copy of its attributes under their legacy names. It answers
// key-value coding with those names, so NSPredicate, sort descriptors and
// valueForKeyPath: work on it as they did on the managed objects; the
// attributes the user edits (comments, state, report, key image) are set
// through the plugin API, and any other attribute cannot be set: the
// attempt is the failure of the command that runs.

#import "IsiXLegacyBridgeDefines.h"
#import <CoreData/CoreData.h>

ISIX_LEGACY_CLASS(DatabaseObject)
@interface IsiXLegacyDatabaseObject : NSObject

/// "Study", "Series", "Image" or "Album".
- (NSString*) type;
/// The entity of the kit's model of the legacy database, for -entity.name.
- (NSEntityDescription*) entity;
/// The kit keeps no store: the object stands for its own identifier, and
/// -[NSManagedObjectContext objectWithID:] of the kit's context gives it back.
- (id) objectID;
- (NSManagedObjectContext*) managedObjectContext;
- (BOOL) isFault;
- (BOOL) isDeleted;
- (BOOL) isInserted;
- (BOOL) hasChanges;
- (id) primitiveValueForKey: (NSString*) key;
- (void) willAccessValueForKey: (NSString*) key;
- (void) didAccessValueForKey: (NSString*) key;

@end
