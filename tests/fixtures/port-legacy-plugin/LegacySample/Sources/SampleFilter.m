//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A legacy plugin for the converter's test, written for manual reference
// counting: every call tools/port-legacy-plugin.py rewrites, as legacy
// plugins wrote them. "NSRunAlertPanel(" in a string and in this comment stays.

#import "SampleFilter.h"
#import <objc/objc-auto.h>

@implementation SampleFilter

- (long) filterImage: (NSString*) menuName
{
    if (NSRunAlertPanel(@"Sample", @"Run %@?", @"OK", @"Cancel", nil, menuName) != NSAlertDefaultReturn)
        return 0;
    NSRunCriticalAlertPanel(@"Sample", @"Critical", nil, nil, nil);
    NSRunInformationalAlertPanel(@"Sample", @"NSRunAlertPanel(", @"OK", 0L, 0L);
    NSBeginAlertSheet(@"Sample", nil, nil, nil, [viewerController window], self, @selector(sheetDidEnd:returnCode:contextInfo:), nil, nil, @"%d images", 3);

    [[NSAlert alertWithMessageText: @"Sample" defaultButton: @"OK" alternateButton: @"Cancel" otherButton: nil
         informativeTextWithFormat: @"%@", menuName] beginSheetModalForWindow: [viewerController window]
                                                                 modalDelegate: self
                                                                didEndSelector: @selector(sheetDidEnd:returnCode:contextInfo:)
                                                                   contextInfo: nil];

    [NSBundle loadNibNamed: @"Panel" owner: self];
    [NSApp beginSheet: window
       modalForWindow: [NSApp keyWindow]
        modalDelegate: self
       didEndSelector: @selector(sheetDidEnd:returnCode:contextInfo:)
          contextInfo: nil];

    NSSavePanel *panel = [NSSavePanel savePanel];
    [panel setRequiredFileType: @"txt"];
    [panel beginSheetForDirectory: nil file: @"sample.txt" modalForWindow: [viewerController window] modalDelegate: self didEndSelector: @selector(panelDidEnd:returnCode:contextInfo:) contextInfo: nil];
    if ([panel runModalForDirectory: NSHomeDirectory() file: @"sample.txt"] == NSFileHandlingPanelOKButton)
        NSLog(@"saved");
    NSOpenPanel *open = [NSOpenPanel openPanel];
    if ([open runModalForTypes: [NSArray arrayWithObject: @"txt"]] == NSOKButton)
        NSLog(@"%@", [open filenames]);
    [open beginSheetForDirectory: nil file: nil types: [NSArray arrayWithObject: @"txt"] modalForWindow: [viewerController window] modalDelegate: self didEndSelector: @selector(panelDidEnd:returnCode:contextInfo:) contextInfo: nil];
    if ([open runModalForDirectory: nil file: nil types: nil] == NSCancelButton)
        return 0;

    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent: @"sample"];
    [manager createDirectoryAtPath: folder attributes: nil];
    NSArray *names = [manager directoryContentsAtPath: folder];
    NSDictionary *attributes = [manager fileAttributesAtPath: folder traverseLink: YES];
    [manager copyPath: folder toPath: [folder stringByAppendingString: @"-copy"] handler: nil];
    [manager movePath: [folder stringByAppendingString: @"-copy"] toPath: [folder stringByAppendingString: @"-moved"] handler: nil];
    [manager removeFileAtPath: folder handler: nil];
    NSString *text = [NSString stringWithContentsOfFile: [folder stringByAppendingPathComponent: @"a.txt"]];

    NSCalendarDate *now = [NSCalendarDate calendarDate];
    NSString *stamp = [[NSDate date] descriptionWithCalendarFormat: @"%Y%m%d" timeZone: nil locale: nil];
    NSCalendarDate *day = [[NSDate date] dateWithCalendarFormat: nil timeZone: nil];
    NSLog(@"%@ %@ %@ %@ %@ %ld %ld", names, attributes, text, stamp, day, (long)[now minuteOfHour], (long)[day dayOfMonth]);

    if (objc_collectingEnabled())
        objc_collect(OBJC_COLLECT_IF_NEEDED);
    [[NSGarbageCollector defaultCollector] collectIfNeeded];
    CFStringRef name = CFStringCreateCopy(NULL, CFSTR("sample"));
    NSString *collected = NSMakeCollectable(name);
    NSLog(@"%@", collected);
    [collected release];
    return 0;
}

- (void) sheetDidEnd: (NSWindow*) sheet returnCode: (NSInteger) returnCode contextInfo: (void*) contextInfo
{
    [sheet orderOut: self];
}

- (void) panelDidEnd: (NSSavePanel*) sheet returnCode: (int) returnCode contextInfo: (void*) contextInfo
{
}

@end
