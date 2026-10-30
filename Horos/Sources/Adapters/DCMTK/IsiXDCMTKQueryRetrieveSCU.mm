//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The associations of the query nodes (verification, C-FIND, C-MOVE and C-GET
// as the Query window, the auto-retrieve and Locations' Verify ask for them)
// and of a send (its storage presentation contexts; the C-STOREs are in
// IsiXDCMTKStoreSCU.mm). What to ask, when to give up and what to tell the
// user stay in Swift (DCMTKQueryNode+Network.swift, DCMTKStoreSCU.swift);
// this file is what DCMTK does for them. Compiled with ARC.

#import "IsiXDCMTKQueryRetrieveSCU.h"
#import "IsiXDCMTKInternal.hpp"

#include "HorosDIMSEAssociation.h"
#include "IsiXDCMTKRetrieveLoops.hpp"
#include "HorosDICOMGlobalAbort.h"
#include "HorosTLSConfiguration.h"

#include <dcmtk/dcmnet/dimse.h>
#include <dcmtk/dcmnet/diutil.h>
#include <dcmtk/dcmnet/dicom.h>
#include <dcmtk/dcmdata/dcdatset.h>
#include <dcmtk/dcmdata/dcdict.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <string>
#include <dcmtk/dcmdata/dcuid.h>
#include <dcmtk/ofstd/ofstd.h>
#include <dcmtk/ofstd/ofstream.h>
#ifdef WITH_OPENSSL
#include <dcmtk/dcmtls/tlstrans.h>
#include <dcmtk/dcmtls/tlslayer.h>
#include <dcmtk/dcmtls/tlsciphr.h>
#endif

#include <cstdarg>
#include <ctime>
#include <mutex>
#include <unistd.h>
#include <vector>

#if !__has_feature(objc_arc)
#error "IsiXDCMTKQueryRetrieveSCU.mm is compiled with ARC (-fobjc-arc)"
#endif

#ifndef WITH_OPENSSL
class DcmTLSTransportLayer;
#endif

// The name the diagnostics have always carried.
#define OFFIS_CONSOLE_APPLICATION "DCMTKQueryNode"
#define APPLICATIONTITLE "FINDSCU"
#define PEERAPPLICATIONTITLE "ANY-SCP"

static void errmsg(const char *message, ...)
{
    va_list args;
    fprintf(stderr, "%s: ", OFFIS_CONSOLE_APPLICATION);
    va_start(args, message);
    vfprintf(stderr, message, args);
    va_end(args);
    fprintf(stderr, "\n");
}

// The legacy diagnostic destinations, newlines and association direction.
static void IsiXDCMTKDumpCondition(const OFCondition &condition)
{
    OFString text;
    DimseCondition::dump(text, condition);
    ofConsole.lockCerr() << text << OFendl;
    ofConsole.unlockCerr();
}

static void IsiXDCMTKDumpParameters(T_ASC_Parameters *parameters)
{
    OFString text;
    ASC_dumpParameters(text, parameters, ASC_ASSOC_AC);
    COUT << text << OFendl;
}

static NSString *IsiXDCMTKConditionReason(NSString *step, const OFCondition &condition)
{
    return [NSString stringWithFormat:@"%@ - %04x:%04x %s", step, condition.module(), condition.code(), condition.text()];
}

// errmsg under the name the association's caller gives its diagnostics.
static void IsiXDCMTKReport(NSString *application, const char *message)
{
    fprintf(stderr, "%s: %s\n", application.UTF8String ?: OFFIS_CONSOLE_APPLICATION, message);
}

// The error of a step of the set-up, naming the DCMTK call that failed.
static NSError *IsiXDCMTKStepError(NSString *step, const OFCondition &condition, BOOL secureTransport = NO)
{
    NSError *error = IsiXDCMTKErrorFromCondition(condition, IsiXDCMTKConditionReason(step, condition), secureTransport);
    if (!error) return nil;
    NSMutableDictionary *info = [error.userInfo mutableCopy];
    info[IsiXDCMTKOperationKey] = step;
    return [NSError errorWithDomain:error.domain code:error.code userInfo:info];
}

static BOOL IsiXDCMTKIsGet(const char *abstractSyntax)
{
    return strcmp(abstractSyntax, UID_GETPatientRootQueryRetrieveInformationModel) == 0 ||
        strcmp(abstractSyntax, UID_GETStudyRootQueryRetrieveInformationModel) == 0 ||
        strcmp(abstractSyntax, UID_GETPatientStudyOnlyQueryRetrieveInformationModel) == 0;
}

#pragma mark Deferred release

// An association given up on may still be in use by the thread that requested
// it: its network, association and TLS layer are destroyed two minutes after
// it is released, or as soon as the global abort is asked for.
struct IsiXDCMTKRetired {
    time_t since;
    T_ASC_Association *association;
    T_ASC_Network *network;
    DcmTLSTransportLayer *layer;
};

// Never destroyed: the release thread below runs until the process ends, and a
// function-local static would be destroyed at exit while that thread still
// locks it, which aborts with "mutex lock failed".
static std::mutex &IsiXDCMTKRetiredLock() { static std::mutex *lock = new std::mutex; return *lock; }
static std::vector<IsiXDCMTKRetired> &IsiXDCMTKRetiredList() { static auto *list = new std::vector<IsiXDCMTKRetired>; return *list; }

static void IsiXDCMTKDestroy(IsiXDCMTKRetired &retired)
{
    try {
        if (retired.association) {
            OFCondition condition = ASC_destroyAssociation(&retired.association);
            if (condition.bad()) IsiXDCMTKDumpCondition(condition);
        }
        if (retired.network) {
            OFCondition condition = ASC_dropNetwork(&retired.network);
            if (condition.bad()) IsiXDCMTKDumpCondition(condition);
        }
#ifdef WITH_OPENSSL
        delete retired.layer;
#endif
    } catch (const std::exception &exception) {
        IsiXDCMTKErrorFromException(exception.what(), "ASC_destroyAssociation");
    } catch (...) {
        IsiXDCMTKErrorFromException("unknown exception", "ASC_destroyAssociation");
    }
}

static void IsiXDCMTKRetire(IsiXDCMTKRetired retired)
{
    if (!retired.association && !retired.network && !retired.layer) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSThread detachNewThreadWithBlock:^{
            [NSThread currentThread].name = @"DCMTK Network release variables";
            while (true) @autoreleasepool {
                const bool abort = HorosDICOMGlobalAbortRequested();
                const time_t now = time(NULL);
                std::vector<IsiXDCMTKRetired> due;
                {
                    std::lock_guard<std::mutex> guard(IsiXDCMTKRetiredLock());
                    auto &list = IsiXDCMTKRetiredList();
                    for (auto entry = list.begin(); entry != list.end();) {
                        if (abort || now - entry->since > 120) { due.push_back(*entry); entry = list.erase(entry); }
                        else ++entry;
                    }
                }
                for (auto &entry : due) IsiXDCMTKDestroy(entry);
                [NSThread sleepForTimeInterval:1];
            }
        }];
    });
    retired.since = time(NULL);
    std::lock_guard<std::mutex> guard(IsiXDCMTKRetiredLock());
    IsiXDCMTKRetiredList().push_back(retired);
}

#pragma mark Parameters and results

@implementation IsiXDCMTKPresentationContext

- (instancetype)initWithIdentifier:(uint8_t)identifier abstractSyntax:(NSString *)abstractSyntax
                  transferSyntaxes:(NSArray<NSString *> *)transferSyntaxes
{
    if ((self = [super init])) {
        _identifier = identifier;
        _abstractSyntax = [abstractSyntax copy];
        _transferSyntaxes = [transferSyntaxes copy];
    }
    return self;
}

@end

@implementation IsiXDCMTKAssociationParameters

- (instancetype)init
{
    if ((self = [super init])) {
        _peerHost = @"";
        _abstractSyntax = @"";
        _preferredTransferSyntax = EXS_LittleEndianExplicit;
        _trustedCertificateFiles = @[];
        _cipherSuites = @[];
        _certificateVerification = 2;
    }
    return self;
}

@end

@interface IsiXDCMTKFindResult ()
@property (readwrite, nullable) NSError *condition;
@property (readwrite) BOOL conditionGood;
@property (readwrite) uint16_t status;
@property (readwrite, copy) NSString *statusText;
@property (readwrite, nullable, copy) NSString *statusDetail;
@end

@implementation IsiXDCMTKFindResult
- (instancetype)init
{
    if ((self = [super init])) _statusText = @"";
    return self;
}
@end

@interface IsiXDCMTKRetrieveResult ()
@property (readwrite, nullable) NSError *condition;
@property (readwrite) BOOL conditionGood;
@property (readwrite) uint16_t status;
@property (readwrite) unsigned completed;
@property (readwrite) unsigned failed;
@property (readwrite) unsigned warnings;
@property (readwrite) unsigned remaining;
@property (readwrite, copy) NSString *moveStatusText;
@property (readwrite, nullable, copy) NSString *failedSOPInstanceUIDs;
@property (copy) NSString *responseDump;
@end

@implementation IsiXDCMTKRetrieveResult
- (instancetype)init
{
    if ((self = [super init])) { _moveStatusText = @""; _responseDump = @""; }
    return self;
}

- (void)printResponse
{
    fprintf(stdout, "%s\n", self.responseDump.UTF8String ?: "");
}

@end

// The counts, status and failed instances of a final response, and the
// response as DIMSE_printCMoveRSP and DIMSE_printCGetRSP print it.
template <typename Response>
static void IsiXDCMTKFillRetrieveResult(IsiXDCMTKRetrieveResult *result, Response &response, DcmDataset *identifiers)
{
    result.status = response.DimseStatus;
    result.completed = response.NumberOfCompletedSubOperations;
    result.failed = response.NumberOfFailedSubOperations;
    result.warnings = response.NumberOfWarningSubOperations;
    result.remaining = response.NumberOfRemainingSubOperations;
    result.moveStatusText = [NSString stringWithUTF8String:DU_cmoveStatusString(response.DimseStatus)] ?: @"";
    OFString failed;
    if (identifiers && identifiers->findAndGetOFStringArray(DCM_FailedSOPInstanceUIDList, failed).good())
        result.failedSOPInstanceUIDs = [NSString stringWithUTF8String:failed.c_str()];
    OFString dump;
    DIMSE_dumpMessage(dump, response, DIMSE_INCOMING);
    result.responseDump = [NSString stringWithUTF8String:dump.c_str()] ?: @"";
}

#pragma mark Callbacks

struct IsiXDCMTKFindContext {
    __unsafe_unretained void (^response)(IsiXDCMTKDataset *);
};

static void IsiXDCMTKFindCallback(void *data, T_DIMSE_C_FindRQ *, int, T_DIMSE_C_FindRSP *, DcmDataset *identifiers)
{
    if (!identifiers) return;
    IsiXDCMTKFindContext *context = static_cast<IsiXDCMTKFindContext *>(data);
    @autoreleasepool {
        context->response(IsiXDCMTKDatasetTakingOwnership(new DcmDataset(*identifiers)));
    }
}

struct IsiXDCMTKProgressContext {
    __unsafe_unretained void (^progress)(BOOL, NSUInteger, NSUInteger);
};

template <typename Response>
static void IsiXDCMTKReportProgress(void *data, Response *response)
{
    IsiXDCMTKProgressContext *context = static_cast<IsiXDCMTKProgressContext *>(data);
    if (response == NULL) { context->progress(NO, 0, 0); return; }
    const unsigned finished = response->NumberOfCompletedSubOperations + response->NumberOfFailedSubOperations
                            + response->NumberOfWarningSubOperations;
    context->progress(YES, finished + response->NumberOfRemainingSubOperations, finished);
}

static void IsiXDCMTKMoveCallback(void *data, T_DIMSE_C_MoveRQ *, int, T_DIMSE_C_MoveRSP *response)
{
    @autoreleasepool { IsiXDCMTKReportProgress(data, response); }
}

static void IsiXDCMTKGetCallback(void *data, T_DIMSE_C_GetRQ *, int, T_DIMSE_C_GetRSP *response)
{
    @autoreleasepool { IsiXDCMTKReportProgress(data, response); }
}

static void IsiXDCMTKSubOperationCallback(void *, T_ASC_Network *, T_ASC_Association **)
{
}

struct IsiXDCMTKIncomingContext {
    __unsafe_unretained void (^incoming)(void);
};

static void IsiXDCMTKIncoming(void *data)
{
    IsiXDCMTKIncomingContext *context = static_cast<IsiXDCMTKIncomingContext *>(data);
    @autoreleasepool { if (context->incoming) context->incoming(); }
}

#pragma mark Association

@interface IsiXDCMTKAssociation ()
- (T_ASC_Association *)handle;
- (int)dimseTimeout;
@end

@implementation IsiXDCMTKAssociation
{
    T_ASC_Network *_network;
    T_ASC_Parameters *_parameters;
    T_ASC_Association *_association;
    DcmTLSTransportLayer *_layer;
    BOOL _verbose;
    BOOL _reportsFailures;
    NSString *_application;
    BOOL _get;
    int _dimseTimeout;
}

- (instancetype)initWithParameters:(IsiXDCMTKAssociationParameters *)parameters error:(NSError **)error
{
    if (!(self = [super init])) return nil;
    _verbose = parameters.verbose;
    _reportsFailures = parameters.reportsFailures;
    _application = [parameters.consoleApplication copy] ?: @OFFIS_CONSOLE_APPLICATION;
    _dimseTimeout = parameters.dimseTimeout;
    _get = IsiXDCMTKIsGet(parameters.abstractSyntax.UTF8String ?: "");
    if (!IsiXDCMTKGuard(error, "ASC_initializeNetwork", [&]() -> NSError * { return [self openWithParameters:parameters]; }))
        return nil;
    return self;
}

- (void)dealloc
{
    IsiXDCMTKRetired retired = {0, _association, _network, _layer};
    IsiXDCMTKRetire(retired);
}

- (NSError *)invalidate
{
    NSError *last = nil;
    try {
        if (_association) {
            OFCondition condition = ASC_destroyAssociation(&_association);
            if (condition.bad()) {
                IsiXDCMTKDumpCondition(condition);
                last = IsiXDCMTKStepError(@"ASC_destroyAssociation", condition);
            }
            _association = NULL;
        }
        if (_network) {
            OFCondition condition = ASC_dropNetwork(&_network);
            if (condition.bad()) {
                IsiXDCMTKDumpCondition(condition);
                last = IsiXDCMTKStepError(@"ASC_dropNetwork", condition);
            }
            _network = NULL;
        }
#ifdef WITH_OPENSSL
        delete _layer;
#endif
        _layer = NULL;
    } catch (const std::exception &exception) {
        last = IsiXDCMTKErrorFromException(exception.what(), "ASC_destroyAssociation");
    } catch (...) {
        last = IsiXDCMTKErrorFromException("unknown exception", "ASC_destroyAssociation");
    }
    return last;
}

- (NSError *)openWithParameters:(IsiXDCMTKAssociationParameters *)parameters
{
    const char *ourTitle = parameters.callingAETitle ? parameters.callingAETitle.UTF8String : APPLICATIONTITLE;
    const char *peerTitle = parameters.calledAETitle ? parameters.calledAETitle.UTF8String : PEERAPPLICATIONTITLE;

    // Make sure the data dictionary is loaded.
    if (!dcmDataDict.isDictionaryLoaded())
        fprintf(stderr, "Warning: no data dictionary loaded, check environment variable: %s\n", DCM_DICT_ENVIRONMENT_VARIABLE);

    OFCondition condition = ASC_initializeNetwork(NET_REQUESTOR, 0, parameters.acseTimeout, &_network);
    if (condition.bad()) {
        if (_verbose || _reportsFailures) IsiXDCMTKDumpCondition(condition);
        return IsiXDCMTKStepError(@"ASC_initializeNetwork", condition);
    }

#ifdef WITH_OPENSSL
    if (parameters.secureConnection) {
        _layer = new DcmTLSTransportLayer(NET_REQUESTOR, parameters.seedFile.fileSystemRepresentation, OFTrue);
        if (parameters.certificateVerification == 0 || parameters.certificateVerification == 1) {
            for (NSString *file in parameters.trustedCertificateFiles)
                if (_layer->addTrustedCertificateFile(file.fileSystemRepresentation, DCF_Filetype_PEM).bad())
                    return IsiXDCMTKFailure([NSString stringWithFormat:@"Unable to load certificate file %@", file], YES);
        }
        if (parameters.dhParameterFile && !_layer->setTempDHParameters(parameters.dhParameterFile.UTF8String))
            return IsiXDCMTKFailure([NSString stringWithFormat:@"Unable to load temporary DH parameter file %@", parameters.dhParameterFile], YES);
        if (parameters.privateKeyFile && parameters.certificateFile) {
            _layer->setPrivateKeyPasswd(parameters.privateKeyPassword.UTF8String);
            if (_layer->setPrivateKeyFile(parameters.privateKeyFile.UTF8String, DCF_Filetype_PEM).bad())
                return IsiXDCMTKFailure([NSString stringWithFormat:@"Unable to load private TLS key from %@", parameters.privateKeyFile], YES);
            if (_layer->setCertificateFile(parameters.certificateFile.UTF8String, DCF_Filetype_PEM, TSP_Profile_BCP_195_RFC_8996).bad())
                return IsiXDCMTKFailure([NSString stringWithFormat:@"Unable to load certificate from %@", parameters.certificateFile], YES);
            if (!_layer->checkPrivateKeyMatchesCertificate())
                return IsiXDCMTKFailure([NSString stringWithFormat:@"private key '%@' and certificate '%@' do not match",
                                         parameters.privateKeyFile, parameters.certificateFile], YES);
        }
        if (HorosConfigureTLSCipherSuites(*_layer, parameters.cipherSuites).bad())
            return IsiXDCMTKFailure(@"Unable to set selected cipher suites", YES);
        _layer->setCertificateVerification(parameters.certificateVerification == 0 ? DCV_requireCertificate
                                           : parameters.certificateVerification == 1 ? DCV_checkCertificate : DCV_ignoreCertificate);
        condition = ASC_setTransportLayer(_network, _layer, 0);
        if (condition.bad()) {
            if (_verbose || _reportsFailures) IsiXDCMTKDumpCondition(condition);
            return IsiXDCMTKStepError(@"ASC_setTransportLayer", condition, YES);
        }
    }
#endif

    const NSInteger connectionTimeout = parameters.connectionTimeout;
    condition = ASC_createAssociationParameters(&_parameters, parameters.maxReceivePDULength ?: ASC_DEFAULTMAXPDU,
                                                (Sint32)(connectionTimeout > 0 ? connectionTimeout : parameters.acseTimeout));
    if (condition.bad()) {
        if (_verbose || _reportsFailures) IsiXDCMTKDumpCondition(condition);
        return IsiXDCMTKStepError(@"ASC_createAssociationParameters", condition);
    }
    ASC_setAPTitles(_parameters, ourTitle, peerTitle, NULL);

    // An insecure connection unless TLS is asked for.
    condition = ASC_setTransportLayerType(_parameters, parameters.secureConnection ? OFTrue : OFFalse);
    if (condition.bad()) {
        if (_verbose || _reportsFailures) IsiXDCMTKDumpCondition(condition);
        return IsiXDCMTKStepError(@"ASC_setTransportLayerType", condition);
    }

    // Address formatting and dual-stack DNS fallback are application policy.
    DIC_NODENAME localHost;
    gethostname(localHost, sizeof(localHost) - 1);
    condition = HorosDIMSESetPeerAddress(_parameters, localHost, parameters.peerHost.UTF8String, parameters.peerPort);
    if (condition.bad()) {
        NSError *failure = IsiXDCMTKErrorFromCondition(condition);
        NSMutableDictionary *info = [failure.userInfo mutableCopy];
        info[IsiXDCMTKPeerAddressKey] = @YES;
        return [NSError errorWithDomain:failure.domain code:failure.code userInfo:info];
    }

    if (parameters.presentationContextsRefused)
        condition = ASC_BADPRESENTATIONCONTEXTID;
    else if (parameters.presentationContexts)
        condition = [self addPresentationContexts:parameters.presentationContexts];
    else
        condition = [self addPresentationContextsForAbstractSyntax:parameters.abstractSyntax.UTF8String
                                           preferredTransferSyntax:(E_TransferSyntax)parameters.preferredTransferSyntax];
    if (condition.bad()) {
        if (_verbose || _reportsFailures) IsiXDCMTKDumpCondition(condition);
        return IsiXDCMTKStepError(@"addPresentationContext", condition);
    }

    if (_verbose && !_get) {
        printf("Request Parameters:\n");
        IsiXDCMTKDumpParameters(_parameters);
    }
    if (_verbose) printf("Requesting Association\n");
    return nil;
}

// We prefer explicitly encoded transfer syntaxes, and Little Endian to Big
// Endian on a Little Endian machine. Some SCP implementations select the
// first transfer syntax they support (this is not part of the standard), so
// the order matters. A C-GET receives its C-STORE sub-operations on this
// association as Storage SCP, in the syntax of the preference.
- (OFCondition)addPresentationContextsForAbstractSyntax:(const char *)abstractSyntax
                                preferredTransferSyntax:(E_TransferSyntax)preferred
{
    if (!_parameters || !abstractSyntax || !abstractSyntax[0]) return EC_IllegalParameter;

    const char *transferSyntaxes[] = { NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL };
    int count = 0;
    switch (preferred) {
        case EXS_LittleEndianImplicit:
            transferSyntaxes[0] = UID_LittleEndianImplicitTransferSyntax;
            count = 1;
            break;
        default:
        case EXS_LittleEndianExplicit:
            transferSyntaxes[0] = UID_LittleEndianExplicitTransferSyntax;
            transferSyntaxes[1] = UID_LittleEndianImplicitTransferSyntax;
            transferSyntaxes[2] = UID_BigEndianExplicitTransferSyntax;
            transferSyntaxes[3] = UID_JPEG2000LosslessOnlyTransferSyntax;
            transferSyntaxes[4] = UID_JPEG2000TransferSyntax;
            transferSyntaxes[5] = UID_JPEGProcess14SV1TransferSyntax;
            transferSyntaxes[6] = UID_JPEGProcess1TransferSyntax;
            transferSyntaxes[7] = UID_JPEGProcess2_4TransferSyntax;
            transferSyntaxes[8] = UID_RLELosslessTransferSyntax;
            transferSyntaxes[9] = UID_MPEG2MainProfileAtMainLevelTransferSyntax;
            count = 10;
            break;
        case EXS_BigEndianExplicit:
            transferSyntaxes[0] = UID_BigEndianExplicitTransferSyntax;
            transferSyntaxes[1] = UID_LittleEndianExplicitTransferSyntax;
            transferSyntaxes[2] = UID_LittleEndianImplicitTransferSyntax;
            transferSyntaxes[3] = UID_JPEG2000TransferSyntax;
            transferSyntaxes[4] = UID_JPEGProcess14SV1TransferSyntax;
            transferSyntaxes[5] = UID_JPEGProcess1TransferSyntax;
            transferSyntaxes[6] = UID_JPEGProcess2_4TransferSyntax;
            transferSyntaxes[7] = UID_RLELosslessTransferSyntax;
            count = 8;
            break;
#ifndef DISABLE_COMPRESSION_EXTENSION
        case EXS_JPEGProcess14SV1TransferSyntax:
            transferSyntaxes[0] = UID_JPEGProcess14SV1TransferSyntax;
            transferSyntaxes[1] = UID_JPEGProcess1TransferSyntax;
            transferSyntaxes[2] = UID_JPEGProcess2_4TransferSyntax;
            transferSyntaxes[3] = UID_LittleEndianExplicitTransferSyntax;
            transferSyntaxes[4] = UID_LittleEndianImplicitTransferSyntax;
            transferSyntaxes[5] = UID_BigEndianExplicitTransferSyntax;
            count = 6;
            break;
        case EXS_JPEGProcess1TransferSyntax:
            transferSyntaxes[0] = UID_JPEGProcess1TransferSyntax;
            transferSyntaxes[1] = UID_JPEGProcess2_4TransferSyntax;
            transferSyntaxes[2] = UID_JPEGProcess14SV1TransferSyntax;
            transferSyntaxes[3] = UID_LittleEndianExplicitTransferSyntax;
            transferSyntaxes[4] = UID_LittleEndianImplicitTransferSyntax;
            transferSyntaxes[5] = UID_BigEndianExplicitTransferSyntax;
            count = 6;
            break;
        case EXS_JPEGProcess2_4TransferSyntax:
            transferSyntaxes[0] = UID_JPEGProcess2_4TransferSyntax;
            transferSyntaxes[1] = UID_JPEGProcess14SV1TransferSyntax;
            transferSyntaxes[2] = UID_JPEGProcess1TransferSyntax;
            transferSyntaxes[3] = UID_LittleEndianExplicitTransferSyntax;
            transferSyntaxes[4] = UID_LittleEndianImplicitTransferSyntax;
            transferSyntaxes[5] = UID_BigEndianExplicitTransferSyntax;
            count = 6;
            break;
        case EXS_JPEG2000LosslessOnly:
            transferSyntaxes[0] = UID_JPEG2000LosslessOnlyTransferSyntax;
            transferSyntaxes[1] = UID_LittleEndianExplicitTransferSyntax;
            transferSyntaxes[2] = UID_LittleEndianImplicitTransferSyntax;
            transferSyntaxes[3] = UID_BigEndianExplicitTransferSyntax;
            count = 4;
            break;
        case EXS_JPEG2000:
            transferSyntaxes[0] = UID_JPEG2000TransferSyntax;
            transferSyntaxes[1] = UID_JPEG2000LosslessOnlyTransferSyntax;
            transferSyntaxes[2] = UID_LittleEndianExplicitTransferSyntax;
            transferSyntaxes[3] = UID_LittleEndianImplicitTransferSyntax;
            transferSyntaxes[4] = UID_BigEndianExplicitTransferSyntax;
            count = 5;
            break;
        case EXS_JPEGLSLossless:
            transferSyntaxes[0] = UID_JPEGLSLosslessTransferSyntax;
            transferSyntaxes[1] = UID_LittleEndianExplicitTransferSyntax;
            transferSyntaxes[2] = UID_LittleEndianImplicitTransferSyntax;
            transferSyntaxes[3] = UID_BigEndianExplicitTransferSyntax;
            count = 4;
            break;
        case EXS_JPEGLSLossy:
            transferSyntaxes[0] = UID_JPEGLSLossyTransferSyntax;
            transferSyntaxes[1] = UID_JPEGLSLosslessTransferSyntax;
            transferSyntaxes[2] = UID_LittleEndianExplicitTransferSyntax;
            transferSyntaxes[3] = UID_LittleEndianImplicitTransferSyntax;
            transferSyntaxes[4] = UID_BigEndianExplicitTransferSyntax;
            count = 5;
            break;
        case EXS_RLELossless:
            transferSyntaxes[0] = UID_RLELosslessTransferSyntax;
            transferSyntaxes[1] = UID_LittleEndianExplicitTransferSyntax;
            transferSyntaxes[2] = UID_LittleEndianImplicitTransferSyntax;
            transferSyntaxes[3] = UID_BigEndianExplicitTransferSyntax;
            transferSyntaxes[4] = UID_JPEG2000TransferSyntax;
            transferSyntaxes[5] = UID_JPEGProcess14SV1TransferSyntax;
            transferSyntaxes[6] = UID_JPEGProcess2_4TransferSyntax;
            transferSyntaxes[7] = UID_JPEGProcess1TransferSyntax;
            transferSyntaxes[8] = UID_MPEG2MainProfileAtMainLevelTransferSyntax;
            count = 9;
            break;
#endif
    }

    OFCondition condition = ASC_addPresentationContext(_parameters, 1, abstractSyntax, transferSyntaxes, count);
    if (IsiXDCMTKIsGet(abstractSyntax)) {
        int identifier = 3; // only odd presentation context IDs
        for (int i = 0; i < numberOfDcmLongSCUStorageSOPClassUIDs && condition.good(); i++, identifier += 2)
            condition = ASC_addPresentationContext(_parameters, identifier, dcmLongSCUStorageSOPClassUIDs[i],
                                                   transferSyntaxes, count, ASC_SC_ROLE_SCP);
    }
    return condition;
}

// The contexts the caller planned, as they are; stops at the first DCMTK refuses.
- (OFCondition)addPresentationContexts:(NSArray<IsiXDCMTKPresentationContext *> *)contexts
{
    OFCondition condition = EC_Normal;
    for (IsiXDCMTKPresentationContext *context in contexts) {
        std::vector<const char *> syntaxes;
        for (NSString *syntax in context.transferSyntaxes) syntaxes.push_back(syntax.UTF8String);
        condition = ASC_addPresentationContext(_parameters, context.identifier, context.abstractSyntax.UTF8String,
                                               syntaxes.data(), (int)syntaxes.size());
        if (condition.bad()) break;
    }
    return condition;
}

- (NSError *)request
{
    NSError *error = nil;
    IsiXDCMTKGuard(&error, "ASC_requestAssociation", [&]() -> NSError * {
        T_ASC_Association *association = NULL;
        OFCondition condition = HorosDIMSERequestAssociation(_network, _parameters, &association);
        if (association) _association = association;
        if (condition == DUL_ASSOCIATIONREJECTED) {
            if (_verbose || _reportsFailures) {
                T_ASC_RejectParameters rejection;
                ASC_getRejectParameters(_parameters, &rejection);
                IsiXDCMTKReport(_application, "Association Rejected:");
                OFString text;
                ASC_printRejectParameters(text, &rejection);
                fprintf(stderr, "%s\n", text.c_str());
            }
        } else if (condition.bad()) {
            if (_verbose || _reportsFailures) {
                IsiXDCMTKReport(_application, "Association Request Failed:");
                IsiXDCMTKDumpCondition(condition);
            }
        } else if (_verbose && !_get && _association) {
            printf("Association Parameters Negotiated:\n");
            IsiXDCMTKDumpParameters(_parameters);
        }
        return IsiXDCMTKErrorFromCondition(condition);
    });
    return error;
}

- (BOOL)hasAssociation
{
    return _association != NULL;
}

- (NSError *)closeTransportConnection
{
    NSError *error = nil;
    if (!_association) return nil;
    IsiXDCMTKGuard(&error, "ASC_closeTransportConnection", [&]() -> NSError * {
        return IsiXDCMTKErrorFromCondition(ASC_closeTransportConnection(_association));
    });
    return error;
}

- (NSError *)releaseAssociation
{
    NSError *error = nil;
    if (!_association) return [IsiXDCMTKError errorForConditionKind:IsiXDCMTKConditionKindIllegalParameter];
    IsiXDCMTKGuard(&error, "ASC_releaseAssociation", [&]() -> NSError * {
        return IsiXDCMTKErrorFromCondition(ASC_releaseAssociation(_association));
    });
    return error;
}

- (NSUInteger)acceptedPresentationContextCount
{
    NSUInteger count = 0;
    try { count = _parameters ? (NSUInteger)ASC_countAcceptedPresentationContexts(_parameters) : 0; }
    catch (const std::exception &exception) { IsiXDCMTKErrorFromException(exception.what(), "ASC_countAcceptedPresentationContexts"); }
    catch (...) { IsiXDCMTKErrorFromException("unknown exception", "ASC_countAcceptedPresentationContexts"); }
    return count;
}

- (uint8_t)acceptedPresentationContextForAbstractSyntax:(NSString *)abstractSyntax transferSyntax:(NSString *)transferSyntax
{
    uint8_t identifier = 0;
    IsiXDCMTKGuard(NULL, "ASC_findAcceptedPresentationContextID", [&]() -> NSError * {
        if (!_association) return nil;
        identifier = transferSyntax
            ? ASC_findAcceptedPresentationContextID(_association, abstractSyntax.UTF8String, transferSyntax.UTF8String)
            : ASC_findAcceptedPresentationContextID(_association, abstractSyntax.UTF8String);
        return nil;
    });
    return identifier;
}

- (NSString *)acceptedTransferSyntaxOfPresentationContext:(uint8_t)identifier
{
    NSString *syntax = nil;
    IsiXDCMTKGuard(NULL, "ASC_findAcceptedPresentationContext", [&]() -> NSError * {
        T_ASC_PresentationContext context;
        if (identifier && _association && ASC_findAcceptedPresentationContext(_association->params, identifier, &context).good())
            syntax = [NSString stringWithUTF8String:context.acceptedTransferSyntax];
        return nil;
    });
    return syntax;
}

- (BOOL)acceptsAbstractSyntax:(NSString *)abstractSyntax
{
    BOOL accepted = NO;
    try { accepted = _association && ASC_findAcceptedPresentationContextID(_association, abstractSyntax.UTF8String) != 0; }
    catch (const std::exception &exception) { IsiXDCMTKErrorFromException(exception.what(), "ASC_findAcceptedPresentationContextID"); }
    catch (...) { IsiXDCMTKErrorFromException("unknown exception", "ASC_findAcceptedPresentationContextID"); }
    return accepted;
}

- (NSError *)echoWithStatus:(uint16_t *)status
{
    NSError *error = nil;
    if (status) *status = 0xffff;
    if (!_association) return [IsiXDCMTKError errorForConditionKind:IsiXDCMTKConditionKindIllegalParameter];
    IsiXDCMTKGuard(&error, "DIMSE_echoUser", [&]() -> NSError * {
        DIC_US answer = 0xffff;
        DcmDataset *statusDetail = NULL;
        OFCondition condition = DIMSE_echoUser(_association, _association->nextMsgID++, DIMSE_NONBLOCKING,
                                               _dimseTimeout, &answer, &statusDetail);
        delete statusDetail;
        if (status) *status = answer;
        return IsiXDCMTKErrorFromCondition(condition);
    });
    return error;
}

- (IsiXDCMTKFindResult *)findWithIdentifier:(IsiXDCMTKDataset *)identifier response:(void (NS_NOESCAPE ^)(IsiXDCMTKDataset *))response
{
    return [self findWithIdentifier:identifier abstractSyntax:@UID_FINDStudyRootQueryRetrieveInformationModel response:response];
}

- (IsiXDCMTKFindResult *)findWithIdentifier:(IsiXDCMTKDataset *)identifier
                             abstractSyntax:(NSString *)abstractSyntax
                                   response:(void (NS_NOESCAPE ^)(IsiXDCMTKDataset *))response
{
    const std::string model = abstractSyntax.UTF8String ?: "";
    IsiXDCMTKFindResult *result = [[IsiXDCMTKFindResult alloc] init];
    NSError *error = nil;
    IsiXDCMTKGuard(&error, "DIMSE_findUser", [&]() -> NSError * {
        DcmDataset *dataset = IsiXDCMTKDatasetStorage(identifier);
        if (!_association || !dataset) return IsiXDCMTKErrorFromCondition(EC_IllegalParameter);
        const DIC_US messageID = _association->nextMsgID++;
        const T_ASC_PresentationContextID presentation =
            ASC_findAcceptedPresentationContextID(_association, model.c_str());
        if (presentation == 0) {
            errmsg("No presentation context");
            return IsiXDCMTKErrorFromCondition(DIMSE_NOVALIDPRESENTATIONCONTEXTID);
        }
        T_DIMSE_C_FindRQ request;
        T_DIMSE_C_FindRSP answer;
        bzero(&request, sizeof(request));
        bzero(&answer, sizeof(answer));
        request.MessageID = messageID;
        OFStandard::strlcpy(request.AffectedSOPClassUID, model.c_str(), sizeof(request.AffectedSOPClassUID));
        request.DataSetType = DIMSE_DATASET_PRESENT;
        request.Priority = DIMSE_PRIORITY_LOW;
        if (_verbose) {
            printf("Find SCU RQ: MsgID %d\n", messageID);
            printf("REQUEST:\n");
            dataset->print(COUT);
            printf("--------\n");
        }
        IsiXDCMTKFindContext context = {response};
        DcmDataset *statusDetail = NULL;
        int responseCount = 0;
        OFCondition condition = DIMSE_findUser(_association, presentation, &request, dataset, responseCount,
                                               IsiXDCMTKFindCallback, &context, DIMSE_NONBLOCKING, _dimseTimeout,
                                               &answer, &statusDetail);
        result.conditionGood = condition.good() ? YES : NO;
        result.status = answer.DimseStatus;
        result.statusText = [NSString stringWithUTF8String:DU_cfindStatusString(answer.DimseStatus)] ?: @"";
        if (statusDetail) {
            OFOStringStream stream;
            statusDetail->print(stream);
            OFSTRINGSTREAM_GETSTR(stream, printed)
            result.statusDetail = [NSString stringWithUTF8String:printed];
            OFSTRINGSTREAM_FREESTR(printed)
        }
        if (condition == EC_Normal) {
            if (_verbose) DIMSE_printCFindRSP(stdout, &answer);
            else if (answer.DimseStatus != STATUS_Success) printf("Response: %s\n", DU_cfindStatusString(answer.DimseStatus));
        } else if (_verbose) {
            errmsg("Find Failed\n Condition:\n");
            IsiXDCMTKDumpCondition(condition);
            NSLog(@"Dimse Status: %@", result.statusText);
        }
        if (statusDetail) {
            if (_verbose) {
                printf("  Status Detail:\n");
                statusDetail->print(COUT);
            }
            delete statusDetail;
        }
        return IsiXDCMTKErrorFromCondition(condition);
    });
    result.condition = error;
    return result;
}

- (IsiXDCMTKRetrieveResult *)moveWithIdentifier:(IsiXDCMTKDataset *)identifier destination:(NSString *)destination
                                       progress:(void (NS_NOESCAPE ^)(BOOL, NSUInteger, NSUInteger))progress
{
    IsiXDCMTKRetrieveResult *result = [[IsiXDCMTKRetrieveResult alloc] init];
    NSError *error = nil;
    IsiXDCMTKGuard(&error, "HorosDIMSEMoveUser", [&]() -> NSError * {
        DcmDataset *dataset = IsiXDCMTKDatasetStorage(identifier);
        if (!_association || !dataset) return IsiXDCMTKErrorFromCondition(EC_IllegalParameter);
        const T_ASC_PresentationContextID presentation =
            ASC_findAcceptedPresentationContextID(_association, UID_MOVEStudyRootQueryRetrieveInformationModel);
        if (presentation == 0) return IsiXDCMTKErrorFromCondition(DIMSE_NOVALIDPRESENTATIONCONTEXTID);
        T_DIMSE_C_MoveRQ request = {};
        T_DIMSE_C_MoveRSP answer = {};
        const DIC_US messageID = _association->nextMsgID++;
        DcmDataset *identifiers = NULL, *statusDetail = NULL;
        OFCondition condition = EC_Normal;
        try {
            if (_verbose) {
                printf("Move SCU RQ: MsgID %d\n", messageID);
                printf("Request:\n");
                dataset->print(COUT);
            }
            request.MessageID = messageID;
            strcpy(request.AffectedSOPClassUID, UID_MOVEStudyRootQueryRetrieveInformationModel);
            request.Priority = DIMSE_PRIORITY_MEDIUM;
            request.DataSetType = DIMSE_DATASET_PRESENT;
            if (destination) OFStandard::strlcpy(request.MoveDestination, destination.UTF8String, sizeof(request.MoveDestination));
            else ASC_getAPTitles(_association->params, request.MoveDestination, sizeof(request.MoveDestination), NULL, 0, NULL, 0);
            IsiXDCMTKProgressContext context = {progress};
            condition = HorosDIMSEMoveUser(_association, presentation, &request, dataset, IsiXDCMTKMoveCallback, &context,
                                           DIMSE_BLOCKING, _dimseTimeout, _network, IsiXDCMTKSubOperationCallback, NULL,
                                           &answer, &statusDetail, &identifiers, OFTrue);
            result.conditionGood = condition.good() ? YES : NO;
            IsiXDCMTKFillRetrieveResult(result, answer, identifiers);
            if (condition == EC_Normal) {
                if (_verbose) {
                    DIMSE_printCMoveRSP(stdout, &answer);
                    if (identifiers) {
                        printf("Response Identifiers:\n");
                        identifiers->print(COUT);
                    }
                }
            } else if (_verbose) {
                errmsg("Move Failed:");
                IsiXDCMTKDumpCondition(condition);
            }
        } catch (...) {
            delete statusDetail;
            delete identifiers;
            throw;
        }
        if (statusDetail) {
            printf("  Status Detail:\n");
            statusDetail->print(COUT);
            delete statusDetail;
        }
        delete identifiers;
        return IsiXDCMTKErrorFromCondition(condition);
    });
    result.condition = error;
    return result;
}

- (IsiXDCMTKRetrieveResult *)getWithIdentifier:(IsiXDCMTKDataset *)identifier
                                       storage:(id<IsiXDCMTKSCPDatabase> (NS_NOESCAPE ^)(NSString *))storage
                                      progress:(void (NS_NOESCAPE ^)(BOOL, NSUInteger, NSUInteger))progress
                                      incoming:(void (NS_NOESCAPE ^)(void))incoming
{
    IsiXDCMTKRetrieveResult *result = [[IsiXDCMTKRetrieveResult alloc] init];
    NSError *error = nil;
    IsiXDCMTKGuard(&error, "HorosDIMSEGetUser", [&]() -> NSError * {
        DcmDataset *dataset = IsiXDCMTKDatasetStorage(identifier);
        if (!_association || !dataset) return IsiXDCMTKErrorFromCondition(EC_IllegalParameter);
        const T_ASC_PresentationContextID presentation =
            ASC_findAcceptedPresentationContextID(_association, UID_GETStudyRootQueryRetrieveInformationModel);
        if (presentation == 0) return IsiXDCMTKErrorFromCondition(DIMSE_NOVALIDPRESENTATIONCONTEXTID);
        T_DIMSE_C_GetRQ request = {};
        T_DIMSE_C_GetRSP answer = {};
        const DIC_US messageID = _association->nextMsgID++;
        DcmDataset *identifiers = NULL, *statusDetail = NULL;
        OFCondition condition = EC_Normal;
        try {
            if (_verbose) {
                printf("Get SCU RQ: MsgID %d\n", messageID);
                printf("Request:\n");
                dataset->print(COUT);
            }
            request.MessageID = messageID;
            strcpy(request.AffectedSOPClassUID, UID_GETStudyRootQueryRetrieveInformationModel);
            request.Priority = DIMSE_PRIORITY_MEDIUM;
            request.DataSetType = DIMSE_DATASET_PRESENT;
            IsiXDCMTKProgressContext context = {progress};
            IsiXDCMTKIncomingContext arrivals = {incoming};
            condition = HorosDIMSEGetUser(_association, presentation, &request, dataset, IsiXDCMTKGetCallback, &context,
                                          DIMSE_NONBLOCKING, _dimseTimeout, _network, IsiXDCMTKSubOperationCallback, NULL,
                                          &answer, &statusDetail, &identifiers, IsiXDCMTKIncoming, &arrivals,
                                          storage([NSString stringWithUTF8String:_association->params->DULparams.calledAPTitle] ?: @""));
            result.conditionGood = condition.good() ? YES : NO;
            IsiXDCMTKFillRetrieveResult(result, answer, identifiers);
            if (condition == EC_Normal) {
                if (_verbose) {
                    DIMSE_printCGetRSP(stdout, &answer);
                    if (identifiers) {
                        printf("Response Identifiers:\n");
                        identifiers->print(COUT);
                    }
                }
            } else if (_verbose) {
                errmsg("Get Failed:");
                IsiXDCMTKDumpCondition(condition);
            }
        } catch (...) {
            delete statusDetail;
            delete identifiers;
            throw;
        }
        delete statusDetail;
        delete identifiers;
        return IsiXDCMTKErrorFromCondition(condition);
    });
    result.condition = error;
    return result;
}

- (T_ASC_Association *)handle
{
    return _association;
}

- (int)dimseTimeout
{
    return _dimseTimeout;
}

+ (NSArray<NSString *> *)availableCipherSuites
{
    NSMutableArray<NSString *> *suites = [NSMutableArray array];
#ifdef WITH_OPENSSL
    IsiXDCMTKGuard(NULL, "DcmTLSCiphersuiteHandler::getTLSCipherSuiteName", [&]() -> NSError * {
        for (size_t index = 0; index < DcmTLSCiphersuiteHandler::getNumberOfCipherSuites(); ++index) {
            const char *name = DcmTLSCiphersuiteHandler::getTLSCipherSuiteName(index);
            if (name) [suites addObject:[NSString stringWithUTF8String:name]];
        }
        return nil;
    });
#endif
    return suites;
}

+ (NSArray<NSString *> *)storageSOPClassesOfferedByGet
{
    static NSArray<NSString *> *offered;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *classes = [NSMutableArray array];
        for (int i = 0; i < numberOfDcmLongSCUStorageSOPClassUIDs; i++)
            if (dcmLongSCUStorageSOPClassUIDs[i]) [classes addObject:[NSString stringWithUTF8String:dcmLongSCUStorageSOPClassUIDs[i]]];
        offered = [classes copy];
    });
    return offered;
}

@end

T_ASC_Association *IsiXDCMTKAssociationHandle(IsiXDCMTKAssociation *association)
{
    return [association handle];
}

int IsiXDCMTKAssociationDIMSETimeout(IsiXDCMTKAssociation *association)
{
    return [association dimseTimeout];
}
