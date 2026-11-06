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
import IsiXDICOMNetwork

/// A C-FIND identifier written from the keys IsiXDICOMNetwork makes
/// (PluginQueryKeys.Key), and the values of a match read back by keyword:
/// the plugin API's C-FIND and the Modality Worklist window ask through it.
///
/// A key of the scheduled procedure step goes in the first item of the
/// Scheduled Procedure Step Sequence, as the Modality Worklist model has it.
/// An empty value asks for the attribute back without matching on it.
enum CFindKeysCoding {
    /// The identifier of `keys`, declared ISO_IR 192 when a filter is not ASCII.
    static func identifier(for keys: [PluginQueryKeys.Key]) throws -> IsiXDCMTKDataset {
        let identifier = IsiXDCMTKDataset()
        let sequence = PluginQueryKeys.scheduledProcedureStepSequence.rawValue
        if PluginQueryKeys.needsUTF8(keys) {
            try identifier.putValue(Data("ISO_IR 192".utf8), forTag: DICOMTag.specificCharacterSet.rawValue)
        }
        for key in keys {
            let value = key.value.isEmpty ? nil : Data(key.value.utf8)
            if key.inScheduledStep {
                try identifier.putValue(value, forTag: key.tag.rawValue, inItemOfSequence: sequence)
            } else if let value {
                try identifier.putValue(value, forTag: key.tag.rawValue)
            } else {
                try identifier.insertEmptyElement(withTag: key.tag.rawValue)
            }
        }
        return identifier
    }

    /// The non-empty values of `keys` in `match`, by keyword, decoded with
    /// `encoding`; a key of the scheduled step is read from its first item.
    static func values(of match: IsiXDCMTKDataset, keys: [PluginQueryKeys.Key], encoding: String.Encoding) -> [String: String] {
        let sequence = PluginQueryKeys.scheduledProcedureStepSequence.rawValue
        var values: [String: String] = [:]
        for key in keys {
            let raw = key.inScheduledStep ? match.stringValues(forTag: key.tag.rawValue, inItemsOfSequence: sequence).first
                : match.stringArrayValue(forTag: key.tag.rawValue)
            guard let raw else { continue }
            let text = String(data: raw, encoding: encoding) ?? String(decoding: raw, as: UTF8.self)
            if !text.isEmpty { values[key.keyword] = text }
        }
        return values
    }

    /// The first character set a match's Specific Character Set names, nil
    /// when it names none: then the default repertoire applies.
    static func characterSet(of match: IsiXDCMTKDataset) -> String? {
        guard let raw = match.stringArrayValue(forTag: DICOMTag.specificCharacterSet.rawValue) else { return nil }
        return String(decoding: raw, as: UTF8.self).components(separatedBy: "\\")
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }
}
