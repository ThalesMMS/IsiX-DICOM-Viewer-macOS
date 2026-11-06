//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The application's own C-GET and C-MOVE loops (IsiXDCMTKGetUser.mm,
// IsiXDCMTKMoveUser.mm), for IsiXDCMTKQueryRetrieveSCU.mm: DCMTK's public
// messaging API with the host's cancellation, and, for C-GET, the C-STORE
// sub-operations received on the same association, stored through the
// application's IsiXDCMTKSCPDatabase. Upstream providers stay stock. Only
// the adapters' Objective-C++ files include this header.

#pragma once

#ifndef __cplusplus
#error "IsiXDCMTKRetrieveLoops.hpp is for the Objective-C++ files of the DCMTK adapters"
#endif

#include "HorosDCMTKCompatibility.h"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmnet/dimse.h>

@protocol IsiXDCMTKSCPDatabase;

/// Called when the instances a C-GET received are worth importing: after its
/// first C-STORE sub-operation is stored, and when it ends other than on an
/// error of its own messages.
typedef void (*IsiXDCMTKIncomingCallback)(void *data);

OFCondition HorosDIMSEGetUser(T_ASC_Association*, T_ASC_PresentationContextID,
    T_DIMSE_C_GetRQ*, DcmDataset*, DIMSE_GetUserCallback, void*,
    T_DIMSE_BlockingMode, int, T_ASC_Network*, DIMSE_SubOpProviderCallback, void*,
    T_DIMSE_C_GetRSP*, DcmDataset**, DcmDataset**,
    IsiXDCMTKIncomingCallback incoming, void *incomingData, id<IsiXDCMTKSCPDatabase> storage);
OFCondition HorosDIMSEMoveUser(T_ASC_Association*, T_ASC_PresentationContextID,
    T_DIMSE_C_MoveRQ*, DcmDataset*, DIMSE_MoveUserCallback, void*,
    T_DIMSE_BlockingMode, int, T_ASC_Network*, DIMSE_SubOpProviderCallback, void*,
    T_DIMSE_C_MoveRSP*, DcmDataset**, DcmDataset**, OFBool = OFFalse);
