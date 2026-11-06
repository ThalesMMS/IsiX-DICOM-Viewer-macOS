//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The calls into VTK's libtiff the import makes, each inside a guard that turns
// a C++ exception into an NSError. The FluoView tags are registered with libtiff
// once at launch (registerFluoViewTags); the MM header is read with
// FV_Read_MM_HEAD (IsiXVTKFluoView.mm).

#import "IsiXVTKTIFF.h"
#include "IsiXVTKFluoView.hpp"
#include "IsiXVTKInternal.hpp"
#include <exception>
#include <utility>

@interface IsiXVTKTIFFPages ()
@property (readwrite) NSInteger count, width, height;
@end
@implementation IsiXVTKTIFFPages
@end

@interface IsiXVTKFluoViewDimension ()
@property (readwrite, copy) NSString *name;
@property (readwrite) char initial;
@property (readwrite) NSUInteger size;
@property (readwrite) double origin;
@property (readwrite) double resolution;
@end
@implementation IsiXVTKFluoViewDimension
@end

@interface IsiXVTKFluoViewHeader ()
@property (readwrite, copy) NSArray<IsiXVTKFluoViewDimension *> *dimensions;
@property (readwrite) NSInteger width, height;
@end
@implementation IsiXVTKFluoViewHeader
@end

/// `error` with the file's path.
static NSError *IsiXVTKTIFFAtPath(NSError *error, NSString *path)
{
    if (!path) return error;
    NSMutableDictionary *info = [error.userInfo mutableCopy];
    info[NSFilePathErrorKey] = path;
    return [NSError errorWithDomain:error.domain code:error.code userInfo:info];
}

static NSError *IsiXVTKTIFFError(IsiXVTKErrorCode code, NSString *description, NSString *path, const char *operation)
{
    return IsiXVTKTIFFAtPath(IsiXVTKFailure(code, description, operation), path);
}

/// Runs `body`, which returns the call's error (nil when it succeeded), and
/// turns a C++ exception into an error. Whether the call succeeded.
template <typename Body>
static BOOL IsiXVTKTIFFGuard(NSString *path, NSError * __autoreleasing *error, const char *operation, Body &&body)
{
    NSError *failure = nil;
    try {
        failure = std::forward<Body>(body)();
    } catch (const std::exception &exception) {
        failure = IsiXVTKTIFFAtPath(IsiXVTKErrorFromException(exception.what(), operation), path);
    } catch (...) {
        failure = IsiXVTKTIFFAtPath(IsiXVTKErrorFromException("unknown exception", operation), path);
    }
    if (failure && error) *error = failure;
    return failure == nil;
}

/// TIFFOpen(path, "r") and TIFFClose around `body`, which reads the open file.
template <typename Body>
static NSError *IsiXVTKTIFFWithFile(NSString *path, const char *operation, Body &&body)
{
    TIFF *tif = TIFFOpen(path.UTF8String, "r");
    if (!tif)
        return IsiXVTKTIFFError(IsiXVTKErrorCodeCannotOpen, @"libtiff does not open the file", path, operation);
    NSError *failure = nil;
    try {
        failure = std::forward<Body>(body)(tif);
    } catch (...) {
        TIFFClose(tif);
        throw;
    }
    TIFFClose(tif);
    return failure;
}

@implementation IsiXVTKTIFF

+ (void)registerFluoViewTags
{
    IsiXVTKTIFFGuard(nil, NULL, "registerFluoViewTags", [&]() -> NSError * {
        IsiXVTKRegisterFluoViewTags();
        return nil;
    });
}

+ (BOOL)opensFileAtPath:(NSString *)path
{
    return IsiXVTKTIFFGuard(path, NULL, "opensFileAtPath", [&]() -> NSError * {
        return IsiXVTKTIFFWithFile(path, "opensFileAtPath", [](TIFF *) -> NSError * { return nil; });
    });
}

+ (IsiXVTKTIFFPages *)pagesOfFileAtPath:(NSString *)path error:(NSError **)error
{
    IsiXVTKTIFFPages *pages = [[IsiXVTKTIFFPages alloc] init];
    BOOL read = IsiXVTKTIFFGuard(path, error, "pagesOfFileAtPath", [&]() -> NSError * {
        return IsiXVTKTIFFWithFile(path, "pagesOfFileAtPath", [&](TIFF *tif) -> NSError * {
            // The fields are read into ints, as the import always read them;
            // a directory without one keeps the previous directory's.
            int w = 0, h = 0;
            NSInteger count = 0, width = 0, height = 0;
            do {
                TIFFGetField(tif, TIFFTAG_IMAGEWIDTH, &w);
                TIFFGetField(tif, TIFFTAG_IMAGELENGTH, &h);
                if (w > width) width = w;
                if (h > height) height = h;
                count++;
            } while (TIFFReadDirectory(tif));
            pages.count = count;
            pages.width = width;
            pages.height = height;
            return nil;
        });
    });
    return read ? pages : nil;
}

/// The MM header of the open file's current directory into `head`, whether it has one.
static BOOL IsiXVTKReadFluoViewHeader(TIFF *tif, FV_MM_HEAD *head)
{
    short size = 0;
    char *data = 0;
    if (!TIFFGetField(tif, TIFFTAG_FV_MMHEADER, &size, &data))
        return NO;
    if (head)
        FV_Read_MM_HEAD(data, head);
    return YES;
}

+ (BOOL)hasFluoViewHeaderAtPath:(NSString *)path
{
    return IsiXVTKTIFFGuard(path, NULL, "hasFluoViewHeaderAtPath", [&]() -> NSError * {
        return IsiXVTKTIFFWithFile(path, "hasFluoViewHeaderAtPath", [&](TIFF *tif) -> NSError * {
            return IsiXVTKReadFluoViewHeader(tif, NULL) ? nil
                : IsiXVTKTIFFError(IsiXVTKErrorCodeNoFluoViewHeader, @"the TIFF has no FluoView header", path,
                                   "hasFluoViewHeaderAtPath");
        });
    });
}

+ (IsiXVTKFluoViewHeader *)fluoViewHeaderOfFileAtPath:(NSString *)path error:(NSError **)error
{
    IsiXVTKFluoViewHeader *header = [[IsiXVTKFluoViewHeader alloc] init];
    BOOL read = IsiXVTKTIFFGuard(path, error, "fluoViewHeaderOfFileAtPath", [&]() -> NSError * {
        return IsiXVTKTIFFWithFile(path, "fluoViewHeaderOfFileAtPath", [&](TIFF *tif) -> NSError * {
            FV_MM_HEAD head;
            if (!IsiXVTKReadFluoViewHeader(tif, &head))
                return IsiXVTKTIFFError(IsiXVTKErrorCodeNoFluoViewHeader, @"the TIFF has no FluoView header", path,
                                        "fluoViewHeaderOfFileAtPath");
            NSMutableArray *dimensions = [NSMutableArray arrayWithCapacity:FV_SPATIAL_DIMENSION];
            for (int i = 0; i < FV_SPATIAL_DIMENSION; i++) {
                IsiXVTKFluoViewDimension *dimension = [[IsiXVTKFluoViewDimension alloc] init];
                // The name as the series descriptions always wrote it, with %s.
                dimension.name = [NSString stringWithFormat:@"%s", head.DimInfo[i].Name];
                dimension.initial = head.DimInfo[i].Name[0];
                dimension.size = head.DimInfo[i].Size;
                dimension.origin = head.DimInfo[i].Origin;
                dimension.resolution = head.DimInfo[i].Resolution;
                [dimensions addObject:dimension];
            }
            int w = 0, h = 0;
            TIFFGetField(tif, TIFFTAG_IMAGEWIDTH, &w);
            TIFFGetField(tif, TIFFTAG_IMAGELENGTH, &h);
            header.dimensions = dimensions;
            header.width = w;
            header.height = h;
            return nil;
        });
    });
    return read ? header : nil;
}

+ (NSXMLDocument *)fluoViewXMLOfFileAtPath:(NSString *)path
{
    NSXMLDocument *document = nil;
    IsiXVTKTIFFGuard(path, NULL, "fluoViewXMLOfFileAtPath", [&]() -> NSError * {
        document = IsiXVTKFluoViewXML(path);
        return nil;
    });
    return document;
}

@end

#pragma mark - libtiff for Swift

extern "C" {

const uint32_t HorosTIFFTagImageWidth = TIFFTAG_IMAGEWIDTH, HorosTIFFTagImageLength = TIFFTAG_IMAGELENGTH,
    HorosTIFFTagBitsPerSample = TIFFTAG_BITSPERSAMPLE, HorosTIFFTagSamplesPerPixel = TIFFTAG_SAMPLESPERPIXEL,
    HorosTIFFTagDataType = TIFFTAG_DATATYPE, HorosTIFFTagPlanarConfig = TIFFTAG_PLANARCONFIG,
    HorosTIFFTagSampleFormat = TIFFTAG_SAMPLEFORMAT;
const uint16_t HorosTIFFPlanarConfigSeparate = PLANARCONFIG_SEPARATE, HorosTIFFSampleFormatIEEEFloat = SAMPLEFORMAT_IEEEFP,
    HorosTIFFSampleFormatSignedInteger = SAMPLEFORMAT_INT,
    HorosTIFFDataTypeSignedShort = TIFF_SSHORT, HorosTIFFDataTypeSignedLong = TIFF_SLONG;

void *HorosTIFFOpen(NSString *path) { return TIFFOpen(path.UTF8String, "r"); }
void HorosTIFFClose(void *tif) { TIFFClose((TIFF*) tif); }
int HorosTIFFReadDirectory(void *tif) { return TIFFReadDirectory((TIFF*) tif); }
int HorosTIFFGetUInt16(void *tif, uint32_t tag, uint16_t *value) { return TIFFGetField((TIFF*) tif, tag, value); }
int HorosTIFFGetUInt32(void *tif, uint32_t tag, uint32_t *value) { return TIFFGetField((TIFF*) tif, tag, value); }
long HorosTIFFScanlineSize(void *tif) { return TIFFScanlineSize((TIFF*) tif); }
int HorosTIFFReadScanline(void *tif, void *buffer, uint32_t row) { return TIFFReadScanline((TIFF*) tif, buffer, row, 0); }
int HorosTIFFReadRGBAImage(void *tif, uint32_t width, uint32_t height, uint32_t *raster)
{
    return TIFFReadRGBAImage((TIFF*) tif, width, height, raster, 0);
}
void *HorosTIFFMalloc(long size) { return _TIFFmalloc(size); }
void HorosTIFFFree(void *buffer) { _TIFFfree(buffer); }

}
