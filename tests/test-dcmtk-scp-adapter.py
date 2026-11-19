#!/usr/bin/env python3
"""The listener's DCMTK adapter turns DCMTK's errors and the database's exceptions into NSError or a status.

The DICOM listener (DCMTKQueryRetrieveSCP.swift) reaches DCMTK only through
Horos/Sources/Adapters/DCMTK: IsiXDCMTKListener opens the port, takes the
connections and serves each association on a thread, and the database handle
(IsiXDCMTKSCPDatabase.mm) hands DCMTK's find, retrieve and store contexts to
the application's database object. The adapter is compiled here, with strict
warnings, against the DCMTK, OpenSSL and OpenJPEG the Debug build installed
(exit 2 without that build), with a host and a database written for the test,
and driven by a DCMTK SCU over the loopback:

- a DCMTK error: a second listener on a port the first one holds fails to
  open it with an NSError of IsiXDCMTKErrorDomain that names the step and
  gives the errno (EADDRINUSE);
- C-ECHO, a C-FIND answered with two matches, and a C-STORE stored through
  the database, published to its folder, with the sender's AE title in the
  file and its attributes handed to the database;
- a C++ exception and an Objective-C exception in the database's C-FIND,
  C-GET and publication end that request with Unable to process or Out of
  resources, and the same association answers the next request;
- an association its peer aborts tells the database it ended incomplete and
  the host the error, of the peer-abort kind; each database is closed;
- a peer that stops in the middle of a message, with the connection open,
  against a second listener that waits 2 s: one writes the command of a
  C-FIND-RQ and nothing of its identifier, another the command of a C-STORE-RQ
  and the first part of its data set, a third the first half of a command.
  Each association ends with an error of the no-data kind, whose message
  names the peer, its address, the 2 s and what never came, and the database
  of the first two is told it ended incomplete;
- stopped, the listener ends its associations and closes the port: nothing
  answers there, and a new listener opens it again.
"""
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dcmtk_scp_adapter  # noqa: E402

DRIVER = r'''
#import <Foundation/Foundation.h>
#import "IsiXDCMTKQueryRetrieveSCP.h"
#import "IsiXDCMTKError.h"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dctk.h>
#include <dcmtk/dcmdata/dcostrmb.h>
#include <dcmtk/dcmnet/assoc.h>
#include <dcmtk/dcmnet/dimse.h>
#include <dcmtk/dcmnet/dul.h>
#include <dcmtk/dcmnet/scu.h>
#include <arpa/inet.h>
#include <atomic>
#include <cerrno>
#include <stdexcept>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

static int failures = 0;
static void check(bool condition, const char *what)
{
    printf("%s: %s\n", condition ? "PASS" : "FAIL", what);
    fflush(stdout);
    if (!condition) failures++;
}

enum { Succeed = 0, ThrowCxx, RaiseObjC };
static std::atomic<int> findFailure{Succeed}, retrieveFailure{Succeed}, publishFailure{Succeed};
static std::atomic<int> stored{0}, endedStores{0}, closedDatabases{0}, incomplete{0}, endedAssociations{0}, peerAborts{0};
static std::atomic<int> starved{0};
static NSString *receiving = nil, *published = nil;
// The messages of the associations that ended on the no-data condition, in order.
static NSMutableArray<NSString *> *starvedMessages = nil;

static void fail(int how, const char *what)
{
    if (how == ThrowCxx) throw std::runtime_error(what);
    if (how == RaiseObjC) [NSException raise:NSInternalInconsistencyException format:@"%s", what];
}

@interface Database : NSObject <IsiXDCMTKSCPDatabase>
@end
@implementation Database { int _responses; }
- (IsiXDCMTKSCPRequestStart)startFindWithSOPClass:(NSString *)sopClass identifier:(IsiXDCMTKDataset *)identifier
{
    fail(findFailure, "the index went away");
    _responses = 2;
    return IsiXDCMTKSCPRequestStartMatches;
}
- (BOOL)nextFindResponse:(IsiXDCMTKDataset *)response
{
    if (_responses <= 0) return NO;
    _responses--;
    [response putValue:[@"STUDY" dataUsingEncoding:NSASCIIStringEncoding] forTag:0x00080052 error:NULL];
    [response putValue:[@"ADAPTER^FIND" dataUsingEncoding:NSASCIIStringEncoding] forTag:0x00100010 error:NULL];
    return YES;
}
- (IsiXDCMTKSCPRequestStart)startRetrieveWithSOPClass:(NSString *)sopClass identifier:(IsiXDCMTKDataset *)identifier
                                     moveDestination:(NSData *)moveDestination
{
    fail(retrieveFailure, "the index went away");
    return IsiXDCMTKSCPRequestStartNoMatch;
}
- (NSInteger)retrieveCount { return 0; }
- (NSString *)nextRetrievePath { return nil; }
- (void)cancelRetrieve {}
- (NSString *)receivingDirectory { return receiving; }
- (NSString *)publishReceivedFileAtPath:(NSString *)path
{
    fail(publishFailure, "the disk went away");
    NSError *error = nil;
    NSString *destination = [published stringByAppendingPathComponent:path.lastPathComponent];
    return [NSFileManager.defaultManager moveItemAtPath:path toPath:destination error:&error] ? nil : error.localizedDescription;
}
- (BOOL)namesSenderInReceivedFiles { return YES; }
- (BOOL)namesCalledTitleInReceivedFiles { return NO; }
- (void)didStoreInstanceWithAttributes:(NSDictionary<NSNumber *, NSData *> *)attributes
{
    NSData *name = attributes[@(0x00100010)];
    if ([[[NSString alloc] initWithData:name encoding:NSASCIIStringEncoding] isEqual:@"ADAPTER^STORE"]) stored++;
}
- (void)didEndStoreOfInstance:(NSString *)sopInstanceUID study:(NSString *)studyInstanceUID
                       series:(NSString *)seriesInstanceUID status:(uint16_t)status { endedStores++; }
- (void)associationEndedIncomplete { incomplete++; }
- (void)close { closedDatabases++; }
@end

@interface Host : NSObject <IsiXDCMTKListenerHost>
@end
@implementation Host
- (id<IsiXDCMTKSCPDatabase>)databaseForCallingAETitle:(NSString *)callingAETitle { return [Database new]; }
- (IsiXDCMTKMoveDestination *)moveDestinationForAETitle:(NSString *)aeTitle { return nil; }
- (BOOL)answersCommand:(IsiXDCMTKListenerCommand)command { return YES; }
- (NSUInteger)maximumConcurrentAssociations { return 4; }
- (BOOL)isListenerAETitle:(NSData *)calledAETitle { return YES; }
- (uint16_t)finalStatusOfGet:(uint16_t)proposed completed:(NSUInteger)completed failed:(NSUInteger)failed
                    warnings:(NSUInteger)warnings { return proposed; }
- (void)associationEndedWithError:(NSError *)error message:(NSString *)message
{
    if ([IsiXDCMTKError kindOfError:error] == IsiXDCMTKConditionKindPeerAbortedAssociation) peerAborts++;
    if ([IsiXDCMTKError kindOfError:error] == IsiXDCMTKConditionKindNoDataAvailable) {
        @synchronized (starvedMessages) { [starvedMessages addObject:message]; }
        starved++;
    }
}
- (void)startAssociationThread:(NSThread *)thread peer:(NSString *)peer { [thread start]; }
- (void)association:(NSString *)peer willServe:(IsiXDCMTKListenerCommand)command secure:(BOOL)secure {}
- (void)associationDidEnd { endedAssociations++; }
@end

static IsiXDCMTKListener *makeListener(int port, Host *host, int timeout = 10)
{
    IsiXDCMTKListenerSettings *settings = [IsiXDCMTKListenerSettings new];
    settings.port = port;
    settings.aeTitle = @"ADAPTERSCP";
    settings.preferredTransferSyntax = EXS_LittleEndianExplicit;
    settings.timeout = timeout;
    settings.connectionTimeout = 5;
    settings.maxAssociations = 8;
    return [[IsiXDCMTKListener alloc] initWithSettings:settings host:host];
}

static bool answers(int port)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    bool connected = connect(s, (struct sockaddr *)&address, sizeof address) == 0;
    close(s);
    return connected;
}

static bool waitFor(std::atomic<int> &counter, int value, int tries = 200)
{
    for (int i = 0; i < tries && counter.load() < value; i++) usleep(25000);
    return counter.load() >= value;
}

static OFCondition associate(DcmSCU &scu, int port)
{
    scu.setAETitle("ADAPTERSCU");
    scu.setPeerHostName("127.0.0.1");
    scu.setPeerPort(port);
    scu.setPeerAETitle("ADAPTERSCP");
    scu.setACSETimeout(10);
    scu.setDIMSETimeout(10);
    scu.setDIMSEBlockingMode(DIMSE_BLOCKING);
    OFList<OFString> syntaxes;
    syntaxes.push_back(UID_LittleEndianExplicitTransferSyntax);
    syntaxes.push_back(UID_LittleEndianImplicitTransferSyntax);
    for (const char *model : {UID_VerificationSOPClass, UID_FINDStudyRootQueryRetrieveInformationModel,
                              UID_GETStudyRootQueryRetrieveInformationModel, UID_SecondaryCaptureImageStorage})
        scu.addPresentationContext(model, syntaxes);
    OFCondition result = scu.initNetwork();
    return result.good() ? scu.negotiateAssociation() : result;
}

static Uint16 find(DcmSCU &scu, size_t *matches)
{
    DcmDataset keys;
    keys.putAndInsertString(DCM_QueryRetrieveLevel, "STUDY");
    keys.putAndInsertString(DCM_PatientName, "");
    OFList<QRResponse *> responses;
    OFCondition result = scu.sendFINDRequest(scu.findAnyPresentationContextID(UID_FINDStudyRootQueryRetrieveInformationModel, ""),
                                             &keys, &responses);
    Uint16 status = result.good() && !responses.empty() ? responses.back()->m_status : 0xFFFF;
    *matches = 0;
    for (QRResponse *response : responses) {
        OFString name;
        if (response->m_dataset && response->m_dataset->findAndGetOFString(DCM_PatientName, name).good() && name == "ADAPTER^FIND")
            ++*matches;
        delete response;
    }
    return status;
}

static Uint16 get(DcmSCU &scu)
{
    DcmDataset keys;
    keys.putAndInsertString(DCM_QueryRetrieveLevel, "STUDY");
    keys.putAndInsertString(DCM_StudyInstanceUID, "1.2.826.0.1.3680043.8.498.1486.1");
    OFList<RetrieveResponse *> responses;
    OFCondition result = scu.sendCGETRequest(scu.findAnyPresentationContextID(UID_GETStudyRootQueryRetrieveInformationModel, ""),
                                             &keys, &responses);
    Uint16 status = result.good() && !responses.empty() ? responses.back()->m_status : 0xFFFF;
    for (RetrieveResponse *response : responses) delete response;
    return status;
}

static void fillInstance(DcmDataset &dataset, int instance)
{
    char uid[64];
    snprintf(uid, sizeof uid, "1.2.826.0.1.3680043.8.498.1486.2.%d", instance);
    dataset.putAndInsertString(DCM_SOPClassUID, UID_SecondaryCaptureImageStorage);
    dataset.putAndInsertString(DCM_SOPInstanceUID, uid);
    dataset.putAndInsertString(DCM_StudyInstanceUID, "1.2.826.0.1.3680043.8.498.1486.1");
    dataset.putAndInsertString(DCM_SeriesInstanceUID, "1.2.826.0.1.3680043.8.498.1486.3");
    dataset.putAndInsertString(DCM_PatientName, "ADAPTER^STORE");
    dataset.putAndInsertUint16(DCM_Rows, 2); dataset.putAndInsertUint16(DCM_Columns, 2);
    dataset.putAndInsertUint16(DCM_BitsAllocated, 16); dataset.putAndInsertUint16(DCM_BitsStored, 16);
    dataset.putAndInsertUint16(DCM_HighBit, 15); dataset.putAndInsertUint16(DCM_PixelRepresentation, 0);
    dataset.putAndInsertUint16(DCM_SamplesPerPixel, 1);
    dataset.putAndInsertString(DCM_PhotometricInterpretation, "MONOCHROME2");
    const Uint16 pixels[4] = {1, 2, 3, 4};
    dataset.putAndInsertUint16Array(DCM_PixelData, pixels, 4);
}

static Uint16 store(DcmSCU &scu, int instance)
{
    DcmDataset dataset;
    fillInstance(dataset, instance);
    Uint16 status = 0xFFFF;
    OFCondition result = scu.sendSTORERequest(scu.findAnyPresentationContextID(UID_SecondaryCaptureImageStorage, ""),
                                              "", &dataset, status);
    return result.good() ? status : 0xFFFF;
}

// A peer that writes its PDVs itself, in Implicit VR Little Endian, so that
// it can stop in the middle of a message and leave the connection open.
struct RawPeer
{
    T_ASC_Network *network = NULL;
    T_ASC_Association *association = NULL;
    T_ASC_PresentationContextID find = 0, storage = 0;

    bool associate(int port)
    {
        if (ASC_initializeNetwork(NET_REQUESTOR, 0, 10, &network).bad()) return false;
        T_ASC_Parameters *parameters = NULL;
        if (ASC_createAssociationParameters(&parameters, ASC_DEFAULTMAXPDU, 10).bad()) return false;
        char peer[64];
        snprintf(peer, sizeof peer, "127.0.0.1:%d", port);
        ASC_setAPTitles(parameters, "RAWPEER", "ADAPTERSCP", NULL);
        ASC_setPresentationAddresses(parameters, "localhost", peer);
        const char *syntaxes[] = {UID_LittleEndianImplicitTransferSyntax};
        ASC_addPresentationContext(parameters, 1, UID_FINDStudyRootQueryRetrieveInformationModel, syntaxes, 1);
        ASC_addPresentationContext(parameters, 3, UID_SecondaryCaptureImageStorage, syntaxes, 1);
        if (ASC_requestAssociation(network, parameters, &association).bad()) return false;
        find = ASC_findAcceptedPresentationContextID(association, UID_FINDStudyRootQueryRetrieveInformationModel);
        storage = ASC_findAcceptedPresentationContextID(association, UID_SecondaryCaptureImageStorage);
        return find != 0 && storage != 0;
    }

    // The command set of a request that says a data set follows it.
    static void fillCommand(DcmDataset &command, const char *sopClass, Uint16 field, const char *sopInstance)
    {
        command.putAndInsertString(DCM_AffectedSOPClassUID, sopClass);
        command.putAndInsertUint16(DCM_CommandField, field);
        command.putAndInsertUint16(DCM_MessageID, 1);
        command.putAndInsertUint16(DCM_Priority, DIMSE_PRIORITY_MEDIUM);
        command.putAndInsertUint16(DCM_CommandDataSetType, DIMSE_DATASET_PRESENT);
        if (sopInstance) command.putAndInsertString(DCM_AffectedSOPInstanceUID, sopInstance);
    }

    // Writes one PDV, in a PDU of its own: all of `dataset` as the last
    // fragment, or, with `whole` false, its first half as a fragment that is
    // not the last.
    bool write(DcmDataset &dataset, T_ASC_PresentationContextID context, DUL_DATAPDV type, bool whole)
    {
        std::vector<char> buffer(16384);
        DcmOutputBufferStream stream(buffer.data(), (offile_off_t)buffer.size());
        dataset.transferInit();
        OFCondition written = dataset.write(stream, EXS_LittleEndianImplicit, EET_ExplicitLength, NULL,
                                            type == DUL_COMMANDPDV ? EGL_withGL : EGL_withoutGL);
        dataset.transferEnd();
        void *bytes = NULL;
        offile_off_t length = 0;
        stream.flushBuffer(bytes, length);
        if (written.bad() || length < 4) return false;
        DUL_PDV pdv = {};
        pdv.fragmentLength = whole ? (unsigned long)length : ((unsigned long)length / 2) & ~1UL;
        pdv.presentationContextID = context;
        pdv.pdvType = type;
        pdv.lastPDV = whole ? OFTrue : OFFalse;
        pdv.data = bytes;
        DUL_PDVLIST list = {};
        list.count = 1;
        list.pdv = &pdv;
        return DUL_WritePDVs(&association->DULassociation, &list).good();
    }

    // Without an A-ABORT: the listener has closed the connection by then.
    void close()
    {
        if (association) {
            ASC_closeTransportConnection(association);
            ASC_destroyAssociation(&association);
        }
        if (network) ASC_dropNetwork(&network);
    }
};

static NSString *lastStarvedMessage(void)
{
    @synchronized (starvedMessages) { return starvedMessages.lastObject; }
}

// Whether `message` is the end of RAWPEER's association on the no-data
// condition, after the listener waited 2 s for `missing`.
static bool saysStarved(NSString *message, NSString *missing)
{
    NSString *end = [NSString stringWithFormat:@": nothing received for 2 s while reading %@", missing];
    return [message hasPrefix:@"DICOM association from RAWPEER ("] && [message containsString:@") to ADAPTERSCP ended: 0006:0207 "]
        && [message hasSuffix:end];
}

static NSArray<NSString *> *publishedFiles(void)
{
    return [NSFileManager.defaultManager contentsOfDirectoryAtPath:published error:NULL] ?: @[];
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        const int port = atoi(argv[1]);
        receiving = @(argv[2]);
        published = @(argv[3]);
        const int quietPort = atoi(argv[4]);
        starvedMessages = [NSMutableArray array];
        check(IsiXDCMTKListener.dataDictionaryLoaded, "DCMTK's data dictionary is loaded");

        Host *host = [Host new];
        IsiXDCMTKListener *listener = makeListener(port, host);
        NSError *error = nil;
        check(listener && [listener openNetwork:&error] && !error, "the listener opens its port");
        check([listener configure:&error] && !error, "and reads its DCMTK configuration");

        // A DCMTK error: the same port, twice.
        IsiXDCMTKListener *second = makeListener(port, host);
        error = nil;
        check(![second openNetwork:&error], "a second listener on the port does not open it");
        NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
        check([error.domain isEqual:IsiXDCMTKErrorDomain] && [error.userInfo[IsiXDCMTKOperationKey] isEqual:@"ASC_initializeNetwork"]
              && [underlying.domain isEqual:NSPOSIXErrorDomain] && underlying.code == EADDRINUSE,
              "the error is DCMTK's, names the step and gives errno EADDRINUSE");
        printf("  %s (errno %ld)\n", error.localizedDescription.UTF8String, (long)underlying.code);
        [second close];

        static std::atomic<bool> stop{false};
        static std::atomic<bool> stopped{false};
        __block NSError *closed = [NSError errorWithDomain:@"not closed" code:1 userInfo:nil];
        [NSThread detachNewThreadWithBlock:^{
            [listener serveUntil:^BOOL { return stop.load(); }];
            closed = [listener close];
            stopped = true;
        }];

        {
            DcmSCU scu;
            check(associate(scu, port).good(), "an association is accepted");
            check(scu.sendECHORequest(scu.findAnyPresentationContextID(UID_VerificationSOPClass, "")).good(), "C-ECHO is answered");
            size_t matches = 0;
            check(find(scu, &matches) == STATUS_Success && matches == 2, "a C-FIND gives the database's two matches");
            findFailure = ThrowCxx;
            check(find(scu, &matches) == STATUS_FIND_Failed_UnableToProcess && matches == 0,
                  "a C++ exception in the database's C-FIND ends it with Unable to process");
            findFailure = RaiseObjC;
            check(find(scu, &matches) == STATUS_FIND_Failed_UnableToProcess,
                  "an Objective-C exception in the database's C-FIND ends it with Unable to process");
            findFailure = Succeed;
            check(find(scu, &matches) == STATUS_Success && matches == 2, "and the association answers the next C-FIND");

            check(store(scu, 1) == STATUS_Success && waitFor(stored, 1), "a C-STORE is stored through the database");
            NSArray<NSString *> *files = publishedFiles();
            check(files.count == 1, "and published to its folder");
            if (files.count == 1) {
                DcmFileFormat file;
                OFString sender;
                NSString *path = [published stringByAppendingPathComponent:files[0]];
                check(file.loadFile(path.fileSystemRepresentation).good()
                      && file.getMetaInfo()->findAndGetOFString(DCM_SourceApplicationEntityTitle, sender).good() && sender == "ADAPTERSCU",
                      "with the sender's AE title in the file");
            }
            publishFailure = ThrowCxx;
            check(store(scu, 2) == STATUS_STORE_Refused_OutOfResources, "a C++ exception publishing a file refuses the C-STORE");
            publishFailure = RaiseObjC;
            check(store(scu, 3) == STATUS_STORE_Refused_OutOfResources, "so does an Objective-C exception");
            publishFailure = Succeed;
            check(publishedFiles().count == 1 && stored == 1, "and neither is published or recorded");
            check(endedStores == 3, "each C-STORE's end reaches the database");

            check(get(scu) == STATUS_Success, "a C-GET of nothing ends with Success");
            retrieveFailure = ThrowCxx;
            check(get(scu) == STATUS_GET_Failed_UnableToProcess, "a C++ exception in the database's retrieve ends the C-GET with Unable to process");
            retrieveFailure = RaiseObjC;
            check(get(scu) == STATUS_GET_Failed_UnableToProcess, "so does an Objective-C exception");
            retrieveFailure = Succeed;
            check(scu.sendECHORequest(scu.findAnyPresentationContextID(UID_VerificationSOPClass, "")).good(),
                  "the association still answers");
            check(scu.releaseAssociation().good(), "and is released");
        }
        check(waitFor(endedAssociations, 1) && waitFor(closedDatabases, 1) && incomplete == 0,
              "a released association closes its database, complete");

        {
            DcmSCU scu;
            check(associate(scu, port).good(), "another association is accepted");
            size_t matches = 0;
            find(scu, &matches);
            scu.abortAssociation();
        }
        check(waitFor(incomplete, 1) && waitFor(peerAborts, 1) && waitFor(closedDatabases, 2),
              "an association its peer aborts ends incomplete, with the peer-abort error, and closes its database");

        // A peer that begins a message and sends no more of it, with the
        // connection open, against a listener of its own that waits 2 s.
        {
            IsiXDCMTKListener *quiet = makeListener(quietPort, host, 2);
            error = nil;
            check(quiet && [quiet openNetwork:&error] && [quiet configure:&error] && !error,
                  "a second listener, which waits 2 s for its peers, opens another port");
            static std::atomic<bool> stopQuiet{false};
            static std::atomic<bool> quietStopped{false};
            [NSThread detachNewThreadWithBlock:^{
                [quiet serveUntil:^BOOL { return stopQuiet.load(); }];
                [quiet close];
                quietStopped = true;
            }];

            {
                RawPeer peer;
                check(peer.associate(quietPort), "it accepts a peer that writes its own PDVs");
                const int incompleteBefore = incomplete, closedBefore = closedDatabases;
                DcmDataset command;
                RawPeer::fillCommand(command, UID_FINDStudyRootQueryRetrieveInformationModel, DIMSE_C_FIND_RQ, NULL);
                check(peer.write(command, peer.find, DUL_COMMANDPDV, true),
                      "the peer sends the command of a C-FIND-RQ and nothing of its identifier");
                check(waitFor(starved, 1, 400), "the association ends with an error of the no-data kind");
                NSString *message = lastStarvedMessage();
                printf("  %s\n", message.UTF8String ?: "(no message)");
                check(saysStarved(message, @"the identifier of a C-FIND-RQ"),
                      "whose message names the peer, its address, the 2 s and the identifier of a C-FIND-RQ");
                check(waitFor(incomplete, incompleteBefore + 1) && waitFor(closedDatabases, closedBefore + 1),
                      "and its database is told it ended incomplete, and closed");
                peer.close();
            }
            {
                RawPeer peer;
                check(peer.associate(quietPort), "it accepts another");
                const int incompleteBefore = incomplete, closedBefore = closedDatabases;
                const int storedBefore = stored;
                const NSUInteger publishedBefore = publishedFiles().count;
                DcmDataset command, dataset;
                RawPeer::fillCommand(command, UID_SecondaryCaptureImageStorage, DIMSE_C_STORE_RQ, "1.2.826.0.1.3680043.8.498.1486.2.9");
                fillInstance(dataset, 9);
                check(peer.write(command, peer.storage, DUL_COMMANDPDV, true) && peer.write(dataset, peer.storage, DUL_DATASETPDV, false),
                      "the peer sends the command of a C-STORE-RQ and the first part of its data set");
                check(waitFor(starved, 2, 400), "the association ends with an error of the no-data kind");
                NSString *message = lastStarvedMessage();
                printf("  %s\n", message.UTF8String ?: "(no message)");
                check(saysStarved(message, @"the data set of a C-STORE-RQ"),
                      "whose message names the peer, its address, the 2 s and the data set of a C-STORE-RQ");
                check(waitFor(incomplete, incompleteBefore + 1) && waitFor(closedDatabases, closedBefore + 1),
                      "and its database is told it ended incomplete, and closed");
                check(publishedFiles().count == publishedBefore && stored == storedBefore, "nothing of the instance is published or recorded");
                peer.close();
            }
            {
                RawPeer peer;
                check(peer.associate(quietPort), "and a third");
                const int incompleteBefore = incomplete;
                DcmDataset command;
                RawPeer::fillCommand(command, UID_FINDStudyRootQueryRetrieveInformationModel, DIMSE_C_FIND_RQ, NULL);
                check(peer.write(command, peer.find, DUL_COMMANDPDV, false),
                      "the peer sends the first half of a command, as a fragment that is not the last");
                check(waitFor(starved, 3, 400), "the association ends with an error of the no-data kind");
                NSString *message = lastStarvedMessage();
                printf("  %s\n", message.UTF8String ?: "(no message)");
                check(saysStarved(message, @"the rest of a command"),
                      "whose message names the peer, its address, the 2 s and the rest of a command");
                check(incomplete == incompleteBefore, "no database was opened for it");
                peer.close();
            }
            check(peerAborts == 1, "none of the three ends is a peer abort");

            stopQuiet = true;
            for (int i = 0; i < 400 && !quietStopped; i++) usleep(25000);
            check(quietStopped, "stopped, the second listener closes");
        }

        stop = true;
        for (int i = 0; i < 400 && !stopped; i++) usleep(25000);
        check(stopped && closed == nil, "stopped, the listener closes without an error");
        check(!answers(port), "and nothing answers on its port");
        IsiXDCMTKListener *again = makeListener(port, host);
        error = nil;
        check([again openNetwork:&error] && answers(port), "a new listener opens the port again");
        check([again close] == nil && !answers(port), "and closes it");
    }
    return failures ? 1 : 0;
}
'''


def free_port():
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        return probe.getsockname()[1]


with tempfile.TemporaryDirectory(prefix='isix-dcmtk-scp-adapter-') as temporary:
    folder = Path(temporary)
    executable = dcmtk_scp_adapter.build(folder, DRIVER)
    for name in ('receiving', 'published'):
        (folder / name).mkdir()
    try:
        ports = set()
        while len(ports) < 2:
            ports.add(free_port())
        port, quiet_port = sorted(ports)
        run = subprocess.run([str(executable), str(port), str(folder / 'receiving'), str(folder / 'published'), str(quiet_port)],
                             capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        print('FAIL: the adapter driver did not end within 120 s')
        sys.exit(1)
    print(run.stdout, end='')
    if run.returncode:
        print(run.stderr[-3000:])
        print('FAIL: the adapter driver failed (exit %d)' % run.returncode)
        sys.exit(1)
print('PASS: the listener\'s DCMTK errors and its database\'s exceptions reach the application as NSError or a DIMSE status')
