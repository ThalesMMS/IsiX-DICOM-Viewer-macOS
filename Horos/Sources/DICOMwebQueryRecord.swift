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

import Foundation

/// One QIDO-RS result, a DICOM JSON object (PS3.18 F.2), read as the string
/// values a DICOM dataset takes. The query node puts them into its DCMTK
/// dataset; reading the JSON here keeps that step free of JSON rules.
@objc(HorosDICOMwebQueryRecord)
final class DICOMwebQueryRecord: NSObject {
    /// The values of each attribute, in order, keyed by its tag as
    /// (group << 16) | element.
    ///
    /// - A JSON null is an empty value that keeps its position, so the values
    ///   after it stay where the node put them.
    /// - A person name is its first component group with text: Alphabetic,
    ///   then Ideographic, then Phonetic. A null group counts as absent.
    /// - A number, as IS and DS may be sent, is its decimal text.
    /// - Sequences, bulk data, attributes without a Value array and attributes
    ///   whose every value is empty are left out, as a missing attribute.
    @objc(stringValuesOfRecord:)
    static func stringValues(of record: [String: Any]) -> [NSNumber: [String]] {
        var result: [NSNumber: [String]] = [:]
        for (key, attribute) in record {
            guard let tag = tag(key),
                  let attribute = attribute as? [String: Any],
                  (attribute["vr"] as? String) != "SQ",
                  let values = attribute["Value"] as? [Any] else { continue }
            let strings = values.map(string)
            if strings.contains(where: { !$0.isEmpty }) {
                result[NSNumber(value: tag)] = strings
            }
        }
        return result
    }

    /// The tag of an attribute keyword such as "00100010": eight hexadecimal digits.
    private static func tag(_ key: String) -> UInt32? {
        let hexadecimal = { (byte: UInt8) in (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }
        guard key.utf8.count == 8, key.utf8.allSatisfy(hexadecimal) else { return nil }
        return UInt32(key, radix: 16)
    }

    private static func string(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let name = value as? [String: Any] {
            for group in ["Alphabetic", "Ideographic", "Phonetic"] {
                if let text = name[group] as? String, !text.isEmpty { return text }
            }
            return ""
        }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
}
