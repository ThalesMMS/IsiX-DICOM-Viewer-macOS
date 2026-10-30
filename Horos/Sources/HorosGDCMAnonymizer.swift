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
import IsiXDICOMFile

/// The selected-field anonymization of one staged file. The rules are
/// SelectedFieldAnonymization (IsiXDICOMFile); DCMTK reads, changes, writes
/// and verifies the file in the adapter (IsiXDCMTKAnonymizationFile). The
/// class name and selector stay for the Swift and plugin callers.
@objc @implementation extension HorosGDCMAnonymizer {

    @objc(anonymizeStagedFile:withTags:failure:)
    class func anonymizeStagedFile(_ f: String, tags: [Any],
                                   failure: (String, String?) -> Void) -> String? {
        typealias Rules = SelectedFieldAnonymization
        guard let file = IsiXDCMTKAnonymizationFile(stagedPath: f) else {
            failure(NSLocalizedString("An input file is not a readable DICOM file.", comment: ""), nil)
            return nil
        }
        // A DICOMDIR identifies its class in the file meta. Other legacy
        // objects without a dataset identity are refused instead of inferring
        // one from Modality.
        var storage = file.datasetSOPClassUID
        var directory = false
        if storage == nil {
            let meta = file.metaStorageSOPClassUID
            directory = meta == Rules.directoryStorageClass
            storage = meta
        }
        let instance = directory ? file.metaStorageSOPInstanceUID : file.datasetSOPInstanceUID
        guard Rules.isSupportedStorage(storage), let storage, let instance else {
            failure(NSLocalizedString("An input DICOM storage type or SOP identity is not supported for anonymization.",
                                      comment: ""), nil)
            return nil
        }
        guard file.canKeepTransferSyntax else {
            failure(NSLocalizedString("The input DICOM transfer syntax cannot be preserved for anonymization.",
                                      comment: ""), nil)
            return nil
        }
        guard file.recordShape() else {
            failure(NSLocalizedString("An input file is truncated or no longer readable.", comment: ""), nil)
            return nil
        }

        let declaration = [UInt8](file.characterSet)
        // The host's chosen encoding for an absent or empty declaration.
        let fallback = String.Encoding(rawValue: NSString.encoding(forDICOMCharacterSet: ""))
        var replacements: [(tag: UInt32, value: Data)] = []
        for item in tags {
            let entry = item as! NSArray
            let tag = anonymizationTagNumber(entry[0])
            let creator = Rules.isPrivateCreator(tag)
            var value = Data()
            var encoded = true
            if entry.count > 1 {
                // -description of the value; an NSString is its own, kept as
                // UTF-16 units, unpaired surrogates included.
                let text = (entry[1] as? NSString) ?? (((entry[1] as AnyObject).description ?? "") as NSString)
                let element = file.element(forTag: tag)
                let facts = anonymizationFacts(element)
                encoded = anonymizationText(text, valueRepresentation: Rules.encodingValueRepresentation(facts),
                                 privateCreator: creator, declaration: declaration, fallback: fallback,
                                 file: file, into: &value)
            }
            if !encoded || (tag == Rules.specificCharacterSetTag && [UInt8](value) != declaration) {
                failure(NSLocalizedString("A replacement value cannot be represented in the input file's character set.",
                                          comment: ""), Rules.tagText(tag))
                continue
            }
            replacements.append((tag, value))
        }
        for replacement in replacements {
            let facts = anonymizationFacts(file.element(forTag: replacement.tag))
            let decided = Rules.replacement(for: replacement.tag, valueIsEmpty: replacement.value.isEmpty, facts: facts)
            if decided == .refuse || !file.apply(anonymizationReplacement(decided), toTag: replacement.tag,
                                                 value: replacement.value) {
                failure(NSLocalizedString("The DICOM anonymizer cannot replace one or more selected fields.", comment: ""),
                        Rules.tagText(replacement.tag))
            }
        }

        // saveFile must not generate an identity for missing or emptied SOP UIDs.
        var finalStorage = storage, finalInstance = instance
        if !directory {
            guard let changedStorage = file.datasetSOPClassUID, Rules.isSupportedStorage(changedStorage),
                  let changedInstance = file.datasetSOPInstanceUID else {
                failure(NSLocalizedString("The selected fields leave an unsupported DICOM SOP identity.", comment: ""), nil)
                return nil
            }
            finalStorage = changedStorage
            finalInstance = changedInstance
        }
        guard file.recordShape() else {
            failure(NSLocalizedString("The staged input is no longer readable for anonymization.", comment: ""), nil)
            return nil
        }
        let folder = (f as NSString).deletingLastPathComponent as NSString
        let output = folder.appendingPathComponent(Rules.outputName(for: (f as NSString).lastPathComponent))
        guard file.writeVerifiedCopy(toPath: output, temporaryTemplate: Rules.temporaryNameTemplate,
                                     storageClass: finalStorage, instance: finalInstance) else {
            failure(NSLocalizedString("An anonymized file could not be written. Check available space and destination permissions.",
                                      comment: ""), nil)
            return nil
        }
        return output
    }
}

// MARK: - Helpers

/// The group and element of a tag object (an IsiXDICOMAttributeTag, or any object
/// answering -group and -element), as (group << 16) | element.
fileprivate func anonymizationTagNumber(_ tag: Any) -> UInt32 {
    let object = tag as AnyObject
    let group = (object.value(forKey: "group") as? NSNumber)?.uint32Value ?? 0
    let element = (object.value(forKey: "element") as? NSNumber)?.uint32Value ?? 0
    return (group & 0xffff) << 16 | (element & 0xffff)
}

fileprivate func anonymizationFacts(_ element: IsiXDCMTKSelectedElement) -> SelectedFieldAnonymization.ElementFacts {
    SelectedFieldAnonymization.ElementFacts(exists: element.exists, isPixelData: element.isPixelData,
                                            valueRepresentation: element.valueRepresentation,
                                            dictionaryValueRepresentation: element.dictionaryValueRepresentation,
                                            catalogPolicy: element.catalogPolicy)
}

fileprivate func anonymizationReplacement(
    _ replacement: SelectedFieldAnonymization.Replacement) -> IsiXDCMTKSelectedReplacement {
    switch replacement {
    case .clearExisting, .refuse: return .clearExisting
    case .emptyPixelData: return .emptyPixelData
    case .insertEmpty: return .insertEmpty
    case .insertEmptySequence: return .insertEmptySequence
    case .putIntoExisting: return .putIntoExisting
    case .insertText: return .insertText
    }
}

/// `string` as the bytes written for the field, or false when it cannot be
/// written faithfully in the file's declared repertoire.
fileprivate func anonymizationText(_ string: NSString, valueRepresentation: String, privateCreator: Bool,
                                   declaration: [UInt8], fallback: String.Encoding,
                                   file: IsiXDCMTKAnonymizationFile, into value: inout Data) -> Bool {
    let utf8 = string.data(using: String.Encoding.utf8.rawValue, allowLossyConversion: false).map { [UInt8]($0) }
    let units = (0..<string.length).lazy.map { string.character(at: $0) }
    let plan = SelectedFieldAnonymization.textPlan(utf8: utf8, utf16: units,
                                                   valueRepresentation: valueRepresentation,
                                                   privateCreator: privateCreator, declaration: declaration,
                                                   isASCII: string.canBeConverted(to: String.Encoding.ascii.rawValue))
    switch plan {
    case .refuse:
        return false
    case .empty:
        value = Data()
        return true
    case .foundation(let useFallback):
        let encoding = useFallback ? fallback : .ascii
        guard let bytes = string.data(using: encoding.rawValue, allowLossyConversion: false),
              let roundTrip = NSString(data: bytes, encoding: encoding.rawValue), roundTrip.isEqual(string),
              !bytes.contains(0), !bytes.contains(0x1b) else { return false }
        value = bytes
        return true
    case .declared(let codeExtensions):
        guard let utf8, let encoded = file.encodeUTF8(Data(utf8), valueRepresentation: valueRepresentation,
                                                      codeExtensions: codeExtensions) else { return false }
        value = encoded
        return true
    }
}
