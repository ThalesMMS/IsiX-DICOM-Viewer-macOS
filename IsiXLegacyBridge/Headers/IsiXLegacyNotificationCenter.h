//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The notification center a ported plugin's source reaches as
// NSNotificationCenter. The application posts notifications of the names a
// legacy plugin observed, mouseDown, roiChange, CloseViewerNotification and
// the others of Notifications.h, with the application's own viewers and
// ROIs as their objects; a ported plugin must get them with the kit's
// objects, the ones it compares with its viewerController, and only once.
// So the names of Notifications.h are the kit's: observing and posting them
// goes through this center, where the kit posts them for the viewers' events
// and the application never does. Every other name goes to the default
// center, as before.
//
// The source keeps writing [NSNotificationCenter defaultCenter]: below, the
// kit's headers make the name NSNotificationCenter mean this class in the
// files that import them.

#import <Foundation/Foundation.h>

#ifndef ISIX_LEGACY_NOTIFICATION_CENTER_H
#define ISIX_LEGACY_NOTIFICATION_CENTER_H

ISIX_LEGACY_CLASS(NotificationCenter)
@interface IsiXLegacyNotificationCenter : NSNotificationCenter

/// The plugin's center: the kit's names here, the others in the default center.
@property (class, readonly, strong) IsiXLegacyNotificationCenter *defaultCenter;

/// The names of Notifications.h, which the kit posts and the application does not reach.
+ (NSSet<NSString*>*) kitNotificationNames;

@end

#ifndef ISIX_LEGACY_KEEP_NOTIFICATION_CENTER
#define NSNotificationCenter IsiXLegacyNotificationCenter
#endif

#endif
