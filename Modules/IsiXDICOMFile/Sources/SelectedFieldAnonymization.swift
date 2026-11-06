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

import Foundation

/// The rules of the selected-field anonymization, which replaces the tags the
/// user chose in a staged copy of each file and refuses whatever it cannot do
/// faithfully: the storage classes it accepts, what each selected tag becomes,
/// and the text it will not write. Reading the file, the frozen catalog of
/// public fields and the character set conversions stay with DCMTK, in the
/// app's adapter; the app applies these rules over it.
public enum SelectedFieldAnonymization {

    /// The Media Storage Directory class, which a DICOMDIR names in its file
    /// meta rather than in its dataset.
    public static let directoryStorageClass = "1.2.840.10008.1.3.10"

    /// The selected-field storage gate, retired and private classes included.
    /// It is a compatibility list, not an IOD validator nor a confidentiality
    /// profile.
    public static let supportedStorageClasses: Set<String> = [
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
    ]

    public static func isSupportedStorage(_ uid: String?) -> Bool {
        guard let uid else { return false }
        return supportedStorageClasses.contains(uid)
    }

    /// The Specific Character Set, (0008,0005).
    public static let specificCharacterSetTag: UInt32 = 0x0008_0005

    /// A private group: odd, and none of the groups DICOM forbids (1, 3, 5, 7,
    /// FFFF), as DCMTK's DcmTagKey::isPrivate says.
    public static func isPrivate(group: UInt16) -> Bool {
        group & 1 == 1 && ![1, 3, 5, 7, 0xffff].contains(group)
    }

    /// A private creator: (gggg,0010) to (gggg,00FF) of a private group.
    public static func isPrivateCreator(group: UInt16, element: UInt16) -> Bool {
        isPrivate(group: group) && element >= 0x10 && element <= 0xff
    }

    public static func isPrivateCreator(_ tag: UInt32) -> Bool {
        isPrivateCreator(group: UInt16(tag >> 16), element: UInt16(tag & 0xffff))
    }

    /// "(GGGG,EEEE)", as a field failure names the tag.
    public static func tagText(_ tag: UInt32) -> String {
        String(format: "(%04X,%04X)", tag >> 16, tag & 0xffff)
    }

    /// The name the anonymized copy of `name` is committed under, beside it.
    public static func outputName(for name: String) -> String { "anon_" + name }

    /// The template of the temporary file the copy is written to first.
    public static let temporaryNameTemplate = ".horos-anonymized-XXXXXX"

    /// The value representations of text, which a selected field may be given.
    public static let textualValueRepresentations: Set<String> = [
        "AE", "AS", "CS", "DA", "DS", "DT", "IS", "LO", "LT", "PN", "SH", "ST", "TM", "UC", "UI", "UR", "UT",
    ]

    /// The value representations the Specific Character Set applies to.
    public static let characterSetValueRepresentations: Set<String> = ["LO", "LT", "PN", "SH", "ST", "UC", "UT"]

    /// What the file says of a selected tag at the root of its dataset, and
    /// what the catalog says of it.
    public struct ElementFacts: Equatable, Sendable {
        /// The dataset's root has the element.
        public var exists: Bool
        /// The element is pixel data, native or encapsulated.
        public var isPixelData: Bool
        /// The element's value representation, as DCMTK names it.
        public var valueRepresentation: String
        /// The dictionary's value representation for the tag.
        public var dictionaryValueRepresentation: String
        /// The frozen catalog's policy for a public tag: 0 not selectable,
        /// 1 text, 2 empty only, 3 an empty sequence only.
        public var catalogPolicy: Int

        public init(exists: Bool, isPixelData: Bool, valueRepresentation: String,
                    dictionaryValueRepresentation: String, catalogPolicy: Int) {
            self.exists = exists
            self.isPixelData = isPixelData
            self.valueRepresentation = valueRepresentation
            self.dictionaryValueRepresentation = dictionaryValueRepresentation
            self.catalogPolicy = catalogPolicy
        }
    }

    /// What becomes of a selected tag.
    public enum Replacement: Equatable, Sendable {
        /// Not replaced: the batch fails for this field.
        case refuse
        /// The existing element is emptied (private sequences included; empty
        /// is not removal).
        case clearExisting
        /// The existing pixel data becomes a truly empty one, in the encoding
        /// it had.
        case emptyPixelData
        /// An empty element is inserted with the dictionary's representation.
        case insertEmpty
        /// The selected sequence stays, with no items.
        case insertEmptySequence
        /// The existing element takes the text.
        case putIntoExisting
        /// A new element is inserted with the text; a private creator as LO.
        case insertText
    }

    /// The value representation a selected tag's text is encoded for: the
    /// element's own, or the dictionary's when the file does not have it.
    public static func encodingValueRepresentation(_ facts: ElementFacts) -> String {
        facts.exists ? facts.valueRepresentation : facts.dictionaryValueRepresentation
    }

    /// What replacing `tag` with a value that is empty or not does.
    public static func replacement(for tag: UInt32, valueIsEmpty: Bool, facts: ElementFacts) -> Replacement {
        let group = UInt16(tag >> 16), element = UInt16(tag & 0xffff)
        if group < 8 { return .refuse }
        let creator = isPrivateCreator(group: group, element: element)
        if isPrivate(group: group) && !creator {
            return facts.exists && valueIsEmpty ? .clearExisting : .refuse
        }
        let policy = creator ? 1 : facts.catalogPolicy
        if policy == 0 { return .refuse }
        let dictionaryVR = creator ? "LO" : facts.dictionaryValueRepresentation
        if policy == 3 {
            // A string cannot describe sequence items.
            return valueIsEmpty ? .insertEmptySequence : .refuse
        }
        if policy == 2 {
            if !valueIsEmpty { return .refuse }
            if facts.exists { return facts.isPixelData ? .emptyPixelData : .clearExisting }
            return dictionaryVR != "??" && dictionaryVR != "UN" && !dictionaryVR.isEmpty ? .insertEmpty : .refuse
        }
        if !textualValueRepresentations.contains(dictionaryVR) ||
            (facts.exists && !textualValueRepresentations.contains(facts.valueRepresentation)) {
            return .refuse
        }
        return facts.exists ? .putIntoExisting : .insertText
    }

    /// How a replacement text is to be encoded before any character set is
    /// consulted.
    public enum TextPlan: Equatable, Sendable {
        /// Refused: it cannot be written faithfully.
        case refuse
        /// The empty value.
        case empty
        /// In a single-byte encoding the host chose (`fallback`) or in ASCII,
        /// checked by converting it back.
        case foundation(useFallback: Bool)
        /// Through the declared character set, with DCMTK.
        case declared(codeExtensions: Bool)
    }

    /// Whether the declaration names more than one repertoire or ISO 2022
    /// code extensions: DCMTK decodes those but does not encode into them.
    public static func usesCodeExtensions(_ declaration: [UInt8]) -> Bool {
        declaration.contains(UInt8(ascii: "\\")) || declaration.containsSequence(Array("ISO 2022".utf8))
    }

    /// The plan for `text`, given as UTF-8 (nil when it has none) and as its
    /// UTF-16 units, for a value of representation `valueRepresentation` in a
    /// file declaring `declaration` (its bytes, empty when absent).
    public static func textPlan(utf8: [UInt8]?, utf16: some Collection<UInt16>, valueRepresentation: String,
                                privateCreator: Bool, declaration: [UInt8], isASCII: Bool) -> TextPlan {
        guard let utf8 else { return .refuse }
        if utf8.isEmpty { return .empty }
        // DCMTK takes a C string: a NUL would cut the value. A user-supplied
        // ESC must not become a repertoire-switch instruction.
        if utf8.contains(0) || utf8.contains(0x1b) { return .refuse }
        // C1 controls.
        if utf16.contains(where: { $0 >= 0x80 && $0 <= 0x9f }) { return .refuse }
        let affected = !privateCreator && characterSetValueRepresentations.contains(valueRepresentation)
        if !affected || declaration.isEmpty {
            // The host's chosen default for an absent or empty declaration;
            // the representations outside the character set and private
            // creators use ASCII.
            return .foundation(useFallback: affected)
        }
        let extensions = usesCodeExtensions(declaration)
        // With code extensions only ASCII is written, which needs no escape.
        if extensions && !isASCII { return .refuse }
        return .declared(codeExtensions: extensions)
    }

    /// The characters DCMTK treats as delimiters when it converts a value of
    /// `valueRepresentation`.
    public static func conversionDelimiters(_ valueRepresentation: String) -> String {
        switch valueRepresentation {
        case "PN": return "\\^="
        case "ST", "LT", "UT": return ""
        default: return "\\"
        }
    }
}

extension Array where Element == UInt8 {
    func containsSequence(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, count >= needle.count else { return needle.isEmpty }
        for start in 0...(count - needle.count) where self[start..<start + needle.count].elementsEqual(needle) {
            return true
        }
        return false
    }
}
