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

#import "DCMPix+NonDICOMCAPI.h"
#import "IsiXVTKTIFF.h"
#define uint64 tiff_uint64
#include "nifti1.h"
#include "nifti1_io.h"

void HorosTIFFInitialize(void) { [IsiXVTKTIFF registerFluoViewTags]; }

NSXMLDocument *HorosXMLFromFVTiff(NSString *path) { return [[IsiXVTKTIFF fluoViewXMLOfFileAtPath:path] retain]; }

BOOL HorosFVTiffDimensions(NSString *path, HorosFVDimension *dimensions)
{
    IsiXVTKFluoViewHeader *header = [IsiXVTKTIFF fluoViewHeaderOfFileAtPath:path error:NULL];
    if (header == nil)
        return NO;
    NSUInteger i = 0;
    for (IsiXVTKFluoViewDimension *dimension in header.dimensions)
    {
        dimensions[i].name = dimension.initial;
        dimensions[i].size = (unsigned int) dimension.size;
        dimensions[i].origin = dimension.origin;
        dimensions[i].resolution = dimension.resolution;
        i++;
    }
    return YES;
}

BOOL HorosNIfTIReadHeader(NSString *path, HorosNIfTIHeader *header)
{
    nifti_1_header *read = nifti_read_header(path.UTF8String, NULL, 0);
    if (read == NULL)
        return NO;
    memcpy(header->magic, read->magic, 4);
    memcpy(header->dim, read->dim, sizeof(header->dim));
    memcpy(header->pixdim, read->pixdim, sizeof(header->pixdim));
    header->datatype = read->datatype;
    header->qformCode = read->qform_code;
    header->sformCode = read->sform_code;
    header->voxOffset = read->vox_offset;
    int swapSize = 0;
    header->bytesPerVoxel = 0;
    nifti_datatype_sizes(read->datatype, &header->bytesPerVoxel, &swapSize);
    free(read);
    return YES;
}

void *HorosNIfTIImageRead(NSString *path) { return nifti_image_read(path.UTF8String, 0); }
void HorosNIfTIImageFree(void *image) { nifti_image_free((nifti_image*) image); }

NSString *HorosNIfTIDataFile(void *image, unsigned long long *offset, unsigned long long *voxels, int *bytesPerVoxel)
{
    nifti_image *nim = (nifti_image*) image;
    *offset = nim->iname_offset > 0 ? (unsigned long long) nim->iname_offset : 0;
    *voxels = (unsigned long long) nim->nvox;
    *bytesPerVoxel = nim->nbyper;
    return nim->iname ? [[NSFileManager defaultManager] stringWithFileSystemRepresentation: nim->iname length: strlen(nim->iname)] : nil;
}

int HorosNIfTIReadSlice(void *image, int frame, void **voxels)
{
    int slice[8] = { 0, -1, -1, frame, 0, 0, 0, 0 };
    *voxels = NULL;
    return nifti_read_collapsed_image((nifti_image*) image, slice, voxels);
}

char *HorosNIfTIImageASCII(void *image) { return nifti_image_to_ascii((nifti_image*) image); }

int HorosNIfTIExtensionCount(void *image)
{
    nifti_image *nim = (nifti_image*) image;
    return nim->num_ext > 0 && nim->ext_list != NULL ? nim->num_ext : 0;
}

void HorosNIfTIExtension(void *image, int index, int *code, const char **data, int *length)
{
    nifti1_extension *extension = ((nifti_image*) image)->ext_list + index;
    *code = extension->ecode;
    *data = extension->edata;
    *length = extension->edata ? extension->esize - 8 : 0;
}

void HorosNIfTIOrientation(void *image, short qformCode, short sformCode, int *i, int *j, int *k)
{
    nifti_image *nim = (nifti_image*) image;
    if (qformCode > 0)
        nifti_mat44_to_orientation(nim->qto_xyz, i, j, k);
    else if (sformCode > 0)
        nifti_mat44_to_orientation(nim->sto_xyz, i, j, k);
}
