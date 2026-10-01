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

#import "HorosGDCMAnonymizer.h"
#import "DCMAttributeTag.h"
#import "DCMCharacterSet.h"
#include <dcmtk/config/osconfig.h>
#include <dcmtk/dcmdata/dctk.h>
#include <dcmtk/dcmdata/dcpixseq.h>
#include <dcmtk/dcmdata/dcpxitem.h>
#include <dcmtk/dcmdata/dcspchrs.h>
#include "HorosDCMTKSeekableInput.h"
#include "HorosSelectedAnonymizationCatalog.h"
#include <algorithm>
#include <string>
#include <memory>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>

namespace {
// Preserve the selected-field storage gate, including retired and private IODs.
// This is a compatibility list, not an IOD validator or a confidentiality profile.
static const char *const selectedStorageClasses[] = {
    "1.2.840.10008.1.3.10", // MediaStorageDirectoryStorage
    "1.2.840.10008.5.1.4.1.1.4", // MRImageStorage
    "1.2.840.10008.5.1.4.1.1.4.1", // EnhancedMRImageStorage
    "1.2.840.10008.5.1.4.1.1.2", // CTImageStorage
    "1.2.840.10008.5.1.4.1.1.2.1", // EnhancedCTImageStorage
    "1.2.840.10008.5.1.4.1.1.1", // ComputedRadiographyImageStorage
    "1.2.840.10008.5.1.4.1.1.12.1", // XRayAngiographicImageStorage
    "1.2.840.10008.5.1.4.1.1.6", // UltrasoundImageStorageRetired
    "1.2.840.10008.5.1.4.1.1.6.1", // UltrasoundImageStorage
    "1.2.840.10008.5.1.4.1.1.3", // UltrasoundMultiFrameImageStorageRetired
    "1.2.840.10008.5.1.4.1.1.3.1", // UltrasoundMultiFrameImageStorage
    "1.2.840.10008.5.1.4.1.1.7", // SecondaryCaptureImageStorage
    "1.2.840.10008.5.1.4.1.1.12.2", // XRayRadiofluoroscopingImageStorage
    "1.2.840.10008.5.1.4.1.1.4.2", // MRSpectroscopyStorage
    "1.2.840.10008.5.1.4.1.1.5", // NuclearMedicineImageStorageRetired
    "1.2.840.10008.5.1.4.1.1.20", // NuclearMedicineImageStorage
    "1.2.840.10008.5.1.4.1.1.7.1", // MultiframeSingleBitSecondaryCaptureImageStorage
    "1.2.840.10008.5.1.4.1.1.7.2", // MultiframeGrayscaleByteSecondaryCaptureImageStorage
    "1.2.840.10008.5.1.4.1.1.7.3", // MultiframeGrayscaleWordSecondaryCaptureImageStorage
    "1.2.840.10008.5.1.4.1.1.7.4", // MultiframeTrueColorSecondaryCaptureImageStorage
    "1.2.840.10008.5.1.4.1.1.104.1", // EncapsulatedPDFStorage
    "1.2.840.10008.5.1.4.1.1.104.2", // EncapsulatedCDAStorage
    "1.2.840.10008.5.1.4.1.1.77.1.4", // VLPhotographicImageStorage
    "1.2.840.10008.5.1.4.1.1.66.4", // SegmentationStorage
    "1.2.840.10008.5.1.4.1.1.66", // RawDataStorage
    "1.2.840.10008.5.1.4.1.1.88.50", // MammographyCADSR
    "1.2.840.10008.5.1.4.1.1.77.1.1.1", // VideoEndoscopicImageStorage
    "1.2.840.10008.5.1.4.1.1.481.1", // RTImageStorage
    "1.2.840.10008.5.1.4.1.1.481.2", // RTDoseStorage
    "1.2.840.10008.5.1.4.1.1.481.3", // RTStructureSetStorage
    "1.2.840.10008.5.1.4.1.1.481.5", // RTPlanStorage
    "1.2.840.10008.3.1.2.3.3", // ModalityPerformedProcedureStepSOPClass
    "1.2.840.10008.5.1.4.38.1", // HangingProtocolStorage
    "1.2.840.10008.5.1.4.1.1.88.59", // KeyObjectSelectionDocument
    "1.2.840.10008.5.1.4.1.1.88.33", // ComprehensiveSR
    "1.2.840.10008.5.1.4.1.1.9.2.1", // HemodynamicWaveformStorage
    "1.2.840.10008.5.1.4.1.1.1.3", // DigitalIntraoralXrayImageStorageForPresentation
    "1.2.840.10008.5.1.4.1.1.1.3.1", // DigitalIntraoralXRayImageStorageForProcessing
    "1.2.840.10008.5.1.4.1.1.1.1", // DigitalXRayImageStorageForPresentation
    "1.2.840.10008.5.1.4.1.1.1.1.1", // DigitalXRayImageStorageForProcessing
    "1.2.840.10008.5.1.4.1.1.1.2", // DigitalMammographyImageStorageForPresentation
    "1.2.840.10008.5.1.4.1.1.1.2.1", // DigitalMammographyImageStorageForProcessing
    "1.2.840.10008.5.1.4.1.1.11.1", // GrayscaleSoftcopyPresentationStateStorageSOPClass
    "1.2.840.10008.5.1.4.1.1.9.1.1", // LeadECGWaveformStorage
    "1.2.840.10008.5.1.4.1.1.9.1.2", // GeneralECGWaveformStorage
    "1.2.840.10008.5.1.4.1.1.9.1.3", // AmbulatoryECGWaveformStorage
    "1.2.840.10008.5.1.4.1.1.9.4.1", // BasicVoiceAudioWaveformStorage
    "1.2.840.10008.5.1.4.1.1.66.2", // SpacialFiducialsStorage
    "1.2.840.10008.5.1.4.1.1.88.11", // BasicTextSR
    "1.2.840.10008.5.1.4.1.1.9.3.1", // CardiacElectrophysiologyWaveformStorage
    "1.2.840.10008.5.1.4.1.1.128", // PETImageStorage
    "1.2.840.10008.5.1.4.1.1.88.22", // EnhancedSR
    "1.2.840.10008.5.1.4.1.1.66.1", // SpacialRegistrationStorage
    "1.2.840.10008.5.1.4.1.1.481.8", // RTIonPlanStorage
    "1.2.840.10008.5.1.4.1.1.13.1.1", // XRay3DAngiographicImageStorage
    "1.2.840.10008.5.1.4.1.1.12.1.1", // EnhancedXAImageStorage
    "1.2.840.10008.5.1.4.1.1.481.9", // RTIonBeamsTreatmentRecordStorage
    "1.2.840.10008.5.1.4.1.1.481.7", // RTTreatmentSummaryRecordStorage
    "1.2.840.10008.5.1.4.1.1.77.1.1", // VLEndoscopicImageStorage
    "1.2.840.10008.5.1.4.1.1.88.67", // XRayRadiationDoseSR
    "1.2.392.200036.9125.1.1.2", // FujiPrivateCRImageStorage
    "1.2.392.200036.9125.1.1.4", // FujiPrivateMammoCRImageStorage
    "1.3.12.2.1107.5.9.1", // CSANonImageStorage
    "1.2.840.10008.5.1.4.1.1.77.1.2", // VLMicroscopicImageStorage
    "1.2.840.10008.5.1.4.1.1.13.1.2", // XRay3DCraniofacialImageStorage
};

bool supportedStorage(const OFString &uid)
{
    for (const char *known : selectedStorageClasses)
        if (uid == known) return true;
    return false;
}

bool rootUID(DcmItem &item, const DcmTagKey &key, OFString &value)
{
    DcmElement *element = nullptr;
    return item.findAndGetElement(key, element, OFFalse).good() &&
        element->getVR() == EVR_UI && element->getLengthField() > 0 &&
        element->getLengthField() <= 64 && element->getOFStringArray(value).good() && !value.empty();
}

E_TransferSyntax sourceTransferSyntax(DcmFileFormat &file)
{
    // A deflated source is read through an Explicit LE backing dataset. Its
    // original serialization syntax remains in the retained file meta.
    OFString syntax;
    if (rootUID(*file.getMetaInfo(), DCM_TransferSyntaxUID, syntax))
        return DcmXfer(syntax.c_str()).getXfer();
    return file.getDataset()->getOriginalXfer(); // Dataset without file meta.
}

unsigned publicPolicy(const DcmTagKey &key)
{
    if (key.getElement() == 0) return 2; // Generic group length.
    uint32_t group = key.getGroup();
    if ((group & 0xff00) == 0x5000 || (group & 0xff00) == 0x6000 || (group & 0xff00) == 0x7f00)
        group &= 0xff00; // Retired repeating groups in the frozen catalog.
    uint64_t needle = uint64_t((group << 16) | key.getElement()) << 8;
    auto begin = std::begin(HorosSelectedPublicFields), end = std::end(HorosSelectedPublicFields);
    auto found = std::lower_bound(begin, end, needle);
    return found != end && (*found >> 8) == (needle >> 8) ? unsigned(*found & 255) : 0;
}

bool textualVR(DcmEVR vr)
{
    switch (vr) {
        case EVR_AE: case EVR_AS: case EVR_CS: case EVR_DA: case EVR_DS: case EVR_DT:
        case EVR_IS: case EVR_LO: case EVR_LT: case EVR_PN: case EVR_SH: case EVR_ST:
        case EVR_TM: case EVR_UC: case EVR_UI: case EVR_UR: case EVR_UT: return true;
        default: return false;
    }
}

// The selected-field editor cannot change the declaration without re-encoding
// every unselected text value. DCMTK decodes code extensions, but does not
// encode them as a destination. Keep that declaration and refuse text needing
// extensions rather than writing bytes from just its first repertoire.
class ReplacementEncoding {
    OFString declaration;
    DcmSpecificCharacterSet encoder, decoder;
    bool prepared = false, usable = false;
    NSStringEncoding fallback;

public:
    explicit ReplacementEncoding(const OFString &charset) : declaration(charset),
        fallback([DCMCharacterSet encodingForDICOMCharacterSet:@""]) {}

    bool encode(NSString *text, DcmEVR vr, bool creator, std::string &value)
    {
        NSData *utf8Data = [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
        if (!utf8Data) return false;
        if (!utf8Data.length) { value.clear(); return true; }
        const OFString utf8(static_cast<const char *>(utf8Data.bytes), utf8Data.length);
        // putString uses a C string; NUL would truncate the requested value.
        // A user-supplied ESC must not become a repertoire-switch instruction.
        if (utf8.find('\0') != OFString_npos || utf8.find('\x1b') != OFString_npos) return false;
        for (NSUInteger i = 0; i < text.length; ++i)
            if ([text characterAtIndex:i] >= 0x80 && [text characterAtIndex:i] <= 0x9f) return false;
        const bool affected = !creator && DcmVR(vr).isAffectedBySpecificCharacterSet();
        if (!affected || declaration.empty()) {
            // Retain the host's chosen default for absent/empty declarations;
            // VRs outside SpecificCharacterSet and private creators use ASCII.
            NSData *bytes = [text dataUsingEncoding:affected ? fallback : NSASCIIStringEncoding allowLossyConversion:NO];
            if (!bytes) return false;
            NSString *roundtrip = [[[NSString alloc] initWithData:bytes encoding:affected ? fallback : NSASCIIStringEncoding] autorelease];
            if (![roundtrip isEqualToString:text]) return false;
            value.assign(static_cast<const char *>(bytes.bytes), bytes.length);
            return value.find('\0') == std::string::npos && value.find('\x1b') == std::string::npos;
        }
        const bool extensions = declaration.find('\\') != OFString_npos ||
            declaration.find("ISO 2022") != OFString_npos;
        if (extensions && ![text canBeConvertedToEncoding:NSASCIIStringEncoding]) return false;
        if (!prepared) {
            prepared = true;
            const OFString charset = declaration == "ISO_IR 6" ? "" : declaration;
            usable = decoder.selectCharacterSet(charset, "ISO_IR 192").good() &&
                decoder.setConversionFlags(OFCharacterEncoding::AbortTranscodingOnIllegalSequence).good();
            if (usable && !extensions)
                usable = encoder.selectCharacterSet("ISO_IR 192", charset).good() &&
                    encoder.setConversionFlags(OFCharacterEncoding::AbortTranscodingOnIllegalSequence).good();
        }
        if (!usable) return false;
        const OFString delimiters = vr == EVR_PN ? "\\^=" :
            (vr == EVR_ST || vr == EVR_LT || vr == EVR_UT ? "" : "\\");
        OFString encoded, decoded;
        if (extensions) encoded = utf8; // ASCII needs no escape; prove its declared meaning below.
        else if (encoder.convertString(utf8, encoded, delimiters).bad()) return false;
        if (encoded.find('\0') != OFString_npos || encoded.find('\x1b') != OFString_npos ||
            decoder.convertString(encoded, decoded, delimiters).bad() || decoded != utf8) return false;
        value.assign(encoded.data(), encoded.length());
        return true;
    }
};

bool replaceSelected(DcmDataset &dataset, const DcmTagKey &key, const std::string &value)
{
    if (key.getGroup() < 8) return false;
    DcmElement *existing = nullptr;
    dataset.findAndGetElement(key, existing, OFFalse); // Only the dataset root.
    const bool creator = key.isPrivate() && key.getElement() >= 0x10 && key.getElement() <= 0xff;
    if (key.isPrivate() && !creator) {
        if (!existing || !value.empty()) return false;
        return existing->clear().good(); // Includes private sequences; empty is not removal.
    }
    const unsigned policy = creator ? 1 : publicPolicy(key);
    if (!policy) return false;
    DcmTag tag(key);
    if (creator) tag.setVR(EVR_LO);
    const DcmEVR dictionaryVR = tag.getEVR();
    if (policy == 3) {
        // Empty keeps the selected sequence present with no items. A string
        // cannot describe sequence items, so nonempty replacements are refused.
        return value.empty() && dataset.insertEmptyElement(DcmTag(key, EVR_SQ), OFTrue).good();
    }
    if (policy == 2) {
        if (!value.empty()) return false;
        if (existing && existing->ident() == EVR_PixelData) {
            // clear() inherited from the byte value does not clear encapsulated
            // representations. Replace the selected value with a truly empty one.
            auto &pixels = static_cast<DcmPixelData &>(*existing);
            E_TransferSyntax representation;
            const DcmRepresentationParameter *parameters = nullptr;
            pixels.getOriginalRepresentationKey(representation, parameters);
            std::unique_ptr<DcmPixelData> empty(new DcmPixelData(existing->getTag()));
            if (DcmXfer(representation).usesEncapsulatedFormat()) {
                std::unique_ptr<DcmPixelSequence> sequence(new DcmPixelSequence(DCM_PixelSequenceTag));
                std::unique_ptr<DcmPixelItem> offsets(new DcmPixelItem(DCM_PixelItemTag));
                if (sequence->insert(offsets.get()).bad()) return false;
                offsets.release();
                empty->putOriginalRepresentation(representation, parameters, sequence.release());
            }
            if (dataset.insert(empty.get(), OFTrue).bad()) return false;
            empty.release();
            return true;
        }
        if (existing) return existing->clear().good();
        return dictionaryVR != EVR_UNKNOWN && dictionaryVR != EVR_UN &&
            dataset.insertEmptyElement(tag, OFTrue).good();
    }
    if (!textualVR(dictionaryVR) || (existing && !textualVR(existing->getVR()))) return false;
    if (existing) return existing->putString(value.c_str()).good();
    return dataset.putAndInsertString(tag, value.c_str(), OFTrue).good();
}

// Capture serialized leaf sizes and tree boundaries before writing. DCMTK can
// turn an inaccessible deferred value into an empty element while reporting a
// successful header write. A fresh full parse must still have this shape.
using Shape = std::vector<uint64_t>;
bool elementShape(DcmElement &element, E_TransferSyntax xfer, Shape &shape);
bool itemShape(DcmItem &item, E_TransferSyntax xfer, Shape &shape)
{
    shape.push_back(0x100000000ULL);
    for (unsigned long i = 0; i < item.card(); ++i) {
        DcmElement *element = item.getElement(i);
        if (element->getTag().getElement() == 0 || element->getTag() == DCM_DataSetTrailingPadding) continue;
        if (!elementShape(*element, xfer, shape)) return false;
    }
    shape.push_back(0x200000000ULL);
    return true;
}

bool elementShape(DcmElement &element, E_TransferSyntax xfer, Shape &shape)
{
    shape.push_back((uint32_t(element.getTag().getGroup()) << 16) | element.getTag().getElement());
    if (element.ident() == EVR_SQ) {
        auto &sequence = static_cast<DcmSequenceOfItems &>(element);
        shape.push_back(sequence.card());
        for (unsigned long i = 0; i < sequence.card(); ++i)
            if (!itemShape(*sequence.getItem(i), xfer, shape)) return false;
        return true;
    }
    if (element.ident() == EVR_PixelData) {
        auto &pixels = static_cast<DcmPixelData &>(element);
        E_TransferSyntax representation;
        const DcmRepresentationParameter *parameters = nullptr;
        pixels.getOriginalRepresentationKey(representation, parameters);
        if (DcmXfer(representation).usesEncapsulatedFormat()) {
            DcmPixelSequence *sequence = nullptr;
            if (pixels.getEncapsulatedRepresentation(representation, parameters, sequence).bad() || !sequence) return false;
            shape.push_back(sequence->card());
            for (unsigned long i = 0; i < sequence->card(); ++i) {
                DcmPixelItem *fragment = nullptr;
                if (sequence->getItem(fragment, i).bad() || !fragment || !elementShape(*fragment, xfer, shape)) return false;
            }
            return true;
        }
    }
    const Uint32 length = element.getLength(xfer, EET_UndefinedLength);
    shape.push_back(length);
    if (!element.valueLoaded() && length) {
        // A skipped value may extend past EOF even when loadFile succeeds.
        // Probe its final byte without loading its payload into memory.
        Uint8 byte;
        if (element.getPartialValue(&byte, length - 1, 1).bad()) return false;
    }
    return true;
}

bool sameSource(const char *path, const struct stat &before)
{
    struct stat now;
    return stat(path, &now) == 0 && S_ISREG(now.st_mode) && (now.st_mode & 0444) &&
        access(path, R_OK) == 0 && now.st_dev == before.st_dev && now.st_ino == before.st_ino &&
        now.st_size == before.st_size && now.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec &&
        now.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec &&
        now.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec && now.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec;
}
}

@implementation HorosGDCMAnonymizer

+ (NSString *)anonymizeStagedFile:(NSString *)f withTags:(NSArray *)tags failure:(NS_NOESCAPE HorosGDCMAnonymizerFailure)failure
{
    const char *filename = f.fileSystemRepresentation;
    struct stat source;
    NSString *folder = f.stringByDeletingLastPathComponent;
    const char *workingDirectory = folder.fileSystemRepresentation;
    HorosDCMTKSeekableInput input;
    DcmFileFormat &file = input.fileFormat();
    file.setMaxNestingDepth(16);
    if (!filename || stat(filename, &source) != 0 || !S_ISREG(source.st_mode) || !(source.st_mode & 0444) ||
        access(filename, R_OK) != 0 ||
        input.load(filename, workingDirectory).bad()) {
        failure(NSLocalizedString(@"An input file is not a readable DICOM file.", nil), nil);
        return nil;
    }
    DcmDataset &dataset = *file.getDataset();
    OFString storage, instance;
    bool directory = false;
    if (!rootUID(dataset, DCM_SOPClassUID, storage)) {
        // DICOMDIR identifies its class in the file meta. Other legacy objects
        // without a dataset identity are refused instead of inferring one from Modality.
        directory = rootUID(*file.getMetaInfo(), DCM_MediaStorageSOPClassUID, storage) && storage == UID_MediaStorageDirectoryStorage;
    }
    if (!supportedStorage(storage) || (!directory && !rootUID(dataset, DCM_SOPInstanceUID, instance)) ||
        (directory && !rootUID(*file.getMetaInfo(), DCM_MediaStorageSOPInstanceUID, instance))) {
        failure(NSLocalizedString(@"An input DICOM storage type or SOP identity is not supported for anonymization.", nil), nil);
        return nil;
    }
    const E_TransferSyntax xfer = sourceTransferSyntax(file);
    if (xfer == EXS_Unknown || !dataset.canWriteXfer(xfer)) {
        failure(NSLocalizedString(@"The input DICOM transfer syntax cannot be preserved for anonymization.", nil), nil);
        return nil;
    }
    Shape inputShape;
    if (!itemShape(dataset, xfer, inputShape) || !sameSource(filename, source)) {
        failure(NSLocalizedString(@"An input file is truncated or no longer readable.", nil), nil);
        return nil;
    }
    OFString charset;
    dataset.findAndGetOFStringArray(DCM_SpecificCharacterSet, charset, OFFalse);
    ReplacementEncoding encoding(charset);
    std::vector<std::pair<DcmTagKey, std::string>> replacements;
    for (NSArray *item in tags) {
        DCMAttributeTag *tag = item[0];
        const DcmTagKey key(tag.group, tag.element);
        DcmElement *existing = nullptr;
        dataset.findAndGetElement(key, existing, OFFalse);
        const DcmEVR vr = existing ? existing->getVR() : DcmTag(key).getEVR();
        const bool creator = key.isPrivate() && key.getElement() >= 0x10 && key.getElement() <= 0xff;
        std::string value;
        if ((item.count > 1 && !encoding.encode([item[1] description], vr, creator, value)) ||
            (key == DCM_SpecificCharacterSet && value != charset)) {
            failure(NSLocalizedString(@"A replacement value cannot be represented in the input file's character set.", nil),
                [NSString stringWithFormat:@"(%04X,%04X)", tag.group, tag.element]);
            continue;
        }
        replacements.emplace_back(key, value);
    }
    for (const auto &replacement : replacements)
        if (!replaceSelected(dataset, replacement.first, replacement.second))
            failure(NSLocalizedString(@"The DICOM anonymizer cannot replace one or more selected fields.", nil),
                [NSString stringWithFormat:@"(%04X,%04X)", replacement.first.getGroup(), replacement.first.getElement()]);

    // Prevent saveFile from generating an identity for missing or emptied SOP UIDs.
    OFString finalStorage, finalInstance;
    if (!directory && (!rootUID(dataset, DCM_SOPClassUID, finalStorage) || !supportedStorage(finalStorage) ||
        !rootUID(dataset, DCM_SOPInstanceUID, finalInstance))) {
        failure(NSLocalizedString(@"The selected fields leave an unsupported DICOM SOP identity.", nil), nil);
        return nil;
    }
    if (directory) { finalStorage = storage; finalInstance = instance; }
    Shape expected;
    if (!itemShape(dataset, xfer, expected) || !sameSource(filename, source)) {
        failure(NSLocalizedString(@"The staged input is no longer readable for anonymization.", nil), nil);
        return nil;
    }
    NSString *output = [folder stringByAppendingPathComponent:[@"anon_" stringByAppendingString:f.lastPathComponent]];
    std::string temporary = [[folder stringByAppendingPathComponent:@".horos-anonymized-XXXXXX"] fileSystemRepresentation];
    std::vector<char> name(temporary.begin(), temporary.end());
    name.push_back(0);
    const int fd = mkstemp(name.data());
    bool written = fd >= 0;
    if (written) written = close(fd) == 0;
    if (written) written = file.saveFile(name.data(), xfer, EET_UndefinedLength, EGL_recalcGL,
        EPD_noChange, 0, 0, EWM_updateMeta).good();
    if (written) {
        HorosDCMTKSeekableInput verificationInput;
        DcmFileFormat &verified = verificationInput.fileFormat();
        verified.setMaxNestingDepth(16);
        Shape actual;
        OFString metaStorage, metaInstance;
        written = sameSource(filename, source) &&
            verificationInput.load(name.data(), workingDirectory).good() &&
            sourceTransferSyntax(verified) == xfer &&
            itemShape(*verified.getDataset(), xfer, actual) && expected == actual &&
            rootUID(*verified.getMetaInfo(), DCM_MediaStorageSOPClassUID, metaStorage) && metaStorage == finalStorage &&
            rootUID(*verified.getMetaInfo(), DCM_MediaStorageSOPInstanceUID, metaInstance) && metaInstance == finalInstance;
    }
    if (written) written = rename(name.data(), output.fileSystemRepresentation) == 0;
    if (!written) {
        if (fd >= 0) unlink(name.data());
        failure(NSLocalizedString(@"An anonymized file could not be written. Check available space and destination permissions.", nil), nil);
        return nil;
    }
    return output;
}
@end
