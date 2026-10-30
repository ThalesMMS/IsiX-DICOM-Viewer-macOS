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
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

// What DicomDatabase, implemented in Swift, keeps in Objective-C
// (DicomDatabase+CAPI.m): the lock of the registry of the databases, which
// -release takes, N2LogError and N2LogStackTrace, which are variadic, the
// NSCalendarDate of the smart albums and of the import, and the static inline
// helpers of the import, written for manual retain and release, which Swift
// cannot call. Swift sees this header through the bridging header; it is not
// part of the SDK.

#import "DicomDatabase.h"

NS_ASSUME_NONNULL_BEGIN

/// The lock of the registry of the databases by path. -release holds it while
/// the object may be deallocated, so that a lookup cannot retain a database
/// whose -dealloc is removing it from the registry.
NSRecursiveLock* DicomDatabaseRegistryLock(void);

/// Leaves the registry's lock that -release took, once the deallocating
/// database is out of the registry: what it does next (its cleaning and routing
/// threads, the superclass's -dealloc) must not hold the registry. -release
/// then does not leave it a second time.
void DicomDatabaseRegistryUnlockForDealloc(void);

/// N2LogError(@"%@", message), with the function, file and line of the caller.
void DicomDatabaseLogError(const char* function, const char* file, int line, NSString* message);

/// N2LogStackTrace(@"%@", message).
void DicomDatabaseLogStackTrace(NSString* message);

/// [NSCalendarDate calendarDate], typed id: Swift cannot name NSCalendarDate,
/// and would turn an NSDate into a Date.
id DicomDatabaseSmartAlbumNow(void);

/// The start of the day of `now`, an NSCalendarDate, in its time zone: an
/// NSDate, typed id.
id DicomDatabaseSmartAlbumStartOfToday(id now);

/// The date of a study that has none: 1 January 1901, midnight, in the default
/// time zone, as DCMCalendarDate makes it.
NSDate* DicomDatabaseUndefinedStudyDate(void);

/// HorosCopyFileForPublication(NSFileManager.defaultManager, …): a copy
/// published only once complete.
BOOL DicomDatabaseCopyFileForPublication(NSString* source, NSString* destination, BOOL mountedVolume, NSError** error);

/// HorosQuarantineUnindexedImport: moves a rejected file of the database folder
/// that no image refers to into the errors folder; its new path, or nil.
NSString* _Nullable DicomDatabaseQuarantineUnindexedImport(NSManagedObjectContext* _Nullable context, NSString* _Nullable source,
                                                           NSString* _Nullable dataDirectory, NSString* _Nullable errorsDirectory);

/// HorosRetireImportedFileAfterSave: removes the file a new one replaces once
/// the save that records the new one has succeeded.
void DicomDatabaseRetireImportedFileAfterSave(NSManagedObjectContext* _Nullable context, NSString* _Nullable oldPath, NSString* _Nullable newPath);

/// HorosPrepareImportedReport: moves an extracted report into the reports
/// folder under a name of its own; the study's report URL, or nil.
NSString* _Nullable DicomDatabasePrepareImportedReport(NSManagedObjectContext* _Nullable context, NSString* _Nullable extractedPath,
                                                       NSString* _Nullable reportsDirectory, NSError** error);

/// HorosReportsHaveSameContents.
BOOL DicomDatabaseReportsHaveSameContents(NSString* _Nullable existing, NSString* _Nullable incoming);

/// HorosCleanReportExtractionParent.
void DicomDatabaseCleanReportExtractionParent(NSString* report);

/// HorosExtractReportArchive: the report a structured report encapsulates,
/// extracted; nil when the archive could not be extracted completely.
NSString* _Nullable DicomDatabaseExtractReportArchive(NSData* archive, NSDate* _Nullable date);

NS_ASSUME_NONNULL_END
