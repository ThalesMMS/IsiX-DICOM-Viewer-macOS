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

#import "IsiXDCMTKTranscoding.h"
#include "IsiXDCMTKInternal.hpp"
#include <dcmtk/dcmdata/dcfilefo.h>
#include <dcmtk/dcmdata/dcdatset.h>
#include <dcmtk/dcmdata/dcdeftag.h>
#include <dcmtk/dcmdata/dcuid.h>
#include <dcmtk/dcmdata/dcxfer.h>
#include <dcmtk/dcmdata/dcrlerp.h>
#include <dcmtk/dcmjpeg/djrploss.h>
#include <dcmtk/dcmjpeg/djrplol.h>
#include "HorosDICOMRepresentation.h"
#include "HorosDCMTKSeekableInput.h"

@interface IsiXDCMTKCompressionFacts ()
@property (readwrite) BOOL pixelDataCompressed;
@property (readwrite, copy, nullable) NSString *modality;
@property (readwrite, copy, nullable) NSString *SOPClassUID;
@property (readwrite, nullable) NSNumber *rows;
@property (readwrite, nullable) NSNumber *columns;
@end

@implementation IsiXDCMTKCompressionFacts
@end

@implementation IsiXDCMTKTranscoding

+ (NSString *)nameOfUID:(NSString *)uid
{
    NSString *name = nil;
    IsiXDCMTKGuard(NULL, "dcmFindNameOfUID", [&]() -> NSError * {
        const char *utf8 = uid.UTF8String;
        const char *found = utf8 ? dcmFindNameOfUID(utf8) : NULL;
        if (found) name = [NSString stringWithFormat:@"%s", found];
        return nil;
    });
    return name;
}

+ (IsiXDCMTKCompressionFacts *)compressionFactsOfFileAtPath:(NSString *)path error:(NSError **)error
{
    IsiXDCMTKCompressionFacts *facts = nil;
    BOOL read = IsiXDCMTKGuard(error, "DcmFileFormat::loadFile", [&]() -> NSError * {
        const char *fileSystemPath = path.UTF8String;
        if (!fileSystemPath) return IsiXDCMTKFailure(@"The file has no usable path");
        DcmFileFormat fileformat;
        OFCondition condition = fileformat.loadFile(fileSystemPath);
        if (condition.bad()) return IsiXDCMTKErrorFromCondition(condition);
        DcmDataset *dataset = fileformat.getDataset();
        DcmXfer original(dataset->getOriginalXfer());
        IsiXDCMTKCompressionFacts *found = [[IsiXDCMTKCompressionFacts alloc] init];
        found.pixelDataCompressed = original.usesEncapsulatedFormat() && original.isPixelDataCompressed();
        const char *string = NULL;
        found.modality = @"OT";
        if (dataset->findAndGetString(DCM_Modality, string, OFFalse).good() && string != NULL)
            found.modality = [NSString stringWithCString:string encoding:NSASCIIStringEncoding];
        found.SOPClassUID = @"";
        if (dataset->findAndGetString(DCM_SOPClassUID, string, OFFalse).good() && string != NULL)
            found.SOPClassUID = [NSString stringWithCString:string encoding:NSASCIIStringEncoding];
        Uint16 value = 0;
        if (dataset->findAndGetUint16(DCM_Rows, value, OFFalse).good()) found.rows = @(value);
        if (dataset->findAndGetUint16(DCM_Columns, value, OFFalse).good()) found.columns = @(value);
        facts = found;
        return nil;
    });
    return read ? facts : nil;
}

+ (IsiXDCMTKTranscodeOutcome)transcodeFileAtPath:(NSString *)path
                                toTransferSyntax:(NSString *)transferSyntax
                                         quality:(int)quality
                                     destination:(NSString *)destination
                                  servesOriginal:(NS_NOESCAPE BOOL (^)(NSString *, NSString *))servesOriginal
                                           error:(NSError **)error
{
    IsiXDCMTKTranscodeOutcome outcome = IsiXDCMTKTranscodeOutcomeUnreadable;
    IsiXDCMTKGuard(error, "DcmDataset::chooseRepresentation", [&]() -> NSError * {
        const char *source = path.UTF8String;
        if (!source) return IsiXDCMTKFailure(@"The file has no usable path");
        DcmFileFormat fileformat;
        OFCondition condition = fileformat.loadFile(source);
        if (condition.bad()) return IsiXDCMTKErrorFromCondition(condition);

        DcmDataset *dataset = fileformat.getDataset();
        DcmXfer filexfer(dataset->getOriginalXfer());
        DcmXfer xfer(transferSyntax.UTF8String ? transferSyntax.UTF8String : "");
        NSString *original = [NSString stringWithUTF8String:filexfer.getXferID()] ?: @"";
        if (servesOriginal(original, transferSyntax ?: @"")) {
            outcome = IsiXDCMTKTranscodeOutcomeServesOriginal;
            return nil;
        }

        DcmRepresentationParameter *params = nil;
        DJ_RPLossy lossyParams(90);
        DJ_RPLossy JP2KParams(quality);
        DJ_RPLossy JP2KParamsLossLess(quality);
        DcmRLERepresentationParameter rleParams;
        DJ_RPLossless losslessParams(6, 0);

        if (xfer.getXfer() == EXS_JPEGProcess14SV1)
            params = &losslessParams;
        else if (xfer.getXfer() == EXS_JPEGProcess2_4)
            params = &lossyParams;
        else if (xfer.getXfer() == EXS_RLELossless)
            params = &rleParams;
        else if (xfer.getXfer() == EXS_JPEG2000LosslessOnly)
            params = &JP2KParamsLossLess;
        else if (xfer.getXfer() == EXS_JPEG2000)
            params = &JP2KParams;
        else if (xfer.getXfer() == EXS_JPEGLSLossless)
            params = &JP2KParamsLossLess;
        else if (xfer.getXfer() == EXS_JPEGLSLossy)
            params = &JP2KParams;

        HorosChooseDICOMRepresentation(fileformat, xfer.getXfer(), params, quality);

        if (!dataset->canWriteXfer(xfer.getXfer())) {
            outcome = IsiXDCMTKTranscodeOutcomeCannotWrite;
            return nil;
        }
        fileformat.loadAllDataIntoMemory();
        const char *target = IsiXDCMTKFileSystemPath(destination);
        condition = target ? fileformat.saveFile(target, xfer.getXfer()) : EC_IllegalParameter;
        outcome = condition.good() ? IsiXDCMTKTranscodeOutcomeWritten : IsiXDCMTKTranscodeOutcomeSaveFailed;
        return nil;
    });
    return outcome;
}

/// What a file read for the service says: as +compressionFactsOfFileAtPath:.
static IsiXDCMTKCompressionFacts *IsiXDCMTKFactsOfDataset(DcmDataset *dataset, const DcmXfer &original)
{
    IsiXDCMTKCompressionFacts *facts = [[IsiXDCMTKCompressionFacts alloc] init];
    facts.pixelDataCompressed = original.usesEncapsulatedFormat() && original.isPixelDataCompressed();
    const char *string = NULL;
    facts.modality = @"OT";
    if (dataset->findAndGetString(DCM_Modality, string, OFFalse).good() && string != NULL)
        facts.modality = [NSString stringWithCString:string encoding:NSASCIIStringEncoding];
    facts.SOPClassUID = @"";
    if (dataset->findAndGetString(DCM_SOPClassUID, string, OFFalse).good() && string != NULL)
        facts.SOPClassUID = [NSString stringWithCString:string encoding:NSASCIIStringEncoding];
    Uint16 value = 0;
    if (dataset->findAndGetUint16(DCM_Rows, value, OFFalse).good()) facts.rows = @(value);
    if (dataset->findAndGetUint16(DCM_Columns, value, OFFalse).good()) facts.columns = @(value);
    return facts;
}

+ (IsiXDCMTKConversionOutcome)convertFileAtPath:(NSString *)path
                                  workingFolder:(NSString *)workingFolder
                                    destination:(NSString *)destination
                                       choosing:(NS_NOESCAPE IsiXDCMTKConversionChooser)choose
                                          error:(NSError **)error
{
    IsiXDCMTKConversionOutcome outcome = IsiXDCMTKConversionOutcomeUnreadable;
    BOOL loaded = NO;
    BOOL finished = IsiXDCMTKGuard(error, "DcmDataset::chooseRepresentation", [&]() -> NSError * {
        const char *source = IsiXDCMTKFileSystemPath(path);
        const char *folder = IsiXDCMTKFileSystemPath(workingFolder);
        if (!source || !folder) return IsiXDCMTKFailure(@"The file has no usable path");
        // The input owns any inflated copy and outlives the save, which may
        // still read values from the file.
        HorosDCMTKSeekableInput input;
        DcmFileFormat &fileformat = input.fileFormat();
        OFCondition condition = input.load(source, folder);
        if (condition.bad()) return IsiXDCMTKErrorFromCondition(condition);
        loaded = YES;

        DcmDataset *dataset = fileformat.getDataset();
        DcmXfer original(dataset->getOriginalXfer());
        // "GEIIS": the problematic private group, with an always JPEG compressed PixelData.
        delete dataset->remove(DcmTagKey(0x0009, 0x1110));

        int quality = 0;
        NSString *originalSyntax = [NSString stringWithUTF8String:original.getXferID()] ?: @"";
        NSString *syntax = choose(IsiXDCMTKFactsOfDataset(dataset, original), originalSyntax, &quality);
        if (!syntax) {
            outcome = IsiXDCMTKConversionOutcomeUnchanged;
            return nil;
        }

        E_TransferSyntax target = DcmXfer(syntax.UTF8String ? syntax.UTF8String : "").getXfer();
        DJ_RPLossless losslessParams(6, 0);
        DJ_RPLossy losslessQuality(0);
        DJ_RPLossy lossyQuality(quality);
        DcmRepresentationParameter *params = NULL;
        if (target == EXS_JPEGProcess14SV1)
            params = &losslessParams;
        else if (target == EXS_JPEGLSLossless || target == EXS_JPEG2000LosslessOnly)
            params = &losslessQuality;
        else if (target == EXS_JPEGLSLossy || target == EXS_JPEG2000)
            params = &lossyQuality;
        HorosChooseDICOMRepresentation(fileformat, target, params, quality);

        if (!dataset->canWriteXfer(target)) {
            outcome = IsiXDCMTKConversionOutcomeCannotWrite;
            return nil;
        }
        const char *output = IsiXDCMTKFileSystemPath(destination);
        condition = output ? fileformat.saveFile(output, target) : EC_IllegalParameter;
        outcome = condition.good() ? IsiXDCMTKConversionOutcomeWritten : IsiXDCMTKConversionOutcomeSaveFailed;
        return condition.good() ? nil : IsiXDCMTKErrorFromCondition(condition);
    });
    if (!finished && loaded && outcome == IsiXDCMTKConversionOutcomeUnreadable)
        outcome = IsiXDCMTKConversionOutcomeSaveFailed;
    return outcome;
}

@end
