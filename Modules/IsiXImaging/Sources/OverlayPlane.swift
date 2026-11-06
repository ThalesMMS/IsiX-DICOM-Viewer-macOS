/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// One overlay plane of repeating group 6000-601E: a bitmap drawn over the
/// image (PS 3.3 C.9.2).
public struct OverlayPlane: Equatable, Sendable {
    /// Sixteen planes, 6000 to 601E in steps of two.
    public static let maximumCount = 16

    /// The object carries Overlay Data for this plane.
    public var isOn = false
    public var rows: Int32 = 0
    public var columns: Int32 = 0
    /// The first character of Overlay Type: G (graphics) or R (ROI).
    public var type: Int32 = 0
    /// Overlay Origin, zero-based: column then row.
    public var origin: [Int32] = [0, 0]
    public var bitsAllocated: Int32 = 0
    public var bitPosition: Int32 = 0
    /// One byte a pixel, 0xFF where the overlay is set. Set when the plane's
    /// data was unpacked in this read; nil then means the bitmap could not be
    /// made, and the previous one is dropped all the same.
    public var unpackedReplacement: [UInt8]??

    public init() {}

    /// The tag key of an element of plane `index`, as the parsed object files
    /// it (`6002,0010`). The keys are made once: the reading asks for them on
    /// every image, and formatting them each time cost more than the reading.
    static func key(_ index: Int, _ element: String) -> String {
        keys[index][element] ?? String(format: "%4X,%@", 0x6000 + index * 2, element)
    }

    private static let keys: [[String: String]] = (0..<maximumCount).map { index in
        let group = String(format: "%4X", 0x6000 + index * 2)
        var keys: [String: String] = [:]
        for element in ["3000", "0010", "0011", "0040", "0050", "0100", "0102"] {
            keys[element] = group + "," + element
        }
        return keys
    }

    /// The bitmap of a plane of this size, all clear. The size was an int
    /// product: one that wraps negative asked calloc for more memory than
    /// there is, and got none.
    static func clearBitmap(rows: Int32, columns: Int32) -> [UInt8]? {
        let product = rows &* columns
        guard product >= 0 else { return nil }
        return [UInt8](repeating: 0, count: Int(product))
    }

    /// Unpacks one-bit overlay data into a clear bitmap: each little-endian
    /// 16-bit word holds sixteen pixels, lowest bit first. Words the data does
    /// not have are read as zero; the Objective-C loop read past the end of
    /// the data instead.
    static func unpack(_ data: Data, into pixels: inout [UInt8], rows: Int32, columns: Int32) {
        let words = Int((rows &* columns) / 16)
        guard words > 0 else { return }
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for word in 0..<words {
                let low = 2 * word < bytes.count ? UInt16(bytes[2 * word]) : 0
                let high = 2 * word + 1 < bytes.count ? UInt16(bytes[2 * word + 1]) : 0
                var octet = low | high << 8
                for bit in 0..<16 {
                    if octet & 1 != 0 { pixels[word * 16 + bit] = 0xFF }
                    octet >>= 1
                }
            }
        }
    }
}

extension ImageAttributeReader {
    /// Group 6000: the planes the object carries. What one plane raises is
    /// recorded and that plane is left as far as it was read; the others are
    /// still read.
    public mutating func readOverlays(from dataset: DICOMAttributeSource) {
        for index in 0..<OverlayPlane.maximumCount {
            attributes.overlays[index].isOn = false
            attributes.overlays[index].unpackedReplacement = nil
        }
        for index in 0..<OverlayPlane.maximumCount {
            guard dataset.attributeArray(forKey: OverlayPlane.key(index, "3000")) != nil else { continue }
            attributes.overlays[index].isOn = true
            do {
                try readOverlay(index, from: dataset)
            } catch let exception as AttributeReadException {
                overlayExceptions.append(exception)
            } catch {
                overlayExceptions.append(AttributeReadException(name: NSExceptionName.genericException.rawValue,
                                                                reason: String(describing: error)))
            }
        }
    }

    private mutating func readOverlay(_ index: Int, from dataset: DICOMAttributeSource) throws {
        func value(_ element: String) -> Any? {
            dataset.attributeValue(forKey: OverlayPlane.key(index, element))
        }

        if let rows = value("0010") as? NSNumber { attributes.overlays[index].rows = rows.int32Value }
        if let columns = value("0011") as? NSNumber { attributes.overlays[index].columns = columns.int32Value }
        if let type = value("0040"), ParsedValue.object(type) is NSString {
            attributes.overlays[index].type = try ParsedValue.firstCharacter(type)
        }
        // Overlay Origin: row then column, one-based (PS 3.3 C.9.2.1). Its key
        // was once written without the comma, so it was never found and every
        // overlay was drawn from the image's corner.
        if let values = dataset.attributeArray(forKey: OverlayPlane.key(index, "0050")), values.count >= 2 {
            attributes.overlays[index].origin[0] = try ParsedValue.int(values[1]) - 1
            attributes.overlays[index].origin[1] = try ParsedValue.int(values[0]) - 1
        }
        if let bits = value("0100") as? NSNumber { attributes.overlays[index].bitsAllocated = bits.int32Value }
        if let position = value("0102") as? NSNumber { attributes.overlays[index].bitPosition = position.int32Value }

        let plane = attributes.overlays[index]
        if let data = value("3000"), plane.bitsAllocated == 1 && plane.bitPosition == 0 {
            // The previous bitmap is dropped and a clear one made before the
            // data is asked for its bytes, as it always was.
            var bitmap = OverlayPlane.clearBitmap(rows: plane.rows, columns: plane.columns)
            attributes.overlays[index].unpackedReplacement = .some(bitmap)
            guard bitmap != nil else { return }
            guard let bytes = ParsedValue.object(data) as? NSData else {
                throw AttributeReadException.unrecognizedSelector("bytes", sentTo: data as AnyObject)
            }
            OverlayPlane.unpack(bytes as Data, into: &bitmap!, rows: plane.rows, columns: plane.columns)
            attributes.overlays[index].unpackedReplacement = .some(bitmap)
        }
    }
}
