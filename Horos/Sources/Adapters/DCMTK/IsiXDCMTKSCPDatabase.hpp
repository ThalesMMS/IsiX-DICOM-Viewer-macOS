//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The database handle DCMTK's Q/R classes read, over the application's
// IsiXDCMTKSCPDatabase, and the C-STORE provider of the listener and of the
// C-GET loop (IsiXDCMTKGetUser.mm). Only the adapters' Objective-C++ files
// include this header.

#pragma once

#ifndef __cplusplus
#error "IsiXDCMTKSCPDatabase.hpp is for the Objective-C++ files of the DCMTK adapters"
#endif

#import "IsiXDCMTKQueryRetrieveSCP.h"

#include "HorosDCMTKCompatibility.h"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmnet/dimse.h>
#include <dcmtk/dcmqrdb/dcmqrdba.h>
#include <dcmtk/dcmqrdb/dcmqropt.h>

/// The DCMTK database handle of one association: each call of DCMTK's find,
/// move and store contexts goes to the application's database object, and
/// what it answers becomes the DIMSE status DCMTK expects.
class IsiXDCMTKSCPDatabaseHandle : public DcmQueryRetrieveDatabaseHandle
{
public:
    /// Keeps `database` for the handle's life and closes it when destroyed.
    explicit IsiXDCMTKSCPDatabaseHandle(id<IsiXDCMTKSCPDatabase> database);
    ~IsiXDCMTKSCPDatabaseHandle() override;

    id<IsiXDCMTKSCPDatabase> database() const;

    /// The move destination of the C-MOVE about to start; cleared by each
    /// retrieve that starts.
    void setMoveDestination(const char* aeTitle);

    OFCondition makeNewStoreFileName(const char* sopClass, const char* sopInstance, char* path, size_t capacity) override;
    OFCondition storeRequest(const char* sopClass, const char* sopInstance, const char* path,
                             DcmQueryRetrieveDatabaseStatus* status, OFBool isNew = OFTrue) override;
    OFCondition startFindRequest(const char* sopClass, DcmDataset* identifiers,
                                 DcmQueryRetrieveDatabaseStatus* status) override;
    OFCondition nextFindResponse(DcmDataset** identifiers, DcmQueryRetrieveDatabaseStatus* status,
                                 const DcmQueryRetrieveCharacterSetOptions& options) override;
    OFCondition cancelFindRequest(DcmQueryRetrieveDatabaseStatus* status) override;
    OFCondition startMoveRequest(const char* sopClass, DcmDataset* identifiers,
                                 DcmQueryRetrieveDatabaseStatus* status) override;
    OFCondition nextMoveResponse(char* sopClass, size_t classCapacity, char* sopInstance, size_t instanceCapacity,
                                 char* path, size_t pathCapacity, unsigned short* remaining,
                                 DcmQueryRetrieveDatabaseStatus* status) override;
    OFCondition cancelMoveRequest(DcmQueryRetrieveDatabaseStatus* status) override;
    OFCondition pruneInvalidRecords() override;
    void setIdentifierChecking(OFBool checkFind, OFBool checkMove) override;

private:
    IsiXDCMTKSCPDatabaseHandle(const IsiXDCMTKSCPDatabaseHandle&) = delete;
    IsiXDCMTKSCPDatabaseHandle& operator=(const IsiXDCMTKSCPDatabaseHandle&) = delete;

    struct State;
    State* state_;
};

/// The error condition the handle answers a failed request with.
extern const OFCondition IsiXDCMTKSCPDatabaseError;

/// Receives one C-STORE on `association` and stores it through `database`:
/// the file is written in the database's receiving folder, published when
/// complete, and the sender answered with the status. A C-STORE refused, or
/// cancelled with the thread or the global abort, consumes the dataset first.
OFCondition IsiXDCMTKStoreSCP(T_ASC_Association* association, T_DIMSE_C_StoreRQ& request,
                              T_ASC_PresentationContextID presentationID,
                              IsiXDCMTKSCPDatabaseHandle& database, const DcmQueryRetrieveOptions& options);
