//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import "IsiXDCMTKSCPDatabase.hpp"
#import "IsiXDCMTKInternal.hpp"

#include "HorosDICOMIdentity.h"
#include "HorosDICOMStoreSource.h"
#include "HorosDICOMGlobalAbort.h"
#include <dcmtk/dcmdata/dcdatset.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/dcmdata/dcmetinf.h>
#include <dcmtk/dcmdata/dcuid.h>
#include <dcmtk/dcmnet/diutil.h>
#include <dcmtk/dcmqrdb/dcmqrcbs.h>
#include <dcmtk/dcmqrdb/dcmqrdbs.h>
#include <dcmtk/ofstd/offname.h>
#include <dcmtk/ofstd/ofstd.h>
#include <atomic>
#include <exception>
#include <sys/param.h>
#include <unistd.h>

#if !__has_feature(objc_arc)
#error "IsiXDCMTKSCPDatabase.mm is compiled with ARC (-fobjc-arc)"
#endif

makeOFConditionConst(IsiXDCMTKSCPDatabaseErrorConstant, OFM_dcmqrdb, 0x001, OF_error, "DcmQR Index Database Error");
const OFCondition IsiXDCMTKSCPDatabaseError(IsiXDCMTKSCPDatabaseErrorConstant);

struct IsiXDCMTKSCPDatabaseHandle::State
{
    id<IsiXDCMTKSCPDatabase> database;
    /// The move destination of the C-MOVE about to start.
    NSData *moveDestination = nil;
    /// The sub-operations of the current retrieve not yet asked for.
    int remaining = 0;
    OFFilenameCreator names;
};

IsiXDCMTKSCPDatabaseHandle::IsiXDCMTKSCPDatabaseHandle(id<IsiXDCMTKSCPDatabase> database)
    : state_(new State)
{
    state_->database = database;
}

IsiXDCMTKSCPDatabaseHandle::~IsiXDCMTKSCPDatabaseHandle()
{
    @try { [state_->database close]; }
    @catch (NSException *exception) { NSLog(@"DICOM listener: closing the database failed: %@", exception); }
    delete state_;
}

id<IsiXDCMTKSCPDatabase> IsiXDCMTKSCPDatabaseHandle::database() const
{
    return state_->database;
}

void IsiXDCMTKSCPDatabaseHandle::setMoveDestination(const char* aeTitle)
{
    state_->moveDestination = aeTitle ? [NSData dataWithBytes:aeTitle length:strlen(aeTitle)] : nil;
}

static NSString *IsiXDCMTKString(const char *text)
{
    return [NSString stringWithUTF8String:text ? text : ""] ?: @"";
}

// DCMTK's find, move and store contexts call the handle from C code that must
// not unwind: an exception the application's database raises, Objective-C or
// C++, fails the request it was asked for, with `failure` as its status.
template <typename Body>
static OFCondition IsiXDCMTKSCPCall(const char *step, DcmQueryRetrieveDatabaseStatus *status, Uint16 failure, Body body)
{
    // The Objective-C handler is the inner one: catch (...) would take an
    // NSException too.
    try {
        @try { return body(); }
        @catch (NSException *exception) { NSLog(@"DICOM listener: the database's %s raised %@", step, exception); }
    }
    catch (const std::exception& error) { NSLog(@"DICOM listener: the database's %s threw: %s", step, error.what()); }
    catch (...) { NSLog(@"DICOM listener: the database's %s threw a C++ exception", step); }
    if (status) status->setStatus(failure);
    return IsiXDCMTKSCPDatabaseError;
}

// The application's answer as the status DCMTK's find and move contexts read.
static OFCondition IsiXDCMTKSCPStart(IsiXDCMTKSCPRequestStart start, bool find, DcmQueryRetrieveDatabaseStatus *status)
{
    switch (start) {
        case IsiXDCMTKSCPRequestStartNoMatch:
            status->setStatus(STATUS_Success);
            return EC_Normal;
        case IsiXDCMTKSCPRequestStartMatches:
            status->setStatus(STATUS_Pending);
            return EC_Normal;
        case IsiXDCMTKSCPRequestStartSOPClassNotSupported:
            status->setStatus(find ? STATUS_FIND_Refused_SOPClassNotSupported : STATUS_MOVE_Failed_SOPClassNotSupported);
            return IsiXDCMTKSCPDatabaseError;
        case IsiXDCMTKSCPRequestStartMissingLevel:
            // A retrieve answers with the find's status, as DCMTK's index database did.
            status->setStatus(STATUS_FIND_Failed_IdentifierDoesNotMatchSOPClass);
            CERR << "DB_startFindRequest(): missing Query/Retrieve Level" << OFendl;
            return IsiXDCMTKSCPDatabaseError;
        case IsiXDCMTKSCPRequestStartUnknownLevel:
            status->setStatus(STATUS_FIND_Failed_UnableToProcess);
            return IsiXDCMTKSCPDatabaseError;
        case IsiXDCMTKSCPRequestStartFailed:
        default:
            status->setStatus(STATUS_FIND_Failed_UnableToProcess);
            return EC_IllegalParameter;
    }
}

OFCondition IsiXDCMTKSCPDatabaseHandle::startFindRequest(const char* sopClass, DcmDataset* identifiers,
                                                         DcmQueryRetrieveDatabaseStatus* status)
{
    return IsiXDCMTKSCPCall("C-FIND start", status, STATUS_FIND_Failed_UnableToProcess, [&]() -> OFCondition {
        IsiXDCMTKDataset *identifier = IsiXDCMTKDatasetTakingOwnership(new DcmDataset(*identifiers));
        return IsiXDCMTKSCPStart([state_->database startFindWithSOPClass:IsiXDCMTKString(sopClass) identifier:identifier],
                                 true, status);
    });
}

OFCondition IsiXDCMTKSCPDatabaseHandle::nextFindResponse(DcmDataset** identifiers, DcmQueryRetrieveDatabaseStatus* status,
                                                         const DcmQueryRetrieveCharacterSetOptions&)
{
    *identifiers = NULL;
    return IsiXDCMTKSCPCall("C-FIND response", status, STATUS_FIND_Failed_UnableToProcess, [&]() -> OFCondition {
        // The application writes each response in its character set and names
        // it in Specific Character Set itself.
        IsiXDCMTKDataset *response = [[IsiXDCMTKDataset alloc] init];
        if (![state_->database nextFindResponse:response]) {
            status->setStatus(STATUS_Success);
            return EC_Normal;
        }
        *identifiers = IsiXDCMTKDatasetReleaseStorage(response);
        status->setStatus(STATUS_Pending);
        return EC_Normal;
    });
}

OFCondition IsiXDCMTKSCPDatabaseHandle::cancelFindRequest(DcmQueryRetrieveDatabaseStatus*)
{
    return IsiXDCMTKSCPDatabaseError;
}

OFCondition IsiXDCMTKSCPDatabaseHandle::startMoveRequest(const char* sopClass, DcmDataset* identifiers,
                                                         DcmQueryRetrieveDatabaseStatus* status)
{
    NSData *destination = state_->moveDestination;
    state_->moveDestination = nil;
    state_->remaining = 0;
    return IsiXDCMTKSCPCall("retrieve start", status, STATUS_MOVE_Failed_UnableToProcess, [&]() -> OFCondition {
        IsiXDCMTKDataset *identifier = IsiXDCMTKDatasetTakingOwnership(new DcmDataset(*identifiers));
        IsiXDCMTKSCPRequestStart start = [state_->database startRetrieveWithSOPClass:IsiXDCMTKString(sopClass)
                                                                           identifier:identifier
                                                                      moveDestination:destination];
        if (start == IsiXDCMTKSCPRequestStartMatches || start == IsiXDCMTKSCPRequestStartNoMatch ||
            start == IsiXDCMTKSCPRequestStartFailed) {
            // What could not be read is nothing to send.
            state_->remaining = start == IsiXDCMTKSCPRequestStartMatches ? (int)[state_->database retrieveCount] : 0;
            return IsiXDCMTKSCPStart(state_->remaining > 0 ? IsiXDCMTKSCPRequestStartMatches : IsiXDCMTKSCPRequestStartNoMatch,
                                     false, status);
        }
        return IsiXDCMTKSCPStart(start, false, status);
    });
}

OFCondition IsiXDCMTKSCPDatabaseHandle::nextMoveResponse(char* sopClass, size_t classCapacity, char* sopInstance,
                                                         size_t instanceCapacity, char* path, size_t pathCapacity,
                                                         unsigned short* remaining, DcmQueryRetrieveDatabaseStatus* status)
{
    if (!sopClass || !sopInstance || !path || classCapacity < DICOM_UI_LENGTH + 1 ||
        instanceCapacity < DICOM_UI_LENGTH + 1 || pathCapacity < MAXPATHLEN + 1)
        return EC_IllegalParameter;
    if (state_->remaining <= 0) {
        status->setStatus(STATUS_Success);
        return EC_Normal;
    }
    *remaining = (unsigned short)--state_->remaining;
    status->setStatus(STATUS_Pending);
    // A path the database cannot give is a sub-operation that fails, as one
    // that does not load.
    NSString *file = nil;
    OFCondition asked = IsiXDCMTKSCPCall("next retrieve file", NULL, 0, [&]() -> OFCondition {
        file = [state_->database nextRetrievePath];
        return EC_Normal;
    });
    if (asked.bad() || !file || ![file getFileSystemRepresentation:path maxLength:MAXPATHLEN + 1])
        return EC_IllegalParameter;
    DcmFileFormat fileformat;
    OFCondition condition = fileformat.loadFile(path);
    if (condition.good() && !HorosFindSOPClassAndInstanceInDataSet(fileformat.getDataset(),
            sopClass, DICOM_UI_LENGTH + 1, sopInstance, DICOM_UI_LENGTH + 1))
        condition = EC_IllegalParameter;
    return condition;
}

OFCondition IsiXDCMTKSCPDatabaseHandle::cancelMoveRequest(DcmQueryRetrieveDatabaseStatus* status)
{
    // The provider must see a terminal status before deciding whether to start
    // another C-STORE and whether to release its storage association.
    NSLog(@"---- DICOM retrieve cancellation accepted: %d remaining", state_->remaining);
    IsiXDCMTKSCPCall("retrieve cancellation", NULL, 0, [&]() -> OFCondition {
        [state_->database cancelRetrieve];
        return EC_Normal;
    });
    state_->remaining = 0;
    status->setStatus(STATUS_MOVE_Cancel_SubOperationsTerminatedDueToCancelIndication);
    return EC_Normal;
}

static std::atomic<unsigned> IsiXDCMTKStoreSeed{0};

OFCondition IsiXDCMTKSCPDatabaseHandle::makeNewStoreFileName(const char* sopClass, const char*, char* path, size_t capacity)
{
    if (!path || capacity < MAXPATHLEN + 1) return EC_IllegalParameter;
    const char *modality = dcmSOPClassUIDToModality(sopClass);
    if (modality == NULL) modality = "XX";
    char prefix[64];
    snprintf(prefix, sizeof(prefix), "%.16s_%d_", modality, getpid());
    unsigned seed = IsiXDCMTKStoreSeed.fetch_add(1, std::memory_order_relaxed) + 1;
    path[0] = 0; // an empty name when it fails
    NSString *folder = nil;
    if (IsiXDCMTKSCPCall("receiving folder", NULL, 0, [&]() -> OFCondition {
            folder = [state_->database receivingDirectory];
            return EC_Normal;
        }).bad())
        return IsiXDCMTKSCPDatabaseError;
    OFString filename;
    if (!state_->names.makeFilename(seed, folder.length ? folder.fileSystemRepresentation : NULL, prefix, ".dcm", filename))
        return IsiXDCMTKSCPDatabaseError;
    if (filename.length() > MAXPATHLEN) return IsiXDCMTKSCPDatabaseError;
    memcpy(path, filename.c_str(), filename.length() + 1);
    return EC_Normal;
}

OFCondition IsiXDCMTKSCPDatabaseHandle::storeRequest(const char*, const char*, const char* path,
                                                     DcmQueryRetrieveDatabaseStatus* status, OFBool)
{
    // Published before the C-STORE response promises Success: a file still in
    // the receiving folder is not one the database imports.
    return IsiXDCMTKSCPCall("publication", status, STATUS_STORE_Refused_OutOfResources, [&]() -> OFCondition {
        NSString *file = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:path length:strlen(path)];
        NSString *failure = [state_->database publishReceivedFileAtPath:file];
        if (failure) {
            status->setStatus(STATUS_STORE_Refused_OutOfResources);
            return makeOFCondition(OFM_imagectn, 0x001, OF_error, failure.UTF8String ?: "");
        }
        status->setStatus(STATUS_Success);
        return EC_Normal;
    });
}

OFCondition IsiXDCMTKSCPDatabaseHandle::pruneInvalidRecords()
{
    return EC_Normal;
}

void IsiXDCMTKSCPDatabaseHandle::setIdentifierChecking(OFBool, OFBool)
{
    // The application checks the identifiers itself.
}

// MARK: - C-STORE

namespace {

struct StoreCallbackContext
{
    DcmQueryRetrieveStoreContext* store;
    T_ASC_Association* association;
    IsiXDCMTKSCPDatabaseHandle* database;
    bool aborted = false;
    bool preserveCompletedFile = false;
};

NSString *StoreString(const OFString& value)
{
    return [NSString stringWithUTF8String:value.c_str()] ?: @"";
}

void storeCallback(void* data, T_DIMSE_StoreProgress* progress, T_DIMSE_C_StoreRQ* request,
                   char* path, DcmDataset** dataset, T_DIMSE_C_StoreRSP* response, DcmDataset** detail)
{
    auto* info = static_cast<StoreCallbackContext*>(data);
    auto* context = info->store;
    // Cancellation stays on the receiving worker, including a streaming C-GET
    // sub-operation. No cancelled object may reach publication or inventory.
    if ([NSThread currentThread].isCancelled || HorosDICOMGlobalAbortRequested()) {
        context->setStatus(STATUS_STORE_Refused_OutOfResources);
        response->DimseStatus = STATUS_STORE_Refused_OutOfResources;
        if (!info->aborted) {
            info->aborted = true;
            ASC_closeTransportConnection(info->association);
        }
        return;
    }
    if (progress->state == DIMSE_StoreEnd && dataset && *dataset && context->getStatus() == STATUS_Success) {
        char sopClass[65] = {}, sopInstance[65] = {};
        if (!HorosFindSOPClassAndInstanceInDataSet(*dataset, sopClass, sizeof(sopClass),
                sopInstance, sizeof(sopInstance)) || !sopClass[0] || !sopInstance[0])
            context->setStatus(STATUS_STORE_Error_CannotUnderstand);
        // Stored, it would be indexed and counted as received; refused, the
        // retrieve inventory records it and a later retrieve asks again.
        else if (HorosDataSetLacksDeclaredPixels(*dataset)) {
            context->setStatus(STATUS_STORE_Error_DataSetDoesNotMatchSOPClass);
            NSLog(@"Refused %s from %.16s: it declares an image but its Pixel Data is empty",
                  sopInstance, info->association->params->DULparams.callingAPTitle);
        }
    }
    if (context->getStatus() != STATUS_Success)
        response->DimseStatus = context->getStatus();
    const bool canPublish = context->getStatus() == STATUS_Success && response->DimseStatus == STATUS_Success;
    context->callbackHandler(progress, request, path, dataset, response, detail);
    // Upstream deletes an incomplete write itself. If a complete, valid file
    // remains after publication fails, preserve it for diagnosis/recovery.
    if (progress->state == DIMSE_StoreEnd && canPublish && response->DimseStatus == STATUS_STORE_Refused_OutOfResources)
        info->preserveCompletedFile = true;
    if (progress->state == DIMSE_StoreEnd) {
        OFString study, series;
        if (dataset && *dataset) {
            (*dataset)->findAndGetOFString(DCM_StudyInstanceUID, study);
            (*dataset)->findAndGetOFString(DCM_SeriesInstanceUID, series);
        }
        IsiXDCMTKSCPCall("end of a C-STORE", NULL, 0, [&]() -> OFCondition {
            [info->database->database() didEndStoreOfInstance:[NSString stringWithUTF8String:request->AffectedSOPInstanceUID] ?: @""
                                                         study:StoreString(study) series:StoreString(series)
                                                        status:response->DimseStatus];
            return EC_Normal;
        });
    }
}

// What a received instance's log entry reads of it, as DCMTK holds the values.
NSDictionary<NSNumber *, NSData *> *StoredAttributes(DcmDataset* dataset)
{
    NSMutableDictionary<NSNumber *, NSData *> *attributes = [NSMutableDictionary dictionary];
    const DcmTagKey tags[] = {DCM_SpecificCharacterSet, DCM_PatientName, DCM_StudyDescription,
                              DCM_SeriesDescription, DCM_SeriesInstanceUID};
    for (const DcmTagKey& tag : tags) {
        const char* value = NULL;
        if (dataset->findAndGetString(tag, value, OFFalse).good() && value != NULL)
            attributes[@(((uint32_t)tag.getGroup() << 16) | tag.getElement())] = [NSData dataWithBytes:value length:strlen(value)];
    }
    return attributes;
}

} // namespace

OFCondition IsiXDCMTKStoreSCP(T_ASC_Association* association, T_DIMSE_C_StoreRQ& request,
                              T_ASC_PresentationContextID presentationID,
                              IsiXDCMTKSCPDatabaseHandle& database, const DcmQueryRetrieveOptions& options)
{
    id<IsiXDCMTKSCPDatabase> application = database.database();
    DcmFileFormat file;
    DcmQueryRetrieveStoreContext context(database, options, STATUS_Success, &file, options.correctUIDPadding_);
    char path[MAXPATHLEN + 1] = {};
    if (!dcmIsaStorageSOPClassUID(request.AffectedSOPClassUID))
        context.setStatus(STATUS_STORE_Refused_SOPClassNotSupported);
    else if (!options.ignoreStoreData_ && database.makeNewStoreFileName(request.AffectedSOPClassUID,
                 request.AffectedSOPInstanceUID, path, sizeof(path)).bad())
        context.setStatus(STATUS_STORE_Refused_OutOfResources);
    if (!path[0] || context.getStatus() != STATUS_Success)
        OFStandard::strlcpy(path, NULL_DEVICE_NAME, sizeof(path));

    HorosDICOMFileLock lock(path, true);
    if (!lock.valid()) {
        context.setStatus(STATUS_STORE_Refused_OutOfResources);
        OFStandard::strlcpy(path, NULL_DEVICE_NAME, sizeof(path));
    }
    context.setFileName(path);
    BOOL namesSender = NO, namesCalledTitle = NO;
    IsiXDCMTKSCPCall("names of received files", NULL, 0, [&]() -> OFCondition {
        namesSender = application.namesSenderInReceivedFiles;
        namesCalledTitle = application.namesCalledTitleInReceivedFiles;
        return EC_Normal;
    });
    if (namesSender)
        file.getMetaInfo()->putAndInsertString(DCM_SourceApplicationEntityTitle,
                                               association->params->DULparams.callingAPTitle);
    if (namesCalledTitle)
        file.getMetaInfo()->putAndInsertString(DCM_PrivateInformationCreatorUID,
                                               association->params->DULparams.calledAPTitle);
    DcmDataset* dataset = file.getDataset();
    StoreCallbackContext callback;
    callback.store = &context;
    callback.association = association;
    callback.database = &database;
    // Even a refused store must consume the incoming dataset before replying.
    OFCondition result = DIMSE_storeProvider(association, presentationID, &request,
        options.bitPreserving_ ? path : NULL, options.useMetaheader_,
        options.bitPreserving_ ? NULL : &dataset, storeCallback, &callback,
        options.blockMode_, options.dimse_timeout_);
    if (!options.ignoreStoreData_ && (result.bad() || context.getStatus() != STATUS_Success)) {
        if (!callback.preserveCompletedFile && strcmp(path, NULL_DEVICE_NAME) != 0)
            OFStandard::deleteFile(path);
        database.pruneInvalidRecords();
    }
    // The sender does not say how many it will send: the count alone, and one
    // network log entry per association, what it received and from whom.
    if (result.good() && context.getStatus() == STATUS_Success)
        IsiXDCMTKSCPCall("record of a C-STORE", NULL, 0, [&]() -> OFCondition {
            [application didStoreInstanceWithAttributes:dataset ? StoredAttributes(dataset) : nil];
            return EC_Normal;
        });
    return result;
}
