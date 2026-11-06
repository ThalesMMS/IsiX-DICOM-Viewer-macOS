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
// DicomDatabase of the legacy plugin SDK, kept by IsiXLegacyBridge: the
// application's local database through the plugin API. Fetches of its
// context (NSFetchRequest with an NSPredicate and sort descriptors) are
// evaluated by the kit over what the plugin API returns; files are added by
// the application, which copies them; the folders a plugin writes into are
// the kit's, outside the application's data.

#import "IsiXLegacyBridgeDefines.h"
#import <CoreData/CoreData.h>

@class IsiXLegacyDicomStudy, IsiXLegacyDicomAlbum;

ISIX_LEGACY_CLASS(DicomDatabase)
@interface IsiXLegacyDicomDatabase : NSObject

+ (IsiXLegacyDicomDatabase*) defaultDatabase;
+ (IsiXLegacyDicomDatabase*) activeLocalDatabase;
+ (IsiXLegacyDicomDatabase*) databaseForContext: (NSManagedObjectContext*) c;
+ (NSArray*) allDatabases;

/// The kit's folders, outside the application's data: what a plugin writes
/// there reaches the database only when the plugin adds it.
@property(readonly, retain) NSString* baseDirPath;
@property(readonly, retain) NSString* dataBaseDirPath;
@property(readonly, retain) NSString* dataDirPath;
@property(readonly, retain) NSString* incomingDirPath;
@property(readonly, retain) NSString* tempDirPath;
@property(readwrite, retain, nonatomic) NSString* name;
@property(readonly) BOOL isLocal;
@property(readonly) BOOL isReadOnly;
/// A context whose fetches the kit evaluates over the plugin API.
@property(readonly, retain) NSManagedObjectContext* managedObjectContext;
@property(readonly, retain) NSManagedObjectModel* managedObjectModel;

- (NSEntityDescription*) studyEntity;
- (NSEntityDescription*) seriesEntity;
- (NSEntityDescription*) imageEntity;
- (NSEntityDescription*) albumEntity;
- (NSEntityDescription*) entityForName: (NSString*) name;

- (NSArray*) objectsForEntity: (id) e;
- (NSArray*) objectsForEntity: (id) e predicate: (NSPredicate*) p;
- (NSArray*) objectsForEntity: (id) e predicate: (NSPredicate*) p error: (NSError**) err;
- (NSUInteger) countObjectsForEntity: (id) e;
- (NSUInteger) countObjectsForEntity: (id) e predicate: (NSPredicate*) p;
- (id) objectWithID: (id) oid;
- (NSArray*) objectsWithIDs: (NSArray*) objectIDs;
/// Changes go through the plugin API when they are made: nothing is left to save.
- (BOOL) save;
- (BOOL) save: (NSError**) err;
- (void) lock;
- (void) unlock;
- (BOOL) tryLock;

/// The albums, by name, as DicomAlbum.
- (NSArray*) albums;
- (void) addStudies: (NSArray*) dicomStudies toAlbum: (IsiXLegacyDicomAlbum*) dicomAlbum;
/// A new album, not smart, or nil when the application refused the name.
- (IsiXLegacyDicomAlbum*) newAlbumWithName: (NSString*) name NS_RETURNS_NOT_RETAINED;

/// Adds DICOM files to the database: the application copies them and
/// indexes the copies. Returns the images made of them, as DicomImage.
- (NSArray*) addFilesAtPaths: (NSArray*) paths;
- (NSArray*) addFilesAtPaths: (NSArray*) paths postNotifications: (BOOL) postNotifications;
- (NSArray*) addFilesAtPaths: (NSArray*) paths postNotifications: (BOOL) postNotifications dicomOnly: (BOOL) dicomOnly rereadExistingItems: (BOOL) rereadExistingItems;
- (NSArray*) addFilesAtPaths: (NSArray*) paths postNotifications: (BOOL) postNotifications dicomOnly: (BOOL) dicomOnly rereadExistingItems: (BOOL) rereadExistingItems generatedByOsiriX: (BOOL) generatedByOsiriX;
- (NSArray*) addFilesAtPaths: (NSArray*) paths postNotifications: (BOOL) postNotifications dicomOnly: (BOOL) dicomOnly rereadExistingItems: (BOOL) rereadExistingItems generatedByOsiriX: (BOOL) generatedByOsiriX returnArray: (BOOL) returnArray;
/// A new file in the kit's folder of files waiting to be added.
- (NSString*) uniquePathForNewDataFileWithExtension: (NSString*) ext;

@end

@compatibility_alias DicomDatabase IsiXLegacyDicomDatabase;
