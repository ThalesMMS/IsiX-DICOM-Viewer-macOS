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
import IsiXDICOMDataset
import IsiXDICOMFile

// A Softcopy Presentation State file, read with the DICOM parser (DCMObject)
// into the dictionary the document is built from: every named attribute, its
// values, and a sequence as the dictionaries of its items. Pixel Data is not
// decoded.
extension GSPSDocument {
    @objc(documentWithContentsOfFile:)
    public static func document(contentsOfFile path: String?) -> GSPSDocument? {
        guard let dictionary = dictionary(contentsOfFile: path), !dictionary.isEmpty else { return nil }
        return GSPSDocument.document(dictionary: dictionary)
    }

    @objc(dictionaryWithContentsOfFile:)
    public static func dictionary(contentsOfFile path: String?) -> [String: Any]? {
        guard let path, !path.isEmpty, let object = DCMObject.object(contentsOfFile: path) else { return nil }
        return dictionary(of: object)
    }

    private static func dictionary(of object: DCMObject) -> [String: Any] {
        var dictionary: [String: Any] = [:]
        for case let attribute as DCMAttribute in (object.attributes as NSDictionary? ?? [:]).allValues {
            guard let name = attribute.attrTag?.name, !name.isEmpty, name != "Unknown" else { continue }
            dictionary[name] = value(of: attribute)
        }
        return dictionary
    }

    private static func value(of attribute: DCMAttribute) -> Any {
        if let sequence = attribute as? DCMSequenceAttribute {
            return (sequence.sequence ?? []).compactMap { $0 as? DCMObject }.map { dictionary(of: $0) }
        }
        return attribute.values ?? NSMutableArray()
    }
}
