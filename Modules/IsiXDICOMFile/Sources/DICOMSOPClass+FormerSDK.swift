//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

// What the class answered in the plugin SDK of Horos and OsiriX and the
// application itself does not ask: the UID of each SOP class by its own
// method, with the values and the spellings of that SDK, and the accessors of
// an instance. A plugin built for that SDK is not rebuilt and still sends them.
extension DICOMSOPClass {

    // MARK: The UID of each SOP class

    @objc(CTImageStorage) public static func sdkCapitalCTImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.2" }
    @objc(EnhancedXAImageStorage) public static func sdkCapitalEnhancedXAImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.12.1.1" }
    @objc(EnhancedXRFImageStorage) public static func sdkCapitalEnhancedXRFImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.12.2.1" }
    @objc(MRImageStorage) public static func sdkCapitalMRImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.4" }
    @objc(MRSpectroscopyStorage) public static func sdkCapitalMRSpectroscopyStorage() -> String { "1.2.840.10008.5.1.4.1.1.4.2" }
    @objc(PETImageStorage) public static func sdkCapitalPETImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.128" }
    @objc(RTBeamsTreatmentRecordStorage) public static func sdkCapitalRTBeamsTreatmentRecordStorage() -> String { "1.2.840.10008.5.1.4.1.1.481.4" }
    @objc(RTBrachyTreatmentRecordStorage) public static func sdkCapitalRTBrachyTreatmentRecordStorage() -> String { "1.2.840.10008.5.1.4.1.1.481.6" }
    @objc(RTDoseStorage) public static func sdkCapitalRTDoseStorage() -> String { "1.2.840.10008.5.1.4.1.1.481.2" }
    @objc(RTImageStorage) public static func sdkCapitalRTImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.481.1" }
    @objc(RTPlanStorage) public static func sdkCapitalRTPlanStorage() -> String { "1.2.840.10008.5.1.4.1.1.481.5" }
    @objc(RTTreatmentSummaryRecordStorage) public static func sdkCapitalRTTreatmentSummaryRecordStorage() -> String { "1.2.840.10008.5.1.4.1.1.481.7" }
    @objc(XRay3DAngiographicImageStorage) public static func sdkCapitalXRay3DAngiographicImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.13.1.1" }
    @objc(XRay3DCraniofacialImageStorage) public static func sdkCapitalXRay3DCraniofacialImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.13.1.2" }
    @objc(XrayAngiographicBiplaneImageStorage) public static func sdkCapitalXrayAngiographicBiplaneImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.12.3" }
    @objc(XrayAngiographicImageStorage) public static func sdkCapitalXrayAngiographicImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.12.1" }
    @objc(XrayRadioFlouroscopicImageStorage) public static func sdkCapitalXrayRadioFlouroscopicImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.12.2" }
    @objc(ambulatoryECGStorage) public static func sdkAmbulatoryECGStorage() -> String { "1.2.840.10008.5.1.4.1.1.9.1.3" }
    @objc(basicColorPrintManagementMetaSOPClassUID) public static func sdkBasicColorPrintManagementMetaSOPClassUID() -> String { ".2.840.10008.5.1.1.18" }
    @objc(basicGrayscalePrintManagementMetaSOPClassUID) public static func sdkBasicGrayscalePrintManagementMetaSOPClassUID() -> String { "1.2.840.10008.5.1.1.9" }
    @objc(basicTextSRStorage) public static func sdkBasicTextSRStorage() -> String { "1.2.840.10008.5.1.4.1.1.88.11" }
    @objc(basicVoiceStorage) public static func sdkBasicVoiceStorage() -> String { "1.2.840.10008.5.1.4.1.1.9.4.1" }
    @objc(cardiacElectrophysiologyWaveformStorage) public static func sdkCardiacElectrophysiologyWaveformStorage() -> String { "1.2.840.10008.5.1.4.1.1.9.3.1" }
    @objc(comprehensiveSRStorage) public static func sdkComprehensiveSRStorage() -> String { "1.2.840.10008.5.1.4.1.1.88.33" }
    @objc(computedRadiographyImageStorage) public static func sdkComputedRadiographyImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.1" }
    @objc(digitalIntraoralXRayImageStorageForPresentation) public static func sdkDigitalIntraoralXRayImageStorageForPresentation() -> String { "1.2.840.10008.5.1.4.1.1.1.3" }
    @objc(digitalIntraoralXRayImageStorageForProcessing) public static func sdkDigitalIntraoralXRayImageStorageForProcessing() -> String { "1.2.840.10008.5.1.4.1.1.1.3.1" }
    @objc(digitalMammographyXRayImageStorageForPresentation) public static func sdkDigitalMammographyXRayImageStorageForPresentation() -> String { "1.2.840.10008.5.1.4.1.1.1.2" }
    @objc(digitalMammographyXRayImageStorageForProcessing) public static func sdkDigitalMammographyXRayImageStorageForProcessing() -> String { "1.2.840.10008.5.1.4.1.1.1.2.1" }
    @objc(digitalXRayImageStorageForPresentation) public static func sdkDigitalXRayImageStorageForPresentation() -> String { "1.2.840.10008.5.1.4.1.1.1.1" }
    @objc(digitalXRayImageStorageForProcessing) public static func sdkDigitalXRayImageStorageForProcessing() -> String { "1.2.840.10008.5.1.4.1.1.1.1.1" }
    @objc(enhancedCTImageStorage) public static func sdkEnhancedCTImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.2.1" }
    @objc(enhancedPETImageStorage) public static func sdkEnhancedPETImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.130" }
    @objc(enhancedSRStorage) public static func sdkEnhancedSRStorage() -> String { "1.2.840.10008.5.1.4.1.1.88.22" }
    @objc(enhancedUSVolumeStorage) public static func sdkEnhancedUSVolumeStorage() -> String { "1.2.840.10008.5.1.4.1.1.6.2" }
    @objc(generalECGStorage) public static func sdkGeneralECGStorage() -> String { "1.2.840.10008.5.1.4.1.1.9.1.2" }
    @objc(grayscaleSoftcopyPresentationStateStorage) public static func sdkGrayscaleSoftcopyPresentationStateStorage() -> String { "1.2.840.10008.5.1.4.1.1.11.1" }
    @objc(hemodynamicWaveformStorage) public static func sdkHemodynamicWaveformStorage() -> String { "1.2.840.10008.5.1.4.1.1.9.2.1" }
    @objc(mammographyCADSRStorage) public static func sdkMammographyCADSRStorage() -> String { "1.2.840.10008.5.1.4.1.1.88.50" }
    @objc(mediaStorageDirectoryStorage) public static func sdkMediaStorageDirectoryStorage() -> String { "1.2.840.10008.1.3.10" }
    @objc(multiframeGrayscaleByteSecondaryCaptureImageStorage) public static func sdkMultiframeGrayscaleByteSecondaryCaptureImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.7.2" }
    @objc(multiframeGrayscaleWordSecondaryCaptureImageStorage) public static func sdkMultiframeGrayscaleWordSecondaryCaptureImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.7.3" }
    @objc(multiframeSingleBitSecondaryCaptureImageStorage) public static func sdkMultiframeSingleBitSecondaryCaptureImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.7.1" }
    @objc(multiframeTrueColorSecondaryCaptureImageStorage) public static func sdkMultiframeTrueColorSecondaryCaptureImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.7.4" }
    @objc(nuclearMedicineImageStorage) public static func sdkNuclearMedicineImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.20" }
    @objc(nuclearMedicineImageStorageRetired) public static func sdkNuclearMedicineImageStorageRetired() -> String { "1.2.840.10008.5.1.4.1.1.5" }
    @objc(rawDataStorage) public static func sdkRawDataStorage() -> String { "1.2.840.10008.5.1.4.1.1.66" }
    @objc(standaloneCurveStorage) public static func sdkStandaloneCurveStorage() -> String { "1.2.840.10008.5.1.4.1.1.10" }
    @objc(standaloneModalityLUTStorage) public static func sdkStandaloneModalityLUTStorage() -> String { "1.2.840.10008.5.1.4.1.1.10" }
    @objc(standaloneOverlayStorage) public static func sdkStandaloneOverlayStorage() -> String { "1.2.840.10008.5.1.4.1.1.8" }
    @objc(standalonePETCurveStorage) public static func sdkStandalonePETCurveStorage() -> String { "1.2.840.10008.5.1.4.1.1.129" }
    @objc(standaloneVOILUTStorage) public static func sdkStandaloneVOILUTStorage() -> String { "1.2.840.10008.5.1.4.1.1.11" }
    @objc(studyRootQueryRetrieveInformationModelMove) public static func sdkStudyRootQueryRetrieveInformationModelMove() -> String { "1.2.840.10008.5.1.4.1.2.2.2" }
    @objc(twelveLeadECGStorage) public static func sdkTwelveLeadECGStorage() -> String { "1.2.840.10008.5.1.4.1.1.9.1.1" }
    @objc(ultrasoundImageStorage) public static func sdkUltrasoundImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.6.1" }
    @objc(ultrasoundImageStorageRetired) public static func sdkUltrasoundImageStorageRetired() -> String { "1.2.840.10008.5.1.4.1.1.6" }
    @objc(ultrasoundMultiframeImageStorage) public static func sdkUltrasoundMultiframeImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.3.1" }
    @objc(ultrasoundMultiframeImageStorageRetired) public static func sdkUltrasoundMultiframeImageStorageRetired() -> String { "1.2.840.10008.5.1.4.1.1.3" }
    @objc(verificationClassUID) public static func sdkVerificationClassUID() -> String { "1.2.840.10008.1.1" }
    @objc(videoEndoscopicImageStorage) public static func sdkVideoEndoscopicImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.77.1.1.1" }
    @objc(videoMicroscopicImageStorage) public static func sdkVideoMicroscopicImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.77.1.2.1" }
    @objc(videoPhotographicImageStorage) public static func sdkVideoPhotographicImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.77.1.4.1" }
    @objc(visibleLightDraftImageStorage) public static func sdkVisibleLightDraftImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.77.1" }
    @objc(visibleLightEndoscopicImageStorage) public static func sdkVisibleLightEndoscopicImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.77.1.1" }
    @objc(visibleLightMicroscopicImageStorage) public static func sdkVisibleLightMicroscopicImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.77.1.2" }
    @objc(visibleLightMultiFrameDraftImageStorage) public static func sdkVisibleLightMultiFrameDraftImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.77.2" }
    @objc(visibleLightPhotographicImageStorage) public static func sdkVisibleLightPhotographicImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.77.1.4" }
    @objc(visibleLightSlideCoordinatesMicroscopicImageStorage) public static func sdkVisibleLightSlideCoordinatesMicroscopicImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.77.1.3" }
    @objc(xrayAngiographicBiplaneImageStorage) public static func sdkXrayAngiographicBiplaneImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.12.3" }
    @objc(xrayAngiographicImageStorage) public static func sdkXrayAngiographicImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.12.1" }
    @objc(xrayRadioFlouroscopicImageStorage) public static func sdkXrayRadioFlouroscopicImageStorage() -> String { "1.2.840.10008.5.1.4.1.1.12.2" }

    // MARK: An instance

    @objc(uid) public func legacyInstanceUID() -> String? { instanceUID }
    @objc(name) public func legacyInstanceName() -> String? { instanceName }
    @objc(type) public func legacyInstanceType() -> String? { instanceType }

    // The kind an instance was made with decides, not its UID.
    @objc(isImageStorage) public func legacyInstanceIsImageStorage() -> Bool { instanceType == "ImageStorage" }
    @objc(isNonImageStorage) public func legacyInstanceIsNonImageStorage() -> Bool { instanceType != "ImageStorage" }
    @objc(isDirectory) public func legacyInstanceIsDirectory() -> Bool { instanceType == "Directory" }
    @objc(isStructuredReport) public func legacyInstanceIsStructuredReport() -> Bool { instanceType == "StructuredReport" }
    @objc(isPresentationState) public func legacyInstanceIsPresentationState() -> Bool { instanceType == "PresentationState" }
    @objc(isWaveform) public func legacyInstanceIsWaveform() -> Bool { instanceType == "Waveform" }
    @objc(isStandalone) public func legacyInstanceIsStandalone() -> Bool { instanceType == "Standalone" }
    @objc(isRadiotherapy) public func legacyInstanceIsRadiotherapy() -> Bool { instanceType == "Radiotherapy" }
    @objc(isSpectroscopy) public func legacyInstanceIsSpectroscopy() -> Bool { instanceType == "Spectroscopy" }
    @objc(isRawData) public func legacyInstanceIsRawData() -> Bool { instanceType == "RawData" }

    public override var description: String {
        guard instanceUID != nil || instanceName != nil || instanceType != nil else { return super.description }
        return "Abstract Syntax:\(instanceUID ?? "(null)")  name:\(instanceName ?? "(null)")  type:\(instanceType ?? "(null)")"
    }
}
