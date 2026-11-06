/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

#import "IsiXDCMTKCodecs.h"
#include "IsiXDCMTKInternal.hpp"
#include <dcmtk/dcmjpeg/djdecode.h>
#include <dcmtk/dcmjpeg/djencode.h>
#include <dcmtk/dcmdata/dcrledrg.h>
#include <dcmtk/dcmdata/dcrleerg.h>
#include <dcmtk/dcmjpls/djdecode.h>
#include <dcmtk/dcmjpls/djencode.h>
#include "HorosJPEG2000Codec.hpp"
#include "HorosJPEGColourModel.h"
// Colour support for DicomImage, which the JPEG-LS encoder reads the pixels
// through (always for near-lossless, and for lossless as it prefers). Without
// it every RGB image fails "unsupported value for 'PhotometricInterpretation'"
// and stays uncompressed. Including the header registers the support for the
// whole process, through a static object. Both processes that compress need
// it: the Decompress service and the application, which transcodes to JPEG-LS
// for the web portal and DICOMweb. The application also got it from DCMTK's
// structured report code (dsrimgvl.cc includes the same header), but only as
// long as that code stays linked.
#include <dcmtk/dcmimage/diregist.h>

@implementation IsiXDCMTKCodecs

+ (BOOL)registerCodecs:(NSError **)error
{
    return IsiXDCMTKGuard(error, "codec registration", []() -> NSError * {
        // JPEG decoders: the colour model follows the Photometric
        // Interpretation, as in the Decompress helper.
        DJDecoderRegistration::registerCodecs(EDC_photometricInterpretation, EUC_never);
        DJLSDecoderRegistration::registerCodecs();

        DJEncoderRegistration::registerCodecs(
            ECC_lossyRGB,
            EUC_never,
            OFFalse,
            0,
            0,
            0,
            OFTrue,
            ESS_444,
            OFFalse,
            OFFalse,
            0,
            0,
            0.0,
            0.0,
            0,
            0,
            0,
            0,
            OFTrue,
            OFTrue,
            OFFalse,
            OFFalse,
            OFTrue);
        DJLSEncoderRegistration::registerCodecs();

        DcmRLEEncoderRegistration::registerCodecs();
        DcmRLEDecoderRegistration::registerCodecs();

        // JPEG 2000, which upstream DCMTK does not provide.
        HorosJPEG2000Registration::registerCodecs();
        // Per-store metadata policy is applied by the listener's store
        // (IsiXDCMTKSCPDatabase.mm).
        return nil;
    });
}

+ (BOOL)cleanupCodecs:(NSError **)error
{
    return IsiXDCMTKGuard(error, "codec cleanup", []() -> NSError * {
        DJDecoderRegistration::cleanup();
        DJEncoderRegistration::cleanup();
        DcmRLEDecoderRegistration::cleanup();
        DcmRLEEncoderRegistration::cleanup();
        HorosJPEG2000Registration::cleanup();
        return nil;
    });
}

+ (BOOL)markersDecideColour
{
    return HorosJPEGMarkersDecideColour().load();
}

+ (void)setMarkersDecideColour:(BOOL)markersDecideColour
{
    HorosJPEGMarkersDecideColour().store(markersDecideColour);
}

@end
