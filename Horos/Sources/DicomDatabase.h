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

/** The database of a folder of DICOM files: its index (Core Data, through
 * N2ManagedDatabase), its folders, the import of files into it and the
 * incoming folder the DICOM listener fills.
 *
 * The class is implemented in Swift under this interface (@objc @implementation):
 * DicomDatabase.swift holds its state, the registry of the databases by path,
 * the initializer and the life cycle; each category below is its own file.
 * DicomDatabase+CAPI.m keeps what Swift cannot write: the exported constants,
 * -release, which takes the registry's lock, the factory methods below and the
 * C helpers of the import.
 * The interface has no instance variables: Swift stores the state.
 */

#import "N2ManagedDatabase.h"

enum {Compress, Decompress};

extern NSString* const CurrentDatabaseVersion;
extern NSString* const OsirixDataDirName;
// The default name of the screen captures series, in the application's
// language: set when the application loads, so it is not a constant.
extern NSString* O2ScreenCapturesSeriesName;

@class N2MutableUInteger, DicomAlbum, DataNodeIdentifier;

@interface DicomDatabase : N2ManagedDatabase

+(void)initializeDicomDatabaseClass;

+(NSString*)defaultBaseDirPath;
+(NSString*)baseDirPathForPath:(NSString*)path;
+(NSString*)baseDirPathForMode:(int)mode path:(NSString*)path;

+(NSArray*)allDatabases;
+(DicomDatabase*)defaultDatabase;
+(DicomDatabase*)existingDatabaseAtPath:(NSString*)path;
+(DicomDatabase*)activeLocalDatabase;
+(void)setActiveLocalDatabase:(DicomDatabase*)ldb;

@property(readonly,retain) NSString* baseDirPath; // Horos Data
@property(readonly,retain) NSString* dataBaseDirPath; // depends on the content of the file at baseDirPath/DBFOLDER_LOCATION
@property(readwrite,retain,nonatomic) NSString* name, *sourcePath;
@property(readwrite) NSTimeInterval timeOfLastModification;
@property BOOL isReadOnly;
@property BOOL hasPotentiallySlowDataAccess;

// -isLocal, -dataNodeIdentifier, the entities and the paths: DicomDatabase+Instance.h.

#pragma mark Entities
extern NSString* const DicomDatabaseImageEntityName;
extern NSString* const DicomDatabaseSeriesEntityName;
extern NSString* const DicomDatabaseStudyEntityName;
extern NSString* const DicomDatabaseAlbumEntityName;
extern NSString* const DicomDatabaseLogEntryEntityName;

#pragma mark Paths
// these paths are used from the DICOM listener
-(const char*)baseDirPathC;
-(const char*)incomingDirPathC;
-(const char*)tempDirPathC;

// Albums: DicomDatabase+Albums.h.

@end

/// The factory methods Swift sees as initializers (DicomDatabase(atPath:),
/// DicomDatabase(for:)), which an @implementation cannot provide:
/// DicomDatabase+CAPI.m.
@interface DicomDatabase (Factory)

+(DicomDatabase*)databaseAtPath:(NSString*)path;
+(DicomDatabase*)databaseAtPath:(NSString*)path name:(NSString*)name;
+(DicomDatabase*)databaseForContext:(NSManagedObjectContext*)c; // hopefully one day this will be __deprecated

@end

/// Adding files to the index: DicomDatabase+Import.swift.
@interface DicomDatabase (Import)

#pragma mark Add files
-(NSArray*)addFilesAtPaths:(NSArray*)paths;
-(NSArray*)addFilesAtPaths:(NSArray*)paths postNotifications:(BOOL)postNotifications;
-(NSArray*)addFilesAtPaths:(NSArray*)paths postNotifications:(BOOL)postNotifications dicomOnly:(BOOL)dicomOnly rereadExistingItems:(BOOL)rereadExistingItems;
-(NSArray*)addFilesAtPaths:(NSArray*)paths postNotifications:(BOOL)postNotifications dicomOnly:(BOOL)dicomOnly rereadExistingItems:(BOOL)rereadExistingItems generatedByOsiriX:(BOOL)generatedByOsiriX;
-(NSArray*)addFilesAtPaths:(NSArray*)paths postNotifications:(BOOL)postNotifications dicomOnly:(BOOL)dicomOnly rereadExistingItems:(BOOL)rereadExistingItems generatedByOsiriX:(BOOL)generatedByOsiriX returnArray: (BOOL) returnArray;
-(NSArray*)addFilesAtPaths:(NSArray*)paths postNotifications:(BOOL)postNotifications dicomOnly:(BOOL)dicomOnly rereadExistingItems:(BOOL)rereadExistingItems generatedByOsiriX:(BOOL)generatedByOsiriX importedFiles: (BOOL) importedFiles returnArray: (BOOL) returnArray;

-(NSArray*)addFilesDescribedInDictionaries:(NSArray*)dicomFilesArray postNotifications:(BOOL)postNotifications rereadExistingItems:(BOOL)rereadExistingItems generatedByOsiriX:(BOOL)generatedByOsiriX; // returns NSArray<NSManagedObjectID>
-(NSArray*)addFilesDescribedInDictionaries:(NSArray*)dicomFilesArray postNotifications:(BOOL)postNotifications rereadExistingItems:(BOOL)rereadExistingItems generatedByOsiriX:(BOOL)generatedByOsiriX returnArray: (BOOL) returnArray;
-(NSArray*)addFilesDescribedInDictionaries:(NSArray*)dicomFilesArray postNotifications:(BOOL)postNotifications rereadExistingItems:(BOOL)rereadExistingItems generatedByOsiriX:(BOOL)generatedByOsiriX importedFiles: (BOOL) importedFiles returnArray: (BOOL) returnArray;

@end

/// The incoming folder the DICOM listener fills, and its scan:
/// DicomDatabase+IncomingImport.swift.
@interface DicomDatabase (IncomingImport)

#pragma mark Incoming
-(BOOL)isFileSystemFreeSizeLimitReached;
-(BOOL) hasFilesToImport;
@property(readonly) BOOL incomingImportInProgress;
-(NSInteger)importFilesFromIncomingDir;
-(NSInteger)importFilesFromIncomingDir: (NSNumber*) showGUI;
-(NSInteger)importFilesFromIncomingDir: (NSNumber*) showGUI listenerCompressionSettings: (int) listenerCompressionSettings;
-(void)initiateImportFilesFromIncomingDirUnlessAlreadyImporting;
-(void)importFilesFromIncomingDirThread;
+(void)syncImportFilesFromIncomingDirTimerWithUserDefaults; // called from deprecated API

@end

/// What an import tells the user: the files it refused, a volume too full to
/// import into, and the notifications of new images: DicomDatabase+ImportAlerts.swift.
@interface DicomDatabase (ImportAlerts)

@property(readonly) BOOL incomingImportWaitingForSpace;
// What the last import refused, for the window to show. A refusal used to reach
// the log only, so a study arrived with fewer images and nothing said which.
@property(readonly, copy) NSString *lastImportRefusalSummary;
- (void)setLastImportRefusalSummary:(NSString*)summary;
- (void)addImportRefusalSummary:(NSString*)summary;
- (void)updateStorageAvailabilityWarning; // main-thread, nonmodal storage status

@end

/// Compressing and decompressing DICOM files, and the queue of the incoming
/// files waiting for it: DicomDatabase+Compression.swift.
@interface DicomDatabase (Compression)

#pragma mark Compress/decompress
-(BOOL)compressFilesAtPaths:(NSArray*)paths;
-(BOOL)compressFilesAtPaths:(NSArray*)paths intoDirAtPath:(NSString*)destDir;
-(BOOL)decompressFilesAtPaths:(NSArray*)paths;
-(BOOL)decompressFilesAtPaths:(NSArray*)paths intoDirAtPath:(NSString*)destDir;
-(void)initiateCompressFilesAtPaths:(NSArray*)paths;
-(void)initiateCompressFilesAtPaths:(NSArray*)paths intoDirAtPath:(NSString*)destDir;
-(void)initiateDecompressFilesAtPaths:(NSArray*)paths;
-(void)initiateDecompressFilesAtPaths:(NSArray*)paths intoDirAtPath:(NSString*)destDir;
-(void)processFilesAtPaths:(NSArray*)paths intoDirAtPath:(NSString*)destDir mode:(int)mode;
// Swift would import this as throwing, under the name of the method above, and
// cannot implement such a method: NS_SWIFT_NOTHROW keeps the NSError**.
-(BOOL)processFilesAtPaths:(NSArray*)paths intoDirAtPath:(NSString*)destDir mode:(int)mode error:(NSError**)error NS_SWIFT_NOTHROW;
-(BOOL)waitForCompressThread;

@end

/// Copying the files of a folder or a medium into the database and indexing
/// them: DicomDatabase+MediaCopy.swift.
@interface DicomDatabase (MediaCopy)

-(void)copyFilesThread:(NSDictionary*)dict;

@end

#pragma mark Other
// The rest, and +recomputePatientUIDsInContext:: DicomDatabase+Other.h.

// Blocks of methods implemented in Swift, with the same selectors.
#import "DicomDatabase+Instance.h"
#import "DicomDatabase+Albums.h"
#import "DicomDatabase+Other.h"
