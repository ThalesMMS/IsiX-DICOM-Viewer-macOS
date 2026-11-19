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

/// An attribute and a DCMDataContainer, as the SDK of Horos and OsiriX had
/// them: an attribute reads its values from the bytes at the container's
/// position and writes itself, tag, value representation, length and values,
/// at the container's end. The application reads and writes datasets through
/// the host's DICOM library and uses none of this; it answers a plugin that
/// builds or reads an element by hand.
extension DCMAttribute {
    @objc(attributeinitWithAttributeTag:vr:length:data:specificCharacterSet:isExplicit:forImplicitUseOW:)
    public class func attribute(with tag: DICOMAttributeTag?, vr: String?, length: Int, data: DCMDataContainer?,
                                specificCharacterSet: DICOMCharacterSet?, isExplicit: Bool,
                                forImplicitUseOW: Bool) -> DCMAttribute {
        DCMAttribute(attributeTag: tag, vr: vr, length: length, data: data, specificCharacterSet: specificCharacterSet,
                     isExplicit: isExplicit, forImplicitUseOW: forImplicitUseOW)
    }

    /// The attribute of `tag` with the `length` bytes at the container's
    /// position as its values, read as `vr` says. Without a container it has
    /// no values.
    @objc(initWithAttributeTag:vr:length:data:specificCharacterSet:isExplicit:forImplicitUseOW:)
    public convenience init(attributeTag tag: DICOMAttributeTag?, vr: String?, length: Int, data: DCMDataContainer?,
                            specificCharacterSet: DICOMCharacterSet?, isExplicit: Bool, forImplicitUseOW: Bool) {
        self.init(attributeTag: tag, vr: vr, values: NSMutableArray())
        characterSet = specificCharacterSet ?? DICOMCharacterSet(code: "ISO_IR 100")
        if let data, let read = values(forVR: vr, length: Int32(truncatingIfNeeded: length), data: data) {
            values = NSMutableArray(array: read)
        }
    }

    /// The values the `length` bytes at the container's position hold for the
    /// value representation `vrString`; nil for a sequence.
    @objc(valuesForVR:length:data:)
    public func values(forVR vrString: String?, length: Int32, data: DCMDataContainer?) -> [Any]? {
        guard let data else { return nil }
        if length == 0 { return [] }
        if DCMValueRepresentation.isAffectedBySpecificCharacterSet(vrString) {
            let set: DICOMCharacterSet = characterSet ?? DICOMCharacterSet(code: "ISO_IR 100")
            return data.nextString(withLength: length, encodings: set.encodings)?.components(separatedBy: "\\") ?? []
        }
        func numbers(of size: Int32, _ next: () -> NSNumber) -> [Any] {
            let values = (0..<(length / size)).map { _ in next() }
            if length % size > 0 { _ = data.skipLength(length % size) }
            return values
        }
        switch vrString {
        case "US": return (0..<(length / 2)).map { _ in NSNumber(value: Int32(data.nextUnsignedShort())) }
        case "SS": return (0..<(length / 2)).map { _ in NSNumber(value: Int32(data.nextSignedShort())) }
        case "DA": return data.nextDates(withLength: length) as? [Any]
        case "TM": return data.nextTimes(withLength: length) as? [Any]
        case "DT": return data.nextDateTimes(withLength: length) as? [Any]
        case "SQ": return nil
        case "AT", "UL": return numbers(of: 4) { NSNumber(value: UInt(data.nextUnsignedLong())) }
        case "SL": return numbers(of: 4) { NSNumber(value: Int(data.nextSignedLong())) }
        case "FL": return numbers(of: 4) { NSNumber(value: data.nextFloat()) }
        case "FD": return numbers(of: 8) { NSNumber(value: data.nextDouble()) }
        case "AE", "AS", "CS", "DS", "IS", "LO", "LT", "PN", "SH", "ST", "UI", "UT", "QQ":
            return data.nextString(withLength: length)?.components(separatedBy: "\\") ?? []
        default:
            return data.nextData(withLength: length).map { [$0] } ?? []
        }
    }

    /// The tag, then, in an explicit syntax, the value representation and
    /// the length in two bytes or, after two reserved bytes, in four; in an
    /// implicit syntax the length in four bytes.
    @objc(writeBaseToData:transferSyntax:)
    public func writeBase(to data: DCMDataContainer?, transferSyntax ts: DCMTransferSyntax?) {
        guard let data else { return }
        data.addUnsignedShort(UInt16(truncatingIfNeeded: group))
        data.addUnsignedShort(UInt16(truncatingIfNeeded: element))
        let length = UInt(truncatingIfNeeded: paddedLength)
        guard ts?.isExplicit == true else { return data.addUnsignedLong(length) }
        data.addString(vr)
        if DCMValueRepresentation.isShortValueLengthVR(vr) {
            data.addUnsignedShort(UInt16(truncatingIfNeeded: length))
        } else {
            data.addUnsignedShort(0)
            data.addUnsignedLong(length)
        }
    }

    /// The element whole: what -writeBaseToData:transferSyntax: writes, then
    /// the values. A sequence writes its base alone.
    @objc(writeToDataContainer:withTransferSyntax:)
    public func write(to container: DCMDataContainer?, with ts: DCMTransferSyntax?) -> Bool {
        guard let container else { return false }
        if characterSet == nil { characterSet = DICOMCharacterSet(code: "ISO_IR 100") }
        writeBase(to: container, transferSyntax: ts)
        let all = (values as? [Any]) ?? []
        let text = { all.map { "\($0)" }.joined(separator: "\\") }
        if DCMValueRepresentation.isAffectedBySpecificCharacterSet(vr) {
            container.addString(text(), withEncodings: characterSet?.encodings)
            return true
        }
        func dates(_ add: (DICOMCalendarDate?) -> Void) {
            for (index, value) in all.enumerated() {
                add(value as? DICOMCalendarDate)
                if index < all.count - 1 { container.addStringWithoutPadding("\\") }
            }
            if paddedLength != valueLength { container.addStringWithoutPadding(" ") }
        }
        let numbers = all.map { $0 as? NSNumber ?? NSNumber(value: ("\($0)" as NSString).doubleValue) }
        switch vr {
        case "US": numbers.forEach { container.addUnsignedShort(UInt16(truncatingIfNeeded: $0.int32Value)) }
        case "SS": numbers.forEach { container.addSignedShort(Int16(truncatingIfNeeded: $0.int32Value)) }
        case "DA": dates(container.addDate)
        case "TM": dates(container.addTime)
        case "DT": dates(container.addDateTime)
        case "SQ": break
        case "UN", "OB", "OW": all.forEach { container.addData($0 as? Data) }
        case "AT", "UL": numbers.forEach { container.addUnsignedLong($0.uintValue) }
        case "SL": numbers.forEach { container.addSignedLong($0.intValue) }
        case "FL": numbers.forEach { container.addFloat($0.floatValue) }
        case "FD": numbers.forEach { container.addDouble($0.doubleValue) }
        case "UI": container.addStringWithZeroPadding(text())
        case "AE", "AS", "CS", "DS", "IS", "LO", "LT", "PN", "SH", "ST", "UT", "QQ": container.addString(text())
        default: break
        }
        return true
    }
}

extension DCMPixelDataAttribute {
    /// The Pixel Data of `object`, its `length` bytes read from the
    /// container's position as one value. The frames are decoded when they
    /// are asked for, whatever `decodeData`: decoding goes through the host's
    /// codecs, with the geometry `object` gives.
    @objc(initWithAttributeTag:vr:length:data:specificCharacterSet:transferSyntax:dcmObject:decodeData:)
    public convenience init(attributeTag tag: DICOMAttributeTag?, vr: String?, length: Int, data: DCMDataContainer?,
                            specificCharacterSet: DICOMCharacterSet?, transferSyntax ts: DCMTransferSyntax?,
                            dcmObject object: DCMObject?, decodeData: Bool) {
        let values = NSMutableArray()
        if let data, length > 0, let bytes = data.nextData(withLength: Int32(truncatingIfNeeded: length)) {
            values.add(bytes)
        }
        if let object {
            self.init(attributeTag: tag, vr: vr, values: values, object: object, transferSyntax: ts, frameSource: nil)
        } else {
            self.init(attributeTag: tag, vr: vr, values: values)
            transferSyntax = ts
        }
        characterSet = specificCharacterSet
    }
}
