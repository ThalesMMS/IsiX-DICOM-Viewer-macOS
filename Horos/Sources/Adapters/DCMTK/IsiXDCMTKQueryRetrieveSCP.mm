//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The listener over stock DCMTK: DCMTK negotiates and runs DIMSE; this file
// takes the connections, runs each association on a thread of its own and
// answers its commands through IsiXDCMTKSCPDatabaseHandle and the
// application's IsiXDCMTKListenerHost.

#import "IsiXDCMTKQueryRetrieveSCP.h"
#import "IsiXDCMTKInternal.hpp"
#import "IsiXDCMTKSCPDatabase.hpp"
#import "IsiXDCMTKMoveContext.hpp"

#include "HorosDIMSEAssociation.h"
#include "HorosDICOMStoreSource.h"
#include "HorosDICOMGlobalAbort.h"
#include "HorosTLSConfiguration.h"

#include <dcmtk/dcmdata/dcdict.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcuid.h>
#include <dcmtk/dcmdata/dcxfer.h>
#include <dcmtk/dcmnet/assoc.h>
#include <dcmtk/dcmnet/dcasccfg.h>
#include <dcmtk/dcmnet/diutil.h>
#include <dcmtk/dcmnet/scpthrd.h>
#include <dcmtk/dcmqrdb/dcmqrcbf.h>
#include <dcmtk/dcmqrdb/dcmqrcnf.h>
#include <dcmtk/dcmqrdb/dcmqrdbs.h>
#include <dcmtk/dcmqrdb/dcmqropt.h>
#include <dcmtk/dcmtls/tlslayer.h>
#include <dcmtk/ofstd/ofstd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <netdb.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

#if !__has_feature(objc_arc)
#error "IsiXDCMTKQueryRetrieveSCP.mm is compiled with ARC (-fobjc-arc)"
#endif

NSString * const IsiXDCMTKListenerFileKey = @"IsiXDCMTKListenerFile";

// MARK: - Configuration

// The only AE title the listener's DCMTK configuration names. The user's AE
// title is never written there: see IsiXDCMTKLoadListenerConfiguration.
static const char* const IsiXDCMTKListenerConfigurationAETitle = "LISTENER";

// DCMTK's Q/R classes read their AE table from a file, whose parser ends a
// value at a space, '=' or ',', and a quoted one at any quote or parenthesis.
// An AE title may hold all of them, and a database folder most of them, so
// neither is written here: the table names IsiXDCMTKListenerConfigurationAETitle,
// the listener matches its own AE title through its host, and the storage area
// is a placeholder, as received files are written through the database
// handle, never there. Returns nil, or what went wrong.
static NSString* IsiXDCMTKLoadListenerConfiguration(DcmQueryRetrieveConfig& config, int port,
                                                    unsigned long maxPDU, int maxAssociations)
{
    NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Horos-dcmqrscp-%@.cfg", [[NSUUID UUID] UUIDString]]];
    NSString* text = [NSString stringWithFormat:
        @"NetworkTCPPort %d\n"
        @"MaxPDUSize %lu\n"
        @"MaxAssociations %d\n"
        @"HostTable BEGIN\n"
        @"HostTable END\n"
        @"VendorTable BEGIN\n"
        @"VendorTable END\n"
        @"AETable BEGIN\n"
        @"%s /dev/null RW (20000, 1024mb) ANY\n"
        @"AETable END\n",
        port, maxPDU, maxAssociations, IsiXDCMTKListenerConfigurationAETitle];
    NSError* error = nil;
    if (![text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error])
        return [NSString stringWithFormat:@"Unable to create DICOM listener configuration in %@: %@",
                NSTemporaryDirectory(), error.localizedDescription];
    const bool read = config.init(path.fileSystemRepresentation);
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    return read ? nil : @"Unable to read DICOM listener configuration.";
}

static const char *IsiXDCMTKIncomingAssociationProfile = "HOROS_INCOMING";
static const char *IsiXDCMTKIncomingPresentationContexts = "HOROS_INCOMING_CONTEXTS";
static const char *IsiXDCMTKIncomingTransferSyntaxes = "HOROS_INCOMING_TRANSFER_SYNTAXES";
static const char *IsiXDCMTKIncomingRoles = "HOROS_INCOMING_ROLES";

static OFBool IsiXDCMTKSupportsIncomingTransferSyntax(E_TransferSyntax syntax)
{
    const int syntaxValue = OFstatic_cast(int, syntax);
    if (syntaxValue < OFstatic_cast(int, EXS_LittleEndianImplicit) ||
        syntaxValue > OFstatic_cast(int, EXS_HighThroughputJPEG2000))
        return OFFalse;
    if (syntax == EXS_BigEndianImplicit || syntax == EXS_JPIPReferenced || syntax == EXS_JPIPReferencedDeflate)
        return OFFalse;
    DcmXfer xfer(syntax);
    return xfer.isValid() && xfer.getXferID()[0] != '\0' && xfer.getStreamCompression() != ESC_unsupported;
}

static OFCondition IsiXDCMTKAddIncomingTransferSyntax(DcmAssociationConfiguration &configuration,
                                                      OFBool *addedSyntaxes, E_TransferSyntax syntax)
{
    if (!IsiXDCMTKSupportsIncomingTransferSyntax(syntax)) return EC_Normal;
    const int syntaxValue = OFstatic_cast(int, syntax);
    if (addedSyntaxes[syntaxValue]) return EC_Normal;
    DcmXfer xfer(syntax);
    OFCondition condition = configuration.addTransferSyntax(IsiXDCMTKIncomingTransferSyntaxes, xfer.getXferID());
    if (condition.good()) addedSyntaxes[syntaxValue] = OFTrue;
    return condition;
}

// The profile of incoming C-STOREs: every storage SOP class, in every transfer
// syntax DCMTK can read, the preferred one first, then the uncompressed ones.
static OFCondition IsiXDCMTKConfigureIncomingAssociationProfile(DcmAssociationConfiguration &configuration,
                                                                E_TransferSyntax preferredSyntax)
{
    // Most C-STORE senders use the default requestor-SCU role, while C-GET
    // requires the requestor to act as Storage SCP. Accept both forms.
    configuration.setAlwaysAcceptDefaultRole(OFTrue);

    OFBool addedSyntaxes[OFstatic_cast(int, EXS_HighThroughputJPEG2000) + 1];
    memset(addedSyntaxes, 0, sizeof(addedSyntaxes));

    OFCondition condition = IsiXDCMTKAddIncomingTransferSyntax(configuration, addedSyntaxes, preferredSyntax);
    if (condition.good())
        condition = IsiXDCMTKAddIncomingTransferSyntax(configuration, addedSyntaxes, EXS_LittleEndianExplicit);
    if (condition.good())
        condition = IsiXDCMTKAddIncomingTransferSyntax(configuration, addedSyntaxes, EXS_BigEndianExplicit);
    if (condition.good())
        condition = IsiXDCMTKAddIncomingTransferSyntax(configuration, addedSyntaxes, EXS_LittleEndianImplicit);
    for (int syntaxValue = OFstatic_cast(int, EXS_LittleEndianImplicit);
         condition.good() && syntaxValue <= OFstatic_cast(int, EXS_HighThroughputJPEG2000); ++syntaxValue)
        condition = IsiXDCMTKAddIncomingTransferSyntax(configuration, addedSyntaxes,
                                                       OFstatic_cast(E_TransferSyntax, syntaxValue));

    for (int index = 0; condition.good() && index < numberOfDcmAllStorageSOPClassUIDs; ++index) {
        const char *sopClass = dcmAllStorageSOPClassUIDs[index];
        condition = configuration.addPresentationContext(IsiXDCMTKIncomingPresentationContexts, sopClass,
                                                         IsiXDCMTKIncomingTransferSyntaxes, OFFalse);
        if (condition.good())
            condition = configuration.addRole(IsiXDCMTKIncomingRoles, sopClass, ASC_SC_ROLE_SCUSCP);
    }
    if (condition.good())
        condition = configuration.addProfile(IsiXDCMTKIncomingAssociationProfile, IsiXDCMTKIncomingPresentationContexts,
                                             IsiXDCMTKIncomingRoles);
    return condition;
}

static void IsiXDCMTKListenerMessage(const char* message)
{
    fprintf(stderr, "dcmqrscp: %s\n", message);
}

static void IsiXDCMTKDumpDIMSECondition(OFCondition condition)
{
    OFString text;
    DimseCondition::dump(text, condition);
    ofConsole.lockCerr() << text << OFendl;
    ofConsole.unlockCerr();
}

// Held while dcmExternalSocketHandle names a socket for DCMTK to adopt, and
// while an acceptor network is initialized: DCMTK reads that variable in both.
// Never destroyed, so that a listener thread still running when the process
// exits does not lock a mutex the static destructors have already torn down.
static std::mutex& IsiXDCMTKAdoptedSocketMutex()
{
    static std::mutex *mutex = new std::mutex;
    return *mutex;
}

// MARK: - Associations

namespace {

/// The association threads of one listener, and the connections it took whose
/// association request has not been read yet.
class AssociationProcesses
{
public:
    std::atomic<unsigned> active{0};
    std::atomic<unsigned> receiving{0};
    std::atomic<bool> stopping{false};
    // The association limit is checked and the association started as one step.
    std::mutex startMutex;

    void addThread(NSThread* thread)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        [threads_ addObject:thread];
    }
    void removeThread(NSThread* thread)
    {
        std::lock_guard<std::mutex> lock(mutex_);
        [threads_ removeObjectIdenticalTo:thread];
    }
    void requestStop()
    {
        stopping = true;
        std::lock_guard<std::mutex> lock(mutex_);
        for (NSThread* thread in threads_) [thread cancel];
    }

private:
    std::mutex mutex_;
    NSMutableArray<NSThread*>* threads_ = [NSMutableArray array];
};

/// What every association of a listener shares.
struct ListenerContext
{
    DcmQueryRetrieveConfig config;
    DcmQueryRetrieveOptions options;
    DcmAssociationConfiguration profiles;
    OFBool secureConnection = OFFalse;
    OFString aeTitle;
    id<IsiXDCMTKListenerHost> host;
    AssociationProcesses processes;
};

bool Cancelled(const AssociationProcesses& processes)
{
    return processes.stopping || [NSThread currentThread].isCancelled || HorosDICOMGlobalAbortRequested();
}

/// The C-GET of one request: each pending response sends the next instance
/// as a C-STORE sub-operation on the same association.
class GetContext
{
public:
    GetContext(IsiXDCMTKSCPDatabaseHandle& database, const DcmQueryRetrieveOptions& options,
               T_ASC_Association* association, T_ASC_PresentationContextID presentationID, id<IsiXDCMTKListenerHost> host)
        : database_(database), options_(options), association_(association), presentationID_(presentationID), host_(host) {}

    static void callback(void* data, OFBool cancelled, T_DIMSE_C_GetRQ* request, DcmDataset* identifiers,
                         int responseCount, T_DIMSE_C_GetRSP* response, DcmDataset** responseIdentifiers,
                         DcmDataset** detail)
    {
        static_cast<GetContext*>(data)->respond(cancelled, request, identifiers, responseCount, response,
                                                responseIdentifiers, detail);
    }

private:
    void respond(OFBool cancelled, T_DIMSE_C_GetRQ* request, DcmDataset* identifiers, int responseCount,
                 T_DIMSE_C_GetRSP* response, DcmDataset** responseIdentifiers, DcmDataset** detail)
    {
        DcmQueryRetrieveDatabaseStatus status(STATUS_Pending);
        OFCondition result = EC_Normal;
        if (responseCount == 1)
            result = database_.startMoveRequest(request->AffectedSOPClassUID, identifiers, &status);
        if (result.bad() && status.status() == STATUS_Pending)
            status.setStatus(STATUS_GET_Refused_OutOfResourcesNumberOfMatches);

        cancelled = cancelled || [NSThread currentThread].isCancelled || HorosDICOMGlobalAbortRequested();
        if (cancelled && status.status() == STATUS_Pending) cancel(status);
        if (status.status() == STATUS_Pending) {
            DIC_UI sopClass = {}, sopInstance = {};
            char path[MAXPATHLEN + 1] = {};
            result = database_.nextMoveResponse(sopClass, sizeof(sopClass), sopInstance, sizeof(sopInstance),
                                                path, sizeof(path), &remaining_, &status);
            if (result.bad()) status.setStatus(STATUS_GET_Refused_OutOfResourcesSubOperations);
            else if (status.status() == STATUS_Pending) sendImage(request, sopClass, sopInstance, path, status);
        }

        // Do not turn a cancellation or database error into success/warning.
        if (status.status() == STATUS_Success && (failed_ || warnings_))
            status.setStatus([host_ finalStatusOfGet:status.status() completed:completed_ failed:failed_ warnings:warnings_]);
        if (status.status() != STATUS_Success && status.status() != STATUS_Pending && !failedUIDs_.empty()) {
            *responseIdentifiers = new DcmDataset;
            (*responseIdentifiers)->putAndInsertString(DCM_FailedSOPInstanceUIDList, failedUIDs_.c_str());
        }
        response->DimseStatus = status.status();
        response->NumberOfRemainingSubOperations = remaining_;
        response->NumberOfCompletedSubOperations = completed_;
        response->NumberOfFailedSubOperations = failed_;
        response->NumberOfWarningSubOperations = warnings_;
        *detail = status.extractStatusDetail();
    }

    void cancel(DcmQueryRetrieveDatabaseStatus& status)
    {
        database_.cancelMoveRequest(&status);
        status.setStatus(STATUS_GET_Cancel_SubOperationsTerminatedDueToCancelIndication);
    }

    void failed(const char* sopInstance)
    {
        ++failed_;
        if (sopInstance[0]) {
            if (!failedUIDs_.empty()) failedUIDs_ += "\\";
            failedUIDs_ += sopInstance;
        }
    }

    void sendImage(T_DIMSE_C_GetRQ* request, const char* sopClass, const char* sopInstance, const char* path,
                   DcmQueryRetrieveDatabaseStatus& status)
    {
        HorosDICOMStoreSource source(path);
        OFCondition result = source.prepare(association_, sopClass, path);
        if (result.bad()) {
            failed(sopInstance);
            DCMQRDB_ERROR("Horos C-GET: cannot prepare instance " << sopInstance << ": " << result.text());
            return;
        }
        T_DIMSE_C_StoreRQ storeRequest = {};
        storeRequest.MessageID = association_->nextMsgID++;
        storeRequest.Priority = request->Priority;
        storeRequest.DataSetType = DIMSE_DATASET_PRESENT;
        OFStandard::strlcpy(storeRequest.AffectedSOPClassUID, sopClass, sizeof(storeRequest.AffectedSOPClassUID));
        OFStandard::strlcpy(storeRequest.AffectedSOPInstanceUID, sopInstance, sizeof(storeRequest.AffectedSOPInstanceUID));
        T_DIMSE_C_StoreRSP response = {};
        T_DIMSE_DetectedCancelParameters cancellation = {};
        DcmDataset* detail = NULL;
        result = DIMSE_storeUser(association_, source.presentationID, &storeRequest,
            source.datasetToSend ? NULL : path, source.datasetToSend, NULL, NULL,
            options_.blockMode_, options_.dimse_timeout_, &response, &detail, &cancellation);
        delete detail;

        if (result.good() && response.DimseStatus == STATUS_Success) ++completed_;
        else if (result.good() && DICOM_WARNING_STATUS(response.DimseStatus)) ++warnings_;
        else {
            failed(sopInstance);
            DCMQRDB_ERROR("Horos C-GET: store sub-operation failed: " << result.text() << ", status " << response.DimseStatus);
        }
        if (result.bad()) {
            // A failed DIMSE exchange may have left the association unusable.
            // Stop rather than consuming the remaining database results.
            DcmQueryRetrieveDatabaseStatus cleanup;
            database_.cancelMoveRequest(&cleanup);
            status.setStatus(STATUS_GET_Refused_OutOfResourcesSubOperations);
        }
        if (cancellation.cancelEncountered && cancellation.presId == presentationID_ &&
            cancellation.req.MessageIDBeingRespondedTo == request->MessageID)
            cancel(status);
    }

    IsiXDCMTKSCPDatabaseHandle& database_;
    const DcmQueryRetrieveOptions& options_;
    T_ASC_Association* association_;
    T_ASC_PresentationContextID presentationID_;
    id<IsiXDCMTKListenerHost> host_;
    unsigned short remaining_ = 0, completed_ = 0, failed_ = 0, warnings_ = 0;
    OFString failedUIDs_;
};

void findCallback(void* data, OFBool cancelled, T_DIMSE_C_FindRQ* request, DcmDataset* identifiers,
                  int count, T_DIMSE_C_FindRSP* response, DcmDataset** responseIdentifiers, DcmDataset** detail)
{
    static_cast<DcmQueryRetrieveFindContext*>(data)->callbackHandler(
        cancelled || [NSThread currentThread].isCancelled || HorosDICOMGlobalAbortRequested(),
        request, identifiers, count, response, responseIdentifiers, detail);
}

struct MoveCallbackContext
{
    IsiXDCMTKMoveContext* move;
    IsiXDCMTKSCPDatabaseHandle* database;
};

void moveCallback(void* data, OFBool cancelled, T_DIMSE_C_MoveRQ* request, DcmDataset* identifiers,
                  int count, T_DIMSE_C_MoveRSP* response, DcmDataset** responseIdentifiers, DcmDataset** detail)
{
    auto* context = static_cast<MoveCallbackContext*>(data);
    // The destination the database's log names, given before the move asks it
    // for the instances.
    if (count == 1) context->database->setMoveDestination(request->MoveDestination);
    context->move->callbackHandler(
        cancelled || [NSThread currentThread].isCancelled || HorosDICOMGlobalAbortRequested(),
        request, identifiers, count, response, responseIdentifiers, detail);
}

IsiXDCMTKListenerCommand CommandOf(const T_DIMSE_Message* message)
{
    switch (message->CommandField) {
        case DIMSE_C_STORE_RQ: return IsiXDCMTKListenerCommandStore;
        case DIMSE_C_FIND_RQ: return IsiXDCMTKListenerCommandFind;
        case DIMSE_C_MOVE_RQ: return IsiXDCMTKListenerCommandMove;
        case DIMSE_C_GET_RQ: return IsiXDCMTKListenerCommandGet;
        default: return IsiXDCMTKListenerCommandEcho;
    }
}

class QueryRetrieveAssociation : public DcmThreadSCP
{
public:
    QueryRetrieveAssociation(T_ASC_Association* association, ListenerContext& listener)
        : association_(association), listener_(listener)
    {
        const DcmQueryRetrieveOptions& options = listener_.options;
        setRespondWithCalledAETitle(OFTrue);
        forceAssociationRefuse(options.refuse_);
        setACSETimeout(options.acse_timeout_);
        setDIMSEBlockingMode(options.blockMode_);
        setDIMSETimeout(options.dimse_timeout_);
        setProgressNotificationMode(OFFalse);
    }

protected:
    void notifyDIMSEError(const OFCondition& condition) override
    {
        DcmSCP::notifyDIMSEError(condition);
        if (cancelled()) return;
        NSString* message = [NSString stringWithFormat:@"DICOM association from %.64s to %.64s ended: %04x:%04x %s",
            association_->params->DULparams.callingAPTitle, association_->params->DULparams.calledAPTitle,
            condition.module(), condition.code(), condition.text()];
        [listener_.host associationEndedWithError:IsiXDCMTKErrorFromCondition(condition) message:message];
    }

    void notifyAssociationRequest(const T_ASC_Parameters& parameters, DcmSCPActionType& action) override
    {
        // The number of associations at once is limited where they are
        // accepted (receiveAssociation): the listener does not fork.
        if (listener_.options.rejectWhenNoImplementationClassUID_ && !parameters.theirImplementationClassUID[0])
            action = DCMSCP_ACTION_REFUSE_ASSOCIATION;
    }

    // Any called AE title is accepted, as Horos always did: some PACS send the
    // C-STORE sub-operations of a C-MOVE to another title than the move
    // destination, and the calling AE is not restricted either, so refusing
    // them protects nothing. The association answers with the title it was
    // called by (setRespondWithCalledAETitle); a difference is only logged.
    OFBool checkCalledAETitleAccepted(const OFString& calledAE) override
    {
        const auto& parameters = association_->params->DULparams;
        NSData* called = [NSData dataWithBytes:calledAE.c_str() length:calledAE.length()];
        if (![listener_.host isListenerAETitle:called])
            NSLog(@"DICOM listener: association from %.64s (%.64s) calls AE title \"%s\", not \"%s\"; accepted",
                  parameters.callingAPTitle, parameters.callingPresentationAddress, calledAE.c_str(),
                  listener_.aeTitle.c_str());
        return listener_.config.peerInAETitle(IsiXDCMTKListenerConfigurationAETitle, parameters.callingAPTitle,
                                              parameters.callingPresentationAddress);
    }

    OFCondition negotiateAssociation() override
    {
        const DcmQueryRetrieveOptions& options = listener_.options;
        OFCondition result = listener_.profiles.evaluateAssociationParameters(options.incomingProfile.c_str(), *association_);
        if (result.bad()) {
            DCMQRDB_ERROR("Horos listener: association profile failed: " << result.text());
            refuseAssociation(DCMSCP_INTERNAL_ERROR);
            return result;
        }
        std::vector<const char*> syntaxes;
        DcmXfer preferred(options.networkTransferSyntax_);
        if (preferred.isValid()) syntaxes.push_back(preferred.getXferID());
        if (options.networkTransferSyntax_ != EXS_LittleEndianImplicit) {
            syntaxes.push_back(UID_LittleEndianExplicitTransferSyntax);
            syntaxes.push_back(UID_BigEndianExplicitTransferSyntax);
            syntaxes.push_back(UID_LittleEndianImplicitTransferSyntax);
        }
        // Verification and the Study Root model's C-FIND, C-MOVE and C-GET.
        const char* services[] = {
            UID_VerificationSOPClass, UID_FINDStudyRootQueryRetrieveInformationModel,
            UID_MOVEStudyRootQueryRetrieveInformationModel, UID_GETStudyRootQueryRetrieveInformationModel,
        };
        result = ASC_acceptContextsWithPreferredTransferSyntaxes(association_->params, services,
            static_cast<int>(sizeof(services) / sizeof(services[0])), syntaxes.data(), static_cast<int>(syntaxes.size()));
        if (result.bad()) return result;

        const bool refuseStorage = !listener_.config.writableStorageArea(IsiXDCMTKListenerConfigurationAETitle);
        for (int index = 0; index < ASC_countPresentationContexts(association_->params); ++index) {
            T_ASC_PresentationContext context;
            if (ASC_getPresentationContext(association_->params, index, &context).bad() ||
                context.resultReason != ASC_P_ACCEPTANCE) continue;
            if (refuseStorage && dcmIsaStorageSOPClassUID(context.abstractSyntax) && context.acceptedRole != ASC_SC_ROLE_SCP)
                ASC_refusePresentationContext(association_->params, context.presentationContextID, ASC_P_USERREJECTION);
        }
        return EC_Normal;
    }

    bool cancelled() const
    {
        return Cancelled(listener_.processes);
    }

    void handleAssociation() override
    {
        // Poll before receiving commands so idle connections can be cancelled.
        // The actual DIMSE receive retains its configured command timeout.
        OFCondition result = EC_Normal;
        auto idleSince = std::chrono::steady_clock::now();
        int idleTimeout = dcmConnectionTimeout.get() > 0 ? dcmConnectionTimeout.get() : 5;
        while (result.good() && !cancelled()) {
            if (!ASC_dataWaiting(association_, 1)) {
                if (idleTimeout > 0 && std::chrono::duration_cast<std::chrono::seconds>(
                        std::chrono::steady_clock::now() - idleSince).count() >= idleTimeout)
                    result = DIMSE_NODATAAVAILABLE;
                continue;
            }
            T_DIMSE_Message message = {};
            T_ASC_PresentationContextID id = 0;
            result = receiveDIMSECommand(&id, &message, NULL);
            if (result.good()) {
                DcmPresentationContextInfo context;
                if (!getPresentationContextInfo(association_, id, context)) result = DIMSE_NOVALIDPRESENTATIONCONTEXTID;
                else result = handleIncomingCommand(&message, context);
                idleSince = std::chrono::steady_clock::now();
                idleTimeout = listener_.options.dimse_timeout_;
            }
        }
        // An association its sender did not release, aborted, timed out or
        // cancelled here, leaves its log entry "Incomplete".
        if (result != DUL_PEERREQUESTEDRELEASE && database_) [database_->database() associationEndedIncomplete];
        if (result == DUL_PEERREQUESTEDRELEASE) {
            notifyReleaseRequest();
            result = ASC_acknowledgeRelease(association_);
            if (result.bad()) notifyDIMSEError(result);
        } else if (result == DUL_PEERABORTEDASSOCIATION) {
            notifyAbortRequest();
            notifyDIMSEError(result);
        } else {
            if (!cancelled()) notifyDIMSEError(result);
            ASC_closeTransportConnection(association_);
        }
        database_.reset();
    }

    OFCondition handleIncomingCommand(T_DIMSE_Message* message, const DcmPresentationContextInfo& context) override
    {
        if (message->CommandField == DIMSE_C_CANCEL_RQ) return EC_Normal; // Late cancellation.
        const IsiXDCMTKListenerCommand command = CommandOf(message);
        if ((message->CommandField == DIMSE_C_GET_RQ || message->CommandField == DIMSE_C_FIND_RQ) &&
            ![listener_.host answersCommand:command])
            return DIMSE_BADCOMMANDTYPE;
        [listener_.host association:[NSString stringWithUTF8String:association_->params->DULparams.callingPresentationAddress] ?: @""
                          willServe:command secure:listener_.secureConnection ? YES : NO];
        const char* sopClass = NULL;
        switch (message->CommandField) {
            case DIMSE_C_ECHO_RQ: sopClass = message->msg.CEchoRQ.AffectedSOPClassUID; break;
            case DIMSE_C_STORE_RQ: sopClass = message->msg.CStoreRQ.AffectedSOPClassUID; break;
            case DIMSE_C_FIND_RQ: sopClass = message->msg.CFindRQ.AffectedSOPClassUID; break;
            case DIMSE_C_MOVE_RQ: sopClass = message->msg.CMoveRQ.AffectedSOPClassUID; break;
            case DIMSE_C_GET_RQ: sopClass = message->msg.CGetRQ.AffectedSOPClassUID; break;
            default: return DIMSE_BADCOMMANDTYPE;
        }
        if (context.abstractSyntax != sopClass) return DIMSE_BADMESSAGE;
        T_ASC_PresentationContext accepted;
        if (ASC_findAcceptedPresentationContext(association_->params, context.presentationContextID, &accepted).bad() ||
            accepted.acceptedRole == ASC_SC_ROLE_SCP)
            return DIMSE_NOVALIDPRESENTATIONCONTEXTID;

        if (!database_) {
            NSString* calling = [NSString stringWithUTF8String:association_->params->DULparams.callingAPTitle] ?: @"";
            database_.reset(new IsiXDCMTKSCPDatabaseHandle([listener_.host databaseForCallingAETitle:calling]));
        }
        OFCondition result = dispatch(message, context);
        if (!listener_.options.keepDBHandleDuringAssociation_) database_.reset();
        return result;
    }

private:
    OFCondition dispatch(T_DIMSE_Message* message, const DcmPresentationContextInfo& context)
    {
        const DcmQueryRetrieveOptions& options = listener_.options;
        const auto presentation = context.presentationContextID;
        const char* calledAE = association_->params->DULparams.calledAPTitle;
        switch (message->CommandField) {
            case DIMSE_C_ECHO_RQ:
                return DcmSCP::handleIncomingCommand(message, context);
            case DIMSE_C_STORE_RQ:
                return IsiXDCMTKStoreSCP(association_, message->msg.CStoreRQ, presentation, *database_, options);
            case DIMSE_C_FIND_RQ: {
                DcmQueryRetrieveFindContext find(*database_, options, STATUS_Pending, listener_.config.getCharacterSetOptions());
                find.setOurAETitle(calledAE);
                return DIMSE_findProvider(association_, presentation, &message->msg.CFindRQ, findCallback, &find,
                                          options.blockMode_, options.dimse_timeout_);
            }
            case DIMSE_C_MOVE_RQ: {
                auto& request = message->msg.CMoveRQ;
                id<IsiXDCMTKListenerHost> host = listener_.host;
                IsiXDCMTKMoveContext move(*database_, options, &listener_.config, STATUS_Pending, association_,
                    request.MessageID, request.Priority, ^IsiXDCMTKMoveDestination *(NSString* aeTitle) {
                        return [host moveDestinationForAETitle:aeTitle];
                    });
                move.setOurAETitle(calledAE);
                MoveCallbackContext callback = {&move, database_.get()};
                return DIMSE_moveProvider(association_, presentation, &request, moveCallback, &callback,
                                          options.blockMode_, options.dimse_timeout_);
            }
            case DIMSE_C_GET_RQ: {
                GetContext get(*database_, options, association_, presentation, listener_.host);
                return DIMSE_getProvider(association_, presentation, &message->msg.CGetRQ, GetContext::callback, &get,
                                         options.blockMode_, options.dimse_timeout_);
            }
            default:
                return DIMSE_BADCOMMANDTYPE;
        }
    }

    T_ASC_Association* association_; // Borrowed; DcmThreadSCP owns it after run().
    ListenerContext& listener_;
    std::unique_ptr<IsiXDCMTKSCPDatabaseHandle> database_;
};

} // namespace

/// The thread of one association.
@interface IsiXDCMTKAssociationTask : NSObject
{
@public
    QueryRetrieveAssociation* worker;
    T_ASC_Association* association;
    ListenerContext* listener;
}
- (void)run;
@end

@implementation IsiXDCMTKAssociationTask
- (void)run
{
    @autoreleasepool {
        @try {
            try { worker->run(association); }
            catch (const std::exception& error) { NSLog(@"DICOM association failed: %s", error.what()); }
            catch (...) { NSLog(@"DICOM association failed with a C++ exception"); }
        }
        @catch (NSException* exception) { NSLog(@"DICOM association failed: %@", exception); }
        @finally {
            // DcmThreadSCP owns the association after run, including refusal and errors.
            try { delete worker; }
            catch (...) { NSLog(@"DICOM association: its end threw a C++ exception"); }
            worker = NULL;
            @try { [listener->host associationDidEnd]; }
            @catch (NSException* exception) { NSLog(@"DICOM import scheduling failed: %@", exception); }
            listener->processes.removeThread([NSThread currentThread]);
            --listener->processes.active;
        }
    }
}
@end

static void IsiXDCMTKStartAssociationTask(QueryRetrieveAssociation* worker, T_ASC_Association* association,
                                          ListenerContext& listener)
{
    IsiXDCMTKAssociationTask* task = [[IsiXDCMTKAssociationTask alloc] init];
    task->worker = worker;
    task->association = association;
    task->listener = &listener;
    ++listener.processes.active;
    NSThread* thread = nil;
    @try {
        thread = [[NSThread alloc] initWithTarget:task selector:@selector(run) object:nil];
        listener.processes.addThread(thread);
        [listener.host startAssociationThread:thread
                                         peer:[NSString stringWithUTF8String:association->params->DULparams.callingPresentationAddress] ?: @""];
    }
    @catch (NSException* exception) {
        // Registering the thread can throw after it started. In that case the
        // worker still owns the association and its accounting.
        if (!thread.isExecuting && !thread.isFinished) {
            listener.processes.removeThread(thread);
            ASC_dropAssociation(association);
            ASC_destroyAssociation(&association);
            delete worker;
            --listener.processes.active;
        }
        @throw;
    }
}

// MARK: - The listener

// A connection waiting for its association request is one thread: past this
// many, new connections are closed at once.
static const unsigned IsiXDCMTKMaximumUnreadConnections = 64;

static void IsiXDCMTKReceiveAssociation(ListenerContext& listener, T_ASC_Network* network, int descriptor, const char* peer);

@implementation IsiXDCMTKListenerSettings
@end

@implementation IsiXDCMTKListener
{
    IsiXDCMTKListenerSettings *_settings;
    std::unique_ptr<ListenerContext> _listener;
    T_ASC_Network *_network;
    DcmTLSTransportLayer *_layer;
}

+ (BOOL)dataDictionaryLoaded
{
    BOOL loaded = NO;
    IsiXDCMTKGuard(NULL, "DcmDataDictionary::isDictionaryLoaded", [&]() -> NSError * {
        loaded = dcmDataDict.isDictionaryLoaded() ? YES : NO;
        return nil;
    });
    return loaded;
}

- (instancetype)initWithSettings:(IsiXDCMTKListenerSettings *)settings host:(id<IsiXDCMTKListenerHost>)host
{
    if (!(self = [super init])) return nil;
    _settings = settings;
    if (!IsiXDCMTKGuard(NULL, "DcmQueryRetrieveOptions", [&]() -> NSError * {
        _listener.reset(new ListenerContext);
        _listener->host = host;
        _listener->secureConnection = settings.secureConnection ? OFTrue : OFFalse;
        _listener->aeTitle = settings.aeTitle.UTF8String ?: "";
        DcmQueryRetrieveOptions& options = _listener->options;
        // One process, a thread per association, always: a process forked per
        // association could not run a Core Data context with a queue
        // (libdispatch is not safe after fork()).
        options.singleProcess_ = OFTrue;
        // No restriction on moves.
        options.restrictMoveToSameAE_ = OFFalse;
        options.restrictMoveToSameHost_ = OFFalse;
        options.restrictMoveToSameVendor_ = OFFalse;
        // Only the Study Root model.
        options.supportPatientRoot_ = OFFalse;
        options.supportPatientStudyOnly_ = OFFalse;
        options.networkTransferSyntax_ = (E_TransferSyntax)settings.preferredTransferSyntax;
        options.networkTransferSyntaxOut_ = EXS_LittleEndianExplicit;
        options.acse_timeout_ = settings.timeout;
        options.dimse_timeout_ = settings.timeout;
        options.blockMode_ = DIMSE_NONBLOCKING;
        options.bitPreserving_ = OFFalse;
        options.useMetaheader_ = OFTrue;
        options.writeTransferSyntax_ = EXS_Unknown;
        options.groupLength_ = EGL_withoutGL;
        options.maxAssociations_ = settings.maxAssociations;
        options.maxPDU_ = ASC_DEFAULTMAXPDU;
        dcmConnectionTimeout.set((Sint32)settings.connectionTimeout);
        dcmEnableUnknownVRGeneration.set(OFTrue);
        dcmEnableUnlimitedTextVRGeneration.set(OFTrue);
        return nil;
    })) return nil;
    return self;
}

- (void)dealloc
{
    [self close];
}

// DCMTK closes its socket after a bind that failed, and errno no longer holds
// the bind's error then (it read EBADF); the condition's text ends with that
// error's description, which names it.
static int IsiXDCMTKErrnoOfCondition(const OFCondition& condition, int fallback)
{
    const char* text = condition.text();
    int found = 0;
    size_t length = 0;
    for (int code = 1; code <= ELAST; ++code) {
        const char* description = strerror(code);
        const size_t size = description ? strlen(description) : 0;
        if (size > length && strstr(text, description)) {
            found = code;
            length = size;
        }
    }
    return found ? found : fallback;
}

- (BOOL)openNetwork:(NSError **)error
{
    int code = 0;
    BOOL opened = IsiXDCMTKGuard(error, "ASC_initializeNetwork", [&]() -> NSError * {
        dcmIncomingProtocolFamily.set(ASC_AF_UNSPEC);
        // No reverse DNS lookup of the calling host when an association
        // arrives: while name resolution was slow, no peer got an answer
        // within its timeout. The peer is named by its numeric address; the
        // AE table accepts ANY.
        dcmDisableGethostbyaddr.set(OFTrue);
        OFCondition condition;
        {
            // No listening socket is created while DCMTK is being handed an accepted one.
            std::lock_guard<std::mutex> lock(IsiXDCMTKAdoptedSocketMutex());
            condition = ASC_initializeNetwork(NET_ACCEPTORREQUESTOR, _settings.port, _listener->options.acse_timeout_,
                                              &_listener->options.net_);
            code = errno;
        }
        if (condition.bad()) {
            code = IsiXDCMTKErrnoOfCondition(condition, code);
            IsiXDCMTKListenerMessage("Error initialising network:");
            IsiXDCMTKDumpDIMSECondition(condition);
            NSMutableDictionary *info = [IsiXDCMTKErrorFromCondition(condition).userInfo mutableCopy];
            info[NSUnderlyingErrorKey] = [NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:nil];
            info[IsiXDCMTKOperationKey] = @"ASC_initializeNetwork";
            return [NSError errorWithDomain:IsiXDCMTKErrorDomain
                                       code:(NSInteger)(((unsigned)condition.module() << 16) | condition.code())
                                   userInfo:info];
        }
        _network = _listener->options.net_;
#if defined(HAVE_SETUID) && defined(HAVE_GETUID)
        // Back to the real user, should the program ever run setuid root.
        setuid(getuid());
#endif
        return nil;
    });
    return opened;
}

static NSError *IsiXDCMTKTLSFailure(const char *operation, NSString *file, const OFCondition *condition)
{
    NSMutableDictionary *info = condition ? [IsiXDCMTKErrorFromCondition(*condition, nil, YES).userInfo mutableCopy]
                                          : [NSMutableDictionary dictionaryWithObject:@YES forKey:IsiXDCMTKSecureTransportKey];
    info[IsiXDCMTKOperationKey] = [NSString stringWithUTF8String:operation];
    if (!info[NSLocalizedDescriptionKey]) info[NSLocalizedDescriptionKey] = info[IsiXDCMTKOperationKey];
    if (file) info[IsiXDCMTKListenerFileKey] = file;
    const NSInteger code = condition ? (NSInteger)(((unsigned)condition->module() << 16) | condition->code())
                                     : IsiXDCMTKErrorCodeFailure;
    return [NSError errorWithDomain:IsiXDCMTKErrorDomain code:code userInfo:info];
}

// A TLS step asked for before the layer, or the network, it works on.
static NSError *IsiXDCMTKTLSOutOfOrder(const char *operation)
{
    const OFCondition illegal = EC_IllegalCall;
    return IsiXDCMTKTLSFailure(operation, nil, &illegal);
}

- (BOOL)createTLSLayer:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmTLSTransportLayer", [&]() -> NSError * {
        _layer = new DcmTLSTransportLayer(NET_ACCEPTOR, _settings.seedFile.fileSystemRepresentation, OFTrue);
        return _layer ? nil : IsiXDCMTKTLSFailure("DcmTLSTransportLayer", nil, NULL);
    });
}

- (BOOL)addTrustedCertificateFiles:(NSArray<NSString *> *)files error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmTLSTransportLayer::addTrustedCertificateFile", [&]() -> NSError * {
        if (!_layer) return IsiXDCMTKTLSOutOfOrder("addTrustedCertificateFile");
        for (NSString *file in files) {
            OFCondition condition = _layer->addTrustedCertificateFile([file cStringUsingEncoding:NSUTF8StringEncoding],
                                                                      DCF_Filetype_PEM);
            if (condition.bad()) return IsiXDCMTKTLSFailure("addTrustedCertificateFile", file, &condition);
        }
        return nil;
    });
}

- (BOOL)setPrivateKeyFile:(NSString *)privateKeyFile certificateFile:(NSString *)certificateFile
                 password:(NSString *)password error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmTLSTransportLayer::setPrivateKeyFile", [&]() -> NSError * {
        if (!_layer) return IsiXDCMTKTLSOutOfOrder("setPrivateKeyFile");
        _layer->setPrivateKeyPasswd([password cStringUsingEncoding:NSUTF8StringEncoding]);
        OFCondition condition = _layer->setPrivateKeyFile([privateKeyFile cStringUsingEncoding:NSUTF8StringEncoding],
                                                          DCF_Filetype_PEM);
        if (condition.bad()) return IsiXDCMTKTLSFailure("setPrivateKeyFile", privateKeyFile, &condition);
        condition = _layer->setCertificateFile([certificateFile cStringUsingEncoding:NSUTF8StringEncoding],
                                               DCF_Filetype_PEM, TSP_Profile_BCP_195_RFC_8996);
        if (condition.bad()) return IsiXDCMTKTLSFailure("setCertificateFile", certificateFile, &condition);
        if (!_layer->checkPrivateKeyMatchesCertificate())
            return IsiXDCMTKTLSFailure("checkPrivateKeyMatchesCertificate", certificateFile, NULL);
        return nil;
    });
}

- (BOOL)setCipherSuites:(NSArray<NSString *> *)cipherSuites verification:(int)verification error:(NSError **)error
{
    return IsiXDCMTKGuard(error, "HorosConfigureTLSCipherSuites", [&]() -> NSError * {
        if (!_layer) return IsiXDCMTKTLSOutOfOrder("HorosConfigureTLSCipherSuites");
        OFCondition condition = HorosConfigureTLSCipherSuites(*_layer, cipherSuites);
        if (condition.bad()) return IsiXDCMTKTLSFailure("HorosConfigureTLSCipherSuites", nil, &condition);
        // 0 require, 1 verify, 2 ignore (TLSCertificateVerificationType); any
        // other value requires, never ignores.
        _layer->setCertificateVerification(verification == 2 ? DCV_ignoreCertificate :
                                           verification == 1 ? DCV_checkCertificate : DCV_requireCertificate);
        return nil;
    });
}

- (BOOL)attachTLSLayer:(NSError **)error
{
    return IsiXDCMTKGuard(error, "ASC_setTransportLayer", [&]() -> NSError * {
        if (!_layer || !_network) return IsiXDCMTKTLSOutOfOrder("ASC_setTransportLayer");
        OFCondition condition = ASC_setTransportLayer(_network, _layer, 0);
        if (condition.bad()) {
            IsiXDCMTKDumpDIMSECondition(condition);
            return IsiXDCMTKTLSFailure("ASC_setTransportLayer", nil, &condition);
        }
        return nil;
    });
}

- (BOOL)configure:(NSError **)error
{
    return IsiXDCMTKGuard(error, "DcmQueryRetrieveConfig::init", [&]() -> NSError * {
        DcmQueryRetrieveOptions& options = _listener->options;
        NSString *problem = IsiXDCMTKLoadListenerConfiguration(_listener->config, _settings.port,
            (unsigned long)options.maxPDU_, (int)options.maxAssociations_);
        if (problem) {
            NSMutableDictionary *info = [IsiXDCMTKFailure(problem).userInfo mutableCopy];
            info[IsiXDCMTKOperationKey] = @"DcmQueryRetrieveConfig::init";
            return [NSError errorWithDomain:IsiXDCMTKErrorDomain code:IsiXDCMTKErrorCodeFailure userInfo:info];
        }
        OFCondition condition = IsiXDCMTKConfigureIncomingAssociationProfile(_listener->profiles,
                                                                             options.networkTransferSyntax_);
        if (condition.bad()) {
            NSMutableDictionary *info = [IsiXDCMTKErrorFromCondition(condition,
                [NSString stringWithFormat:@"Unable to configure DICOM listener: %s", condition.text()]).userInfo mutableCopy];
            info[IsiXDCMTKOperationKey] = @"DcmAssociationConfiguration";
            return [NSError errorWithDomain:IsiXDCMTKErrorDomain
                                       code:(NSInteger)(((unsigned)condition.module() << 16) | condition.code())
                                   userInfo:info];
        }
        options.incomingProfile = IsiXDCMTKIncomingAssociationProfile;
        return nil;
    });
}

// Takes a waiting connection and returns; its association request is read on
// a thread of its own.
- (void)acceptConnection
{
    T_ASC_Network *network = _network;
    ListenerContext *listener = _listener.get();
    if (!ASC_associationWaiting(network, 1)) return;

    // Only take the connection here. ASC_receiveAssociation also reads the
    // first PDU on its calling thread, for as long as the ACSE timeout: a peer
    // that connects and sends nothing kept every other peer, and a request to
    // stop the listener, waiting for it.
    struct sockaddr_storage from;
    socklen_t length = sizeof(from);
    int descriptor;
    do descriptor = accept(DUL_networkSocket(network->network), (struct sockaddr*)&from, &length);
    while (descriptor < 0 && errno == EINTR);
    if (descriptor < 0) return;

    char peer[NI_MAXHOST] = "unknown address";
    getnameinfo((struct sockaddr*)&from, length, peer, sizeof(peer), NULL, 0, NI_NUMERICHOST);
    if (listener->processes.stopping || listener->processes.receiving.load() >= IsiXDCMTKMaximumUnreadConnections) {
        if (!listener->processes.stopping)
            NSLog(@"DICOM listener: closed the connection from %s, %u others have not sent their association request yet",
                  peer, listener->processes.receiving.load());
        close(descriptor);
        return;
    }
    ++listener->processes.receiving;
    const OFString address(peer);
    [NSThread detachNewThreadWithBlock:^{
        @try {
            try { IsiXDCMTKReceiveAssociation(*listener, network, descriptor, address.c_str()); }
            catch (...) { NSLog(@"***** C++ exception in %s", __PRETTY_FUNCTION__); }
        }
        @catch (NSException* exception) { NSLog(@"***** exception in %s: %@", __PRETTY_FUNCTION__, exception); }
        --listener->processes.receiving;
    }];
}

static void IsiXDCMTKReceiveAssociation(ListenerContext& listener, T_ASC_Network* network, int descriptor, const char* peer)
{
    const DcmQueryRetrieveOptions& options = listener.options;
    // A silent peer costs its own connection and this thread, nothing else.
    const int limit = options.acse_timeout_ > 0 ? options.acse_timeout_ : 30;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(limit);
    bool readable = false;
    while (!readable && !listener.processes.stopping && std::chrono::steady_clock::now() < deadline) {
        struct pollfd waiting = {descriptor, POLLIN, 0};
        const int found = poll(&waiting, 1, 250);
        if (found > 0) readable = true;
        else if (found < 0 && errno != EINTR) break;
    }
    if (!readable) {
        if (!listener.processes.stopping)
            NSLog(@"DICOM listener: closed the connection from %s, which sent nothing in %d s", peer, limit);
        close(descriptor);
        return;
    }

    T_ASC_Association* association = NULL;
    void *pdu = NULL;
    unsigned long pduSize = 0;
    OFCondition result;
    {
        // DCMTK adopts the socket named by a process-wide variable instead of
        // accepting one. Something has arrived, so this read is short.
        std::lock_guard<std::mutex> lock(IsiXDCMTKAdoptedSocketMutex());
        dcmExternalSocketHandle.set(descriptor);
        result = ASC_receiveAssociation(network, &association, options.maxPDU_, &pdu, &pduSize,
                                        listener.secureConnection, DUL_BLOCK, options.acse_timeout_);
        dcmExternalSocketHandle.set(DCMNET_INVALID_SOCKET);
    }
    if (result.good()) result = HorosDIMSEValidateAssociationPDU(pdu, pduSize);
    free(pdu);
    if (result.bad()) {
        // Without an association DCMTK has already closed the socket.
        if (association) {
            ASC_dropAssociation(association);
            ASC_destroyAssociation(&association);
        }
        return;
    }
    QueryRetrieveAssociation* worker = new QueryRetrieveAssociation(association, listener);
    const NSUInteger maximum = listener.host.maximumConcurrentAssociations;
    std::lock_guard<std::mutex> lock(listener.processes.startMutex);
    if (listener.processes.active.load() >= maximum || listener.processes.stopping) {
        T_ASC_RejectParameters reject = {ASC_RESULT_REJECTEDTRANSIENT,
            ASC_SOURCE_SERVICEPROVIDER_PRESENTATION_RELATED, ASC_REASON_SP_PRES_LOCALLIMITEXCEEDED};
        ASC_rejectAssociation(association, &reject);
        ASC_dropAssociation(association);
        ASC_destroyAssociation(&association);
        delete worker;
        return;
    }
    IsiXDCMTKStartAssociationTask(worker, association, listener);
}

- (void)serveUntil:(BOOL (NS_NOESCAPE ^)(void))stop
{
    if (!_network || !_listener) return;
    while (!stop()) {
        @try {
            try { if (!stop()) [self acceptConnection]; }
            catch (...) { NSLog(@"***** C++ exception in %s", __PRETTY_FUNCTION__); }
        }
        @catch (NSException *exception) { NSLog(@"***** exception in %s: %@", __PRETTY_FUNCTION__, exception); }
    }
}

- (NSError *)close
{
    NSError *error = nil;
    IsiXDCMTKGuard(&error, "ASC_dropNetwork", [&]() -> NSError * {
        if (_listener) {
            // The associations end before the configuration they read is destroyed.
            _listener->processes.requestStop();
            while (_listener->processes.active.load() || _listener->processes.receiving.load())
                [NSThread sleepForTimeInterval:0.05];
        }
        NSError *failure = nil;
        if (_network) {
            OFCondition condition = ASC_dropNetwork(&_network);
            if (condition.bad()) {
                IsiXDCMTKListenerMessage("Error dropping network:");
                IsiXDCMTKDumpDIMSECondition(condition);
                failure = IsiXDCMTKErrorFromCondition(condition);
            }
            _network = NULL;
            if (_listener) _listener->options.net_ = NULL;
        }
        delete _layer;
        _layer = NULL;
        return failure;
    });
    return error;
}

@end
