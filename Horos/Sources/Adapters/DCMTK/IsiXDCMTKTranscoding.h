//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// What the browser and the database ask DCMTK about the encoding of a DICOM
// file: the name of a UID, whether a file's pixels are compressed and what
// decides whether compressing it is worth it, and a copy of a file in another
// transfer syntax for the web portal. Objective-C and C types only, for the
// bridging header.

#import <Foundation/Foundation.h>
#import "IsiXDCMTKError.h"

NS_ASSUME_NONNULL_BEGIN

/// What +compressionFactsOfFileAtPath: read from a file DCMTK loaded.
@interface IsiXDCMTKCompressionFacts : NSObject
/// The transfer syntax it was read in encapsulates compressed pixel data.
@property (readonly) BOOL pixelDataCompressed;
/// Modality (0008,0060) as ASCII; "OT" when absent, nil when it is not ASCII.
@property (readonly, copy, nullable) NSString *modality;
/// SOP Class UID (0008,0016) as ASCII; "" when absent, nil when it is not ASCII.
@property (readonly, copy, nullable) NSString *SOPClassUID;
/// Rows (0028,0010) and Columns (0028,0011), nil when absent.
@property (readonly, nullable) NSNumber *rows;
@property (readonly, nullable) NSNumber *columns;
@end

/// How +transcodeFileAtPath:... ended.
typedef NS_ENUM(NSInteger, IsiXDCMTKTranscodeOutcome) {
    /// DCMTK could not load the file.
    IsiXDCMTKTranscodeOutcomeUnreadable = 0,
    /// The file already serves the requested syntax; nothing was written.
    IsiXDCMTKTranscodeOutcomeServesOriginal,
    /// The copy was written at the destination.
    IsiXDCMTKTranscodeOutcomeWritten,
    /// The pixels could not take the syntax; nothing was written.
    IsiXDCMTKTranscodeOutcomeCannotWrite,
    /// The pixels took it, and saving the copy failed.
    IsiXDCMTKTranscodeOutcomeSaveFailed,
};

/// How +convertFileAtPath:... ended.
typedef NS_ENUM(NSInteger, IsiXDCMTKConversionOutcome) {
    /// DCMTK could not load the file; nothing was written.
    IsiXDCMTKConversionOutcomeUnreadable = 0,
    /// The chooser kept the file as it is; nothing was written.
    IsiXDCMTKConversionOutcomeUnchanged,
    /// The converted file was written at the destination.
    IsiXDCMTKConversionOutcomeWritten,
    /// The pixels could not take the syntax; nothing was written.
    IsiXDCMTKConversionOutcomeCannotWrite,
    /// The pixels took it, and saving the file failed.
    IsiXDCMTKConversionOutcomeSaveFailed,
};

/// Chooses the transfer syntax a file is converted to from what it says and
/// the syntax it was read in: nil keeps it as it is. `quality` is
/// DCM_CompressionQuality (0 lossless) for JPEG 2000 and JPEG-LS.
typedef NSString * _Nullable (^IsiXDCMTKConversionChooser)(IsiXDCMTKCompressionFacts *facts, NSString *originalSyntax,
                                                           int *quality);

@interface IsiXDCMTKTranscoding : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// The name DCMTK's UID table gives a UID, nil when it has none.
+ (nullable NSString *)nameOfUID:(NSString *)uid;

/// Loads the file and reads what decides whether it is worth compressing.
/// nil, with DCMTK's condition, when it does not load.
+ (nullable IsiXDCMTKCompressionFacts *)compressionFactsOfFileAtPath:(NSString *)path error:(NSError **)error
    NS_SWIFT_NAME(compressionFacts(ofFileAtPath:));

/// Loads the file and, unless `servesOriginal` says its own transfer syntax
/// (first argument) already serves the requested one (second), writes a copy
/// in `transferSyntax` at `destination`. `quality` is DCM_CompressionQuality
/// (0 lossless) for JPEG 2000 and JPEG-LS.
+ (IsiXDCMTKTranscodeOutcome)transcodeFileAtPath:(NSString *)path
                                toTransferSyntax:(NSString *)transferSyntax
                                         quality:(int)quality
                                     destination:(NSString *)destination
                                  servesOriginal:(NS_NOESCAPE BOOL (^)(NSString *original, NSString *requested))servesOriginal
                                           error:(NSError **)error
    NS_SWIFT_NAME(transcodeFile(atPath:toTransferSyntax:quality:destination:servesOriginal:error:));

/// The Decompress service's conversion of one file. Loads the file at `path`
/// (a deflated one is inflated into `workingFolder`), drops the GEIIS private
/// element (0009,1110), whose pixel data is always JPEG, asks `choose` for the
/// transfer syntax and writes the file in it at `destination`, which is opened
/// once and written in order. Lossless JPEG is process 14 with first-order
/// prediction. A C++ exception after the file loaded ends as SaveFailed.
+ (IsiXDCMTKConversionOutcome)convertFileAtPath:(NSString *)path
                                  workingFolder:(NSString *)workingFolder
                                    destination:(NSString *)destination
                                       choosing:(NS_NOESCAPE IsiXDCMTKConversionChooser)choose
                                          error:(NSError **)error
    NS_SWIFT_NAME(convertFile(atPath:workingFolder:destination:choosing:error:));

@end

NS_ASSUME_NONNULL_END
