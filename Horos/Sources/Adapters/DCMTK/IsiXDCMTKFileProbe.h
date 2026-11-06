//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Whether a file is DICOM, as the import decides it before reading it: DCMTK
// reads the file meta information and walks the dataset's headers with every
// value deferred (HorosDICOMProbe.h), so neither pixels nor a lying length
// are materialized. Objective-C and C types only, for the bridging header.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What the probe found. The import asks for it at every incoming file, so it
/// is a plain structure, made without allocating.
typedef struct {
    /// A DICOM object: it has a SOP Class or a Series Instance UID.
    bool recognized;
    /// Its transfer syntax is one the application and the helper decode.
    bool compressed;
    /// It has Pixel Data at its root.
    bool image;
    /// Its dataset reads whole and its pixels may be transcoded.
    bool mayTranscode;
    /// Not recognized, but its file meta information names a valid transfer
    /// syntax outside the DICOM root (1.2.840.10008.): a private wrapping the
    /// application may still read.
    bool privateTransferSyntax;
} IsiXDCMTKFileProbeResult;

@interface IsiXDCMTKFileProbe : NSObject

/// Probes the file at `path`. A nil or empty path, or one with no file system
/// representation, is refused before DCMTK sees it. When `error` is given, a
/// file that is not recognized gives an error of IsiXDCMTKErrorDomain
/// (IsiXDCMTKErrorCodeFailure) with what DCMTK said of it, and a C++ exception
/// one with IsiXDCMTKErrorCodeException.
+ (IsiXDCMTKFileProbeResult)inspectFileAtPath:(nullable NSString *)path error:(NSError **)error;

/// The same, without the error.
+ (IsiXDCMTKFileProbeResult)inspectFileAtPath:(nullable NSString *)path;

@end

NS_ASSUME_NONNULL_END
