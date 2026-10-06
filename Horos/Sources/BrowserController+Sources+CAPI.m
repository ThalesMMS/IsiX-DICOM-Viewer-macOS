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

#import "HorosVolumeDiscovery.h"
#import "BrowserController+SwiftIvars.h"
#import "HorosAlertPanel.h"

// HorosVolumeDiscovery is declared in its header, which is part of the SDK, and
// implemented here only: a plugin that includes <Horos/Horos.h> uses the
// application's class instead of compiling one of its own.
@implementation HorosVolumeDiscovery
- (id)init {
    if ((self = [super init])) {
        _queue = [[NSOperationQueue alloc] init];
        _queue.maxConcurrentOperationCount = 2;
        _tokens = [[NSMutableDictionary alloc] init];
    }
    return self;
}
- (BOOL)discoverPath:(NSString *)path worker:(id (^)(void))worker completion:(void (^)(id))completion {
    NSAssert(NSThread.isMainThread, @"Volume requests belong to the main thread.");
    if (!path.length || !worker || !completion || [_tokens objectForKey:path]) return NO;
    NSUUID *token = NSUUID.UUID;
    [_tokens setObject:token forKey:path];
    [_queue addOperationWithBlock:^{
        @autoreleasepool {
            id result = nil;
            @try { result = worker(); }
            @catch (NSException *exception) { NSLog(@"Volume discovery failed: %@", exception.name); }
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([[_tokens objectForKey:path] isEqual:token]) {
                    [_tokens removeObjectForKey:path];
                    completion(result);
                }
            });
        }
    }];
    return YES;
}
- (void)cancelPath:(NSString *)path {
    NSAssert(NSThread.isMainThread, @"Volume requests belong to the main thread.");
    if (path) [_tokens removeObjectForKey:path];
}
- (void)cancelAll {
    NSAssert(NSThread.isMainThread, @"Volume requests belong to the main thread.");
    [_tokens removeAllObjects];
    [_queue cancelAllOperations];
}
- (void)dealloc {
    [_queue cancelAllOperations];
    [_queue release];
    [_tokens release];
    [super dealloc];
}
@end

@implementation BrowserController (SourcesCAPI)

- (void)horos_beginSourcesAlertSheetWithTitle:(NSString*)title message:(NSString*)message
{
    [HorosAlertPanel beginWithTitle:title message:message defaultButton:nil alternateButton:nil otherButton:nil
                    modalForWindow:self.window completionHandler:nil];
}

+ (NSObject*)horos_oneCopyAtATimeLock
{
    static NSString *oneCopyAtATime = @"oneCopyAtATime";
    return oneCopyAtATime;
}

@end
