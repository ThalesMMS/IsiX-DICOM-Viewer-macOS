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
////////////////////////////////////////////
//
//	Matt Brewer
//	December 1, 2009
//
//	matt@matt-brewer.com
//	http://www.matt-brewer.com
//
//
//	This code is released as is
//	with NO warranty, implied or otherwise.
//
////////////////////////////////////////////

#import "NSApplication-Dock.h"
#import "HorosBoundedTask.h"
@implementation NSApplication (Dock)


#pragma mark Application Assumed

////////////////////////////////////////////
//
//	Adds the currently running application
//	to the user's Dock
//
////////////////////////////////////////////

- (BOOL) addApplicationToDock {
	
	if ( ![self applicationExistsInDock] ) {
		return [self addApplicationToDock:[[NSBundle mainBundle] bundlePath]];
	} else return NO;
	
}


////////////////////////////////////////////
//
//	YES/NO if current application is in Dock
//
////////////////////////////////////////////

- (BOOL) applicationExistsInDock {
	return [self applicationExistsInDock:[[NSBundle mainBundle] bundlePath]];
}





#pragma mark Application Specified

////////////////////////////////////////////
//
//	Adds the specified path to the Dock
//	Doesn't check to see if is app or if
//	file even exists
//
////////////////////////////////////////////

// A property list object avoids XML interpolation of application paths.
NSDictionary *PFApplicationDockTile(NSString *path) {
    return @{ @"tile-data": @{ @"file-data": @{
        @"_CFURLString": [[NSURL fileURLWithPath:path] absoluteString],
        @"_CFURLStringType": @15 } }, @"tile-type": @"file-tile" };
}

BOOL PFApplicationDockContains(NSArray *apps, NSString *path) {
    NSURL *target = [[NSURL fileURLWithPath:path] URLByStandardizingPath];
    for (NSDictionary *tile in apps) {
        if (![tile isKindOfClass:[NSDictionary class]]) continue;
        id data = tile[@"tile-data"];
        if (![data isKindOfClass:[NSDictionary class]]) continue;
        id file = data[@"file-data"];
        if (![file isKindOfClass:[NSDictionary class]]) continue;
        id value = file[@"_CFURLString"];
        if (![value isKindOfClass:[NSString class]]) continue;
        NSURL *url = [value hasPrefix:@"file:"] ? [NSURL URLWithString:value] : [NSURL fileURLWithPath:value];
        if ([[url URLByStandardizingPath] isEqual:target]) return YES;
    }
    return NO;
}

- (BOOL) addApplicationToDock:(NSString*)path {
    if (![path.pathExtension isEqualToString:@"app"] ||
        ![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
    CFStringRef domain = CFSTR("com.apple.dock");
    id stored = [(id)CFPreferencesCopyAppValue(CFSTR("persistent-apps"), domain) autorelease];
    if (stored && ![stored isKindOfClass:[NSArray class]]) return NO;
    NSArray *apps = stored ?: @[];
    if (PFApplicationDockContains(apps, path)) return YES;
    NSMutableArray *updated = [[apps mutableCopy] autorelease];
    [updated addObject:PFApplicationDockTile(path)];
    CFPreferencesSetAppValue(CFSTR("persistent-apps"), (CFArrayRef)updated, domain);
    if (!CFPreferencesAppSynchronize(domain)) return NO;
    NSTask *task = [[[NSTask alloc] init] autorelease];
    task.launchPath = @"/usr/bin/killall";
    task.arguments = @[@"-HUP", @"Dock"];
    NSError *error = nil;
    BOOL started = HorosRunTaskUntilExit(task, 5, &error);
    return started && task.terminationStatus == 0;
}


////////////////////////////////////////////
//
//	YES/NO if application is in Dock
//
////////////////////////////////////////////

- (BOOL) applicationExistsInDock:(NSString*)path {
    id apps = [(id)CFPreferencesCopyAppValue(CFSTR("persistent-apps"), CFSTR("com.apple.dock")) autorelease];
    return [apps isKindOfClass:[NSArray class]] && PFApplicationDockContains(apps, path);
}

@end
