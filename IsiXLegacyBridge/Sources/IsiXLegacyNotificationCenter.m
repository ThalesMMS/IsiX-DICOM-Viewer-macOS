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
// The plugin's notification center. A name of Notifications.h is observed and
// posted here, in this center's own table, where the kit posts the viewers'
// events; any other name, or none, goes to the default center. Removing an
// observer removes it from both.

#import "IsiXLegacyBridgeInternal.h"

// From here on NSNotificationCenter is the system's class again.
#undef NSNotificationCenter

@implementation IsiXLegacyNotificationCenter

+ (IsiXLegacyNotificationCenter*) defaultCenter
{
    static IsiXLegacyNotificationCenter *center;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ center = [[IsiXLegacyNotificationCenter alloc] init]; });
    return center;
}

+ (NSSet<NSString*>*) kitNotificationNames
{
    static NSSet *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = [NSSet setWithObjects: OsirixMouseDownNotification, OsirixCloseViewerNotification,
                 OsirixDCMUpdateCurrentImageNotification, OsirixAddROINotification, OsirixROIChangeNotification,
                 OsirixROISelectedNotification, OsirixRemoveROINotification, OsirixDrawObjectsNotification,
                 OsirixUpdateViewNotification, OsirixAddToDBNotification, OsirixAddToDBCompleteNotification,
                 OsirixXMLRPCMessageNotification, nil];
    });
    return names;
}

static BOOL IsiXIsKitName(NSString *name)
{
    return name && [[IsiXLegacyNotificationCenter kitNotificationNames] containsObject: name];
}

static NSNotificationCenter *IsiXApplicationCenter(void)
{
    return [NSNotificationCenter defaultCenter];
}

- (void) isixAddKitObserver: (id) observer selector: (SEL) selector name: (NSString*) name object: (id) object
{
    [super addObserver: observer selector: selector name: name object: object];
}

- (void) addObserver: (id) observer selector: (SEL) selector name: (NSNotificationName) name object: (id) object
{
    if (IsiXIsKitName(name))
    {
        [super addObserver: observer selector: selector name: name object: object];
        [IsiXLegacyViewerEvents notificationObserved: name];
        return;
    }
    [IsiXApplicationCenter() addObserver: observer selector: selector name: name object: object];
}

- (id<NSObject>) addObserverForName: (NSNotificationName) name object: (id) object queue: (NSOperationQueue*) queue
                         usingBlock: (void (^)(NSNotification*)) block
{
    if (IsiXIsKitName(name))
    {
        id<NSObject> token = [super addObserverForName: name object: object queue: queue usingBlock: block];
        [IsiXLegacyViewerEvents notificationObserved: name];
        return token;
    }
    return [IsiXApplicationCenter() addObserverForName: name object: object queue: queue usingBlock: block];
}

- (void) postNotification: (NSNotification*) notification
{
    if (!IsiXIsKitName(notification.name))
    {
        [IsiXApplicationCenter() postNotification: notification];
        return;
    }
    [super postNotification: notification];
    if ([notification.name isEqualToString: OsirixUpdateViewNotification]) [IsiXLegacyViewerEvents updateViews];
}

- (void) postNotificationName: (NSNotificationName) name object: (id) object
{
    [self postNotificationName: name object: object userInfo: nil];
}

/// The userInfo dictionary is handed on as it is: an observer of the
/// mouse-down notification answers in it.
- (void) postNotificationName: (NSNotificationName) name object: (id) object userInfo: (NSDictionary*) userInfo
{
    if (!IsiXIsKitName(name))
    {
        [IsiXApplicationCenter() postNotificationName: name object: object userInfo: userInfo];
        return;
    }
    [super postNotificationName: name object: object userInfo: userInfo];
    if ([name isEqualToString: OsirixUpdateViewNotification]) [IsiXLegacyViewerEvents updateViews];
}

- (void) removeObserver: (id) observer
{
    [super removeObserver: observer];
    [IsiXApplicationCenter() removeObserver: observer];
}

- (void) removeObserver: (id) observer name: (NSNotificationName) name object: (id) object
{
    [super removeObserver: observer name: name object: object];
    [IsiXApplicationCenter() removeObserver: observer name: name object: object];
}

@end
