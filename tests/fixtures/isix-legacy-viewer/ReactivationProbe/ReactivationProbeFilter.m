//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A legacy plugin for the test of a plugin deactivated and activated again in
// the same process: each activation creates a filter that observes, in
// -initPlugin, two viewer notifications (a click, another image shown), a ROI
// notification and a database notification, and stops observing in
// -willUnload. It keeps the names it
// heard in +takeHeard, which the test's host reads and empties. Compiled with
// manual reference counting.

#import <Foundation/Foundation.h>
#import <OsiriXAPI/PluginFilter.h>
#import <OsiriXAPI/Notifications.h>

@interface ReactivationProbeFilter : PluginFilter
+ (NSArray*) takeHeard;
@end

@implementation ReactivationProbeFilter

static NSMutableArray *ProbeHeard(void)
{
    static NSMutableArray *heard;
    if (!heard) heard = [[NSMutableArray alloc] init];
    return heard;
}

+ (NSArray*) takeHeard
{
    NSArray *taken = [[ProbeHeard() copy] autorelease];
    [ProbeHeard() removeAllObjects];
    return taken;
}

- (void) initPlugin
{
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (NSString *name in @[OsirixMouseDownNotification, OsirixDCMUpdateCurrentImageNotification, OsirixAddROINotification,
                             OsirixAddToDBNotification])
        [center addObserver: self selector: @selector(heard:) name: name object: nil];
}

- (void) willUnload
{
    [[NSNotificationCenter defaultCenter] removeObserver: self];
}

- (void) heard: (NSNotification*) note
{
    [ProbeHeard() addObject: note.name];
}

- (long) filterImage: (NSString*) menuName
{
    return 0;
}

@end
