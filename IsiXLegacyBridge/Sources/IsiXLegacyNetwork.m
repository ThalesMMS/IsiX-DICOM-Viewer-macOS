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
// The network classes of the legacy SDK over IsiXLegacyNetworkBridge: the
// nodes of Locations, sending and the query nodes. A legacy plugin named a
// node by its AE title, address and port, or by the dictionary of
// DCMNetServiceDelegate; the kit takes only a node the user configured, and
// a send or a query to any other address fails as a network failure would.

#import "IsiXLegacyBridgeInternal.h"

static NSString *const IsiXLegacyStoreFailure = @"DICOM Network Failure (STORE-SCU)";

/// The files and database images of a legacy send: paths, DicomImage objects,
/// and the images of DicomSeries and DicomStudy objects.
static void IsiXLegacyCollectFiles(id object, NSMutableArray<NSString*> *paths, NSMutableArray<NSString*> *uids)
{
    if ([object isKindOfClass: [NSString class]]) [paths addObject: object];
    else if ([object isKindOfClass: [NSURL class]] && [object isFileURL]) [paths addObject: [object path]];
    else if ([object isKindOfClass: [IsiXLegacyDicomImage class]])
    {
        NSString *uid = [object valueForKey: @"sopInstanceUID"];
        if (uid.length && ![uids containsObject: uid]) [uids addObject: uid];
    }
    else if ([object isKindOfClass: [IsiXLegacyDicomSeries class]])
        for (id image in [object valueForKey: @"images"]) IsiXLegacyCollectFiles(image, paths, uids);
    else if ([object isKindOfClass: [IsiXLegacyDicomStudy class]])
        for (id series in [object valueForKey: @"series"]) IsiXLegacyCollectFiles(series, paths, uids);
    else if ([object isKindOfClass: [NSArray class]] || [object isKindOfClass: [NSSet class]])
        for (id item in object) IsiXLegacyCollectFiles(item, paths, uids);
}

/// The identifier of the configured node a legacy node dictionary names.
static NSString *IsiXLegacyNodeIdentifier(NSDictionary *node, BOOL sending)
{
    if (![node isKindOfClass: [NSDictionary class]]) return nil;
    return [IsiXLegacyNetworkBridge nodeIdentifierWithAETitle: node[@"AETitle"] host: node[@"Address"]
                                                         port: [node[@"Port"] integerValue] forSending: sending];
}

#pragma mark - DCMNetServiceDelegate

@implementation IsiXLegacyDCMNetServiceDelegate

+ (NSArray*) DICOMServersList
{
    return [IsiXLegacyNetworkBridge nodeDictionariesSendOnly: NO queryOnly: NO];
}

+ (NSArray*) DICOMServersListSendOnly: (BOOL) send QROnly: (BOOL) queryRetrieve
{
    return [IsiXLegacyNetworkBridge nodeDictionariesSendOnly: send queryOnly: queryRetrieve];
}

@end

#pragma mark - SendController

@implementation IsiXLegacySendController

static int IsiXLegacyRunningSends;

+ (int) sendControllerObjects
{
    @synchronized (self) { return IsiXLegacyRunningSends; }
}

+ (void) sendFiles: (NSArray*) files toNode: (NSDictionary*) node usingSyntax: (int) syntax
{
    [self sendFiles: files toNode: node];
}

+ (void) sendFiles: (NSArray*) files toNode: (NSDictionary*) node
{
    NSString *identifier = IsiXLegacyNodeIdentifier(node, YES);
    if (!identifier) return;
    NSMutableArray *paths = [NSMutableArray array], *uids = [NSMutableArray array];
    IsiXLegacyCollectFiles(files, paths, uids);
    if (paths.count == 0 && uids.count == 0) return;
    @synchronized (self) { IsiXLegacyRunningSends++; }
    // In the background, as the legacy send ran; a failure is logged.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSNumber *sent = [IsiXLegacyNetworkBridge sendFiles: paths sopInstanceUIDs: uids toNode: identifier error: &error];
        if (sent) NSLog(@"SendController: %@ of %lu files sent to %@", sent, (unsigned long) (paths.count + uids.count), identifier);
        @synchronized (self) { IsiXLegacyRunningSends--; }
    });
}

/// The legacy application asked which node to send to; so does the kit, among
/// the nodes the user configured with Send on.
+ (void) sendFiles: (NSArray*) files
{
    NSArray *nodes = [IsiXLegacyDCMNetServiceDelegate DICOMServersListSendOnly: YES QROnly: NO];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = NSLocalizedString(@"DICOM Send", nil);
    if (nodes.count == 0)
    {
        alert.informativeText = NSLocalizedString(@"No DICOM destinations available. See Preferences to add DICOM locations.", nil);
        [alert runModal];
        return;
    }
    alert.informativeText = NSLocalizedString(@"Send to:", nil);
    NSPopUpButton *popUp = [[NSPopUpButton alloc] initWithFrame: NSMakeRect(0, 0, 300, 26) pullsDown: NO];
    for (NSDictionary *node in nodes)
        [popUp addItemWithTitle: [NSString stringWithFormat: @"%@ - %@", node[@"Description"], node[@"AETitle"]]];
    alert.accessoryView = popUp;
    [alert addButtonWithTitle: NSLocalizedString(@"Send", nil)];
    [alert addButtonWithTitle: NSLocalizedString(@"Cancel", nil)];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    [self sendFiles: files toNode: nodes[(NSUInteger) MAX(popUp.indexOfSelectedItem, 0)]];
}

@end

#pragma mark - DCMTKStoreSCU

@implementation IsiXLegacyDCMTKStoreSCU
{
    NSString *calledAET, *hostname;
    int port;
    NSArray *files;
}

+ (int) sendSyntaxForListenerSyntax: (int) listenerSyntax { return listenerSyntax; }

- (id) initWithCallingAET: (NSString*) myAET calledAET: (NSString*) theirAET hostname: (NSString*) host port: (int) p
              filesToSend: (NSArray*) filesToSend transferSyntax: (int) transferSyntax compression: (float) compression
          extraParameters: (NSDictionary*) extraParameters
{
    if ((self = [super init]))
    {
        calledAET = [theirAET copy];
        hostname = [host copy];
        port = p;
        files = [filesToSend copy] ?: @[];
    }
    return self;
}

- (void) run: (NSOperation*) operation
{
    NSString *identifier = [IsiXLegacyNetworkBridge nodeIdentifierWithAETitle: calledAET host: hostname port: port forSending: YES];
    if (!identifier)
        [NSException raise: IsiXLegacyStoreFailure format: @"%@@%@:%d is not a DICOM node configured in Locations with Send on.",
                            calledAET, hostname, port];
    NSMutableArray *paths = [NSMutableArray array], *uids = [NSMutableArray array];
    IsiXLegacyCollectFiles(files, paths, uids);
    NSError *error = nil;
    NSNumber *sent = [IsiXLegacyNetworkBridge sendFiles: paths sopInstanceUIDs: uids toNode: identifier error: &error];
    if (!sent) [NSException raise: IsiXLegacyStoreFailure format: @"%@", error.localizedDescription ?: @"The send failed."];
    if (sent.unsignedIntegerValue < paths.count + uids.count)
        [NSException raise: IsiXLegacyStoreFailure format: @"%lu of %lu files were not sent.",
                            (unsigned long) (paths.count + uids.count - sent.unsignedIntegerValue), (unsigned long) (paths.count + uids.count)];
}

- (void) updateLogEntry: (NSMutableDictionary*) userInfo {}

@end

#pragma mark - Query nodes

@implementation IsiXLegacyDCMTKServiceClassUser
{
    NSString *callingAET, *calledAET, *hostname;
    int port;
    NSDictionary *extraParameters;
}

- (id) initWithCallingAET: (NSString*) myAET calledAET: (NSString*) theirAET hostname: (NSString*) host port: (int) p
           transferSyntax: (int) transferSyntax compression: (float) compression extraParameters: (NSDictionary*) extra
{
    if ((self = [super init]))
    {
        callingAET = [myAET copy];
        calledAET = [theirAET copy];
        hostname = [host copy];
        port = p;
        extraParameters = [extra copy];
    }
    return self;
}

- (NSString*) _hostname { return hostname; }
- (int) _port { return port; }
- (NSString*) calledAET { return calledAET; }
- (NSString*) callingAET { return callingAET; }
- (NSDictionary*) extraParameters { return extraParameters; }

@end

@interface IsiXLegacyDCMTKQueryNode ()
/// The attributes the node's query answered, by DICOM keyword.
@property (copy) NSDictionary<NSString*, NSString*> *isixValues;
- (NSString*) isixValue: (NSString*) keyword;
/// The level of this node's children (study, series), nil when the kit does
/// not query below it, and their class.
- (NSString*) isixChildLevel;
- (Class) isixChildClass;
@end

@implementation IsiXLegacyDCMTKQueryNode
{
    NSMutableArray *children;
    BOOL lastQuerySucceeded, showErrorMessage;
}

+ (id) queryNodeWithDataset: (void*) dataset callingAET: (NSString*) myAET calledAET: (NSString*) theirAET hostname: (NSString*) hostname
                       port: (int) port transferSyntax: (int) transferSyntax compression: (float) compression
            extraParameters: (NSDictionary*) extraParameters
{
    return [[self alloc] initWithDataset: dataset callingAET: myAET calledAET: theirAET hostname: hostname port: port
                          transferSyntax: transferSyntax compression: compression extraParameters: extraParameters];
}

- (id) initWithDataset: (void*) dataset callingAET: (NSString*) myAET calledAET: (NSString*) theirAET hostname: (NSString*) hostname
                  port: (int) port transferSyntax: (int) transferSyntax compression: (float) compression
       extraParameters: (NSDictionary*) extraParameters
{
    if (dataset) NSLog(@"%@: a query node is made from its query; the dataset is ignored", NSStringFromClass([self class]));
    return [self initWithCallingAET: myAET calledAET: theirAET hostname: hostname port: port transferSyntax: transferSyntax
                        compression: compression extraParameters: extraParameters];
}

- (BOOL) lastQuerySucceeded { return lastQuerySucceeded; }
- (void) setShowErrorMessage: (BOOL) m { showErrorMessage = m; }
- (BOOL) showErrorMessage { return showErrorMessage; }
- (BOOL) isDistant { return YES; }

- (NSString*) isixValue: (NSString*) keyword { return self.isixValues[keyword]; }

- (NSString*) uid { return nil; }
- (NSString*) theDescription { return nil; }
- (NSString*) name { return [self isixValue: @"PatientName"]; }
- (NSString*) patientID { return [self isixValue: @"PatientID"]; }
- (NSString*) accessionNumber { return [self isixValue: @"AccessionNumber"]; }
- (NSString*) referringPhysician { return [self isixValue: @"ReferringPhysicianName"]; }
- (NSString*) performingPhysician { return nil; }
- (NSString*) institutionName { return nil; }
- (IsiXLegacyDCMCalendarDate*) date
{
    NSString *date = [self isixValue: @"StudyDate"] ?: [self isixValue: @"SeriesDate"];
    return date ? [IsiXLegacyDCMCalendarDate dicomDate: date] : nil;
}
- (IsiXLegacyDCMCalendarDate*) time
{
    NSString *time = [self isixValue: @"StudyTime"];
    return time ? [IsiXLegacyDCMCalendarDate dicomTime: time] : nil;
}
- (NSString*) modality { return [self isixValue: @"ModalitiesInStudy"] ?: [self isixValue: @"Modality"]; }
- (NSNumber*) numberImages
{
    NSString *count = [self isixValue: @"NumberOfStudyRelatedInstances"] ?: [self isixValue: @"NumberOfSeriesRelatedInstances"];
    return count ? @(count.integerValue) : nil;
}

- (NSArray*) children { return [children copy]; }
- (void) setChildren: (NSArray*) c { children = [c mutableCopy]; }
- (void) purgeChildren { children = nil; }

/// The level this node's children are, and the filter that ties them to it.
- (NSString*) isixChildLevel { return @"study"; }
- (Class) isixChildClass { return [IsiXLegacyDCMTKStudyQueryNode class]; }

/// The filters of the plugin API from the legacy values.
static NSDictionary *IsiXLegacyQueryFilters(NSArray *values)
{
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    NSDictionary *names = @{@"PatientsName": @"patientName", @"PatientName": @"patientName", @"name": @"patientName",
                            @"PatientID": @"patientID", @"patientID": @"patientID",
                            @"AccessionNumber": @"accessionNumber", @"accessionNumber": @"accessionNumber",
                            @"StudyInstanceUID": @"studyInstanceUID", @"StudyDescription": @"description",
                            @"theDescription": @"description", @"modality": @"modality", @"Modality": @"modality",
                            @"ModalitiesInStudy": @"modality"};
    for (NSDictionary *pair in values)
    {
        if (![pair isKindOfClass: [NSDictionary class]]) continue;
        NSString *name = pair[@"name"];
        id value = pair[@"value"];
        if (!name || !value || value == [NSNull null]) continue;
        if ([name isEqualToString: @"StudyDate"] || [name isEqualToString: @"date"])
        {
            NSDate *from = nil, *to = nil;
            if ([value isKindOfClass: [IsiXLegacyDCMCalendarDate class]]) from = to = [(IsiXLegacyDCMCalendarDate*) value date];
            else if ([value isKindOfClass: [NSDate class]]) from = to = value;
            else if ([value isKindOfClass: [NSString class]])
            {
                NSArray *parts = [value componentsSeparatedByString: @"-"];
                from = [[IsiXLegacyDCMCalendarDate dicomDate: parts.firstObject] date];
                to = parts.count > 1 ? [[IsiXLegacyDCMCalendarDate dicomDate: parts.lastObject] date] : from;
            }
            if (from) filters[@"dateFrom"] = from;
            if (to) filters[@"dateTo"] = to;
        }
        else if (names[name] && [value isKindOfClass: [NSString class]]) filters[names[name]] = value;
        else NSLog(@"DCMTKQueryNode: the query filter %@ is not part of the kit", name);
    }
    return filters;
}

- (void) queryWithValues: (NSArray*) values
{
    children = [NSMutableArray array];
    lastQuerySucceeded = NO;
    NSString *level = [self isixChildLevel];
    if (!level) return;
    NSString *identifier = [IsiXLegacyNetworkBridge nodeIdentifierWithAETitle: self.calledAET host: self._hostname port: self._port
                                                                    forSending: NO];
    if (!identifier) return;
    NSMutableDictionary *filters = [IsiXLegacyQueryFilters(values) mutableCopy];
    if ([level isEqualToString: @"series"]) filters[@"studyInstanceUID"] = self.uid ?: @"";
    NSError *error = nil;
    NSArray<NSDictionary*> *matches = [IsiXLegacyNetworkBridge findLevel: level filters: filters onNode: identifier error: &error];
    if (!matches) return;
    for (NSDictionary *match in matches)
    {
        IsiXLegacyDCMTKQueryNode *child = [[[self isixChildClass] alloc] initWithCallingAET: self.callingAET calledAET: self.calledAET
                                                                                   hostname: self._hostname port: self._port
                                                                             transferSyntax: 0 compression: 0
                                                                            extraParameters: self.extraParameters];
        child.isixValues = match;
        if ([child isKindOfClass: [IsiXLegacyDCMTKSeriesQueryNode class]])
            ((IsiXLegacyDCMTKSeriesQueryNode*) child).study = (IsiXLegacyDCMTKStudyQueryNode*) self;
        [children addObject: child];
    }
    lastQuerySucceeded = YES;
}

@end

@implementation IsiXLegacyDCMTKRootQueryNode
@end

@implementation IsiXLegacyDCMTKStudyQueryNode

- (NSString*) isixChildLevel { return @"series"; }
- (Class) isixChildClass { return [IsiXLegacyDCMTKSeriesQueryNode class]; }
- (NSString*) uid { return [self isixValue: @"StudyInstanceUID"]; }
- (NSString*) theDescription { return [self isixValue: @"StudyDescription"]; }
- (NSString*) studyInstanceUID { return self.uid; }
- (NSString*) studyName { return self.theDescription; }
- (NSNumber*) numberOfImages { return self.numberImages; }
- (NSNumber*) noFiles { return self.numberImages; }
- (NSDate*) dateOfBirth
{
    NSString *birth = [self isixValue: @"PatientBirthDate"];
    return birth ? [[IsiXLegacyDCMCalendarDate dicomDate: birth] date] : nil;
}

@end

@implementation IsiXLegacyDCMTKSeriesQueryNode

/// The images of a series are not queried by the kit.
- (NSString*) isixChildLevel { return nil; }
- (NSString*) uid { return [self isixValue: @"SeriesInstanceUID"]; }
- (NSString*) theDescription { return [self isixValue: @"SeriesDescription"]; }
- (NSString*) name { return self.theDescription; }
- (NSString*) studyInstanceUID { return [self isixValue: @"StudyInstanceUID"] ?: self.study.uid; }
- (NSString*) seriesInstanceUID { return self.uid; }

@end
