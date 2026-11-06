/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

// What DCMPix+NonDICOM.swift cannot call itself: libtiff's TIFFGetField is
// variadic, and the FluoView and NIfTI-1 headers do not import into Swift. The
// libraries stay in C; these functions are their calls, typed for Swift, with
// nothing decided here. This header is for the bridging header only.

#import "DCMPix.h"
#import "IsiXVTKTIFF.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark libtiff

/// +[IsiXVTKTIFF registerFluoViewTags]: registers the FluoView tags with libtiff. The application
/// calls it once at launch, before any TIFF is read.
FOUNDATION_EXPORT void HorosTIFFInitialize(void);

/// +[IsiXVTKTIFF fluoViewXMLOfFileAtPath:]: the FluoView description of the TIFF at `path` as an XML
/// document, for the XML window.
FOUNDATION_EXPORT NSXMLDocument * _Nullable HorosXMLFromFVTiff(NSString * _Nullable path) NS_RETURNS_RETAINED;

// The libtiff calls themselves (HorosTIFFOpen and the rest) are the TIFF
// adapter's: IsiXVTKTIFF.h.

#pragma mark FluoView

/// One dimension of a FluoView MM header: the first letter of its name, its size,
/// origin and resolution, as FV_Read_MM_HEAD reads them.
typedef struct
{
    char name;
    unsigned int size;
    double origin;
    double resolution;
} HorosFVDimension;

/// Reads the MM header of the TIFF at `path` into `dimensions` (ten of them):
/// whether the file has one.
FOUNDATION_EXPORT BOOL HorosFVTiffDimensions(NSString *path, HorosFVDimension *dimensions);

#pragma mark NIfTI-1

/// What the reading uses of a NIfTI-1 (or Analyze) header.
typedef struct
{
    char magic[4];
    short dim[8];
    float pixdim[8];
    short datatype;
    short qformCode, sformCode;
    /// vox_offset, and the bytes of one voxel of the datatype (nifti_datatype_sizes; 0 for none).
    float voxOffset;
    int bytesPerVoxel;
} HorosNIfTIHeader;

/// nifti_read_header: whether the header at `path` could be read.
FOUNDATION_EXPORT BOOL HorosNIfTIReadHeader(NSString *path, HorosNIfTIHeader *header);
/// nifti_image_read without the data; NULL when it cannot.
FOUNDATION_EXPORT void * _Nullable HorosNIfTIImageRead(NSString *path);
FOUNDATION_EXPORT void HorosNIfTIImageFree(void *image);
/// The data file of the image, where its voxels start, how many and their size.
FOUNDATION_EXPORT NSString * _Nullable HorosNIfTIDataFile(void *image, unsigned long long *offset,
                                                          unsigned long long *voxels, int *bytesPerVoxel);
/// nifti_read_collapsed_image of slice `frame` of the first volume: its bytes
/// (malloc'd, freed by the caller), and the count nifti answered.
FOUNDATION_EXPORT int HorosNIfTIReadSlice(void *image, int frame, void * _Nullable * _Nonnull voxels);
/// nifti_image_to_ascii: the header as text, malloc'd and freed by the caller; NULL when it cannot.
FOUNDATION_EXPORT char * _Nullable HorosNIfTIImageASCII(void *image);
/// The number of extensions of the image (num_ext, 0 without a list).
FOUNDATION_EXPORT int HorosNIfTIExtensionCount(void *image);
/// Extension `index`: its code, its bytes and their length, esize - 8 (not
/// NUL-terminated; 0 or less when it has none).
FOUNDATION_EXPORT void HorosNIfTIExtension(void *image, int index, int *code, const char * _Nullable * _Nonnull data, int *length);
/// nifti_mat44_to_orientation of the qform (code > 0), else of the sform (code > 0); untouched otherwise.
FOUNDATION_EXPORT void HorosNIfTIOrientation(void *image, short qformCode, short sformCode, int *i, int *j, int *k);

NS_ASSUME_NONNULL_END
