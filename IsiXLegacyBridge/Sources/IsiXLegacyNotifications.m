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
// The database's and XML-RPC's legacy notifications, posted in the plugin's
// notification center (IsiXLegacyNotificationCenter.h) with the kit's objects:
// images that entered the database, from what IsiXLegacyEventRelay hands it,
// and the calls of the XML-RPC methods the plugin listed, as
// OsirixXMLRPCMessageNotification. The application's same-named
// notifications, which carry its own objects, never reach the plugin.

#import "IsiXLegacyBridgeInternal.h"

@interface IsiXLegacyNotifications () <IsiXLegacyEventPoster, IsiXLegacyXMLRPCAnswering>
@end

@implementation IsiXLegacyNotifications

static IsiXLegacyNotifications *IsiXLegacyNotificationsShared;

+ (void) isixStart
{
    if (IsiXLegacyNotificationsShared) return;
    IsiXLegacyNotificationsShared = [[IsiXLegacyNotifications alloc] init];
    [IsiXLegacyEventRelay setPoster: IsiXLegacyNotificationsShared];
    [IsiXLegacyNetworkBridge setXMLRPCAnswering: IsiXLegacyNotificationsShared];
}

+ (void) isixStop
{
    if (!IsiXLegacyNotificationsShared) return;
    [IsiXLegacyEventRelay setPoster: nil];
    [IsiXLegacyNetworkBridge setXMLRPCAnswering: nil];
    IsiXLegacyNotificationsShared = nil;
}

#pragma mark IsiXLegacyEventPoster

- (void) isixPostEvent: (NSString*) kind info: (NSDictionary*) info
{
    if (![kind isEqualToString: @"imagesAdded"]) return;
    NSArray *images = [IsiXLegacyDatabaseObject isixObjectsWithRecords: info[@"images"] entity: IsiXLegacyEntityImage];
    NSMutableDictionary *perAET = [NSMutableDictionary dictionary];
    NSDictionary<NSString*, NSArray*> *uidsByTitle = info[@"perAET"];
    for (NSString *title in uidsByTitle)
    {
        NSSet *uids = [NSSet setWithArray: uidsByTitle[title]];
        NSMutableArray *sent = [NSMutableArray array];
        for (IsiXLegacyDicomImage *image in images)
            if ([uids containsObject: [image valueForKey: @"sopInstanceUID"]]) [sent addObject: image];
        perAET[title] = sent;
    }
    NSString *name = [info[@"complete"] boolValue] ? OsirixAddToDBCompleteNotification : OsirixAddToDBNotification;
    [[IsiXLegacyNotificationCenter defaultCenter] postNotificationName: name object: [IsiXLegacyDicomDatabase defaultDatabase]
        userInfo: @{OsirixAddToDBNotificationImagesArray: images, OsirixAddToDBNotificationImagesPerAETDictionary: perAET}];
}

#pragma mark IsiXLegacyXMLRPCAnswering

- (id) isixAnswerXMLRPC: (NSString*) method parameters: (NSArray*) parameters
{
    NSMutableDictionary *call = [NSMutableDictionary dictionary];
    if ([parameters.firstObject isKindOfClass: [NSDictionary class]]) [call addEntriesFromDictionary: parameters.firstObject];
    call[@"MethodName"] = method;
    call[@"methodName"] = method;
    NSXMLDocument *request = [[NSXMLDocument alloc] initWithXMLString: [IsiXLegacyN2XMLRPC requestWithMethodName: method arguments: parameters]
                                                              options: 0 error: NULL];
    if (request) call[@"NSXMLDocument"] = request;
    [[IsiXLegacyNotificationCenter defaultCenter] postNotificationName: OsirixXMLRPCMessageNotification object: call];

    id response = call[@"Response"];
    if (response) return response;
    NSXMLNode *answered = call[@"NSXMLDocumentResponse"];
    if ([answered isKindOfClass: [NSXMLNode class]])
    {
        NSArray *values = [answered nodesForXPath: @"/methodResponse/params/param/value" error: NULL];
        return values.count ? [IsiXLegacyN2XMLRPC ParseElement: values[0]] : @{};
    }
    if ([call[@"Processed"] respondsToSelector: @selector(boolValue)] && [call[@"Processed"] boolValue]) return @{};
    return nil;
}

@end
