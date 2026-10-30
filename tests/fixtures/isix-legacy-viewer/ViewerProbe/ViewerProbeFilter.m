//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A legacy plugin written the way Horos plugins were, for the test of the
// viewer's events, drawing and the plugin's own windows: it observes the
// notifications of Notifications.h, answers -handleEvent:forViewer:, draws
// over the image in the drawing notification, shows a window from its nib
// with a DCMView of its own, and changes the phase shown. It keeps what it
// saw in +report, which the test's host reads. Compiled with manual
// reference counting.

#import <Foundation/Foundation.h>
#import <OsiriXAPI/PluginFilter.h>
#import <OsiriXAPI/Notifications.h>

@interface ViewerProbeFilter : PluginFilter
{
    IBOutlet NSWindow *panel;
    IBOutlet DCMView *pane;
    NSArray *nibObjects;
}
+ (NSMutableDictionary*) report;
@end

@implementation ViewerProbeFilter

+ (NSMutableDictionary*) report
{
    static NSMutableDictionary *report;
    if (!report) report = [[NSMutableDictionary alloc] init];
    return report;
}

static void ProbeAppend(NSString *key, id value)
{
    NSMutableArray *list = [ViewerProbeFilter report][key];
    if (!list)
    {
        list = [NSMutableArray array];
        [ViewerProbeFilter report][key] = list;
    }
    [list addObject: value];
}

- (long) filterImage: (NSString*) menuName
{
    NSMutableDictionary *report = [ViewerProbeFilter report];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    report[@"centerClass"] = NSStringFromClass([center class]);
    for (NSString *name in @[OsirixMouseDownNotification, OsirixDCMUpdateCurrentImageNotification, OsirixAddROINotification,
                             OsirixROIChangeNotification, OsirixROISelectedNotification, OsirixRemoveROINotification,
                             OsirixCloseViewerNotification, OsirixDrawObjectsNotification])
        [center addObserver: self selector: @selector(viewerEvent:) name: name object: nil];
    // A name the kit does not post still reaches the default center.
    [center addObserver: self selector: @selector(ownEvent:) name: @"ViewerProbeOwnNotification" object: nil];
    [center postNotificationName: @"ViewerProbeOwnNotification" object: self];

    // The phase shown, in a 4D series.
    report[@"phases"] = @([viewerController maxMovieIndex]);
    [viewerController setMovieIndex: 1];
    report[@"phaseAfter"] = @([viewerController curMovieIndex]);
    [viewerController setMovieIndex: 0];

    // A window of the plugin's own, from its nib, with a DCMView of its own.
    [[NSBundle bundleForClass: [self class]] loadNibNamed: @"ViewerProbePanel" owner: self topLevelObjects: &nibObjects];
    [nibObjects retain];
    report[@"paneClass"] = pane ? NSStringFromClass([pane class]) : @"";
    report[@"paneIsKitView"] = @([pane isKindOfClass: [DCMView class]] && [pane isKindOfClass: [NSView class]]);
    [pane setPixels: [viewerController pixList] files: nil rois: [viewerController roiList] firstImage: 2 level: 0 reset: YES];
    [pane setWLWW: 20.5 :3];
    report[@"paneImage"] = @([pane curImage]);
    NSPoint centre = [pane ConvertFromGL2NSView: NSMakePoint(3, 2)];
    NSPoint back = [pane ConvertFromNSView2GL: centre];
    report[@"paneRoundTrip"] = @[@(back.x), @(back.y)];
    NSImage *picture = [pane nsimage];
    NSBitmapImageRep *bitmap = [[[NSBitmapImageRep alloc] initWithData: [picture TIFFRepresentation]] autorelease];
    // The gray of each pixel of row 1, where the view says its centre is; the
    // view is 120 x 80 points, y up, and the bitmap's rows go down.
    NSMutableArray *grays = [NSMutableArray array];
    for (NSInteger column = 0; column < 6; column++)
    {
        NSPoint at = [pane ConvertFromGL2NSView: NSMakePoint(column + 0.5, 1.5)];
        NSColor *color = [[bitmap colorAtX: at.x * bitmap.pixelsWide / 120 y: (80 - at.y) * bitmap.pixelsHigh / 80]
                          colorUsingColorSpace: [NSColorSpace sRGBColorSpace]];
        [grays addObject: @(round(color.redComponent * 255))];
    }
    report[@"paneRow1"] = grays;
    report[@"paneScale"] = @([pane ConvertFromGL2NSView: NSMakePoint(1, 0)].x - [pane ConvertFromGL2NSView: NSMakePoint(0, 0)].x);
    return 0;
}

- (void) ownEvent: (NSNotification*) note
{
    [ViewerProbeFilter report][@"ownNotification"] = @(note.object == self);
}

- (void) viewerEvent: (NSNotification*) note
{
    NSString *name = note.name;
    id object = note.object;
    if ([name isEqualToString: OsirixMouseDownNotification])
    {
        ProbeAppend(@"clicks", @[note.userInfo[@"X"], note.userInfo[@"Y"], @(object == viewerController)]);
        [note.userInfo setValue: @YES forKey: @"stopMouseDown"];
    }
    else if ([name isEqualToString: OsirixDCMUpdateCurrentImageNotification])
        ProbeAppend(@"images", @[@([(DCMView*) object curImage]), @(object == [viewerController imageView])]);
    else if ([name isEqualToString: OsirixAddROINotification])
    {
        ROI *roi = note.userInfo[@"ROI"];
        ProbeAppend(@"rois", [NSString stringWithFormat: @"added %@ slice %@ %d", roi.name, note.userInfo[@"sliceNumber"],
                              object == [viewerController imageView]]);
    }
    else if ([name isEqualToString: OsirixROIChangeNotification] || [name isEqualToString: OsirixROISelectedNotification]
             || [name isEqualToString: OsirixRemoveROINotification])
    {
        ROI *roi = object;
        BOOL listed = NO;
        for (NSArray *list in [viewerController roiList]) listed |= [list indexOfObjectIdenticalTo: roi] != NSNotFound;
        ProbeAppend(@"rois", [NSString stringWithFormat: @"%@ %@ %lu %d", name, roi.name, (unsigned long) roi.points.count, listed]);
    }
    else if ([name isEqualToString: OsirixCloseViewerNotification])
        ProbeAppend(@"closed", @(object == viewerController));
    else if ([name isEqualToString: OsirixDrawObjectsNotification])
    {
        CGContextRef context = (CGContextRef) note.userInfo[@"context"];
        // Pixels (1, 1) and (2, 1): their centres are at half coordinates.
        CGContextSetRGBFillColor(context, 1, 0, 0, 1);
        CGContextFillRect(context, CGRectMake(1, 1, 2, 1));
        ProbeAppend(@"draws", @[@([(DCMView*) object curImage]), note.userInfo[@"pointSize"], @(object == [viewerController imageView])]);
    }
}

- (BOOL) handleEvent: (NSEvent*) event forViewer: (ViewerController*) controller
{
    if (event.type == NSEventTypeKeyDown)
    {
        ProbeAppend(@"keys", @[event.characters ?: @"", @(controller == viewerController)]);
        return [event.characters isEqualToString: @"k"];
    }
    if (event.type == NSEventTypeLeftMouseDragged) ProbeAppend(@"drags", @(event.locationInWindow.x));
    return NO;
}

@end
