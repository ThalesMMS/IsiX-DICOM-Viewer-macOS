//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import "IsiXDCMTKFileProbe.h"
#include "IsiXDCMTKInternal.hpp"
#include "HorosDICOMProbe.h"

@implementation IsiXDCMTKFileProbe

+ (IsiXDCMTKFileProbeResult)inspectFileAtPath:(NSString *)path
{
    return [self inspectFileAtPath:path error:NULL];
}

+ (IsiXDCMTKFileProbeResult)inspectFileAtPath:(NSString *)path error:(NSError **)error
{
    IsiXDCMTKFileProbeResult result = {};
    // Every crash report once gathered here ended in strlen: a nil path, or a
    // name -UTF8String cannot encode, handed to std::string as NULL. A path that
    // cannot be used is not DICOM, and does not reach the parser.
    const char *fileSystemPath = NULL;
    @try { fileSystemPath = [path fileSystemRepresentation]; }
    @catch (NSException *exception) { fileSystemPath = NULL; }
    if (!fileSystemPath || !*fileSystemPath) {
        if (error) *error = IsiXDCMTKFailure(@"the path has no file system representation");
        return result;
    }

    IsiXDCMTKGuard(error, "HorosDICOMProbe::inspect", [&]() -> NSError * {
        const HorosDICOMProbe::Result probe = HorosDICOMProbe::inspect(fileSystemPath);
        result.recognized = probe.recognized;
        result.compressed = probe.compressed;
        result.image = probe.image;
        result.mayTranscode = probe.mayTranscode;
        // Only a bounded, valid private UID can need the wrapped-image
        // fallback. A malformed envelope must not reach another value reader.
        result.privateTransferSyntax = !probe.recognized && !probe.transferSyntax.empty() &&
            probe.transferSyntax.find("1.2.840.10008.") != 0;
        if (probe.recognized || !error)
            return nil;
        return IsiXDCMTKFailure([NSString stringWithFormat:@"not a DICOM file: %s", probe.diagnostic.c_str()]);
    });
    return result;
}

@end
