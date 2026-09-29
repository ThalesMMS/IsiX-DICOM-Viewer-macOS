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

// What the DicomDatabase (Clean) and (Routing) categories, the Instance, Albums
// and Other blocks of DicomDatabase and RemoteDicomDatabase, implemented in
// Swift, need of DicomDatabase and cannot declare themselves: the ivars they
// use, N2LogError and N2LogStackTrace, which are variadic, a DCMTKStoreSCU given
// the very array and mutable dictionary the routing built, the NSCalendarDate
// of the smart albums and the exception literal of -rebuild:. Swift sees this
// header through the bridging header; it is not part of the SDK.

#import "DicomDatabase.h"

@class DCMTKStoreSCU, N2MutableUInteger;

NS_ASSUME_NONNULL_BEGIN

@interface DicomDatabase (SwiftIvars)

/// _cleanLock, retained; the lock the main database shares with its independent databases.
@property(nonatomic, retain, nullable) NSRecursiveLock* cleanLock;
/// _routingLock, retained.
@property(nonatomic, retain, nullable) NSRecursiveLock* routingLock;
/// _routingSendQueues, retained; the queue the main database shares with its independent databases.
@property(nonatomic, retain, nullable) NSMutableArray* routingSendQueues;
/// _name, read without -name, which RemoteDicomDatabase overrides.
@property(nonatomic, readonly, nullable) NSString* horos_name;
/// _sqlFilePath of N2ManagedDatabase, written without -setSqlFilePath:: the
/// former value is autoreleased and the new one retained, as RemoteDicomDatabase did.
@property(nonatomic, retain, nullable) NSString* horos_sqlFilePath;
/// _dataFileIndex, which the main database shares with its independent databases.
@property(nonatomic, readonly, nullable) N2MutableUInteger* horos_dataFileIndex;
/// _importFilesFromIncomingDirLock, which the main database shares with its independent databases.
@property(nonatomic, readonly, nullable) NSRecursiveLock* horos_importFilesFromIncomingDirLock;

@end

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

/// [[DCMTKStoreSCU alloc] initWithCallingAET:…extraParameters:], retained. The
/// array and the dictionary are typed id so that Swift passes them unbridged.
DCMTKStoreSCU* _Nullable DicomDatabaseRoutingStoreSCU(NSString* _Nullable callingAET, NSString* _Nullable calledAET, NSString* _Nullable hostname, int port, id _Nullable filesToSend, int transferSyntax, float compression, id _Nullable extraParameters) NS_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END
