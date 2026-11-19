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

// The initializer of the plugin SDK of Horos and OsiriX that made an attribute
// over the bytes of its value in a buffer of the caller, which it read when
// the values were asked. The model keeps values, not a pointer: the bytes are
// read here, while the caller's buffer is certainly there. A plugin built for
// that SDK still sends it.
extension DCMAttribute {
    /// The value representations whose value is bytes, not text.
    private static let binary: Set<String> = ["OB", "OW", "OF", "OD", "OL", "UN", "SQ", "US", "SS", "UL", "SL", "FL", "FD", "AT"]

    @objc(initWithAttributeTag:vr:length:dataPtr:)
    public convenience init(attributeTag tag: DICOMAttributeTag?, vr: String?, length: Int, dataPointer: UnsafeMutablePointer<UInt8>?) {
        let representation = vr ?? tag?.vr
        let values = NSMutableArray()
        if let dataPointer, length > 0 {
            let data = Data(bytes: dataPointer, count: length)
            if Self.binary.contains(representation ?? "UN") {
                values.add(data as NSData)
            } else {
                // Text: the values are separated by a backslash and padded with a space or a NUL.
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
                for value in text.components(separatedBy: "\\") { values.add(value) }
            }
        }
        self.init(attributeTag: tag, vr: representation, values: values)
    }
}
