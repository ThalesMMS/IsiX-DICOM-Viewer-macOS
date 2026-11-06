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

// What N2ManagedDatabase and N2ManagedObjectContext, implemented in Swift
// (N2ManagedDatabase.swift, N2ManagedObjectContext.swift), keep in
// Objective-C:
//
// - N2ManagedObjectContextPerformAndWait, a C function that Objective-C(++)
//   files, Swift and plug-ins call. It catches on the context's queue the
//   exception the block raised and raises it again here, off the queue: Swift
//   can neither catch an Objective-C exception nor raise one across its frames.
// - The legacy -lock, -tryLock and -unlock of the context and of the database:
//   NSManagedObjectContext's are deprecated since macOS 10.10, and Swift cannot
//   silence a deprecation warning.
// - -[N2ManagedDatabase newObjectForEntity:], a selector of the new family whose
//   declaration says NS_RETURNS_NOT_RETAINED: a Swift implementation returns +1
//   whatever the declaration says.
// - -[N2ManagedObjectContext countForFetchRequest:error:], which answers
//   NSNotFound with its error: Swift cannot override a method that both returns
//   an integer and reports an error.
// - -[N2ManagedDatabase objectsForEntity:predicate:error:]: its name without the
//   error is another method, so Swift imports it as a throwing method with a
//   placeholder error: () argument, which Swift cannot implement.
// - -[N2ManagedDatabase performBlockAndWait:], whose block is non-escaping and
//   has no nullability: Swift imports it as an optional non-escaping closure,
//   which it cannot declare.

#import "N2ManagedDatabase.h"
#import "N2Debug.h"

// Runs block on the context's queue and waits. An exception must not unwind
// through the queue (libdispatch is not exception-safe): it is caught on the
// queue and raised again here, once the context is released. The application
// makes no confined context any more; one a plug-in made itself has no
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
    // so that the caller moves to a context of its own.
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

@implementation N2ManagedObjectContext (CAPI)

- (NSUInteger)countForFetchRequest:(NSFetchRequest *)request error:(NSError **)error
{
#ifndef NDEBUG
    [self.database checkForCorrectContextThread: self];
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

@end

@implementation N2ManagedDatabase (CAPI)

// Published database compatibility adapters; never used by internal queue work.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
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

-(void)performBlockAndWait:(void (NS_NOESCAPE ^)(void))block {
    N2ManagedObjectContextPerformAndWait(self.managedObjectContext, block);
}

-(NSArray*)objectsForEntity:(id)e predicate:(NSPredicate*)p error:(NSError**)error {
    return [self objectsForEntity:e predicate:p error:error fetchLimit:0 sortDescriptors:nil];
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

@end
