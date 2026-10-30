//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// DICOMDIRs through DCMTK: the records of one that name a file, read through
// DcmDicomDir in one pass for the media scan, and one written for an export
// folder through DicomDirInterface. Objective-C and C types only, for the
// bridging header.

#import <Foundation/Foundation.h>
#import "IsiXDCMTKError.h"

NS_ASSUME_NONNULL_BEGIN

/// The icon image (0088,0200) of a record, as DCMTK read its single item.
@interface IsiXDCMTKDirectoryIcon : NSObject
@property (readonly) uint16_t bitsAllocated;
@property (readonly) uint16_t bitsStored;
@property (readonly) uint16_t rows;
@property (readonly) uint16_t columns;
/// Photometric Interpretation (0028,0004) as read; nil when absent.
@property (readonly, copy, nullable) NSString *photometricInterpretation;
/// Pixel Data (7FE0,0010) as bytes.
@property (readonly, copy) NSData *pixels;
@end

/// A record whose Referenced File ID (0004,1500) names a file, with the
/// elements of the records above it: a record's own element wins over an
/// ancestor's of the same tag.
@interface IsiXDCMTKDirectoryRecord : NSObject
/// Asked-for tag (group << 16 | element) → its value as DCMTK gives it as text
/// (getOFStringArray, up to the first NUL), or NSNull when the element is
/// there and DCMTK gives no text for it.
@property (readonly, copy) NSDictionary<NSNumber *, id> *values;
/// The icon, when the winning (0088,0200) is a sequence of exactly one item
/// whose Bits Allocated, Bits Stored, Rows, Columns and Pixel Data all read.
@property (readonly, nullable) IsiXDCMTKDirectoryIcon *icon;
@end

@interface IsiXDCMTKDicomDir : NSObject

- (instancetype)init NS_UNAVAILABLE;

/// The records that name a file, depth first, a record before those under it.
/// `tags` lists the tags whose values are read. Empty when DCMTK reads no
/// records; nil, with an error, only when the reading throws.
+ (nullable NSArray<IsiXDCMTKDirectoryRecord *> *)fileRecordsOfDicomDirAtPath:(NSString *)path
                                                                        tags:(NSArray<NSNumber *> *)tags
                                                                       error:(NSError **)error
    NS_SWIFT_NAME(fileRecords(ofDicomDirAtPath:tags:));

/// Reads the DICOMDIR at `path` and walks its root record, the text of every
/// tenth element read: the validation before importing, which the Decompress
/// service runs so that a DICOMDIR that brings DCMTK down ends the service.
/// A file DCMTK cannot open or parse still reads to the end, as before; NO,
/// with an error, only when the reading throws.
+ (BOOL)readRootRecordOfDicomDirAtPath:(NSString *)path error:(NSError **)error
    NS_SWIFT_NAME(readRootRecord(ofDicomDirAtPath:));

/// The files under `folder`, relative to it with slashes, in the order DCMTK's
/// recursive search lists them (dcmmkdir +r +id): every file, hidden ones
/// included. Nil, with an error, only when the search throws.
+ (nullable NSArray<NSString *> *)relativePathsOfFilesInFolder:(NSString *)folder error:(NSError **)error
    NS_SWIFT_NAME(relativePathsOfFiles(inFolder:));

/// Writes at `path` a DICOMDIR of the files at `relativePaths` under `folder`,
/// as an export burns it: the general purpose USB and flash profile with
/// JPEG, invented values where a file lacks a required one, no consistency
/// or transfer syntax check, the default file-set ID and descriptor
/// character set, explicit lengths without group lengths. Each series record
/// then gets the icon of its middle image (128 pixels), and the file is
/// made readable by all (0755). The error's description is what failed, as
/// "Couldn't add <file> to DICOMDIR: <condition>"; a C++ exception gives its
/// text as IsiXDCMTKConditionTextKey.
+ (BOOL)writeDicomDirAtPath:(NSString *)path folder:(NSString *)folder
              relativePaths:(NSArray<NSString *> *)relativePaths error:(NSError **)error
    NS_SWIFT_NAME(writeDicomDir(atPath:folder:relativePaths:));

@end


NS_ASSUME_NONNULL_END
