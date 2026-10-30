//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// What the import reads of a TIFF through the libtiff VTK builds with
// (vtk_tiff.h), and of the Olympus FluoView header such a TIFF may carry. Like
// every header of Adapters/VTK, this declares only Objective-C and C types:
// Swift reads it through the bridging header. Every call into the library runs
// inside a guard; a C++ exception that comes out of it (libtiff calls the error
// handler the process installed) is an NSError of IsiXVTKErrorDomain
// (IsiXVTKErrorCodeException), as a file libtiff does not open
// (IsiXVTKErrorCodeCannotOpen) or a TIFF without a FluoView header
// (IsiXVTKErrorCodeNoFluoViewHeader) are; NSFilePathErrorKey holds the path.

#import <Foundation/Foundation.h>
#import "IsiXVTKError.h"

NS_ASSUME_NONNULL_BEGIN

/// The directories (pages) of a TIFF, and the largest width and height among them.
@interface IsiXVTKTIFFPages : NSObject
@property (readonly) NSInteger count;
@property (readonly) NSInteger width;
@property (readonly) NSInteger height;
@end

/// One dimension of a FluoView MM header: its name, as a C string, the name's
/// first byte, its size, origin and resolution.
@interface IsiXVTKFluoViewDimension : NSObject
@property (readonly, copy) NSString *name;
@property (readonly) char initial;
@property (readonly) NSUInteger size;
@property (readonly) double origin;
@property (readonly) double resolution;
@end

/// The FluoView MM header of a TIFF's first directory: its ten dimensions, and
/// that directory's width and height.
@interface IsiXVTKFluoViewHeader : NSObject
@property (readonly, copy) NSArray<IsiXVTKFluoViewDimension *> *dimensions;
@property (readonly) NSInteger width;
@property (readonly) NSInteger height;
@end

@interface IsiXVTKTIFF : NSObject

/// Registers the FluoView tags with libtiff. The application calls it once at
/// launch, before any TIFF is read; later calls do nothing.
+ (void)registerFluoViewTags;

/// Whether libtiff opens the file at `path`.
+ (BOOL)opensFileAtPath:(NSString *)path;

/// The pages of the TIFF at `path`: each directory counted, the width and
/// height read from each (a directory without them keeps the previous one's).
+ (nullable IsiXVTKTIFFPages *)pagesOfFileAtPath:(NSString *)path error:(NSError **)error;

/// Whether the first directory of the TIFF at `path` has a FluoView MM header.
+ (BOOL)hasFluoViewHeaderAtPath:(NSString *)path;

/// The FluoView MM header of the TIFF at `path`.
+ (nullable IsiXVTKFluoViewHeader *)fluoViewHeaderOfFileAtPath:(NSString *)path error:(NSError **)error;

/// The image description of the TIFF at `path` as an XML document, one node
/// per [Name] ... [Name End] block: an empty document when it has none, nil
/// when a C++ exception came out of the library.
+ (nullable NSXMLDocument *)fluoViewXMLOfFileAtPath:(NSString *)path;

@end

#pragma mark libtiff for Swift

// TIFFGetField is variadic, which Swift cannot call, and the libtiff headers do
// not import into Swift: DCMPix's TIFF reading goes through these, typed for
// Swift, with nothing decided here.

/// TIFFOpen(path, "r"); NULL when the file cannot be opened as a TIFF.
FOUNDATION_EXPORT void * _Nullable HorosTIFFOpen(NSString *path);
FOUNDATION_EXPORT void HorosTIFFClose(void *tif);
FOUNDATION_EXPORT int HorosTIFFReadDirectory(void *tif);
/// TIFFGetField of a 16-bit field; `value` is left as it is when the field is not there.
FOUNDATION_EXPORT int HorosTIFFGetUInt16(void *tif, uint32_t tag, uint16_t *value);
/// TIFFGetField of a 32-bit field; `value` is left as it is when the field is not there.
FOUNDATION_EXPORT int HorosTIFFGetUInt32(void *tif, uint32_t tag, uint32_t *value);
FOUNDATION_EXPORT long HorosTIFFScanlineSize(void *tif);
FOUNDATION_EXPORT int HorosTIFFReadScanline(void *tif, void *buffer, uint32_t row);
FOUNDATION_EXPORT int HorosTIFFReadRGBAImage(void *tif, uint32_t width, uint32_t height, uint32_t *raster);
FOUNDATION_EXPORT void * _Nullable HorosTIFFMalloc(long size);
FOUNDATION_EXPORT void HorosTIFFFree(void *buffer);

FOUNDATION_EXPORT const uint32_t HorosTIFFTagImageWidth, HorosTIFFTagImageLength, HorosTIFFTagBitsPerSample,
    HorosTIFFTagSamplesPerPixel, HorosTIFFTagDataType, HorosTIFFTagPlanarConfig, HorosTIFFTagSampleFormat;
FOUNDATION_EXPORT const uint16_t HorosTIFFPlanarConfigSeparate, HorosTIFFSampleFormatIEEEFloat, HorosTIFFSampleFormatSignedInteger,
    HorosTIFFDataTypeSignedShort, HorosTIFFDataTypeSignedLong;

NS_ASSUME_NONNULL_END
