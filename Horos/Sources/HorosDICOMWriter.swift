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
import IsiXDICOMFile

/// The DICOM object HorosDICOMWriter.h declares: attributes set by name, kept
/// here until the object is written, then written by DCMTK through the adapter
/// (IsiXDCMTKFile) in one pass. Text is written in UTF-8, and Specific
/// Character Set says ISO_IR 192.
@objc @implementation extension HorosDICOMWriter {

    /// The values set for each name, the binary values with their VR, and the
    /// empty sequences.
    final var horos_values: [String: NSArray] = [:]
    final var horos_data: [String: (data: Data, vr: String)] = [:]
    final var horos_sequences: Set<String> = []

    @objc(setValues:forName:)
    func setValues(_ values: [Any], forName name: String) -> Bool {
        guard Self.tag(named: name) != nil else { return false }
        horos_values[name] = NSArray(array: values)
        horos_data[name] = nil
        return true
    }

    @objc(valuesForName:)
    func values(forName name: String) -> [Any]? {
        horos_values[name] as? [Any]
    }

    @objc(setData:forName:vr:)
    func setData(_ data: Data, forName name: String, vr: String) -> Bool {
        guard Self.tag(named: name) != nil else { return false }
        horos_data[name] = (data, vr)
        horos_values[name] = nil
        return true
    }

    @objc(setEmptySequenceForName:)
    func setEmptySequenceForName(_ name: String) -> Bool {
        guard Self.tag(named: name) != nil else { return false }
        horos_sequences.insert(name)
        return true
    }

    @objc(writeToFile:transferSyntax:)
    func write(toFile path: String, transferSyntax transferSyntaxUID: String) -> Bool {
        let file = IsiXDCMTKFile()
        let dataset = file.dataset
        _ = try? dataset.putString("ISO_IR 192", forTag: Self.specificCharacterSet)

        for (name, values) in horos_values {
            guard let tag = Self.tag(named: name), tag != Self.specificCharacterSet, tag >> 16 != 0x0002 else {
                continue
            }
            let vr = IsiXDCMTKDictionary.valueRepresentation(forTag: tag)
            let text = values.map { Self.text(of: $0, vr: vr) }.joined(separator: "\\")
            do {
                try text.withCString { try dataset.putString($0, forTag: tag) }
            } catch {
                NSLog("HorosDICOMWriter: %@ not written: %@", name, Self.conditionText(of: error))
                return false
            }
        }
        for name in horos_sequences {
            if let tag = Self.tag(named: name) { _ = try? dataset.insertEmptySequence(forTag: tag) }
        }
        for (name, value) in horos_data {
            guard let tag = Self.tag(named: name) else { continue }
            do {
                if value.vr == "OW" {
                    try dataset.putWords(value.data, forTag: tag)
                } else {
                    try dataset.putBytes(value.data, forTag: tag)
                }
            } catch {
                NSLog("HorosDICOMWriter: %@ not written: %@", name, Self.conditionText(of: error))
                return false
            }
        }

        // A syntax DCMTK does not know is written as Explicit VR Little Endian;
        // the file goes beside the destination and is moved over it, as the DCM
        // writer did atomically.
        let syntax = HorosDICOMTransferSyntaxes.properties(forTransferSyntax: transferSyntaxUID) != nil
            ? transferSyntaxUID : "1.2.840.10008.1.2.1"
        let temporary = IsiXDCMTKFile.temporaryPath(beside: path)
        do {
            try file.write(toPath: temporary, transferSyntax: syntax, removingPadding: true)
        } catch {
            NSLog("HorosDICOMWriter: %@ not written: %@", (path as NSString).lastPathComponent, Self.conditionText(of: error))
            try? FileManager.default.removeItem(atPath: temporary)
            return false
        }
        if rename(temporary, path) != 0 {
            try? FileManager.default.removeItem(atPath: temporary)
            return false
        }
        return true
    }

    // MARK: - Values

    /// Specific Character Set (0008,0005), which the writer sets itself.
    static let specificCharacterSet: UInt32 = 0x0008_0005

    /// The tag DICOMAttributeTag gives a name, as (group << 16) | element.
    static func tag(named name: String) -> UInt32? {
        guard let tag = DICOMAttributeTag.tag(withName: name) else { return nil }
        return (UInt32(truncatingIfNeeded: tag.group) & 0xffff) << 16 | (UInt32(truncatingIfNeeded: tag.element) & 0xffff)
    }

    /// A value as the element's VR writes it: a date in DA, TM or DT form, a
    /// number's text, a string as it is.
    static func text(of value: Any, vr: String) -> String {
        if let date = value as? DICOMCalendarDate {
            switch vr {
            case "DA": return date.dateString()
            case "TM": return date.timeString()
            case "DT": return date.dateTimeString(false)
            default: return date.description
            }
        }
        if let number = value as? NSNumber { return number.stringValue }
        if let text = value as? String { return text }
        return (value as AnyObject).description ?? ""
    }

    /// The text of the condition an adapter error carries.
    static func conditionText(of error: Error) -> String {
        ((error as NSError).userInfo[IsiXDCMTKConditionTextKey] as? String) ?? error.localizedDescription
    }
}

/// A Part 10 file written again in another transfer syntax, for a DICOMweb
/// node whose Send Syntax is not "As stored".
@objc(Transcoding) @implementation extension HorosDICOMWriter {

    @objc(transcodeFileAtPath:toPath:transferSyntax:error:)
    class func transcodeFile(atPath source: String, toPath destination: String, transferSyntax transferSyntaxUID: String) throws {
        // DCMHighQuality for a lossy syntax, DCMLosslessQuality otherwise.
        let quality: Int32 = IsiXDCMTKDataset.isLossyTransferSyntax(transferSyntaxUID) ? 1 : 0
        do {
            try IsiXDCMTKFile.transcodeFile(atPath: source, toPath: destination, transferSyntax: transferSyntaxUID,
                                            quality: quality)
        } catch {
            let text = conditionText(of: error)
            NSLog("HorosDICOMWriter: %@ not converted to %@: %@", (source as NSString).lastPathComponent, transferSyntaxUID, text)
            throw NSError(domain: "HorosDICOMTranscoding", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The file could not be written in \(transferSyntaxUID): \(text)"])
        }
    }
}
