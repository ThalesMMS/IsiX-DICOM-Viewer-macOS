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

/// The SOP classes the app tells apart: which ones are pictures, reports,
/// presentation states, waveforms, radiotherapy objects or private classes it
/// keeps, and the UIDs it writes itself.
///
/// The lists are the ones the viewer has always used. A UID is matched exactly,
/// except the supported private classes, which are prefixes (a vendor root).
/// `imageSyntaxes` adds the UIDs of `additionalDisplayedStorageSOPClassUIDArray`
/// and takes out those of `hiddenDisplayedStorageSOPClassUIDArray` once, when it
/// is first asked; the hidden ones are known from then on.
@objc(IsiXDICOMSOPClass)
public final class DICOMSOPClass: NSObject {

    // MARK: UIDs

    static let verification = "1.2.840.10008.1.1"
    static let computedRadiographyImageStorage = "1.2.840.10008.5.1.4.1.1.1"
    static let digitalXRayImageStorageForPresentation = "1.2.840.10008.5.1.4.1.1.1.1"
    static let digitalXRayImageStorageForProcessing = "1.2.840.10008.5.1.4.1.1.1.1.1"
    static let digitalMammographyXRayImageStorageForPresentation = "1.2.840.10008.5.1.4.1.1.1.2"
    static let digitalMammographyXRayImageStorageForProcessing = "1.2.840.10008.5.1.4.1.1.1.2.1"
    static let digitalIntraoralXRayImageStorageForPresentation = "1.2.840.10008.5.1.4.1.1.1.3"
    static let digitalIntraoralXRayImageStorageForProcessing = "1.2.840.10008.5.1.4.1.1.1.3.1"
    static let ctImageStorage = "1.2.840.10008.5.1.4.1.1.2"
    static let enhancedCTImageStorage = "1.2.840.10008.5.1.4.1.1.2.1"
    static let legacyConvertedEnhancedCTImageStorage = "1.2.840.10008.5.1.4.1.1.2.2"
    static let enhancedPETImageStorage = "1.2.840.10008.5.1.4.1.1.130"
    static let legacyConvertedEnhancedPETImageStorage = "1.2.840.10008.5.1.4.1.1.128.1"
    static let ultrasoundMultiframeImageStorageRetired = "1.2.840.10008.5.1.4.1.1.3"
    static let ultrasoundMultiframeImageStorage = "1.2.840.10008.5.1.4.1.1.3.1"
    static let mrImageStorage = "1.2.840.10008.5.1.4.1.1.4"
    static let enhancedMRImageStorageUID = "1.2.840.10008.5.1.4.1.1.4.1"
    static let legacyConvertedEnhancedMRImageStorage = "1.2.840.10008.5.1.4.1.1.4.4"
    static let nuclearMedicineImageStorageRetired = "1.2.840.10008.5.1.4.1.1.5"
    static let ultrasoundImageStorageRetired = "1.2.840.10008.5.1.4.1.1.6"
    static let ultrasoundImageStorage = "1.2.840.10008.5.1.4.1.1.6.1"
    static let enhancedUSVolumeStorage = "1.2.840.10008.5.1.4.1.1.6.2"
    static let secondaryCaptureImageStorageUID = "1.2.840.10008.5.1.4.1.1.7"
    // The multi-frame kinds +[DCMObject secondaryCaptureObjectWithBitDepth:...] picks from.
    @objc public static let multiframeSingleBitSecondaryCaptureImageStorage = "1.2.840.10008.5.1.4.1.1.7.1"
    @objc public static let multiframeGrayscaleByteSecondaryCaptureImageStorage = "1.2.840.10008.5.1.4.1.1.7.2"
    @objc public static let multiframeGrayscaleWordSecondaryCaptureImageStorage = "1.2.840.10008.5.1.4.1.1.7.3"
    @objc public static let multiframeTrueColorSecondaryCaptureImageStorage = "1.2.840.10008.5.1.4.1.1.7.4"
    static let xrayAngiographicImageStorage = "1.2.840.10008.5.1.4.1.1.12.1"
    static let enhancedXAImageStorage = "1.2.840.10008.5.1.4.1.1.12.1.1"
    static let xrayRadioFluoroscopicImageStorage = "1.2.840.10008.5.1.4.1.1.12.2"
    static let enhancedXRFImageStorage = "1.2.840.10008.5.1.4.1.1.12.2.1"
    static let xray3DAngiographicImageStorage = "1.2.840.10008.5.1.4.1.1.13.1.1"
    static let xray3DCraniofacialImageStorage = "1.2.840.10008.5.1.4.1.1.13.1.2"
    static let breastTomosynthesisImageStorage = "1.2.840.10008.5.1.4.1.1.13.1.3"
    static let ge3DModelStorage = "1.2.840.113619.4.26"
    static let geCollageStorage = "1.2.528.1.1001.5.1.1.1"
    static let geENTEGRAProtocolOrNMGenieStorage = "1.2.840.113619.4.27"
    static let gePETRawDataStorage = "1.2.840.113619.4.30"
    static let philipsCTSyntheticImageStorage = "1.3.46.670589.5.0.9"
    static let philipsCXImageStorage = "1.3.46.670589.2.4.1.1"
    static let philipsCXSyntheticImageStorage = "1.3.46.670589.5.0.12"
    static let philipsMRColorImageStorage = "1.3.46.670589.11.0.0.12.3"
    static let philipsMRSyntheticImageStorage = "1.3.46.670589.5.0.10"
    static let philipsPerfusionImageStorage = "1.3.46.670589.5.0.14"
    static let philipsPrivateXRayMFStorage = "1.3.46.670589.7.8.1618510091"
    /// A prefix: every private class under Philips' root.
    static let philipsPrivatePrefixStorage = "1.3.46.670589"
    static let siemensCSAPrivateNonImageStorage = "1.3.12.2.1107.5.9.1"
    static let xrayAngiographicBiplaneImageStorage = "1.2.840.10008.5.1.4.1.1.12.3"
    static let nuclearMedicineImageStorage = "1.2.840.10008.5.1.4.1.1.20"
    static let visibleLightDraftImageStorage = "1.2.840.10008.5.1.4.1.1.77.1"
    static let visibleLightMultiFrameDraftImageStorage = "1.2.840.10008.5.1.4.1.1.77.2"
    static let visibleLightEndoscopicImageStorage = "1.2.840.10008.5.1.4.1.1.77.1.1"
    static let videoEndoscopicImageStorage = "1.2.840.10008.5.1.4.1.1.77.1.1.1"
    static let visibleLightMicroscopicImageStorage = "1.2.840.10008.5.1.4.1.1.77.1.2"
    static let videoMicroscopicImageStorage = "1.2.840.10008.5.1.4.1.1.77.1.2.1"
    static let visibleLightSlideCoordinatesMicroscopicImageStorage = "1.2.840.10008.5.1.4.1.1.77.1.3"
    static let visibleLightPhotographicImageStorage = "1.2.840.10008.5.1.4.1.1.77.1.4"
    static let videoPhotographicImageStorage = "1.2.840.10008.5.1.4.1.1.77.1.4.1"
    static let petImageStorage = "1.2.840.10008.5.1.4.1.1.128"
    static let rtImageStorage = "1.2.840.10008.5.1.4.1.1.481.1"
    static let mediaStorageDirectoryStorage = "1.2.840.10008.1.3.10"
    static let basicTextSRStorage = "1.2.840.10008.5.1.4.1.1.88.11"
    static let enhancedSRStorage = "1.2.840.10008.5.1.4.1.1.88.22"
    static let comprehensiveSRStorage = "1.2.840.10008.5.1.4.1.1.88.33"
    static let procedureLogStorage = "1.2.840.10008.5.1.4.1.1.88.40"
    static let mammographyCADSRStorage = "1.2.840.10008.5.1.4.1.1.88.50"
    static let chestCADSR = "1.2.840.10008.5.1.4.1.1.88.65"
    static let xrayRadiationDoseSR = "1.2.840.10008.5.1.4.1.1.88.67"
    static let keyObjectSelectionDocumentStorageUID = "1.2.840.10008.5.1.4.1.1.88.59"
    static let grayscaleSoftcopyPresentationStateStorage = "1.2.840.10008.5.1.4.1.1.11.1"
    static let colorSoftcopyPresentationStateStorage = "1.2.840.10008.5.1.4.1.1.11.2"
    static let pseudoColorSoftcopyPresentationStateStorage = "1.2.840.10008.5.1.4.1.1.11.3"
    static let blendingSoftcopyPresentationStateStorage = "1.2.840.10008.5.1.4.1.1.11.4"
    static let twelveLeadECGStorage = "1.2.840.10008.5.1.4.1.1.9.1.1"
    static let generalECGStorage = "1.2.840.10008.5.1.4.1.1.9.1.2"
    static let ambulatoryECGStorage = "1.2.840.10008.5.1.4.1.1.9.1.3"
    static let hemodynamicWaveformStorage = "1.2.840.10008.5.1.4.1.1.9.2.1"
    static let cardiacElectrophysiologyWaveformStorage = "1.2.840.10008.5.1.4.1.1.9.3.1"
    static let basicVoiceStorage = "1.2.840.10008.5.1.4.1.1.9.4.1"
    static let standaloneOverlayStorage = "1.2.840.10008.5.1.4.1.1.8"
    static let standaloneCurveStorage = "1.2.840.10008.5.1.4.1.1.10"
    static let standaloneVOILUTStorage = "1.2.840.10008.5.1.4.1.1.11"
    static let standalonePETCurveStorage = "1.2.840.10008.5.1.4.1.1.129"
    static let rtDoseStorage = "1.2.840.10008.5.1.4.1.1.481.2"
    static let rtStructureSetStorageUID = "1.2.840.10008.5.1.4.1.1.481.3"
    static let rtBeamsTreatmentRecordStorage = "1.2.840.10008.5.1.4.1.1.481.4"
    static let rtPlanStorage = "1.2.840.10008.5.1.4.1.1.481.5"
    static let rtBrachyTreatmentRecordStorage = "1.2.840.10008.5.1.4.1.1.481.6"
    static let rtTreatmentSummaryRecordStorage = "1.2.840.10008.5.1.4.1.1.481.7"
    static let mrSpectroscopyStorage = "1.2.840.10008.5.1.4.1.1.4.2"
    static let rawDataStorage = "1.2.840.10008.5.1.4.1.1.66"
    static let studyRootFind = "1.2.840.10008.5.1.4.1.2.2.1"
    static let studyRootMove = "1.2.840.10008.5.1.4.1.2.2.2"
    static let pdfStorage = "1.2.840.10008.5.1.4.1.1.104.1"
    static let encapsulatedCDAStorageUID = "1.2.840.10008.5.1.4.1.1.104.2"
    /// Retired, still produced by printers and modality workstations. These are
    /// picture classes: an instance carries Rows, Columns and Pixel Data like
    /// any other image, and one that does not says so for itself.
    static let hardcopyGrayscaleImageStorage = "1.2.840.10008.5.1.1.29"
    static let hardcopyColorImageStorage = "1.2.840.10008.5.1.1.30"
    static let ophthalmicPhotography8BitImageStorage = "1.2.840.10008.5.1.4.1.1.77.1.5.1"
    static let ophthalmicPhotography16BitImageStorage = "1.2.840.10008.5.1.4.1.1.77.1.5.2"
    static let fujiPrivateCR = "1.2.392.200036.9125.1.1.2"
    static let ophthalmicTomographyImageStorage = "1.2.840.10008.5.1.4.1.1.77.1.5.4"

    @objc public static func pdfStorageClassUID() -> String { pdfStorage }
    @objc(EncapsulatedCDAStorage) public static func encapsulatedCDAStorage() -> String { encapsulatedCDAStorageUID }
    @objc public static func secondaryCaptureImageStorage() -> String { secondaryCaptureImageStorageUID }
    @objc(RTStructureSetStorage) public static func rtStructureSetStorage() -> String { rtStructureSetStorageUID }
    @objc public static func keyObjectSelectionDocumentStorage() -> String { keyObjectSelectionDocumentStorageUID }
    @objc public static func enhancedMRImageStorage() -> String { enhancedMRImageStorageUID }
    @objc public static func studyRootQueryRetrieveInformationModelFind() -> String { studyRootFind }
    @objc public static func studyRootQueryRetrieveInformationModelMove() -> String { studyRootMove }

    // MARK: Lists

    static let defaultImageSyntaxes = [
        computedRadiographyImageStorage, digitalXRayImageStorageForPresentation, digitalXRayImageStorageForProcessing,
        digitalMammographyXRayImageStorageForPresentation, digitalMammographyXRayImageStorageForProcessing,
        digitalIntraoralXRayImageStorageForPresentation, digitalIntraoralXRayImageStorageForProcessing,
        ctImageStorage, enhancedCTImageStorage, legacyConvertedEnhancedCTImageStorage, enhancedPETImageStorage,
        legacyConvertedEnhancedPETImageStorage, ultrasoundMultiframeImageStorageRetired, ultrasoundMultiframeImageStorage,
        mrImageStorage, enhancedMRImageStorageUID, legacyConvertedEnhancedMRImageStorage, nuclearMedicineImageStorageRetired,
        ultrasoundImageStorageRetired, enhancedUSVolumeStorage, ultrasoundImageStorage, secondaryCaptureImageStorageUID,
        multiframeSingleBitSecondaryCaptureImageStorage, multiframeGrayscaleByteSecondaryCaptureImageStorage,
        multiframeGrayscaleWordSecondaryCaptureImageStorage, multiframeTrueColorSecondaryCaptureImageStorage,
        xrayAngiographicImageStorage, xrayRadioFluoroscopicImageStorage, xrayAngiographicBiplaneImageStorage,
        nuclearMedicineImageStorage, visibleLightDraftImageStorage, videoEndoscopicImageStorage,
        videoMicroscopicImageStorage, videoPhotographicImageStorage, visibleLightMultiFrameDraftImageStorage,
        visibleLightEndoscopicImageStorage, visibleLightMicroscopicImageStorage,
        visibleLightSlideCoordinatesMicroscopicImageStorage, visibleLightPhotographicImageStorage, petImageStorage,
        rtImageStorage, pdfStorage, encapsulatedCDAStorageUID, ophthalmicPhotography8BitImageStorage,
        ophthalmicPhotography16BitImageStorage, ophthalmicTomographyImageStorage, fujiPrivateCR, enhancedXAImageStorage,
        enhancedXRFImageStorage, xray3DAngiographicImageStorage, xray3DCraniofacialImageStorage,
        philipsPrivateXRayMFStorage, philipsCTSyntheticImageStorage, philipsCXImageStorage, philipsCXSyntheticImageStorage,
        philipsMRColorImageStorage, philipsMRSyntheticImageStorage, philipsPerfusionImageStorage,
        breastTomosynthesisImageStorage, hardcopyGrayscaleImageStorage, hardcopyColorImageStorage,
    ]

    private struct Configured {
        var images: [String]?
        var hidden: [String]?
        var all: [String]?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var configured = Configured()

    /// The picture classes, with the preferences' additions and without the
    /// hidden ones, read the first time this is asked.
    @objc public static func imageSyntaxes() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return imageSyntaxesLocked()
    }

    private static func imageSyntaxesLocked() -> [String] {
        if let images = configured.images { return images }
        var images = defaultImageSyntaxes
        let defaults = UserDefaults.standard
        if let added = defaults.array(forKey: "additionalDisplayedStorageSOPClassUIDArray") {
            images += added.compactMap { $0 as? String }
        }
        if let hidden = defaults.array(forKey: "hiddenDisplayedStorageSOPClassUIDArray") {
            let strings = hidden.compactMap { $0 as? String }
            configured.hidden = strings
            images.removeAll { strings.contains($0) }
        }
        configured.images = images
        return images
    }

    /// The classes the preferences hide from display; nil until
    /// `imageSyntaxes` has been read, or when none is hidden.
    @objc public static func hiddenImageSyntaxes() -> [String]? {
        lock.lock(); defer { lock.unlock() }
        return configured.hidden
    }

    @objc public static func structuredReportSyntaxes() -> [String] {
        [basicTextSRStorage, enhancedSRStorage, comprehensiveSRStorage, mammographyCADSRStorage, procedureLogStorage,
         chestCADSR, xrayRadiationDoseSR]
    }

    @objc public static func presentationStateSyntaxes() -> [String] {
        [grayscaleSoftcopyPresentationStateStorage, colorSoftcopyPresentationStateStorage,
         pseudoColorSoftcopyPresentationStateStorage, blendingSoftcopyPresentationStateStorage]
    }

    @objc public static func supportedPrivateClasses() -> [String] {
        [mrSpectroscopyStorage, rawDataStorage, philipsPrivatePrefixStorage, siemensCSAPrivateNonImageStorage,
         ge3DModelStorage, geCollageStorage, geENTEGRAProtocolOrNMGenieStorage, gePETRawDataStorage]
    }

    @objc public static func waveformSyntaxes() -> [String] {
        [twelveLeadECGStorage, generalECGStorage, ambulatoryECGStorage, hemodynamicWaveformStorage,
         cardiacElectrophysiologyWaveformStorage, basicVoiceStorage]
    }

    @objc public static func radiotherapySyntaxes() -> [String] {
        [rtDoseStorage, rtStructureSetStorageUID, rtBeamsTreatmentRecordStorage, rtPlanStorage,
         rtBrachyTreatmentRecordStorage, rtTreatmentSummaryRecordStorage]
    }

    /// Every class the listener accepts and the database keeps, in this order.
    @objc public static func allSupportedSyntaxes() -> [String] {
        lock.lock(); defer { lock.unlock() }
        if let all = configured.all { return all }
        var all = imageSyntaxesLocked()
        all += radiotherapySyntaxes()
        all += structuredReportSyntaxes()
        all.append(keyObjectSelectionDocumentStorageUID)
        all += presentationStateSyntaxes()
        all += supportedPrivateClasses()
        all += waveformSyntaxes()
        all += configured.hidden ?? []
        configured.all = all
        return all
    }

    // MARK: Predicates

    @objc public static func isVerification(_ uid: String?) -> Bool { uid == verification }

    @objc public static func isMultiframe(_ uid: String?) -> Bool {
        guard let uid else { return false }
        return [enhancedMRImageStorageUID, ultrasoundMultiframeImageStorage, enhancedCTImageStorage,
                // Legacy Converted Enhanced holds the same enhanced multi-frame
                // IOD; it says only that the frames were gathered from single
                // frame originals.
                legacyConvertedEnhancedCTImageStorage, legacyConvertedEnhancedMRImageStorage,
                legacyConvertedEnhancedPETImageStorage, multiframeSingleBitSecondaryCaptureImageStorage,
                multiframeGrayscaleByteSecondaryCaptureImageStorage, multiframeGrayscaleWordSecondaryCaptureImageStorage,
                multiframeTrueColorSecondaryCaptureImageStorage, enhancedXAImageStorage, xrayAngiographicImageStorage,
                xrayRadioFluoroscopicImageStorage, enhancedXRFImageStorage, xrayAngiographicBiplaneImageStorage,
                xray3DAngiographicImageStorage, xray3DCraniofacialImageStorage, enhancedPETImageStorage,
                breastTomosynthesisImageStorage, ultrasoundMultiframeImageStorageRetired].contains(uid)
    }

    @objc public static func isImageStorage(_ uid: String?) -> Bool {
        guard let uid else { return false }
        return imageSyntaxes().contains(uid)
    }

    @objc public static func isHiddenImageStorage(_ uid: String?) -> Bool {
        guard let uid else { return false }
        return hiddenImageSyntaxes()?.contains(uid) ?? false
    }

    @objc public static func isDirectory(_ uid: String?) -> Bool { uid == mediaStorageDirectoryStorage }

    @objc public static func isKeyObjectDocument(_ uid: String?) -> Bool { uid == keyObjectSelectionDocumentStorageUID }

    @objc public static func isStructuredReport(_ uid: String?) -> Bool {
        guard let uid else { return false }
        return structuredReportSyntaxes().contains(uid)
    }

    @objc public static func isPresentationState(_ uid: String?) -> Bool {
        guard let uid else { return false }
        return presentationStateSyntaxes().contains(uid)
    }

    /// A private class the app keeps: the UID starts with one of the roots.
    @objc public static func isSupportedPrivateClasses(_ uid: String?) -> Bool {
        guard let uid else { return false }
        return supportedPrivateClasses().contains { uid.hasPrefix($0) }
    }

    @objc public static func isWaveform(_ uid: String?) -> Bool {
        guard let uid else { return false }
        return waveformSyntaxes().contains(uid)
    }

    /// The standalone overlay, curve and LUT classes. The modality LUT class
    /// was given the curve's UID, so it is that one.
    @objc public static func isStandalone(_ uid: String?) -> Bool {
        guard let uid else { return false }
        return [standaloneOverlayStorage, standaloneCurveStorage, standaloneVOILUTStorage,
                standalonePETCurveStorage].contains(uid)
    }

    @objc public static func isRadiotherapy(_ uid: String?) -> Bool {
        guard let uid else { return false }
        return radiotherapySyntaxes().contains(uid)
    }

    @objc public static func isSpectroscopy(_ uid: String?) -> Bool { uid == mrSpectroscopyStorage }

    @objc public static func isRawData(_ uid: String?) -> Bool { uid == rawDataStorage }

    @objc public static func isNonImageStorage(_ uid: String?) -> Bool {
        isDirectory(uid) || isStructuredReport(uid) || isPresentationState(uid) || isWaveform(uid)
            || isStandalone(uid) || isRadiotherapy(uid) || isSpectroscopy(uid) || isRawData(uid) || isPDF(uid)
            || isHiddenImageStorage(uid)
    }

    @objc public static func isQuery(_ uid: String?) -> Bool { uid == studyRootFind || uid == studyRootMove }

    @objc public static func isPDF(_ uid: String?) -> Bool { uid == pdfStorage }
}
