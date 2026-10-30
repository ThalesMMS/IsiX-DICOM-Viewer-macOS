/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)

 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.

 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.

 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.

 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html

 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL

  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
// DICOMExport of the legacy plugin SDK, kept by IsiXLegacyBridge: an image
// written as a DICOM file of a derived series by the application, through
// the plugin API (IsiXDatabase.writeDerivedSeries). Grayscale pixels are
// written as signed 16-bit samples with a Rescale Slope (exact for whole
// values from -32768 to 32767), colour pixels as RGB; the patient and the
// study are those of the source file, which must be a file of the database
// (-[DCMPix sourceFile], -[DicomImage completePath]). Without a path the
// file goes to the kit's folder, to be added with -[BrowserController
// addFiles:...] or -[DicomDatabase addFilesAtPaths:].

#import "IsiXLegacyBridgeDefines.h"

ISIX_LEGACY_CLASS(DICOMExport)
@interface IsiXLegacyDICOMExport : NSObject

@property(readonly) NSMutableDictionary* metaDataDict;
@property BOOL rotateRawDataBy90degrees;

- (void) setSourceFile: (NSString*) isource;
/// 8, 16 or 32 bits per sample, one sample per pixel (32 bits are Float32
/// values), or 8 bits with 3 or 4 samples per pixel for colour.
- (long) setPixelData: (unsigned char*) idata samplesPerPixel: (int) ispp bitsPerSample: (int) ibps width: (long) iwidth height: (long) iheight;
- (long) setPixelData: (unsigned char*) deprecated samplePerPixel: (long) deprecated bitsPerPixel: (long) deprecated width: (long) deprecated height: (long) deprecated;
- (void) setSigned: (BOOL) s;
- (void) setOffset: (int) o;
- (long) setPixelNSImage: (NSImage*) iimage;
- (NSString*) writeDCMFile: (NSString*) dstPath;
- (void) setModalityAsSource: (BOOL) v;
- (NSString*) seriesDescription;
- (void) setSeriesDescription: (NSString*) desc;
- (void) setSeriesNumber: (long) no;
- (void) beginSeriesWithNumber: (long) no;
- (void) setDefaultWWWL: (long) ww :(long) wl;
- (void) setSlope: (float) s;
- (void) setPixelSpacing: (float) x :(float) y;
- (void) setSliceThickness: (double) t;
- (void) setOrientation: (float*) o;
- (void) setPosition: (float*) p;
- (void) setSlicePosition: (float) p;

@end

@compatibility_alias DICOMExport IsiXLegacyDICOMExport;
