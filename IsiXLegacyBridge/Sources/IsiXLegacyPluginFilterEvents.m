//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Compiled with ARC (-fobjc-arc), whatever the plugin's own setting.
//
// The viewers' events, given to the legacy plugin as the legacy application
// gave them: -handleEvent:forViewer: of the filter, and the notifications of
// Notifications.h in the plugin's notification center, with the kit's
// objects. IsiXLegacyViewerEvents (Swift) calls these for the plugin API's
// events.

#import "IsiXLegacyBridgeInternal.h"

@interface IsiXLegacyPluginFilter (IsiXLegacyEvents) <IsiXLegacyEventSink>
@end

@implementation IsiXLegacyPluginFilter (IsiXLegacyEvents)

- (BOOL) isixTakesEvents
{
    return [self respondsToSelector: @selector(handleEvent:forViewer:)];
}

- (BOOL) isixInput: (IsiXLegacyInput*) input session: (IsiXLegacyViewerSession*) session
{
    IsiXLegacyViewerController *controller = [IsiXLegacyViewerController isixControllerForSession: session];
    if (!controller) return NO;
    BOOL taken = NO;
    if (input.event && self.isixTakesEvents)
        taken = [self handleEvent: input.event forViewer: controller];
    if (!taken && input.isPlainClick)
    {
        // As the legacy application posted it: X in whole pixels, Y as it is;
        // an observer sets stopMouseDown to keep the viewer from the click.
        NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                     @((long) input.x), @"X", @((float) input.y), @"Y", @NO, @"stopMouseDown", nil];
        [[IsiXLegacyNotificationCenter defaultCenter] postNotificationName: OsirixMouseDownNotification object: controller userInfo: info];
        taken = [info[@"stopMouseDown"] boolValue];
    }
    return taken;
}

- (void) isixFlush: (IsiXLegacyViewerSession*) session
{
    if ([session.legacyController isKindOfClass: [IsiXLegacyViewerController class]])
        [(IsiXLegacyViewerController*) session.legacyController needsDisplayUpdate];
}

- (void) isixViewerWillClose: (IsiXLegacyViewerSession*) session
{
    // A plugin that never had this viewer has nothing to compare the object with.
    if (![session.legacyController isKindOfClass: [IsiXLegacyViewerController class]]) return;
    [[IsiXLegacyNotificationCenter defaultCenter] postNotificationName: OsirixCloseViewerNotification object: session.legacyController];
}

- (void) isixSliceChanged: (IsiXLegacyViewerSession*) session
{
    IsiXLegacyViewerController *controller = [IsiXLegacyViewerController isixControllerForSession: session];
    [[IsiXLegacyNotificationCenter defaultCenter] postNotificationName: OsirixDCMUpdateCurrentImageNotification object: controller.imageView];
}

- (void) isixROI: (NSString*) identifier change: (NSString*) change session: (IsiXLegacyViewerSession*) session
{
    [[IsiXLegacyViewerController isixControllerForSession: session] isixROIEvent: identifier change: change];
}

- (void) isixDraw: (IsiXLegacyOverlay*) overlay session: (IsiXLegacyViewerSession*) session
{
    IsiXLegacyViewerController *controller = [IsiXLegacyViewerController isixControllerForSession: session];
    NSDictionary *info = @{@"context": (__bridge id) overlay.context, @"pointSize": @(overlay.pointSize),
                           @"spacingX": @(overlay.spacingX), @"spacingY": @(overlay.spacingY)};
    [[IsiXLegacyNotificationCenter defaultCenter] postNotificationName: OsirixDrawObjectsNotification object: controller.imageView userInfo: info];
}

@end
