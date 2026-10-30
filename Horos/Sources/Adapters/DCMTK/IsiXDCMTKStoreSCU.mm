//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// What DCMTK does for a send (DCMTKStoreSCU.swift): the files read for a
// C-STORE, their copies in another transfer syntax, and the C-STORE itself on
// an IsiXDCMTKAssociation. Which syntax to propose, when to convert a file and
// what to report stay in Swift. Compiled with ARC.

#import "IsiXDCMTKStoreSCU.h"
#import "IsiXDCMTKInternal.hpp"

#include "HorosDICOMIdentity.h"
#include "HorosDICOMRepresentation.h"

#include <dcmtk/dcmnet/dimse.h>
#include <dcmtk/dcmnet/diutil.h>
#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/dcmdata/dcdatset.h>
#include <dcmtk/dcmdata/dcuid.h>
#include <dcmtk/dcmdata/dcxfer.h>
#include <dcmtk/dcmdata/dcostrmz.h>
#include <dcmtk/dcmdata/dcrlerp.h>
#include <dcmtk/dcmjpeg/djrploss.h>
#include <dcmtk/dcmjpeg/djrplol.h>
#include <dcmtk/oflog/oflog.h>
#include <dcmtk/ofstd/ofstd.h>
#include <memory>
#include <unistd.h>

#if !__has_feature(objc_arc)
#error "IsiXDCMTKStoreSCU.mm is compiled with ARC (-fobjc-arc)"
#endif

// The name the send's diagnostics have always carried.
#define OFFIS_CONSOLE_APPLICATION "storescu"

static void IsiXDCMTKStoreDumpCondition(const OFCondition &condition)
{
    OFString text;
    DimseCondition::dump(text, condition);
    ofConsole.lockCerr() << text << OFendl;
    ofConsole.unlockCerr();
}

static NSString *IsiXDCMTKString(const char *text)
{
    return text ? [NSString stringWithUTF8String:text] : nil;
}

@interface IsiXDCMTKTransferSyntax ()
- (instancetype)initWithXfer:(const DcmXfer &)xfer NS_DESIGNATED_INITIALIZER;
@end

@interface IsiXDCMTKStoreFile ()
- (DcmFileFormat *)fileFormat;
@end

#pragma mark Transfer syntaxes and UIDs

@implementation IsiXDCMTKTransferSyntax

- (instancetype)initWithXfer:(const DcmXfer &)xfer
{
    if ((self = [super init])) {
        _uid = IsiXDCMTKString(xfer.getXferID()) ?: @"";
        _known = xfer.getXfer() != EXS_Unknown;
        _usesNativeFormat = xfer.usesNativeFormat() ? YES : NO;
        _usesEncapsulatedFormat = xfer.usesEncapsulatedFormat() ? YES : NO;
        _pixelDataCompressed = xfer.isPixelDataCompressed() ? YES : NO;
    }
    return self;
}

- (instancetype)initWithUID:(NSString *)uid
{
    IsiXDCMTKTransferSyntax *syntax = nil;
    IsiXDCMTKGuard(NULL, "DcmXfer", [&]() -> NSError * {
        syntax = [self initWithXfer:DcmXfer(uid.UTF8String ?: "")];
        return nil;
    });
    return syntax ?: [self initWithXfer:DcmXfer(EXS_Unknown)];
}

- (instancetype)initWithDCMTKValue:(NSInteger)value
{
    IsiXDCMTKTransferSyntax *syntax = nil;
    IsiXDCMTKGuard(NULL, "DcmXfer", [&]() -> NSError * {
        syntax = [self initWithXfer:DcmXfer((E_TransferSyntax)value)];
        return nil;
    });
    return syntax ?: [self initWithXfer:DcmXfer(EXS_Unknown)];
}

@end

@implementation IsiXDCMTKUIDs

+ (NSString *)nameOfUID:(NSString *)uid
{
    return IsiXDCMTKString(dcmFindNameOfUID(uid.UTF8String ?: ""));
}

+ (NSString *)modalityOfSOPClass:(NSString *)sopClass
{
    return IsiXDCMTKString(dcmSOPClassUIDToModality(sopClass.UTF8String ?: ""));
}

+ (NSArray<NSString *> *)shortStorageSOPClasses
{
    static NSArray<NSString *> *classes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *list = [NSMutableArray array];
        for (int i = 0; i < numberOfDcmShortSCUStorageSOPClassUIDs; i++)
            if (dcmShortSCUStorageSOPClassUIDs[i]) [list addObject:@(dcmShortSCUStorageSOPClassUIDs[i])];
        classes = [list copy];
    });
    return classes;
}

@end

#pragma mark Files

@implementation IsiXDCMTKStoreFile
{
    std::unique_ptr<DcmFileFormat> _file;
}

- (instancetype)initWithPath:(NSString *)path error:(NSError **)error
{
    if (!(self = [super init])) return nil;
    _path = [path copy];
    BOOL loaded = IsiXDCMTKGuard(error, "DcmFileFormat::loadFile", [&]() -> NSError * {
        _file.reset(new DcmFileFormat());
        OFCondition condition = _file->loadFile(path.fileSystemRepresentation);
        if (condition.bad()) return IsiXDCMTKErrorFromCondition(condition);
        // DIC_UI: a UID of 64 characters and its terminator.
        DIC_UI sopClass, sopInstance;
        if (HorosFindSOPClassAndInstanceInDataSet(_file->getDataset(), sopClass, sizeof(sopClass),
                                                  sopInstance, sizeof(sopInstance), OFFalse)) {
            _sopClassUID = IsiXDCMTKString(sopClass);
            _sopInstanceUID = IsiXDCMTKString(sopInstance);
        }
        _transferSyntax = [[IsiXDCMTKTransferSyntax alloc] initWithXfer:DcmXfer(_file->getDataset()->getOriginalXfer())];
        return nil;
    });
    return loaded ? self : nil;
}

- (BOOL)writeCopyToPath:(NSString *)path transferSyntax:(NSString *)transferSyntax quality:(int)quality
{
    BOOL written = NO;
    IsiXDCMTKGuard(NULL, "DcmFileFormat::saveFile", [&]() -> NSError * {
        // A copy: this file keeps the representation it was read in.
        DcmFileFormat copy(*_file);
        DcmDataset *dataset = copy.getDataset();
        if (!dataset) return nil;
        const E_TransferSyntax target = DcmXfer(transferSyntax.UTF8String ?: "").getXfer();
        // The representation parameters storescu gave each encoder; JPEG 2000
        // and JPEG-LS take theirs from `quality` (HorosDICOMRepresentation.h).
        DJ_RPLossy lossy(90);
        DJ_RPLossy jpeg2000(quality);
        DJ_RPLossy jpeg2000Lossless(0);
        DcmRLERepresentationParameter rle;
        DJ_RPLossless lossless(6, 0);
        const DcmRepresentationParameter *parameters = NULL;
        switch (target) {
            case EXS_JPEGProcess14SV1: parameters = &lossless; break;
            case EXS_JPEGProcess2_4: parameters = &lossy; break;
            case EXS_RLELossless: parameters = &rle; break;
            case EXS_JPEG2000LosslessOnly: case EXS_JPEGLSLossless: parameters = &jpeg2000Lossless; break;
            case EXS_JPEG2000: case EXS_JPEGLSLossy: parameters = &jpeg2000; break;
            default: break;
        }
        HorosChooseDICOMRepresentation(copy, target, parameters, quality);
        if (!dataset->canWriteXfer(target)) return nil;
        copy.loadAllDataIntoMemory();
        unlink(path.fileSystemRepresentation);
        written = copy.saveFile(path.fileSystemRepresentation, target).good() ? YES : NO;
        return nil;
    });
    return written;
}

+ (NSString *)storageSOPClassOfFileAtPath:(NSString *)path
{
    NSString *sopClass = nil;
    IsiXDCMTKGuard(NULL, "DcmFileFormat::loadFileUntilTag", [&]() -> NSError * {
        char sopClassUID[128], sopInstanceUID[128];
        if (HorosFindSOPClassAndInstanceInFile(path.fileSystemRepresentation, sopClassUID, sizeof(sopClassUID),
                                               sopInstanceUID, sizeof(sopInstanceUID)) &&
            dcmIsaStorageSOPClassUID(sopClassUID))
            sopClass = IsiXDCMTKString(sopClassUID);
        return nil;
    });
    return sopClass;
}

- (DcmFileFormat *)fileFormat
{
    return _file.get();
}

@end

#pragma mark C-STORE

@interface IsiXDCMTKStoreResult ()
@property (readwrite, nullable) NSError *condition;
@property (readwrite) uint16_t status;
@property (readwrite, copy) NSString *statusText;
@property (readwrite) BOOL accepted;
@end

@implementation IsiXDCMTKStoreResult
- (instancetype)init
{
    if ((self = [super init])) _statusText = @"";
    return self;
}
@end

@implementation IsiXDCMTKAssociation (Store)

- (uint16_t)nextMessageID
{
    T_ASC_Association *association = IsiXDCMTKAssociationHandle(self);
    return association ? association->nextMsgID++ : 0;
}

- (IsiXDCMTKStoreResult *)storeFile:(IsiXDCMTKStoreFile *)file presentationContext:(uint8_t)identifier
                          messageID:(uint16_t)messageID
{
    IsiXDCMTKStoreResult *result = [[IsiXDCMTKStoreResult alloc] init];
    NSError *error = nil;
    IsiXDCMTKGuard(&error, "DIMSE_storeUser", [&]() -> NSError * {
        T_ASC_Association *association = IsiXDCMTKAssociationHandle(self);
        DcmFileFormat *format = [file fileFormat];
        if (!association || !format || !file.sopClassUID || !file.sopInstanceUID)
            return IsiXDCMTKErrorFromCondition(EC_IllegalParameter);
        T_DIMSE_C_StoreRQ request = {};
        T_DIMSE_C_StoreRSP response = {};
        request.MessageID = messageID;
        OFStandard::strlcpy(request.AffectedSOPClassUID, file.sopClassUID.UTF8String, sizeof(request.AffectedSOPClassUID));
        OFStandard::strlcpy(request.AffectedSOPInstanceUID, file.sopInstanceUID.UTF8String, sizeof(request.AffectedSOPInstanceUID));
        request.DataSetType = DIMSE_DATASET_PRESENT;
        request.Priority = DIMSE_PRIORITY_LOW;
        DcmDataset *statusDetail = NULL;
        const char *path = file.path.fileSystemRepresentation;
        OFCondition condition = DIMSE_storeUser(association, identifier, &request, NULL, format->getDataset(),
                                                NULL, NULL, DIMSE_NONBLOCKING, IsiXDCMTKAssociationDIMSETimeout(self),
                                                &response, &statusDetail, NULL, OFStandard::getFileSize(path));
        result.status = response.DimseStatus;
        result.statusText = IsiXDCMTKString(DU_cstoreStatusString(response.DimseStatus)) ?: @"";
        result.accepted = condition == EC_Normal &&
            (response.DimseStatus == STATUS_Success || DICOM_WARNING_STATUS(response.DimseStatus));
        if (condition == EC_Normal && !result.accepted)
            DIMSE_printCStoreRSP(stdout, &response);
        if (condition != EC_Normal) {
            fprintf(stderr, "%s: Store Failed, file: %s:\n", OFFIS_CONSOLE_APPLICATION, path);
            IsiXDCMTKStoreDumpCondition(condition);
        }
        if (statusDetail) {
            printf("  Status Detail:\n");
            statusDetail->print(COUT);
            delete statusDetail;
        }
        return IsiXDCMTKErrorFromCondition(condition);
    });
    result.condition = error;
    return result;
}

+ (void)configureForSendingVerbose:(BOOL)verbose deflateLevel:(NSInteger)level deflated:(BOOL)deflated
{
    IsiXDCMTKGuard(NULL, "OFLog::configure", [&]() -> NSError * {
        OFLog::configure(verbose ? OFLogger::DEBUG_LOG_LEVEL : OFLogger::WARN_LOG_LEVEL);
#ifdef WITH_ZLIB
        if (deflated) dcmZlibCompressionLevel.set((int)level);
#endif
        // enable-new-vr
        dcmEnableUnknownVRGeneration.set(OFTrue);
        dcmEnableUnlimitedTextVRGeneration.set(OFTrue);
        return nil;
    });
}

@end
