//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// What the DCMTK adapters share in C++: the conversion of an OFCondition into
// an NSError, the guard every call into DCMTK goes through, the level of
// DCMTK's own log, and the DCMTK dataset behind an IsiXDCMTKDataset. Only the
// adapters' Objective-C++ files include this header; their public headers
// declare Objective-C and C types alone.

#pragma once

#ifndef __cplusplus
#error "IsiXDCMTKInternal.hpp is for the Objective-C++ files of the DCMTK adapters"
#endif

#import <Foundation/Foundation.h>
#import "IsiXDCMTKError.h"

#undef verify
#include "HorosDCMTKCompatibility.h"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/ofstd/ofcond.h>
#include <dcmtk/dcmnet/cond.h>
#include <dcmtk/dcmnet/dul.h>
#include <exception>
#include <memory>
#include <utility>

/// The error for `condition`, nil for EC_Normal. `description` replaces the
/// condition's text as the localized description when given.
NSError *IsiXDCMTKErrorFromCondition(const OFCondition &condition, NSString *description = nil,
                                     BOOL secureTransport = NO);

/// The error for a failure DCMTK reports without a condition.
NSError *IsiXDCMTKFailure(NSString *description, BOOL secureTransport = NO);

/// The error for a C++ exception caught in an adapter.
NSError *IsiXDCMTKErrorFromException(const char *what, const char *operation);

/// An Objective-C exception as the log may write it: its name and how long its
/// reason is. What the listener serves is made of the values a peer sent - a
/// patient's name or identifier in the keys of a C-FIND or a C-MOVE - and the
/// reason of an exception raised over them quotes them: a condition that
/// cannot be evaluated is quoted whole.
NSString *IsiXDCMTKLoggedException(NSException *exception);

/// Sets the level of DCMTK's own log; nothing else in the application does.
/// That log is the process's and is written to the standard error, and DCMTK
/// starts it at INFO, where its Query/Retrieve classes print the identifier
/// of every C-FIND a peer sends the listener: the values of the keys asked,
/// which are a patient's name, ID or birth date, or an accession number.
/// Without `dumpsDatasets` the level is WARN, which has DCMTK's warnings and
/// errors and no dataset; with it (the user default DICOMDatasetDump) it is
/// INFO, for whoever diagnoses a node. Never DEBUG or TRACE.
void IsiXDCMTKConfigureLog(BOOL dumpsDatasets);

/// Runs `body`, which returns the call's error (nil when it succeeded), and
/// turns any C++ exception it throws into an error. Returns whether the call
/// succeeded, and gives its error through `error`.
template <typename Body>
static inline BOOL IsiXDCMTKGuard(NSError * __autoreleasing *error, const char *operation, Body &&body)
{
    NSError *failure = nil;
    try {
        failure = std::forward<Body>(body)();
    } catch (const std::exception &exception) {
        failure = IsiXDCMTKErrorFromException(exception.what(), operation);
    } catch (...) {
        failure = IsiXDCMTKErrorFromException("unknown exception", operation);
    }
    if (failure && error) *error = failure;
    return failure == nil;
}

class DcmDataset;
struct T_ASC_Association;

@class IsiXDCMTKDataset;
@class IsiXDCMTKAssociation;

/// The DCMTK association an IsiXDCMTKAssociation holds, NULL before it is
/// requested or after it is invalidated, its DIMSE timeout, and whether it
/// was asked to print the datasets it exchanges to the standard output.
T_ASC_Association *IsiXDCMTKAssociationHandle(IsiXDCMTKAssociation *association);
int IsiXDCMTKAssociationDIMSETimeout(IsiXDCMTKAssociation *association);
BOOL IsiXDCMTKAssociationDumpsDatasets(IsiXDCMTKAssociation *association);

/// The DCMTK dataset an IsiXDCMTKDataset owns, for the other adapters.
DcmDataset *IsiXDCMTKDatasetStorage(IsiXDCMTKDataset *dataset);

/// A dataset that takes ownership of `storage`.
IsiXDCMTKDataset *IsiXDCMTKDatasetTakingOwnership(DcmDataset *storage);

/// The DCMTK dataset an IsiXDCMTKDataset owns, handed to the caller, who
/// deletes it; the IsiXDCMTKDataset is empty afterwards and must not be used.
DcmDataset *IsiXDCMTKDatasetReleaseStorage(IsiXDCMTKDataset *dataset);

class DcmFileFormat;
@class IsiXDCMTKFile;

/// The DcmFileFormat an IsiXDCMTKFile holds, shared with whoever keeps a view
/// of it (HorosDCMTKObject keeps the file its attributes point into).
std::shared_ptr<DcmFileFormat> IsiXDCMTKFileStorage(IsiXDCMTKFile *file);

/// A file over `storage`, which it shares.
IsiXDCMTKFile *IsiXDCMTKFileSharing(std::shared_ptr<DcmFileFormat> storage);

/// A path as DCMTK opens it, or NULL for one with no file system
/// representation (nil, empty, or a name the file system cannot hold), which
/// must not reach DCMTK.
const char *IsiXDCMTKFileSystemPath(NSString *path);
