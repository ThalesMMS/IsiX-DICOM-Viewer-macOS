//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Runs the porting kit's replacements of deprecated AppKit and Foundation calls
// (IsiXLegacyPortSupport, IsiXLegacyCalendarDate) the way converted plugins
// call them, pressing the alerts' buttons itself, and prints what they
// returned as JSON. Built and run by tests/test-port-legacy-plugin.py, with
// Panel.nib next to the executable.

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "IsiXLegacyPortSupport.h"
#import "IsiXLegacyCalendarDate.h"

@interface PortProbeOwner : NSObject
@property (weak) IBOutlet NSWindow *window;
@end

@implementation PortProbeOwner
@end

@interface PortProbeDelegate : NSObject
@property (strong) NSMutableArray *calls;
@end

@implementation PortProbeDelegate
- (instancetype) init
{
    if ((self = [super init])) _calls = [NSMutableArray array];
    return self;
}
- (void) sheetDidEnd: (id) sheet returnCode: (NSInteger) code contextInfo: (void*) info
{
    [_calls addObject: @[NSStringFromClass([sheet class]), @(code), @((long)info)]];
}
@end

@interface PortProbeFiles : NSObject
@end

@implementation PortProbeFiles
- (NSArray*) filenames { return @[@"/tmp/a", @"/tmp/b"]; }
@end

static NSArray<NSView*> *Views(NSView *view)
{
    NSMutableArray *all = [NSMutableArray arrayWithObject: view];
    for (NSView *subview in view.subviews) [all addObjectsFromArray: Views(subview)];
    return all;
}

static NSButton *Button(NSWindow *window, NSString *title)
{
    for (NSView *view in Views(window.contentView))
        if ([view isKindOfClass: [NSButton class]] && [[(NSButton*)view title] isEqualToString: title]) return (NSButton*)view;
    return nil;
}

static NSArray<NSString*> *Texts(NSWindow *window)
{
    NSMutableArray *texts = [NSMutableArray array];
    for (NSView *view in Views(window.contentView))
        if ([view isKindOfClass: [NSTextField class]] && [(NSTextField*)view stringValue].length)
            [texts addObject: [(NSTextField*)view stringValue]];
    return texts;
}

// Presses the button titled `title` of the next modal window, and keeps its texts.
static NSMutableArray *ModalTexts;
static void PressInModal(NSString *title)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: 5];
    NSTimer *timer = [NSTimer timerWithTimeInterval: 0.05 repeats: YES block: ^(NSTimer *t) {
        NSWindow *modal = [NSApp modalWindow];
        NSButton *button = modal ? Button(modal, title) : nil;
        if (button) {
            [ModalTexts addObject: Texts(modal)];
            [t invalidate];
            [button performClick: nil];
        } else if ([deadline timeIntervalSinceNow] < 0) {
            [t invalidate];
            [NSApp abortModal];
        }
    }];
    [[NSRunLoop currentRunLoop] addTimer: timer forMode: NSModalPanelRunLoopMode];
}

static BOOL Spin(BOOL (^done)(void))
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow: 5];
    while (!done() && [deadline timeIntervalSinceNow] > 0) {
        NSEvent *event = [NSApp nextEventMatchingMask: NSEventMaskAny untilDate: [NSDate dateWithTimeIntervalSinceNow: 0.02]
                                               inMode: NSDefaultRunLoopMode dequeue: YES];
        if (event) [NSApp sendEvent: event];
    }
    return done();
}

int main(void)
{
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy: NSApplicationActivationPolicyAccessory];
        [NSApp finishLaunching];
        NSMutableDictionary *results = [NSMutableDictionary dictionary];
        ModalTexts = [NSMutableArray array];

        // NSCalendarDate.
        NSTimeZone *utc = [NSTimeZone timeZoneForSecondsFromGMT: 0];
        IsiXLegacyCalendarDate *date = [IsiXLegacyCalendarDate dateWithYear: 2026 month: 10 day: 29 hour: 13 minute: 5
                                                                     second: 9 timeZone: utc];
        IsiXLegacyCalendarDate *read = [IsiXLegacyCalendarDate dateWithString: @"2026-10-29 13:05:09 +0000"
                                                               calendarFormat: @"%Y-%m-%d %H:%M:%S %z"];
        IsiXLegacyCalendarDate *later = [date dateByAddingYears: 0 months: 1 days: 3 hours: 0 minutes: 0 seconds: 0];
        NSInteger months = 0, days = 0;
        [later years: NULL months: &months days: &days hours: NULL minutes: NULL seconds: NULL sinceDate: date];
        results[@"calendar"] = @{
            @"components": @[@([date yearOfCommonEra]), @([date monthOfYear]), @([date dayOfMonth]), @([date hourOfDay]),
                             @([date minuteOfHour]), @([date secondOfMinute]), @([date dayOfWeek]), @([date dayOfYear])],
            @"text": [date descriptionWithCalendarFormat: @"%Y-%m-%d %H:%M:%S %z|%j|%w|%e|%I %p|%y|%a %b|%A %B|%%|%F"],
            @"description": [date description],
            @"readEqual": @([read isEqualToDate: date]),
            @"unreadable": @([IsiXLegacyCalendarDate dateWithString: @"not a date" calendarFormat: @"%Y-%m-%d"] == nil),
            @"later": [later descriptionWithCalendarFormat: @"%Y-%m-%d"],
            @"difference": @[@(months), @(days)],
            @"ofDate": [IsiXLegacyCalendarDate descriptionOfDate: [NSDate dateWithTimeIntervalSince1970: 0]
                                                  calendarFormat: @"%Y/%m/%d %H" timeZone: utc locale: nil],
            @"withDate": [[IsiXLegacyCalendarDate dateWithDate: date calendarFormat: @"%d.%m.%Y" timeZone: utc] description],
            @"class": NSStringFromClass([date class]),
        };

        // NSRunAlertPanel() and its forms: the button pressed, as a legacy code.
        NSMutableArray *codes = [NSMutableArray array];
        for (NSString *title in @[@"Go", @"Stop", @"Other"]) {
            PressInModal(title);
            [codes addObject: @(IsiXLegacyRunAlertPanel(@"Probe", @"%d files", @"Go", @"Stop", @"Other", 7))];
        }
        PressInModal(@"OK");
        [codes addObject: @(IsiXLegacyRunCriticalAlertPanel(nil, @"critical", nil, nil, nil))];
        PressInModal(@"OK");
        [codes addObject: @(IsiXLegacyRunInformationalAlertPanel(@"Probe", @"information", @"OK", nil, nil))];
        results[@"alertPanels"] = codes;

        // +[NSAlert alertWithMessageText:...]: buttons tagged with the legacy codes.
        NSAlert *alert = IsiXLegacyAlertWithMessageText(@"Probe", nil, @"No", nil, @"%@ %@", @"x", @"y");
        PressInModal(@"No");
        NSInteger answer = [alert runModal];
        results[@"messageText"] = @{@"answer": @(answer), @"text": alert.informativeText,
                                    @"buttons": [alert.buttons valueForKey: @"title"],
                                    @"tags": [alert.buttons valueForKey: @"tag"]};

        // NSBeginAlertSheet() without a window: run modally, then the delegate.
        PortProbeDelegate *delegate = [[PortProbeDelegate alloc] init];
        PressInModal(@"No");
        IsiXLegacyBeginAlertSheet(@"Probe", @"Yes", @"No", nil, nil, delegate, @selector(sheetDidEnd:returnCode:contextInfo:),
                                  NULL, (void*)3, @"%@", @"sheet");
        results[@"alertSheetWithoutWindow"] = [delegate.calls copy];

        // Sheets on a window: ended by -[NSApplication endSheet:returnCode:] as the legacy plugins did.
        NSWindow *parent = [[NSWindow alloc] initWithContentRect: NSMakeRect(0, 0, 400, 300)
                                                       styleMask: NSWindowStyleMaskTitled backing: NSBackingStoreBuffered
                                                           defer: NO];
        parent.releasedWhenClosed = NO;
        [parent orderFrontRegardless];
        NSPanel *sheet = [[NSPanel alloc] initWithContentRect: NSMakeRect(0, 0, 200, 100) styleMask: NSWindowStyleMaskTitled
                                                      backing: NSBackingStoreBuffered defer: NO];
        delegate = [[PortProbeDelegate alloc] init];
        IsiXLegacyBeginSheet(sheet, parent, delegate, @selector(sheetDidEnd:returnCode:contextInfo:), (void*)42);
        BOOL attached = Spin(^{ return (BOOL)(parent.attachedSheet == sheet); });
        [NSApp endSheet: sheet returnCode: 7];
        [sheet orderOut: nil];
        Spin(^{ return (BOOL)(delegate.calls.count == 1); });
        results[@"appSheet"] = @{@"attached": @(attached), @"calls": [delegate.calls copy]};

        // -[NSAlert beginSheetModalForWindow:modalDelegate:...] on a window.
        delegate = [[PortProbeDelegate alloc] init];
        NSAlert *sheetAlert = [[NSAlert alloc] init];
        sheetAlert.messageText = @"Probe";
        [sheetAlert addButtonWithTitle: @"First"];
        [sheetAlert addButtonWithTitle: @"Second"];
        IsiXLegacyAlertBeginSheet(sheetAlert, parent, delegate, @selector(sheetDidEnd:returnCode:contextInfo:), (void*)5);
        attached = Spin(^{ return (BOOL)(parent.attachedSheet != nil); });
        [Button(parent.attachedSheet, @"Second") performClick: nil];
        Spin(^{ return (BOOL)(delegate.calls.count == 1); });
        results[@"alertSheet"] = @{@"attached": @(attached), @"calls": [delegate.calls copy]};
        [parent close];

        // +[NSBundle loadNibNamed:owner:]: outlets connected, top-level objects kept for the owner.
        PortProbeOwner *owner = [[PortProbeOwner alloc] init];
        BOOL loaded = NO;
        @autoreleasepool {
            loaded = IsiXLegacyLoadNibNamed(@"Panel", owner);
        }
        results[@"nib"] = @{@"loaded": @(loaded), @"window": owner.window.title ?: @"",
                            @"missing": @(IsiXLegacyLoadNibNamed(@"NoSuchNib", owner))};

        // Panels.
        NSSavePanel *save = [NSSavePanel savePanel];
        IsiXLegacyPanelSetRequiredFileType(save, @"txt");
        NSArray *typed = [save.allowedContentTypes valueForKey: @"identifier"];
        IsiXLegacyPanelSetRequiredFileType(save, nil);
        results[@"panel"] = @{@"requiredType": typed ?: @[],
                              @"anyType": [save.allowedContentTypes valueForKey: @"identifier"] ?: @[],
                              @"filenames": IsiXLegacyPanelFilenames([[PortProbeFiles alloc] init]) ?: @[],
                              @"notAPanel": @(IsiXLegacyPanelFilenames(@"text") == nil)};
        results[@"modalTexts"] = ModalTexts;

        NSData *json = [NSJSONSerialization dataWithJSONObject: results options: NSJSONWritingSortedKeys error: NULL];
        fwrite(json.bytes, 1, json.length, stdout);
    }
    return 0;
}
