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

#import "Horos-Swift.h"
#import "N2ManagedDatabase.h"
#import "HorosAlertPanel.h"
#import "N2Debug.h"
#import "NSFileManager+N2.h"
#import "NSException+N2.h"
#import "DCMTKQueryNode.h"
//#import "DicomDatabase.h" // for debug purposes, REMOVE

static int gTotalN2ManagedObjectContext = 0;

@interface N2ManagedDatabase () {
    // The context's merge policy, read when the context is set, on the thread
    // that owns it: -privateQueueIndependentContext gives it to the contexts it
    // makes from other threads, without touching this one.
    id _contextMergePolicy;
}

@property(readwrite,retain) NSString* sqlFilePath;
@property(readwrite,retain) id mainDatabase;

@end

#define N2PersistentStoreCoordinator NSPersistentStoreCoordinator // for debug purposes, disable this #define and enable the commented N2PersistentStoreCoordinator implementation

// Runs block on the context's queue and waits. An exception must not unwind
// through the queue (libdispatch is not exception-safe): it is caught on the
// queue and raised again here, once the context is released. The application
// makes no confined context any more (#967); one a plug-in made itself has no
// queue, and the block runs here, on the caller's thread, which is what that
// context allows - said in Debug, since the caller is then the one to make
// sure no other thread uses it.
void N2ManagedObjectContextPerformAndWait(NSManagedObjectContext *context, void (NS_NOESCAPE ^block)(void))
{
    if (!context) {
        block();
        return;
    }
    NSManagedObjectContextConcurrencyType type = context.concurrencyType;
    // Only these two current types own a queue; preserve the legacy fallback.
    if (type != NSMainQueueConcurrencyType && type != NSPrivateQueueConcurrencyType) {
#ifndef NDEBUG
        N2LogStackTrace(@"--- warning: %@ is a confined context, which has no queue: the block runs on this thread", context);
#endif
        block();
        return;
    }
#ifndef NDEBUG
    // The UI context from another thread waits for the main thread: say who,
    // so that the caller moves to a context of its own (#966).
    if (context.concurrencyType == NSMainQueueConcurrencyType && ![NSThread isMainThread])
        N2LogStackTrace(@"--- warning: the main-queue context %@ is used off the main thread", context);
#endif
    __block id exception = nil;
    [context retain];
    @try {
        [context performBlockAndWait:^{
            @try { block(); }
            @catch (id e) { exception = [e retain]; }
        }];
    } @finally {
        [context release];
    }
    if (exception)
        @throw [exception autorelease];
}

// The type of a database's own context: the UI's, on the main queue, when it
// is made on the main thread; a private queue otherwise (#966).
static NSManagedObjectContextConcurrencyType N2DatabaseContextConcurrencyType(void)
{
    return [NSThread isMainThread] ? NSMainQueueConcurrencyType : NSPrivateQueueConcurrencyType;
}

@implementation N2ManagedObjectContext

@synthesize database = _database;

- (id)initWithDatabase:(N2ManagedDatabase *)db concurrencyType:(NSManagedObjectContextConcurrencyType)ct
{
    if (!(self = [super initWithConcurrencyType:ct]))
        return nil;
    
    _database = db;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(N2ManagedDatabaseDealloced:) name:@"N2ManagedDatabaseDealloced" object:db];
    
#ifndef NDEBUG
    gTotalN2ManagedObjectContext++;
    
    if( gTotalN2ManagedObjectContext > 10)
        NSLog( @"-- gTotalN2ManagedObjectContext = %d", gTotalN2ManagedObjectContext);
#endif
    
    return self;
}

-(void)N2ManagedDatabaseDealloced:(NSNotification*) n
{
    if( n.object != _database)
        N2LogStackTrace( @"******* N2ManagedDatabaseDealloced");
    _database = nil;
}

-(void)dealloc {
#ifndef NDEBUG
    [_database checkForCorrectContextThread: self];
    
    gTotalN2ManagedObjectContext--;
#endif
    
    [NSNotificationCenter.defaultCenter removeObserver:self];
    // The database that merged this context's saves stops observing it.
    if (_database)
        [NSNotificationCenter.defaultCenter removeObserver:_database name:NSManagedObjectContextDidSaveNotification object:self];

    [_nextSuccessfulSaveActions release];
    _nextSuccessfulSaveActions = nil;
    // Do not enqueue a block capturing self during dealloc: copying that block
    // would retain/resurrect the receiver. Remaining discard actions own only
    // resource cleanup and must not access the dying context.
    [self runDiscardedChangesActions];
    _database = nil;
	
    [super dealloc]; //test if db is deallocated
}

- (void)performAfterSuccessfulSave:(void (^)(void))action {
    if (_afterSuccessfulSaveActions && action)
        [_afterSuccessfulSaveActions addObject:[[action copy] autorelease]];
}

- (void)performAfterNextSuccessfulSave:(void (^)(void))action {
    if (!action) return;
    if (!_nextSuccessfulSaveActions)
        _nextSuccessfulSaveActions = [[NSMutableArray alloc] init];
    [_nextSuccessfulSaveActions addObject:[[action copy] autorelease]];
}

- (void)performAfterDiscardingChanges:(void (^)(void))action {
    if (!action) return;
    if (!_discardedChangesActions) _discardedChangesActions = [[NSMutableArray alloc] init];
    [_discardedChangesActions addObject:[[action copy] autorelease]];
}

- (void)runDiscardedChangesActions {
    NSArray *actions = [_discardedChangesActions autorelease];
    _discardedChangesActions = nil;
    for (void (^action)(void) in actions) {
        @try { action(); }
        @catch (NSException *exception) { NSLog(@"Discard action failed: %@", exception.name); }
    }
}

- (BOOL)defersSaves { return _defersSaves; }

- (BOOL)performAtomicChanges:(BOOL (^)(NSError **error))changes error:(NSError **)error {
    // The whole batch - the changes, the save or the rollback and what they
    // run - on the context's queue. The error is kept on the queue and handed
    // back here.
    __block BOOL committed = NO;
    __block NSError *queueError = nil;
    N2ManagedObjectContextPerformAndWait(self, ^{
        NSError *failure = nil;
        committed = [self _performAtomicChanges:changes error:&failure];
        queueError = [failure retain];
    });
    if (error) *error = [queueError autorelease];
    else [queueError release];
    return committed;
}

- (BOOL)_performAtomicChanges:(BOOL (^)(NSError **error))changes error:(NSError **)error {
    // Called only by the queue-isolated public transaction entry point.
    {
        if (!changes || _defersSaves || self.hasChanges || self.parentContext || !self.persistentStoreCoordinator.persistentStores.count || _nextSuccessfulSaveActions.count || _discardedChangesActions.count) {
            if (error) *error = [NSError errorWithDomain:@"N2AtomicChanges" code:1 userInfo:
                @{NSLocalizedDescriptionKey: @"Atomic changes require a clean, independent store context."}];
            return NO;
        }
        _defersSaves = YES;
        _atomicChangesCancelled = NO;
        @try {
            NSError *operationError = nil;
            BOOL ready = changes(&operationError) && !_atomicChangesCancelled;
            _defersSaves = NO;
            BOOL committed = ready && [self save:&operationError];
            if (!committed) {
                [self rollback];
                if (error) *error = operationError ?: [NSError errorWithDomain:@"N2AtomicChanges" code:2 userInfo:
                    @{NSLocalizedDescriptionKey: @"The prepared changes were not committed."}];
            }
            return committed;
        } @catch (...) {
            _defersSaves = NO;
            [self rollback];
            @throw;
        } @finally {
            _defersSaves = NO;
            _atomicChangesCancelled = NO;
        }
    }
}

// On a queue context, rollback, reset and save - with the actions they run -
// happen on its queue, whichever thread asks.

- (void)rollback {
    N2ManagedObjectContextPerformAndWait(self, ^{
        if (_defersSaves) _atomicChangesCancelled = YES;
        [_nextSuccessfulSaveActions release];
        _nextSuccessfulSaveActions = nil;
        [super rollback];
        [self runDiscardedChangesActions];
    });
}

- (void)reset {
    N2ManagedObjectContextPerformAndWait(self, ^{
        if (_defersSaves) _atomicChangesCancelled = YES;
        [_nextSuccessfulSaveActions release];
        _nextSuccessfulSaveActions = nil;
        [super reset];
        [self runDiscardedChangesActions];
    });
}

-(BOOL)save:(NSError**)error {
    __block BOOL saved = NO;
    __block NSError *queueError = nil;
    N2ManagedObjectContextPerformAndWait(self, ^{
        NSError *failure = nil;
        saved = [self _save:&failure];
        queueError = [failure retain];
    });
    if (error) *error = [queueError autorelease];
    else [queueError release];
    return saved;
}

-(BOOL)_save:(NSError**)error {
    if (_defersSaves) return !_atomicChangesCancelled;
    // The public save entry point already owns the context queue.
#ifndef NDEBUG
    [_database checkForCorrectContextThread: self];
#endif
    NSMutableArray *previousActions = _afterSuccessfulSaveActions;
    _afterSuccessfulSaveActions = _nextSuccessfulSaveActions ?: [[NSMutableArray alloc] init];
    _nextSuccessfulSaveActions = nil;
    @try {
        BOOL saved = [super save:error];
        if (saved) {
            [_discardedChangesActions release];
            _discardedChangesActions = nil;
            // Stop accepting work before executing callbacks. A callback may save
            // again; its actions belong to that new save, not this iteration.
            NSArray *actions = [[_afterSuccessfulSaveActions copy] autorelease];
            [_afterSuccessfulSaveActions release];
            _afterSuccessfulSaveActions = nil;
            for (void (^action)(void) in actions) {
                @try { action(); }
                @catch (NSException *exception) {
                    NSLog(@"Post-save action failed: %@", exception.name);
                }
            }
        }
        return saved;
    } @finally {
        [_afterSuccessfulSaveActions release];
        _afterSuccessfulSaveActions = previousActions;
    }
}

-(NSManagedObject*)existingObjectWithID:(NSManagedObjectID*)objectID error:(NSError**)error {
    __block NSManagedObject *object = nil;
    __block NSError *queueError = nil;
    N2ManagedObjectContextPerformAndWait(self, ^{
        NSError *failure = nil;
        // Kept past the pool the queue drains, like the error.
        object = [[super existingObjectWithID:objectID error:&failure] retain];
        queueError = [failure retain];
    });
    if (error) *error = [queueError autorelease];
    else [queueError release];
    return [object autorelease];
}

// SDK compatibility only. These recursive legacy locks do not enter the
// context queue. Internal callers must isolate their entire operation with
// N2ManagedObjectContextPerformAndWait. Each successful acquisition owns one
// retain until unlock; an exception or a failed tryLock owns none.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
-(void)lock {
    [self retain];
    @try { [super lock]; }
    @catch (...) { [self release]; @throw; }
}

-(BOOL)tryLock {
    [self retain];
    BOOL acquired = NO;
    @try { acquired = [super tryLock]; }
    @catch (...) { [self release]; @throw; }
    if (!acquired) [self release];
    return acquired;
}

-(void)unlock {
    [super unlock];
    // Keep the receiver alive through the caller's current autorelease pool.
    [self autorelease];
}
#pragma clang diagnostic pop

- (NSArray *)executeFetchRequest:(NSFetchRequest *)request error:(NSError **)error
{
#ifndef NDEBUG
    [_database checkForCorrectContextThread: self];
#endif
    __block NSArray *result = nil;
    __block NSError *queueError = nil;
    N2ManagedObjectContextPerformAndWait(self, ^{
        NSError *failure = nil;
        result = [[super executeFetchRequest: request error: &failure] retain];
        queueError = [failure retain];
    });
    if (error) *error = [queueError autorelease];
    else [queueError release];
    return [result autorelease];
}

- (NSUInteger)countForFetchRequest:(NSFetchRequest *)request error:(NSError **)error
{
#ifndef NDEBUG
    [_database checkForCorrectContextThread: self];
#endif
    __block NSUInteger count = 0;
    __block NSError *queueError = nil;
    N2ManagedObjectContextPerformAndWait(self, ^{
        NSError *failure = nil;
        count = [super countForFetchRequest: request error: &failure];
        queueError = [failure retain];
    });
    if (error) *error = [queueError autorelease];
    else [queueError release];
    return count;
}

#ifndef NDEBUG

- (void)deleteObject:(NSManagedObject *)object
{
    [_database checkForCorrectContextThread: self];
    
	return [super deleteObject: object];
}
- (NSManagedObject *)objectWithID:(NSManagedObjectID *)objectID
{
    [_database checkForCorrectContextThread: self];
    
    return [super objectWithID: objectID];
}
- (void)mergeChangesFromContextDidSaveNotification:(NSNotification *)notification
{
    [_database checkForCorrectContextThread: self];
    
    return [super mergeChangesFromContextDidSaveNotification: notification];
}
#endif

@end


@implementation N2ManagedDatabase
#ifndef NDEBUG
@synthesize associatedThread;
#endif
@synthesize sqlFilePath = _sqlFilePath;
@synthesize managedObjectContext = _managedObjectContext;
@synthesize mainDatabase = _mainDatabase;

#ifndef NDEBUG
-(void) checkForCorrectContextThread
{
    [self checkForCorrectContextThread: _managedObjectContext];
}

-(void) checkForCorrectContextThread: (NSManagedObjectContext*) c
{
    // By queue, not by thread (#967): a private-queue context is entered from
    // any thread by -performBlockAndWait:, and a main-queue one belongs to the
    // main thread.
    if (c.concurrencyType == NSMainQueueConcurrencyType && ![NSThread isMainThread])
        N2LogStackTrace( @"--- warning : the main-queue context of %@ is used off the main thread (%@)", _sqlFilePath, [[NSThread currentThread] name]);
}
#endif

-(BOOL)isMainDatabase {
    return (_mainDatabase == nil);
}

-(NSManagedObjectContext*)managedObjectContext {
	return _managedObjectContext;
}

-(void)setManagedObjectContext:(NSManagedObjectContext*)managedObjectContext {
	if (managedObjectContext != _managedObjectContext) {
        [self willChangeValueForKey:@"managedObjectContext"];
        
        [_managedObjectContext autorelease];
		_managedObjectContext = [managedObjectContext retain];
        [_contextMergePolicy release];
        _contextMergePolicy = nil;
        if (self.isMainDatabase && managedObjectContext) {
            __block id policy = nil;
            N2ManagedObjectContextPerformAndWait(managedObjectContext, ^{ policy = [managedObjectContext.mergePolicy retain]; });
            _contextMergePolicy = policy;
        }
        
#ifndef NDEBUG
        [associatedThread release];
        associatedThread = [[NSThread currentThread] retain];
#endif
        
        [self didChangeValueForKey:@"managedObjectContext"];
    }
}

+(NSString*)modelName {
	[NSException raise:NSGenericException format:@"[class modelName] must be defined"];
	return NULL;
}

-(BOOL) deleteSQLFileIfOpeningFailed
{
    return NO;
}

-(NSManagedObjectModel*)managedObjectModel {
	[NSException raise:NSGenericException format:@"[%@ managedObjectModel] must be defined", self.className];
	return NULL;
}

/*-(NSMutableDictionary*)persistentStoreCoordinatorsDictionary {
	static NSMutableDictionary* dict = NULL;
	if (!dict)
		dict = [[NSMutableDictionary alloc] initWithCapacity:4];
	return dict;
}*/

-(BOOL)migratePersistentStoresAutomatically {
	return YES;
}

- (void) renewManagedObjectContext
{
    NSPersistentStoreCoordinator *coordinator = self.managedObjectContext.persistentStoreCoordinator;
    if (self.isMainDatabase && coordinator)
    {
        // A fresh context on the same store, in the role of the one it replaces:
        // the UI's, on the main queue, when renewed on the main thread (#966).
        N2ManagedObjectContext *moc = [[[self.NSManagedObjectContextClass alloc] initWithDatabase:self concurrencyType:N2DatabaseContextConcurrencyType()] autorelease];
        moc.undoManager = nil;
        moc.persistentStoreCoordinator = coordinator;
        if (_contextMergePolicy)
            moc.mergePolicy = _contextMergePolicy;
        self.managedObjectContext = moc;
        return;
    }
    self.managedObjectContext = self.isMainDatabase? [self contextAtPath: self.sqlFilePath] : [self.mainDatabase contextAtPath: self.sqlFilePath];
}

- (Class)NSManagedObjectContextClass {
    return N2ManagedObjectContext.class;
}

- (NSManagedObjectContext *)contextAtPath:(NSString *)sqlFilePath {
	sqlFilePath = sqlFilePath.stringByExpandingTildeInPath;
	
    if( sqlFilePath.length == 0)
        return nil;
    
    // The database's own context is the UI's when it is made on the main
    // thread, on the main queue, and has a private queue otherwise (#966); an
    // independent one, over this database's coordinator, has a private queue
    // (#967).
    BOOL independent = self.managedObjectContext.persistentStoreCoordinator && [sqlFilePath isEqualToString:self.sqlFilePath] && [NSFileManager.defaultManager fileExistsAtPath:sqlFilePath];
    NSManagedObjectContextConcurrencyType type = independent ? NSPrivateQueueConcurrencyType : N2DatabaseContextConcurrencyType();
    N2ManagedObjectContext *moc = [[[self.NSManagedObjectContextClass alloc] initWithDatabase:self concurrencyType:type] autorelease];
    //	NSLog(@"---------- NEW %@ at %@", moc, sqlFilePath);
	moc.undoManager = nil;
	
    //	NSMutableDictionary* persistentStoreCoordinatorsDictionary = self.persistentStoreCoordinatorsDictionary;
	
    @try {
        @synchronized (self) {
    //        if (self.managedObjectContext.hasChanges)
    //            [self save];
            
            if ([sqlFilePath isEqualToString:self.sqlFilePath] && [NSFileManager.defaultManager fileExistsAtPath:sqlFilePath]) {
                moc.persistentStoreCoordinator = self.managedObjectContext.persistentStoreCoordinator;
            }
            
            if (!moc.persistentStoreCoordinator) {
                //			moc.persistentStoreCoordinator = [persistentStoreCoordinatorsDictionary objectForKey:sqlFilePath];
                
                BOOL isNewFile = ![NSFileManager.defaultManager fileExistsAtPath:sqlFilePath];
                if (isNewFile)
                {
                    [[NSFileManager defaultManager] confirmDirectoryAtPath:[sqlFilePath stringByDeletingLastPathComponent]];
                    moc.persistentStoreCoordinator = nil;
                }
                
                if (!moc.persistentStoreCoordinator)
                {
                    NSString *localModelsPath = [[sqlFilePath stringByDeletingPathExtension] stringByAppendingPathExtension: @"momd"];
                    NSManagedObjectModel *models = self.managedObjectModel;
                    
                    if ([[NSFileManager defaultManager] fileExistsAtPath:localModelsPath]) @try {
                        NSManagedObjectModel *localModels = [[[NSManagedObjectModel alloc] initWithContentsOfURL: [NSURL fileURLWithPath: localModelsPath]] autorelease]; //Forward compatibility !
                        models = [NSManagedObjectModel modelByMergingModels: [NSArray arrayWithObjects: self.managedObjectModel, localModels, nil]]; //warning localModels can be nil: put it at last position
                    } @catch (NSException *exception) {
                        models = self.managedObjectModel;
                    }
                    
                    // The store is added before the coordinator is given to the context.
                    // Added to the coordinator of a main-queue context, it leaves
                    // Core Data a block on the main queue for that context; the
                    // browser releases the default database's first context in
                    // the turn that made it, and the block then crashed in
                    // CFRelease once the queue drained (#966).
                    NSPersistentStoreCoordinator* persistentStoreCoordinator = [[[N2PersistentStoreCoordinator alloc] initWithManagedObjectModel: models] autorelease];
                    
                    //[persistentStoreCoordinatorsDictionary setObject:persistentStoreCoordinator forKey:sqlFilePath];
                    
                    NSPersistentStore* pStore = nil;
                    NSString *reportedDiagnosis = nil, *reportedKeptIndex = nil;
                    NSInteger reportedRecoverableFiles = -1;
                    int i = 0;
                    do { // try 2 times
                        ++i;
                        
                        NSError* err = nil;
                        NSDictionary* options = @{ NSInferMappingModelAutomaticallyOption: @YES,
                                                   NSMigratePersistentStoresAutomaticallyOption: @([self migratePersistentStoresAutomatically]),
                                                   NSSQLitePragmasOption: @{ @"journal_mode": @"delete" } };
                        NSURL* url = [NSURL fileURLWithPath:sqlFilePath];
                        @try {
                            pStore = [persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:url options:options error:&err];
                            
                        } @catch (...) {
                        }
                        
                        if (!pStore && i == 1)
                        {
                            // The index holds the studies, the albums, the
                            // comments and the ROIs; the images are files beside
                            // it. Deleting it - which is what used to happen
                            // here, on the first failed attempt, whether or not
                            // anyone agreed and with no answer to why it would
                            // not open - loses everything that is not in a file.
                            NSString *diagnosis = [HorosIndexRecovery diagnosisForError: err path: sqlFilePath];
                            NSInteger recoverable = [HorosIndexRecovery recoverableFileCountBesideIndexAtPath: sqlFilePath];
                            NSLog(@"Error: [N2ManagedDatabase contextAtPath:] %@", [err description]);
                            NSLog(@"---- index: %@", diagnosis);
                            if( recoverable >= 0)
                                NSLog(@"---- index: %ld files are in the image folder beside it and can be indexed again", (long) recoverable);
                            
                            NSString *kept = nil;
                            BOOL setAside = self.deleteSQLFileIfOpeningFailed && [HorosIndexRecovery indexCanBeSetAsideForError: err];
                            
                            if (setAside)
                            {
                                NSString *preserved = [HorosIndexRecovery preservedPathForIndexAtPath: sqlFilePath];
                                NSError *moveError = nil;
                                if ([NSFileManager.defaultManager moveItemAtPath:sqlFilePath toPath:preserved error:&moveError])
                                {
                                    kept = preserved;
                                    NSLog(@"---- index: kept as %@; a new index will be created", [preserved lastPathComponent]);
                                    i = 0; // try again, on the new index
                                }
                                else
                                    NSLog(@"---- index: could not be set aside (%@); it is left exactly as it is", moveError.localizedDescription);
                            }
                            else if (self.deleteSQLFileIfOpeningFailed)
                                NSLog(@"---- index: left exactly as it is - this is not a damaged file, and replacing it would destroy a database that is intact");
                            
                            reportedDiagnosis = [diagnosis retain];
                            reportedKeptIndex = [kept retain];
                            reportedRecoverableFiles = recoverable;
                        }
                    } while (!pStore && i < 2);
                    moc.persistentStoreCoordinator = persistentStoreCoordinator;
                    
                    // Said after the recovery rather than instead of it: the file
                    // has already been dealt with without destroying anything, so
                    // there is nothing to ask and nothing to hold up the launch
                    // for. It is still worth saying, because a database that
                    // opens empty otherwise looks like one that was erased.
                    if (reportedDiagnosis && [NSThread isMainThread])
                    {
                        NSString *outcome = reportedKeptIndex
                            ? [NSString stringWithFormat: NSLocalizedString(@"It has been kept as %@, and a new index was created. The %ld files in the image folder can be indexed again with Rebuild Database.", nil), [reportedKeptIndex lastPathComponent], (long) reportedRecoverableFiles]
                            : NSLocalizedString(@"The file has not been touched. Once the cause is gone it will open as it is.", nil);
                        HorosRunCriticalAlertPanel( [NSString stringWithFormat:NSLocalizedString(@"%@ Storage Error", nil), [self className]], @"%@\r\r%@\r\r%@", NSLocalizedString(@"Continue", nil), nil, nil, reportedDiagnosis, sqlFilePath, outcome);
                    }
                    [reportedDiagnosis release];
                    [reportedKeptIndex release];
                    
                    // Save the models for forward compatibility with old OsiriX versions that don't know the current model
                    if (self.saveDatabaseModel){
                        NSString *modelsPath = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent: [[self class] modelName]];
                        [[NSFileManager defaultManager] removeItemAtPath: localModelsPath error: nil];
                        [[NSFileManager defaultManager] copyItemAtPath:modelsPath toPath:localModelsPath error:nil];
                    }

                }
                
                if (isNewFile) {
                    [moc save:NULL];
//                    NSLog(@"New database file created at %@", sqlFilePath);
                }
                
            } else {
                if (self.mainDatabase)
                    N2LogStackTrace(@"****************************: creating independent context from already independent database");
                
                // Our main DicomDatabase context will listen to changes from the independentContext
                // Warning: our independentContext will NOT receive changes from the main DicomDatabase context: add it by yourself if needed (see WebPortalConnection.mm)
                [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(mergeChangesFromContextDidSaveNotification:) name:NSManagedObjectContextDidSaveNotification object:moc];
            }
            
        }
    }
    @catch (NSException *exception) {
        moc = nil;
    }
    
    return moc;
}

- (BOOL)saveDatabaseModel {
    return YES;
}

-(void)mergeChangesFromContextDidSaveNotification:(NSNotification*)n {
    NSManagedObjectContext* moc = [n object];
    
    if (self.managedObjectContext.persistentStoreCoordinator != moc.persistentStoreCoordinator)
        return;
    
    if (self.managedObjectContext == moc)
        return;
    
    if (![NSThread isMainThread])
    {
        [self performSelectorOnMainThread:@selector(mergeChangesFromContextDidSaveNotification:) withObject:n waitUntilDone:NO];
    }
    else
    {
        // On the main thread, and on the queue of the context that merges (#966).
        NSManagedObjectContext *context = self.managedObjectContext;
        @try {
            N2ManagedObjectContextPerformAndWait(context, ^{
                [context mergeChangesFromContextDidSaveNotification:n];
            });
        } @catch (NSException* e) {
            N2LogExceptionWithStackTrace(e);
        }
    }
}

// Published database compatibility adapters; never used by internal queue work.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
-(BOOL)lockBeforeDate:(NSDate*) date
{
    while( [[NSDate date] laterDate: date] == date)
    {
        if( [self tryLock])
            return YES;
        [NSThread sleepForTimeInterval: 0.1];
    }
    return NO;
}

-(void)lock {
	[self.managedObjectContext lock];
}

-(BOOL)tryLock {
	return [self.managedObjectContext tryLock];
}

-(void)unlock {
	[self.managedObjectContext unlock];
}

#pragma clang diagnostic pop

-(id)initWithPath:(NSString*)p {
	return [self initWithPath:p context:nil mainDatabase:nil];
}

-(id)initWithPath:(NSString*)p context:(NSManagedObjectContext*)c {
    return [self initWithPath:p context:c mainDatabase:nil];
}

-(id)initWithPath:(NSString*)p context:(NSManagedObjectContext*)c mainDatabase:(N2ManagedDatabase*)mainDbReference {
	self = [super init];
	
	self.sqlFilePath = p;
    self.mainDatabase = mainDbReference;
	
//#ifndef NDEBUG
//    if( [NSThread isMainThread] == NO && mainDbReference == nil)
//        NSLog( @"****** WARNING - Creating a MAIN database, NOT on the MAIN thread... Be aware that this managedObjectContext could be later used on the MAIN thread, unless you renewManagedObjectContext on the main thread.");
//#endif
    
	self.managedObjectContext = c? c : [self contextAtPath:p];
    
	return self;
}

-(void)dealloc {
    // this should fix dealloc cycles
    if (_isDeallocating)
        return;
    _isDeallocating = YES;
    
#ifndef NDEBUG
    [associatedThread release];
    associatedThread = nil;
#endif
    
    [NSNotificationCenter.defaultCenter postNotificationName: @"N2ManagedDatabaseDealloced" object:self];
    
    [NSNotificationCenter.defaultCenter removeObserver:self];
    
    // Asked on the context's queue: a private-queue context is not ours to read here.
    __block BOOL hasChanges = NO;
    NSManagedObjectContext *context = self.managedObjectContext;
    N2ManagedObjectContextPerformAndWait(context, ^{ hasChanges = context.hasChanges; });
    if (hasChanges && [NSFileManager.defaultManager fileExistsAtPath:[self.sqlFilePath stringByDeletingLastPathComponent]])
        [self save];
    
    if (self.mainDatabase)
        [NSNotificationCenter.defaultCenter removeObserver:self.mainDatabase name:NSManagedObjectContextDidSaveNotification object:self];
    
    self.mainDatabase = nil;
	self.managedObjectContext = nil;
	self.sqlFilePath = nil;
    [_contextMergePolicy release];
    _contextMergePolicy = nil;
    
	[super dealloc];
}

// The selectors plug-ins call: the private-queue independent context and
// database, whose work runs inside -performBlockAndWait: (#967).
- (NSManagedObjectContext *)independentContext:(BOOL)independent {
    if (!independent)
        return self.managedObjectContext;
    return [self privateQueueIndependentContext];
}

- (NSManagedObjectContext *)independentContext {
	return [self independentContext:YES];
}

- (id)independentDatabase {
	return [self privateQueueIndependentDatabase];
}

- (NSManagedObjectContext *)privateQueueIndependentContext {
    // Like -contextAtPath: for an independent context: the coordinator and the
    // merge policy are the main database's.
    N2ManagedDatabase *main = self.isMainDatabase ? self : self.mainDatabase;
    N2ManagedObjectContext *mainContext = (N2ManagedObjectContext *)main.managedObjectContext;
    NSPersistentStoreCoordinator *coordinator = mainContext.persistentStoreCoordinator;
    if (!coordinator)
        return nil;
    
    N2ManagedObjectContext *context = [[[main.NSManagedObjectContextClass alloc] initWithDatabase:main concurrencyType:NSPrivateQueueConcurrencyType] autorelease];
    context.undoManager = nil;
    context.persistentStoreCoordinator = coordinator;
    if (main->_contextMergePolicy)
        context.mergePolicy = main->_contextMergePolicy;
    
    // The main database's context merges what this one saves.
    [NSNotificationCenter.defaultCenter addObserver:main selector:@selector(mergeChangesFromContextDidSaveNotification:) name:NSManagedObjectContextDidSaveNotification object:context];
    return context;
}

- (id)privateQueueIndependentDatabase {
    N2ManagedDatabase *main = self.isMainDatabase ? self : self.mainDatabase;
    NSManagedObjectContext *context = [self privateQueueIndependentContext];
    if (!context)
        return nil;
    return [[[[main class] alloc] initWithPath:main.sqlFilePath context:context mainDatabase:main] autorelease];
}

- (void)performBlockAndWait:(void (NS_NOESCAPE ^)(void))block {
    N2ManagedObjectContextPerformAndWait(self.managedObjectContext, block);
}

- (N2ManagedObjectContext *)privateQueueContext {
    NSPersistentStoreCoordinator *coordinator = self.managedObjectContext.persistentStoreCoordinator;
    if (!coordinator)
        return nil;
    
    // Set up before its first use, which Core Data allows from any thread.
    N2ManagedObjectContext *context = [[[self.NSManagedObjectContextClass alloc] initWithDatabase:self concurrencyType:NSPrivateQueueConcurrencyType] autorelease];
    context.undoManager = nil;
    context.persistentStoreCoordinator = coordinator;
    return context;
}

-(id)objectWithID:(id)oid {
    NSManagedObjectContext *context = self.managedObjectContext;
    __block id result = nil;
    // Resolve an input managed object's ID on its own context, before entering
    // the destination queue (the object may belong to another database).
    @try {
    if ([oid isKindOfClass:[NSManagedObject class]]) {
        NSManagedObject *object = oid;
        __block NSManagedObjectID *objectID = nil;
        N2ManagedObjectContextPerformAndWait(object.managedObjectContext, ^{ objectID = [object.objectID retain]; });
        oid = [objectID autorelease];
    }
        N2ManagedObjectContextPerformAndWait(context, ^{
            id objectID = oid;
#ifndef OSIRIX_LIGHT
            if ([objectID isKindOfClass:[DCMTKQueryNode class]]) {
                result = [objectID retain];
                return;
            }
#endif
            if ([objectID isKindOfClass:[NSURL class]])
                objectID = [context.persistentStoreCoordinator managedObjectIDForURIRepresentation:objectID];
            else if ([objectID isKindOfClass:[NSString class]])
                objectID = [context.persistentStoreCoordinator managedObjectIDForURIRepresentation:[NSURL URLWithString:objectID]];
            result = [[context existingObjectWithID:objectID error:NULL] retain];
        });
    } @catch (...) {
        // Invalid or missing IDs historically return nil.
    }
    return [result autorelease];
}

-(NSArray*)objectsWithIDs:(NSArray*)objectIDs {
    // Resolve source object IDs before entering the destination queue, so that
    // no destination-queue block synchronously enters an unrelated context.
    NSMutableArray *identifiers = [NSMutableArray arrayWithCapacity:objectIDs.count];
    for (id oid in objectIDs) {
        @try {
            if ([oid isKindOfClass:NSManagedObject.class]) {
                NSManagedObject *object = oid;
                __block NSManagedObjectID *identifier = nil;
                N2ManagedObjectContextPerformAndWait(object.managedObjectContext, ^{ identifier = [object.objectID retain]; });
                oid = [identifier autorelease];
            }
            if (oid) [identifiers addObject:oid];
        } @catch (...) {
            // Continue resolving the remaining IDs.
        }
    }
    __block NSMutableArray *result = nil;
    N2ManagedObjectContextPerformAndWait(self.managedObjectContext, ^{
        result = [[NSMutableArray alloc] initWithCapacity:identifiers.count];
        for (id oid in identifiers) {
            id object = [self objectWithID:oid];
            if (object) [result addObject:object];
        }
    });
    return [result autorelease];
}

-(NSEntityDescription*)entityForName:(NSString*)name {
    NSManagedObjectContext *context = self.managedObjectContext;
    __block NSEntityDescription *entity = nil;
    N2ManagedObjectContextPerformAndWait(context, ^{
        entity = [[NSEntityDescription entityForName:name inManagedObjectContext:context] retain];
    });
    return [entity autorelease];
}

-(NSEntityDescription*)_entity:(id*)entity {
    if ([*entity isKindOfClass:[NSString class]])
        *entity = [self entityForName:*entity];
    return *entity;
}

-(NSArray*)objectsForEntity:(id)e {
	return [self objectsForEntity:e predicate:nil error:NULL];
}

-(NSArray*)objectsForEntity:(id)e predicate:(NSPredicate*)p {
	return [self objectsForEntity:e predicate:p error:NULL];
}

-(NSArray*)objectsForEntity:(id)e predicate:(NSPredicate*)p error:(NSError**)error {
    return [self objectsForEntity:e predicate:p error:error fetchLimit:0 sortDescriptors:nil];
}

-(NSArray*)objectsForEntity:(id)e predicate:(NSPredicate*)p error:(NSError**)error fetchLimit:(NSUInteger)fetchLimit sortDescriptors:(NSArray*)sortDescriptors {
    NSManagedObjectContext *context = self.managedObjectContext;
    __block NSArray *result = nil;
    __block NSError *queueError = nil;
    @try {
        N2ManagedObjectContextPerformAndWait(context, ^{
            NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
            request.entity = [e isKindOfClass:NSString.class] ? [self entityForName:e] : e;
            request.predicate = p ?: [NSPredicate predicateWithValue:YES];
            request.sortDescriptors = sortDescriptors;
            request.fetchLimit = fetchLimit;
            NSError *failure = nil;
            result = [[context executeFetchRequest:request error:&failure] retain];
            queueError = [failure retain];
        });
    } @catch (NSException *exception) {
        if (error && !queueError)
            queueError = [[NSError errorWithDomain:N2ErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Core Data fetch failed."}] retain];
        else N2LogException(exception);
    }
    if (error) *error = [queueError autorelease];
    else [queueError release];
    return [result autorelease];
}

-(NSUInteger)countObjectsForEntity:(id)e {
    return [self countObjectsForEntity:e predicate:nil error:NULL];
}

-(NSUInteger)countObjectsForEntity:(id)e predicate:(NSPredicate*)p {
    return [self countObjectsForEntity:e predicate:p error:NULL];
}

-(NSUInteger)countObjectsForEntity:(id)e predicate:(NSPredicate*)p error:(NSError**)error {
    NSManagedObjectContext *context = self.managedObjectContext;
    __block NSUInteger count = 0;
    __block NSError *queueError = nil;
    @try {
        N2ManagedObjectContextPerformAndWait(context, ^{
            NSFetchRequest *request = [[[NSFetchRequest alloc] init] autorelease];
            request.entity = [e isKindOfClass:NSString.class] ? [self entityForName:e] : e;
            request.predicate = p ?: [NSPredicate predicateWithValue:YES];
            NSError *failure = nil;
            count = [context countForFetchRequest:request error:&failure];
            queueError = [failure retain];
        });
    } @catch (NSException *exception) {
        if (error && !queueError)
            queueError = [[NSError errorWithDomain:N2ErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Core Data count failed."}] retain];
        else N2LogException(exception);
    }
    if (error) *error = [queueError autorelease];
    else [queueError release];
    return count;
}

-(id)newObjectForEntity:(id)entity {
    NSManagedObjectContext *context = self.managedObjectContext;
    __block id object = nil;
    N2ManagedObjectContextPerformAndWait(context, ^{
        NSString *name = [entity isKindOfClass:NSString.class] ? entity : [entity name];
        object = [[NSEntityDescription insertNewObjectForEntityForName:name inManagedObjectContext:context] retain];
    });
    return [object autorelease];
}

-(BOOL)save {
    return [self save:NULL];
}

-(BOOL)save:(NSError**)error {
    __block BOOL saved = NO;
    __block NSError *queueError = nil;
    NSManagedObjectContext *context = self.managedObjectContext;
    // dealloc also calls save:; do not capture/retain the deallocating database.
    @try {
        N2ManagedObjectContextPerformAndWait(context, ^{
            NSError *failure = nil;
            saved = [context save:&failure];
            queueError = [failure retain];
        });
    } @catch (NSException *exception) {
        if (!queueError)
            queueError = [[NSError errorWithDomain:N2ErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Core Data save failed."}] retain];
        else N2LogException(exception);
    }
    if (error) *error = [queueError autorelease];
    else [queueError release];
    return saved;
}


@end
