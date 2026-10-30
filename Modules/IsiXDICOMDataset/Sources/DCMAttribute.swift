/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import IsiXDICOMFile

// The value representations, as the two characters of the VR read as a
// big-endian 16-bit number ("AE" is 0x4145).
public let DCM_AE: Int32 = 0x4145 // Application Entity, 16 bytes max
public let DCM_AS: Int32 = 0x4153 // Age String, nnnD, nnnW, nnnM or nnnY
public let DCM_AT: Int32 = 0x4154 // Attribute Tag, two 16-bit unsigned integers
public let DCM_CS: Int32 = 0x4353 // Code String, 16 bytes max
public let DCM_DA: Int32 = 0x4441 // Date, YYYYMMDD
public let DCM_DS: Int32 = 0x4453 // Decimal String, 16 bytes max
public let DCM_DT: Int32 = 0x4454 // Date Time, YYYYMMDDHHMMSS.FFFFFF&ZZZZ
public let DCM_FD: Int32 = 0x4644 // Floating Point Double, 8 bytes
public let DCM_FL: Int32 = 0x464C // Floating Point Single, 4 bytes
public let DCM_IS: Int32 = 0x4953 // Integer String, 12 bytes max
public let DCM_LO: Int32 = 0x4C4F // Long String, 64 characters max
public let DCM_LT: Int32 = 0x4C54 // Long Text, 10240 characters max
public let DCM_PN: Int32 = 0x504E // Person Name
public let DCM_SH: Int32 = 0x5348 // Short String
public let DCM_SL: Int32 = 0x534C // Signed Long
public let DCM_SS: Int32 = 0x5353 // Signed Short
public let DCM_ST: Int32 = 0x5354 // Short Text, 1024 characters max
public let DCM_TM: Int32 = 0x544D // Time
public let DCM_UI: Int32 = 0x5549 // Unique Identifier
public let DCM_UL: Int32 = 0x554C // Unsigned Long
public let DCM_US: Int32 = 0x5553 // Unsigned Short
public let DCM_UT: Int32 = 0x5554 // Unlimited Text
public let DCM_OB: Int32 = 0x4F42 // Other Byte, not sensitive to byte order
public let DCM_OW: Int32 = 0x4F57 // Other Word, 16-bit words
public let DCM_OF: Int32 = 0x4F46 // Other Float
public let DCM_SQ: Int32 = 0x5351 // Sequence of Items
public let DCM_UN: Int32 = 0x554E // Unknown
public let DCM_QQ: Int32 = 0x3F3F

/// The VR code of `vr`: its first two bytes, big-endian; 0 when it has fewer.
func dcmVRCode(_ vr: String?) -> Int32 {
    guard let bytes = vr?.utf8, bytes.count >= 2 else { return 0 }
    var characters = bytes.makeIterator()
    let first = Int32(Int8(bitPattern: characters.next()!))
    let second = Int32(Int8(bitPattern: characters.next()!))
    return first << 8 | second
}

/// One element of a dataset: its tag, its value representation and its
/// values - NSString, NSNumber, NSData or IsiXDICOMCalendarDate, as the reader
/// made them or the caller set them.
@objc(IsiXDCMAttribute)
public class DCMAttribute: NSObject, NSCopying {

    @objc public private(set) var attrTag: DICOMAttributeTag!
    @objc public var values: NSMutableArray!
    @objc public internal(set) var vr: String!
    @objc public var characterSet: DICOMCharacterSet!

    // MARK: Making one

    @objc(attributeWithAttribute:)
    public class func attribute(with attribute: DCMAttribute) -> DCMAttribute {
        DCMAttribute(attribute: attribute)
    }

    @objc(attributeWithAttributeTag:)
    public class func attribute(with tag: DICOMAttributeTag?) -> DCMAttribute {
        DCMAttribute(attributeTag: tag)
    }

    @objc(attributeWithAttributeTag:vr:)
    public class func attribute(with tag: DICOMAttributeTag?, vr: String?) -> DCMAttribute {
        DCMAttribute(attributeTag: tag, vr: vr)
    }

    @objc(attributeWithAttributeTag:vr:values:)
    public class func attribute(with tag: DICOMAttributeTag?, vr: String?, values: NSMutableArray?) -> DCMAttribute {
        DCMAttribute(attributeTag: tag, vr: vr, values: values)
    }

    /// The VR is the tag's when `vr` is nil.
    @objc(initWithAttributeTag:vr:values:)
    public init(attributeTag tag: DICOMAttributeTag?, vr: String?, values: NSMutableArray?) {
        attrTag = tag
        self.values = values
        self.vr = vr ?? tag?.vr
        super.init()
    }

    @objc(initWithAttributeTag:)
    public convenience init(attributeTag tag: DICOMAttributeTag?) {
        self.init(attributeTag: tag, vr: nil)
    }

    /// A private tag the dictionary does not know needs its VR.
    @objc(initWithAttributeTag:vr:)
    public convenience init(attributeTag tag: DICOMAttributeTag?, vr: String?) {
        self.init(attributeTag: tag, vr: vr, values: NSMutableArray())
    }

    @objc(initWithAttribute:)
    public convenience init(attribute: DCMAttribute) {
        self.init(attributeTag: attribute.attrTag.map { DICOMAttributeTag(tag: $0) },
                  vr: attribute.vr.map { String($0) },
                  values: attribute.values?.mutableCopy() as? NSMutableArray)
    }

    /// A plain attribute, whatever the class of the original.
    public func copy(with zone: NSZone? = nil) -> Any {
        DCMAttribute(attribute: self)
    }

    // MARK: Values

    @objc public var group: Int32 { attrTag?.group ?? 0 }
    @objc public var element: Int32 { attrTag?.element ?? 0 }
    @objc public var valueMultiplicity: Int32 { Int32(values?.count ?? 0) }
    @objc public var vrStringValue: String! { attrTag?.stringValue }
    @objc public var paddedValueLength: Int { 0 }

    @objc public func value() -> Any! {
        guard let values, values.count > 0 else { return nil }
        return values.object(at: 0)
    }

    @objc(addValue:)
    public func addValue(_ value: Any) {
        values?.add(value)
    }

    /// The length of the value as it would be written, in bytes.
    @objc public var valueLength: Int {
        let values = self.values ?? NSMutableArray()
        let multiplicity = values.count
        let isQueryDate = (values.firstObject as? DICOMCalendarDate)?.isQuery() == true
        var length = 0
        switch dcmVRCode(vr) {
        case DCM_US, DCM_SS:
            length = multiplicity * 2
        case DCM_DA:
            length = isQueryDate ? values.componentsJoined(by: "\\").utf16.count : multiplicity * 8 + (multiplicity - 1)
        case DCM_TM:
            // 13 with microseconds.
            length = isQueryDate ? values.componentsJoined(by: "\\").utf16.count : multiplicity * 13 + (multiplicity - 1)
        case DCM_DT:
            // YYYYMMDDHHMMSS.FFFFFF: the time zone is not written.
            length = isQueryDate ? values.componentsJoined(by: "\\").utf16.count : multiplicity * 21 + (multiplicity - 1)
        case DCM_UN, DCM_OB, DCM_OW:
            length = values.reduce(0) { $0 + Self.byteLength($1) }
        case DCM_AT, DCM_UL, DCM_SL, DCM_FL:
            length = multiplicity * 4
        case DCM_FD:
            length = multiplicity * 8
        case DCM_AE, DCM_AS, DCM_CS, DCM_DS, DCM_IS, DCM_LO, DCM_LT, DCM_PN, DCM_SH, DCM_ST, DCM_UI, DCM_UT, DCM_QQ:
            // The length depends on the character set the text is written in.
            let string = values.componentsJoined(by: "\\") as NSString
            if characterSet == nil {
                characterSet = DICOMCharacterSet(code: "ISO_IR 100")
            }
            length = string.lengthOfBytes(using: characterSet.encoding)
        default:
            length = values.count > 0 ? Self.byteLength(values.object(at: 0)) : 0
        }
        return max(length, 0)
    }

    private static func byteLength(_ value: Any) -> Int {
        if let data = value as? NSData { return data.length }
        if let string = value as? NSString { return string.length }
        return 0
    }

    @objc public var paddedLength: Int {
        let length = valueLength
        return length % 2 != 0 ? length + 1 : length
    }

    @objc public func valuesAsString() -> String {
        guard let values, values.count > 0 else { return "" }
        return values.description
    }

    @objc(swapBytes:)
    public func swapBytes(_ data: NSMutableData) {
    }

    // MARK: Descriptions

    public override var description: String {
        let tagDescription = attrTag?.description ?? "(null)"
        if valueLength < 100 {
            return String(format: "%@\t %@\t vl:%d\t vm:%d\t %@", tagDescription, attrTag?.vr ?? "(null)",
                          Int32(truncatingIfNeeded: valueLength), valueMultiplicity, valuesAsString())
        }
        return String(format: "%@\t vl:%d\t vm:%d", tagDescription, Int32(truncatingIfNeeded: valueLength),
                      valueMultiplicity)
    }

    @objc public func readableDescription() -> String {
        guard valueLength < 100 else { return "" }
        return String(format: "%@ : %@", attrTag?.readableDescription() ?? "(null)",
                      values?.componentsJoined(by: ",") ?? "")
    }

    @objc public func xmlNode() -> XMLNode {
        let tag = attrTag!
        let attributes = [XMLNode.attribute(withName: "group", stringValue: String(format: "%04x", tag.group)),
                          XMLNode.attribute(withName: "element", stringValue: String(format: "%04x", tag.element)),
                          XMLNode.attribute(withName: "vr", stringValue: tag.vr ?? ""),
                          XMLNode.attribute(withName: "attributeTag", stringValue: tag.stringValue)]
        let name = (tag.name ?? "").replacingOccurrences(of: "/", with: "_")
        var elements: [XMLNode] = []
        for (index, value) in (values ?? NSMutableArray()).enumerated() {
            var string: String?
            if let text = value as? String {
                string = text
            } else if let number = value as? NSNumber {
                string = number.stringValue
            } else if let date = value as? NSDate {
                string = date.description
            } else if let data = value as? Data {
                if DCMHost.catchingObjCException({ string = Self.xmlText(of: data) }) != nil {
                    string = "Unknown"
                }
            } else {
                string = "Unknown"
            }
            let number = XMLNode.attribute(withName: "number", stringValue: "\(index)") as! XMLNode
            let element = XMLNode.element(withName: "value", children: nil, attributes: [number]) as! XMLNode
            element.stringValue = string ?? ""
            elements.append(element)
        }
        return XMLNode.element(withName: name, children: elements, attributes: attributes as? [XMLNode]) as! XMLNode
    }

    /// The first 256 bytes as text when they are printable ASCII (the last one
    /// is not looked at), in hexadecimal otherwise, with "..." when cut.
    private static func xmlText(of value: Data) -> String? {
        let cut = value.count >= 256
        let bytes = cut ? value.prefix(256) : value
        var string: String?
        if !bytes.isEmpty {
            let printable = bytes.dropLast().allSatisfy { $0 >= 32 && $0 <= 125 }
            if printable {
                string = String(data: bytes, encoding: .ascii)
            } else {
                string = "0x" + bytes.map { String(format: "%02lX", UInt($0)) }.joined()
            }
        }
        if cut {
            string = string.map { $0 + "..." }
        }
        return string
    }
}
