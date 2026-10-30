//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import <Foundation/Foundation.h>
#import "IsiXDCMTKQueryRetrieveSCU.h"

NS_ASSUME_NONNULL_BEGIN

/// What DCMTK knows of a transfer syntax.
@interface IsiXDCMTKTransferSyntax : NSObject
/// The transfer syntax named by `uid`; DCMTK's unknown one for any other.
- (instancetype)initWithUID:(NSString *)uid;
/// The transfer syntax DCMTK numbers `value` (an E_TransferSyntax, as the
/// listener's preferences store it).
- (instancetype)initWithDCMTKValue:(NSInteger)value NS_SWIFT_NAME(init(dcmtkValue:));
- (instancetype)init NS_UNAVAILABLE;
/// "" for one DCMTK does not know.
@property (readonly, copy) NSString *uid;
@property (readonly) BOOL known;
@property (readonly) BOOL usesNativeFormat;
@property (readonly) BOOL usesEncapsulatedFormat;
@property (readonly) BOOL pixelDataCompressed;
@end

/// DCMTK's names and lists for the UIDs a send reports.
@interface IsiXDCMTKUIDs : NSObject
/// dcmFindNameOfUID: nil for a UID DCMTK does not name.
+ (nullable NSString *)nameOfUID:(NSString *)uid;
/// dcmSOPClassUIDToModality: nil for a class DCMTK gives no modality.
+ (nullable NSString *)modalityOfSOPClass:(NSString *)sopClass;
/// DCMTK's short list of storage SOP classes, which a send proposes after
/// those of its files when they leave room.
@property (class, readonly, copy) NSArray<NSString *> *shortStorageSOPClasses;
@end

/// A DICOM file loaded for a C-STORE (DcmFileFormat::loadFile: what follows
/// the attributes is read from the file as it is sent).
@interface IsiXDCMTKStoreFile : NSObject
/// nil and the condition when DCMTK cannot read it.
- (nullable instancetype)initWithPath:(NSString *)path error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (readonly, copy) NSString *path;
/// The SOP Class and Instance UIDs, of 64 characters at most (a truncated
/// UID is never taken for another); nil when either is missing.
@property (readonly, nullable, copy) NSString *sopClassUID;
@property (readonly, nullable, copy) NSString *sopInstanceUID;
/// The transfer syntax the dataset was read in.
@property (readonly) IsiXDCMTKTransferSyntax *transferSyntax;
/// Writes a copy of the file to `path` in `transferSyntax` (any pixel data
/// decoded or encoded through the codecs the application registered, with
/// `quality` as the encoders take it). This file is left as it was read. NO
/// when it cannot be encoded so or written.
- (BOOL)writeCopyToPath:(NSString *)path transferSyntax:(NSString *)transferSyntax quality:(int)quality;

/// The storage SOP class of the file at `path`, read up to its Pixel Data;
/// nil when it has no identity or the class is not a storage class.
+ (nullable NSString *)storageSOPClassOfFileAtPath:(NSString *)path NS_SWIFT_NAME(storageSOPClassOfFile(atPath:));
@end

/// How a C-STORE ended.
@interface IsiXDCMTKStoreResult : NSObject
/// The condition it ended on, nil for EC_Normal.
@property (readonly, nullable) NSError *condition;
/// The status of the response, when one came.
@property (readonly) uint16_t status;
/// DCMTK's name for the status.
@property (readonly, copy) NSString *statusText;
/// The peer took the instance: no condition, and a status of success or
/// warning.
@property (readonly) BOOL accepted;
@end

@interface IsiXDCMTKAssociation (Store)

/// The message ID of the next request, taken: a send takes one for each
/// file, sent or not.
- (uint16_t)nextMessageID NS_SWIFT_NAME(nextMessageID());

/// A C-STORE of `file` in the presentation context `identifier`, low
/// priority, waiting the association's DIMSE timeout for the response. A
/// response that refuses the instance and the response's status detail are
/// printed to the standard output, a failed transmission to the standard
/// error, as storescu prints them.
- (IsiXDCMTKStoreResult *)storeFile:(IsiXDCMTKStoreFile *)file presentationContext:(uint8_t)identifier
                          messageID:(uint16_t)messageID
    NS_SWIFT_NAME(store(_:presentationContext:messageID:));

/// Sets DCMTK's process-wide settings for a send: its log level, the zlib
/// level of a deflated syntax, and the VRs it may write (UN, UT). Each send
/// sets them, as storescu does.
+ (void)configureForSendingVerbose:(BOOL)verbose deflateLevel:(NSInteger)level deflated:(BOOL)deflated
    NS_SWIFT_NAME(configureForSending(verbose:deflateLevel:deflated:));

@end

NS_ASSUME_NONNULL_END
