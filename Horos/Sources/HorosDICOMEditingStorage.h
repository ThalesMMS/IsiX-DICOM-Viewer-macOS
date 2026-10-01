//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#pragma once
#include <cstring>

// Preserve the metadata editor's accepted SOP Classes when changing its
// serialization backend. Broader storage support requires a deliberate policy
// change; a library's full storage table or the presence of pixels is not the
// editor's allow-list. UIDs are matched exactly, including retired and private
// classes already supported by the editor.
static inline bool HorosDICOMEditingSupportsStorage(const char *uid)
{
    if (!uid || !*uid) return false;
    static const char *const supported[] = {
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
    for (const char *candidate : supported)
        if (std::strcmp(uid, candidate) == 0) return true;
    return false;
}
