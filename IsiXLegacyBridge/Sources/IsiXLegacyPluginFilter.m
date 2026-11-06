//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Compiled with ARC (-fobjc-arc), whatever the plugin's own setting. The entry
// point of the port (IsiXLegacyPluginEntry, in Swift) drives the filter through
// IsiXLegacyFilterHost.

#import "IsiXLegacyBridgeInternal.h"

@interface IsiXLegacyPluginFilter () <IsiXLegacyFilterHost>
@end

@implementation IsiXLegacyPluginFilter

+ (IsiXLegacyPluginFilter *) filter
{
    return [[self alloc] init];
}

- (long) filterImage: (NSString*) menuName
{
    NSLog(@"%@ does not implement -filterImage: (%@)", NSStringFromClass([self class]), menuName);
    return -1;
}

- (void) initPlugin {}
- (void) willUnload {}
- (BOOL) isCertifiedForMedicalImaging { return NO; }
- (void) setMenus {}

- (NSArray*) viewerControllersList
{
    return [IsiXLegacyViewerController getDisplayed2DViewers];
}

- (IsiXLegacyViewerController*) duplicateCurrent2DViewerWindow
{
    return [IsiXLegacyViewerController isixControllerForSession: [viewerController.isixSession duplicateSeries]];
}

- (long) prepareFilter: (IsiXLegacyViewerController*) vC
{
    viewerController = vC;
    return 0;
}

#pragma mark IsiXLegacyFilterHost

- (void) isixLegacyStart
{
    [IsiXLegacyNotifications isixStart];
    [self initPlugin];
    [self setMenus];
}

- (NSInteger) isixLegacyRunMenu: (NSString*) menu viewer: (IsiXLegacyViewerSession*) viewer
{
    long status = [self prepareFilter: [IsiXLegacyViewerController isixControllerForSession: viewer]];
    if (status != 0) return status;
    return [self filterImage: menu];
}

- (void) isixLegacyStop
{
    [self willUnload];
    [IsiXLegacyNotifications isixStop];
}

@end
