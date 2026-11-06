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

#import <Cocoa/Cocoa.h>

@class N2ManagedObjectContext;

#ifdef __cplusplus
extern "C" {
#endif
// Runs block on the context's queue and waits. An exception raised in block is
// raised again here, off the queue. The application makes no confined context;
// with one a plug-in made itself, the block runs on the calling thread.
void N2ManagedObjectContextPerformAndWait(NSManagedObjectContext *context, void (NS_NOESCAPE ^block)(void));
#ifdef __cplusplus
}
#endif

// N2ManagedDatabase and N2ManagedObjectContext are implemented in Swift
// (N2ManagedDatabase.swift and its extensions, N2ManagedObjectContext.swift);
// the CAPI categories in Objective-C (N2ManagedDatabase+CAPI.m).
@interface N2ManagedDatabase : NSObject

// Debug builds: the thread that set the context. Nil in a Release build.
@property(readonly) NSThread* associatedThread;

@property(readonly,retain) NSString* sqlFilePath;
@property(readonly) NSManagedObjectModel* managedObjectModel;
@property(readwrite,retain) NSManagedObjectContext* managedObjectContext; // only change this value if you know what you're doing

@property(readonly,retain) id mainDatabase; // for independentDatabases
-(BOOL)isMainDatabase;

// SDK compatibility only: -lockBeforeDate: and the locks of the CAPI category
// lock the context, for the plug-ins and callers that still pair them around
// their work. A lock does not make an access from outside the context's queue
// safe: the work itself runs inside -performBlockAndWait: (or on the main
// thread, for the UI's main-queue context).
-(BOOL)lockBeforeDate:(NSDate*) date;
// Debug builds say when a main-queue context is used off the main thread; in a
// Release build these do nothing.
-(void) checkForCorrectContextThread;
-(void) checkForCorrectContextThread: (NSManagedObjectContext*) c;

+(NSString*) modelName;
-(BOOL) deleteSQLFileIfOpeningFailed;
-(NSManagedObjectModel*)managedObjectModel;
-(BOOL)migratePersistentStoresAutomatically; // default implementation returns YES

-(id)initWithPath:(NSString*)sqlFilePath;
-(id)initWithPath:(NSString*)sqlFilePath context:(NSManagedObjectContext*)context;
-(id)initWithPath:(NSString*)sqlFilePath context:(NSManagedObjectContext*)context mainDatabase:(N2ManagedDatabase*)mainDbReference;

- (void) renewManagedObjectContext;
// Kept for plug-ins: -independentContext and -independentDatabase are
// -privateQueueIndependentContext and -privateQueueIndependentDatabase below;
// their work runs inside -performBlockAndWait:.
-(NSManagedObjectContext*)independentContext:(BOOL)independent;
-(NSManagedObjectContext*)independentContext;
-(id)independentDatabase;

// A new context on its own private queue, over this database's store
// coordinator, or nil when the database has no coordinator. It is used only
// inside its -performBlock: / -performBlockAndWait:, and only values and
// permanent object IDs leave those blocks.
-(N2ManagedObjectContext*)privateQueueContext;

// An independent context on its own private queue, over the main database's
// coordinator, whose saves are merged into the main database's context, and an
// independent database around one. The work done with them runs inside
// -performBlockAndWait:.
-(NSManagedObjectContext*)privateQueueIndependentContext;
-(id)privateQueueIndependentDatabase;

@end

// N2ManagedDatabase+Objects.swift
@interface N2ManagedDatabase (Objects)

-(NSEntityDescription*)entityForName:(NSString*)name;

-(id)objectWithID:(id)oid;
-(NSArray*)objectsWithIDs:(NSArray*)objectIDs;

// in these methods, e can be an NSEntityDescription* or an NSString*
-(NSArray*)objectsForEntity:(id)e;
-(NSArray*)objectsForEntity:(id)e predicate:(NSPredicate*)p;
-(NSArray*)objectsForEntity:(id)e predicate:(NSPredicate*)p error:(NSError**)error fetchLimit:(NSUInteger)fetchLimit sortDescriptors:(NSArray*)sortDescriptors;
-(NSUInteger)countObjectsForEntity:(id)e;
-(NSUInteger)countObjectsForEntity:(id)e predicate:(NSPredicate*)p;
-(NSUInteger)countObjectsForEntity:(id)e predicate:(NSPredicate*)p error:(NSError**)err;

-(BOOL)save;
-(BOOL)save:(NSError**)err;

@end

// N2ManagedDatabase+Store.swift
@interface N2ManagedDatabase (Protected)

- (Class)NSManagedObjectContextClass;
- (NSManagedObjectContext *)contextAtPath:(NSString *)sqlFilePath;

- (BOOL)saveDatabaseModel;

@end

// N2ManagedDatabase+CAPI.m
@interface N2ManagedDatabase (CAPI)

-(void)lock;
-(BOOL)tryLock;
-(void)unlock;

// in these methods, e can be an NSEntityDescription* or an NSString*
-(NSArray*)objectsForEntity:(id)e predicate:(NSPredicate*)p error:(NSError**)err;

// Runs block on the queue of this database's context and waits: on the
// calling thread for a private-queue context, on the main thread for the UI's
// main-queue context. An exception raised in block is raised again here, off
// the queue.
-(void)performBlockAndWait:(void (NS_NOESCAPE ^)(void))block;

// Answers an autoreleased object although its name puts it in the new family:
// without the annotation Swift and ARC would take over a +1 that is not there
// and release the object once too often.
-(id)newObjectForEntity:(id)e NS_RETURNS_NOT_RETAINED;

@end

@interface N2ManagedObjectContext : NSManagedObjectContext

@property(readonly) N2ManagedDatabase* database;

// Validation callbacks may schedule side effects only during an active save.
// Failed saves discard these actions; standalone validation has no side effects.
- (void)performAfterSuccessfulSave:(void (^)(void))action;

// Import work prepared before save. Rollback, reset, and failed saves discard it.
- (void)performAfterNextSuccessfulSave:(void (^)(void))action;
// Clean up newly prepared resources only if their changes are discarded.
- (void)performAfterDiscardingChanges:(void (^)(void))action;

@property(readonly) BOOL defersSaves;
// Requires a clean, store-backed context. Nested save calls are preparation only;
// one final save commits the block, or rollback discards the entire batch.
- (BOOL)performAtomicChanges:(BOOL (^)(NSError **error))changes error:(NSError **)error;

- (instancetype)initWithDatabase:(N2ManagedDatabase *)db concurrencyType:(NSManagedObjectContextConcurrencyType)ct NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithConcurrencyType:(NSManagedObjectContextConcurrencyType)ct NS_UNAVAILABLE;

@end

// N2ManagedDatabase+CAPI.m
@interface N2ManagedObjectContext (CAPI)

// Legacy SDK adapters retain the receiver once per successful acquisition.
// Recursive lock/tryLock calls require matching unlock calls. They do not move
// work to the context queue; internal code uses N2ManagedObjectContextPerformAndWait.
-(void)lock;
-(BOOL)tryLock;
-(void)unlock;

@end
