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

// The DICOM value types; found in GENERATED_MODULEMAP_DIR, because this
// target compiles without clang modules.
#import "IsiXDICOMFile-Swift.h"
#import "DicomDatabase+CAPI.h"
#import "HorosFileCopy.h"
#import "HorosImportFileSafety.h"
#import "HorosReportExtraction.h"
#import "HorosReportFileReplacement.h"
#import "N2Debug.h"
#import "Horos-Swift.h"

__attribute__((used)) NSString* const CurrentDatabaseVersion = @"2.6";

// The name a new database's directory gets. A database made before the
// application was renamed keeps its earlier name, such as "Horos Data": ask
// HorosDatabaseLocation, which knows them all, rather than building a path
// from this.
__attribute__((used)) NSString* const OsirixDataDirName = @"IsiX Data";

// The default name of the series of screen captures marked as key images. The
// name in use may be another, set in the preferences: ask
// HorosScreenCaptureSeriesName for it. It is in the application's language, so
// it is set when the application loads, as the former C++ initializer set it.
__attribute__((used)) NSString* O2ScreenCapturesSeriesName = nil;

__attribute__((constructor)) static void DicomDatabaseSetScreenCapturesSeriesName(void)
{
    O2ScreenCapturesSeriesName = [[HorosScreenCaptureSeriesName defaultName] copy];
}

__attribute__((used)) NSString* const DicomDatabaseImageEntityName = @"Image";
__attribute__((used)) NSString* const DicomDatabaseSeriesEntityName = @"Series";
__attribute__((used)) NSString* const DicomDatabaseStudyEntityName = @"Study";
__attribute__((used)) NSString* const DicomDatabaseAlbumEntityName = @"Album";
__attribute__((used)) NSString* const DicomDatabaseLogEntryEntityName = @"LogEntry";

NSRecursiveLock* DicomDatabaseRegistryLock(void)
{
    static NSRecursiveLock* lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [[NSRecursiveLock alloc] init]; });
    return lock;
}

// How many times a -dealloc on this thread left the registry's lock that its
// -release took. Each -release compares it before and after: when it grew,
// the -dealloc it ended in already left the lock.
static _Thread_local NSUInteger DicomDatabaseRegistryUnlocksByDealloc = 0;

void DicomDatabaseRegistryUnlockForDealloc(void)
{
    DicomDatabaseRegistryUnlocksByDealloc++;
    [DicomDatabaseRegistryLock() unlock];
}

// DicomDatabase.swift: the database registered under a base path, retained
// under the registry's lock and autoreleased.
@interface DicomDatabase (Registry)
+(DicomDatabase*)horos_registeredDatabaseAtBaseDirPath:(NSString*)path;
@end

@implementation DicomDatabase (CAPI)

// The registry holds the databases by path without retaining them. A lookup
// retains one under the registry's lock; the last release, and the -dealloc
// that removes the database from the registry, happen under the same lock.
// Swift cannot override -release.
-(oneway void) release
{
    NSRecursiveLock* lock = DicomDatabaseRegistryLock();
    [lock lock];
    NSUInteger unlocksBefore = DicomDatabaseRegistryUnlocksByDealloc;
    [super release];
    if (DicomDatabaseRegistryUnlocksByDealloc > unlocksBefore)
        DicomDatabaseRegistryUnlocksByDealloc--;
    else
        [lock unlock];
}

@end

@implementation DicomDatabase (Factory)

// Swift imports these as initializers, which an @implementation cannot
// provide. A database already open at the path is answered, as before.

+(DicomDatabase*)databaseAtPath:(NSString*)path {
    return [[self class] databaseAtPath:path name:nil];
}

+(DicomDatabase*)databaseAtPath:(NSString*)path name:(NSString*)name
{
    path = [self baseDirPathForPath:path];

    // Retained under the registry's lock, where it was a weak link.
    DicomDatabase* database = [DicomDatabase horos_registeredDatabaseAtBaseDirPath:path];

    if (database) return database;

    database = [[[[self class] alloc] initWithPath:[self sqlFilePathForBasePath:path]] autorelease];
    database.name = name;
    return database;
}

+(DicomDatabase*)databaseForContext:(NSManagedObjectContext*)c
{
    DicomDatabase *db = nil;

    if( [c isKindOfClass: [N2ManagedObjectContext class]])
        db = (DicomDatabase*) [(N2ManagedObjectContext*)c database];

    if( !db)
        N2LogStackTrace( @"databaseForContext == nil");

    return db;
}

@end

void DicomDatabaseLogStackTrace(NSString* message) {
    N2LogStackTrace(@"%@", message);
}

void DicomDatabaseLogError(const char* function, const char* file, int line, NSString* message) {
    _N2LogErrorImpl(function, file, line, @"%@", message);
}

id DicomDatabaseSmartAlbumNow(void) {
    return [IsiXDICOMCalendarDate calendarDate];
}

id DicomDatabaseSmartAlbumStartOfToday(id now) {
    return [NSDate dateWithTimeIntervalSinceReferenceDate: [[IsiXDICOMCalendarDate dateWithYear:[now yearOfCommonEra] month:[now monthOfYear] day:[now dayOfMonth] hour:0 minute:0 second:0 timeZone: [now timeZone]] timeIntervalSinceReferenceDate]];
}

NSDate* DicomDatabaseUndefinedStudyDate(void) {
    return [IsiXDICOMCalendarDate dateWithYear:1901 month:1 day:1 hour:0 minute:0 second:0 timeZone:nil];
}

BOOL DicomDatabaseCopyFileForPublication(NSString* source, NSString* destination, BOOL mountedVolume, NSError** error) {
    return HorosCopyFileForPublication(NSFileManager.defaultManager, source, destination, mountedVolume, error);
}

NSString* DicomDatabaseQuarantineUnindexedImport(NSManagedObjectContext* context, NSString* source, NSString* dataDirectory, NSString* errorsDirectory) {
    return HorosQuarantineUnindexedImport((N2ManagedObjectContext*)context, source, dataDirectory, errorsDirectory);
}

void DicomDatabaseRetireImportedFileAfterSave(NSManagedObjectContext* context, NSString* oldPath, NSString* newPath) {
    HorosRetireImportedFileAfterSave((N2ManagedObjectContext*)context, oldPath, newPath);
}

NSString* DicomDatabasePrepareImportedReport(NSManagedObjectContext* context, NSString* extractedPath, NSString* reportsDirectory, NSError** error) {
    return HorosPrepareImportedReport((N2ManagedObjectContext*)context, extractedPath, reportsDirectory, error);
}

BOOL DicomDatabaseReportsHaveSameContents(NSString* existing, NSString* incoming) {
    return HorosReportsHaveSameContents(existing, incoming);
}

void DicomDatabaseCleanReportExtractionParent(NSString* report) {
    HorosCleanReportExtractionParent(report);
}

NSString* DicomDatabaseExtractReportArchive(NSData* archive, NSDate* date) {
    return HorosExtractReportArchive(archive, date);
}
