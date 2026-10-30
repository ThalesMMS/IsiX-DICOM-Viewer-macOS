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
// BrowserController of the legacy plugin SDK, kept by IsiXLegacyBridge: the
// database window, as far as the plugin API reaches it: its selection, its
// database (DicomDatabase), the files added to it and the series opened
// from it. Its windows, outline and matrix are the application's and are not
// part of it.

#import "IsiXLegacyBridgeDefines.h"
#import <CoreData/CoreData.h>
#import "DicomDatabase.h"

@class IsiXLegacyDicomImage, IsiXLegacyViewerController;

ISIX_LEGACY_CLASS(BrowserController)
@interface IsiXLegacyBrowserController : NSObject

+ (IsiXLegacyBrowserController*) currentBrowser;
/// The names of the states of studies and series, by index.
+ (NSArray*) statesArray;

@property(retain, nonatomic, readonly) IsiXLegacyDicomDatabase* database;
/// The kit's folder, outside the application's data (see DicomDatabase).
@property(readonly) NSString* documentsDirectory;
@property(readonly) NSString* fixedDocumentsDirectory;
@property(readonly) NSString* currentDatabasePath;

- (NSManagedObjectContext*) managedObjectContext;
- (NSManagedObjectContext*) localManagedObjectContext;
- (NSManagedObjectModel*) managedObjectModel;
- (long) saveDatabase;
- (long) saveDatabase: (NSString*) path;

/// The selected studies and series, as DicomStudy and DicomSeries.
- (NSArray*) databaseSelection;
/// The files of the selection's images; `correspondingManagedObjects`
/// receives the images, one per file.
- (NSMutableArray*) filesForDatabaseOutlineSelection: (NSMutableArray*) correspondingManagedObjects;
- (NSMutableArray*) filesForDatabaseOutlineSelection: (NSMutableArray*) correspondingManagedObjects onlyImages: (BOOL) onlyImages;
- (NSMutableArray*) filesForDatabaseMatrixSelection: (NSMutableArray*) correspondingManagedObjects onlyImages: (BOOL) onlyImages;
- (NSArray*) albums;

/// Adds the files to the database: the application copies them. Returns the
/// images made of them, as DicomImage.
+ (NSArray*) addFiles: (NSArray*) newFilesArray toContext: (NSManagedObjectContext*) context onlyDICOM: (BOOL) onlyDICOM notifyAddedFiles: (BOOL) notifyAddedFiles parseExistingObject: (BOOL) parseExistingObject dbFolder: (NSString*) dbFolder;
+ (NSArray*) addFiles: (NSArray*) newFilesArray toContext: (NSManagedObjectContext*) context toDatabase: (IsiXLegacyBrowserController*) browserController onlyDICOM: (BOOL) onlyDICOM notifyAddedFiles: (BOOL) notifyAddedFiles parseExistingObject: (BOOL) parseExistingObject dbFolder: (NSString*) dbFolder;
+ (NSArray*) addFiles: (NSArray*) newFilesArray toContext: (NSManagedObjectContext*) context toDatabase: (IsiXLegacyBrowserController*) browserController onlyDICOM: (BOOL) onlyDICOM notifyAddedFiles: (BOOL) notifyAddedFiles parseExistingObject: (BOOL) parseExistingObject dbFolder: (NSString*) dbFolder generatedByOsiriX: (BOOL) generatedByOsiriX;
- (NSArray*) addFilesToDatabase: (NSArray*) newFilesArray;
- (NSArray*) addFilesToDatabase: (NSArray*) newFilesArray onlyDICOM: (BOOL) onlyDICOM produceAddedFiles: (BOOL) produceAddedFiles;
- (NSArray*) addFilesToDatabase: (NSArray*) newFilesArray onlyDICOM: (BOOL) onlyDICOM produceAddedFiles: (BOOL) produceAddedFiles parseExistingObject: (BOOL) parseExistingObject;
/// The files, and those of the folders; the application copies them.
- (NSArray*) addFilesAndFolderToDatabase: (NSArray*) filenames;
/// A new file in the kit's folder of files waiting to be added.
- (NSString*) getNewFileDatabasePath: (NSString*) extension;
- (NSString*) getNewFileDatabasePath: (NSString*) extension dbFolder: (NSString*) dbFolder;
/// The application imports what it receives by itself: nothing to do.
- (void) checkIncoming: (id) sender;

/// Remembers the image as the kit's selection, for -newViewerDICOM: and
/// -viewerDICOM:; the database window's own selection is left as it is.
- (BOOL) findAndSelectFile: (NSString*) path image: (IsiXLegacyDicomImage*) curImage shouldExpand: (BOOL) expand;
- (BOOL) findAndSelectFile: (NSString*) path image: (IsiXLegacyDicomImage*) curImage shouldExpand: (BOOL) expand extendingSelection: (BOOL) extendingSelection;
/// Opens the series of the image the kit selected last, else of the
/// database window's selection, in a new viewer.
- (void) newViewerDICOM: (id) sender;
- (void) viewerDICOM: (id) sender;
/// Opens the series in a new viewer; returns it when the plugin reads viewers.
- (IsiXLegacyViewerController*) loadSeries: (NSManagedObject*) curFile :(IsiXLegacyViewerController*) viewer :(BOOL) firstViewer keyImagesOnly: (BOOL) keyImages;
/// The database window shows changes by itself: nothing to do.
- (void) refreshDatabase: (id) sender;
- (void) outlineViewRefresh;
- (void) refreshAlbums;

@end

@compatibility_alias BrowserController IsiXLegacyBrowserController;
