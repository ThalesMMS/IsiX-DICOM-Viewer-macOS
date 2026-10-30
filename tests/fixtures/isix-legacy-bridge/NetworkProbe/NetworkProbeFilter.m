//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A legacy network plugin written the way Horos plugins were, for the kit's
// tests: it lists the DICOM nodes, sends the selected study with DCMTKStoreSCU
// and with SendController, queries studies and series with the query nodes,
// formats and parses XML-RPC values, answers the XML-RPC method ProbeEcho,
// and listens to the legacy notifications. Its second command sends to an
// address no user configured, which must be refused; its third writes what
// it saw. Everything goes to the property list named by
// ISIX_LEGACY_PROBE_OUTPUT. The test compiles it with manual reference
// counting and with ARC.

#import <Foundation/Foundation.h>
#import "PluginFilter.h"
#import "BrowserController.h"
#import "DicomStudy.h"
#import "DicomSeries.h"
#import "DicomImage.h"
#import <OsiriX Headers/Notifications.h>
#import <OsiriXAPI/DCMNetServiceDelegate.h>
#import <OsiriXAPI/DCMTKStoreSCU.h>
#import <OsiriXAPI/SendController.h>
#import <OsiriXAPI/DCMTKRootQueryNode.h>
#import <OsiriXAPI/DCMTKStudyQueryNode.h>
#import <OsiriXAPI/DCMTKSeriesQueryNode.h>
#import <OsiriXAPI/N2XMLRPC.h>

@interface NetworkProbeFilter : PluginFilter
{
    NSMutableArray *seen;
    NSMutableDictionary *report;
}
@end

@implementation NetworkProbeFilter

- (void) initPlugin
{
    seen = [[NSMutableArray alloc] init];
    report = [[NSMutableDictionary alloc] init];
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver: self selector: @selector(observe:) name: OsirixAddToDBNotification object: nil];
    [center addObserver: self selector: @selector(observe:) name: OsirixAddToDBCompleteNotification object: nil];
    [center addObserver: self selector: @selector(xmlrpc:) name: OsirixXMLRPCMessageNotification object: nil];
    // A name in text, as many plugins wrote it, which the application posts
    // too, with its own objects.
    [center addObserver: self selector: @selector(literal:) name: @"roiChange" object: nil];
}

- (void) literal: (NSNotification*) note
{
    id object = [note object];
    [seen addObject: [NSString stringWithFormat: @"literal:%@", [object isKindOfClass: [ROI class]] ? @"ROI" : NSStringFromClass([object class])]];
}

- (void) observe: (NSNotification*) note
{
    NSArray *images = [[note userInfo] objectForKey: OsirixAddToDBNotificationImagesArray];
    NSDictionary *perAET = [[note userInfo] objectForKey: OsirixAddToDBNotificationImagesPerAETDictionary];
    id first = [images count] ? [images objectAtIndex: 0] : nil;
    BOOL kit = [first isKindOfClass: [DicomImage class]];
    [seen addObject: [NSString stringWithFormat: @"%@:%lu:%@:%@:%@", note.name, (unsigned long) [images count],
                      kit ? @"DicomImage" : NSStringFromClass([first class]),
                      kit ? [first valueForKeyPath: @"series.study.studyInstanceUID"] : @"",
                      [[[perAET allKeys] sortedArrayUsingSelector: @selector(compare:)] componentsJoinedByString: @","]]];
}

- (void) xmlrpc: (NSNotification*) note
{
    NSMutableDictionary *call = [note object];
    NSString *methodName = [call objectForKey: @"MethodName"];
    [seen addObject: [NSString stringWithFormat: @"XMLRPC:%@", methodName]];
    if ([methodName isEqualToString: @"ProbeEcho"])
    {
        NSString *text = [call objectForKey: @"text"];
        [call setObject: [NSDictionary dictionaryWithObjectsAndKeys: text ?: @"", @"echo",
                          [NSNumber numberWithBool: [call objectForKey: @"NSXMLDocument"] != nil], @"hadDocument", nil]
                 forKey: @"Response"];
    }
    else if ([methodName isEqualToString: @"DisplayStudy"])
        // A method of the application: the kit never registers it for the plugin.
        [call setObject: @"taken over" forKey: @"Response"];
}

- (NSString*) outputPath: (NSString*) what
{
    NSString *path = [[[NSProcessInfo processInfo] environment] objectForKey: @"ISIX_LEGACY_PROBE_OUTPUT"];
    if (!path) path = [NSTemporaryDirectory() stringByAppendingPathComponent: @"isix-legacy-network-probe"];
    return [path stringByAppendingFormat: @"-network-%@-%d.plist", what, __has_feature(objc_arc) ? 1 : 0];
}

- (NSArray*) selectedImages
{
    NSMutableArray *images = [NSMutableArray array];
    for (id object in [[BrowserController currentBrowser] databaseSelection])
    {
        if ([object isKindOfClass: [DicomStudy class]])
            for (DicomSeries *series in [(DicomStudy*) object valueForKey: @"series"])
                [images addObjectsFromArray: [[series valueForKey: @"images"] allObjects]];
        else if ([object isKindOfClass: [DicomSeries class]])
            [images addObjectsFromArray: [[object valueForKey: @"images"] allObjects]];
    }
    return images;
}

- (long) filterImage: (NSString*) menuName
{
    if ([menuName isEqualToString: @"Network Probe Report"])
    {
        [[NSDictionary dictionaryWithObject: seen forKey: @"seen"] writeToFile: [self outputPath: @"seen"] atomically: YES];
        return 0;
    }
    if ([menuName isEqualToString: @"Network Probe Unconfigured Node"])
    {
        // An address the user never configured: refused before anything is sent.
        DCMTKStoreSCU *store = [[DCMTKStoreSCU alloc] initWithCallingAET: @"PROBE" calledAET: @"ELSEWHERE" hostname: @"203.0.113.9"
                                                                    port: 104 filesToSend: [self selectedImages] transferSyntax: 0
                                                             compression: 0 extraParameters: nil];
        NSMutableDictionary *refusal = [NSMutableDictionary dictionary];
        @try { [store run: nil]; [refusal setObject: @"sent" forKey: @"outcome"]; }
        @catch (NSException *e) { [refusal setObject: [e name] forKey: @"exception"]; [refusal setObject: [e reason] forKey: @"reason"]; }
#if !__has_feature(objc_arc)
        [store release];
#endif
        [refusal writeToFile: [self outputPath: @"refusal"] atomically: YES];
        return 0;
    }

    NSDictionary *servers = nil;
    NSArray *sendNodes = [DCMNetServiceDelegate DICOMServersListSendOnly: YES QROnly: NO];
    NSArray *queryNodes = [DCMNetServiceDelegate DICOMServersListSendOnly: NO QROnly: YES];
    [report setObject: [[DCMNetServiceDelegate DICOMServersList] valueForKey: @"AETitle"] forKey: @"nodes"];
    [report setObject: [sendNodes valueForKey: @"AETitle"] forKey: @"sendNodes"];
    [report setObject: [queryNodes valueForKey: @"AETitle"] forKey: @"queryNodes"];

    // A send with DCMTKStoreSCU, to the first node with Send on, of the selected study's files.
    NSArray *images = [self selectedImages];
    [report setObject: [NSNumber numberWithUnsignedInteger: [images count]] forKey: @"selectedImages"];
    if ([sendNodes count])
    {
        servers = [sendNodes objectAtIndex: 0];
        NSArray *paths = [images valueForKey: @"completePath"];
        DCMTKStoreSCU *store = [[DCMTKStoreSCU alloc] initWithCallingAET: @"PROBE" calledAET: [servers objectForKey: @"AETitle"]
                                                                hostname: [servers objectForKey: @"Address"]
                                                                    port: [[servers objectForKey: @"Port"] intValue] filesToSend: paths
                                                          transferSyntax: 0 compression: 0 extraParameters: servers];
        @try { [store run: nil]; [report setObject: @"sent" forKey: @"storeOutcome"]; }
        @catch (NSException *e) { [report setObject: [NSString stringWithFormat: @"%@: %@", [e name], [e reason]] forKey: @"storeOutcome"]; }
#if !__has_feature(objc_arc)
        [store release];
#endif
        // And with SendController, in the background, of the DicomImage objects.
        [SendController sendFiles: images toNode: servers];
    }

    // The query nodes: the studies of the first node with Query/Retrieve on, then the series of the first study.
    if ([queryNodes count])
    {
        NSDictionary *node = [queryNodes objectAtIndex: 0];
        DCMTKRootQueryNode *root = [DCMTKRootQueryNode queryNodeWithDataset: NULL callingAET: @"PROBE"
                                                                  calledAET: [node objectForKey: @"AETitle"]
                                                                   hostname: [node objectForKey: @"Address"]
                                                                       port: [[node objectForKey: @"Port"] intValue]
                                                             transferSyntax: 0 compression: 0 extraParameters: node];
        [root queryWithValues: [NSArray arrayWithObject: [NSDictionary dictionaryWithObjectsAndKeys: @"PatientsName", @"name",
                                                          @"*", @"value", nil]]];
        [report setObject: [NSNumber numberWithBool: [root lastQuerySucceeded]] forKey: @"studyQuerySucceeded"];
        NSMutableArray *studies = [NSMutableArray array];
        for (DCMTKStudyQueryNode *study in [root children])
            [studies addObject: [NSString stringWithFormat: @"%@|%@|%@|%@", [study name], [study uid], [study modality],
                                 [[study date] dateString]]];
        [report setObject: studies forKey: @"studies"];
        if ([[root children] count])
        {
            DCMTKStudyQueryNode *study = [[root children] objectAtIndex: 0];
            [study queryWithValues: nil];
            NSMutableArray *series = [NSMutableArray array];
            for (DCMTKSeriesQueryNode *each in [study children])
                [series addObject: [NSString stringWithFormat: @"%@|%@|%@|%@", [each seriesInstanceUID], [each modality],
                                    [each theDescription], [each numberImages]]];
            [report setObject: series forKey: @"series"];
        }
    }

    // XML-RPC values, formatted and parsed back.
    NSDictionary *value = [NSDictionary dictionaryWithObjectsAndKeys: @"a < b", @"text", [NSNumber numberWithInt: 42], @"count",
                           [NSArray arrayWithObjects: [NSNumber numberWithBool: YES], [NSNumber numberWithDouble: 1.5], nil], @"list", nil];
    NSString *formatted = [N2XMLRPC FormatElement: value];
    NSXMLElement *element = [[NSXMLElement alloc] initWithXMLString: formatted error: NULL];
    [report setObject: [NSNumber numberWithBool: [[N2XMLRPC ParseElement: element] isEqual: value]] forKey: @"xmlrpcRoundTrip"];
#if !__has_feature(objc_arc)
    [element release];
#endif
    [report writeToFile: [self outputPath: @"main"] atomically: YES];
    return 0;
}

@end
