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

/// DCMObject and a DCMDataContainer, as the SDK of Horos and OsiriX had them:
/// a plugin writes an object into a container to have its bytes in memory
/// (-dicomData), or hands a container of bytes to be read.
///
/// The former class serialized attribute by attribute into the container and
/// parsed from it. The model writes and reads through the host's DICOM
/// library, so here the container receives the bytes that writing to a file
/// gives, and reading hands the container's bytes to the reader.
extension DCMObject {
    // MARK: Writing

    @objc(writeToDataContainer:withTransferSyntax:asDICOM3:)
    public func write(to container: DCMDataContainer?, with ts: DCMTransferSyntax?, asDICOM3 flag: Bool) -> Bool {
        write(to: container, with: ts, quality: DCMCompressionQuality.lossless.rawValue, asDICOM3: flag, aet: "OSIRIX",
              strippingGroupLengths: true)
    }

    @objc(writeToDataContainer:withTransferSyntax:AET:asDICOM3:)
    public func write(to container: DCMDataContainer?, with ts: DCMTransferSyntax?, aet: String?, asDICOM3 flag: Bool) -> Bool {
        write(to: container, with: ts, quality: DCMCompressionQuality.lossless.rawValue, asDICOM3: flag, aet: aet,
              strippingGroupLengths: true)
    }

    /// `implicitForPixelData` is not read: the writer encodes the Pixel Data
    /// in the syntax of the dataset, as the former class did whatever the flag.
    @objc(writeToDataContainer:withTransferSyntax:AET:asDICOM3:implicitForPixelData:)
    public func write(to container: DCMDataContainer?, with ts: DCMTransferSyntax?, aet: String?, asDICOM3 flag: Bool,
                      implicitForPixelData: Bool) -> Bool {
        write(to: container, with: ts, quality: DCMCompressionQuality.lossless.rawValue, asDICOM3: flag, aet: aet,
              strippingGroupLengths: true)
    }

    @objc(writeToDataContainer:withTransferSyntax:quality:)
    public func write(to container: DCMDataContainer?, with ts: DCMTransferSyntax?, quality: Int32) -> Bool {
        write(to: container, with: ts, quality: quality, asDICOM3: true, aet: "OSIRIX", strippingGroupLengths: true)
    }

    @objc(writeToDataContainer:withTransferSyntax:quality:asDICOM3:)
    public func write(to container: DCMDataContainer?, with ts: DCMTransferSyntax?, quality: Int32, asDICOM3 flag: Bool) -> Bool {
        write(to: container, with: ts, quality: quality, asDICOM3: flag, aet: "OSIRIX", strippingGroupLengths: true)
    }

    @objc(writeToDataContainer:withTransferSyntax:quality:asDICOM3:strippingGroupLengthLength:)
    public func write(to container: DCMDataContainer?, with ts: DCMTransferSyntax?, quality: Int32, asDICOM3 flag: Bool,
                      strippingGroupLengthLength strip: Bool) -> Bool {
        write(to: container, with: ts, quality: quality, asDICOM3: flag, aet: "OSIRIX", strippingGroupLengths: strip)
    }

    /// Appends to `container` the object as a Part 10 stream (the preamble,
    /// the meta header written for `aet`, the dataset) when `flag` is true, or
    /// the dataset alone. A nil `ts` keeps the object's own syntax. As in the
    /// former class, `strip` removes the group lengths from the object itself.
    @objc(writeToDataContainer:withTransferSyntax:quality:asDICOM3:AET:strippingGroupLengthLength:)
    public func write(to container: DCMDataContainer?, with ts: DCMTransferSyntax?, quality: Int32, asDICOM3 flag: Bool,
                      aet: String?, strippingGroupLengths strip: Bool) -> Bool {
        guard let container else { return false }
        if strip { removeGroupLengths() }
        let syntax = ts ?? transferSyntax
        guard let bytes = flag ? partTenStream(with: syntax, quality: quality, aet: aet)
                               : writeDataset(with: syntax, quality: quality) else { return false }
        container.setTransferSyntaxForDataset(syntax)
        container.dicomData.append(bytes)
        return true
    }

    private func partTenStream(with ts: DCMTransferSyntax?, quality: Int32, aet: String?) -> Data? {
        let temporary = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        guard write(toFile: temporary, with: ts, quality: quality, aet: aet, atomically: true) else { return nil }
        return FileManager.default.contents(atPath: temporary)
    }

    // MARK: Reading

    /// What the host's reader makes of the bytes of `container` from
    /// `byteOffset`: `lengthToRead` of them, or all that is left when it is
    /// negative or passes the end. From the start of a Part 10 stream the meta
    /// header says the syntax; anywhere else the bytes are a dataset in the
    /// syntax the container has in use. `byteOffset` moves past what was read.
    static func object(readingFrom container: DCMDataContainer?, lengthToRead: Int32,
                       byteOffset: UnsafeMutablePointer<Int32>?, decodingPixelData: Bool, lastGroup: UInt16) -> DCMObject? {
        guard let container else { return nil }
        let total = container.dicomData.length
        let start = Int(byteOffset?.pointee ?? container.position)
        guard start >= 0, start <= total else { return nil }
        let end = lengthToRead < 0 ? total : min(total, start + Int(lengthToRead))
        let partTen = start <= Int(container.offset) && container.offset == 132
        let bytes = (container.dicomData as Data).subdata(in: (partTen ? 0 : start)..<end)
        let syntax = partTen ? nil : (container.transferSyntaxInUse() ?? container.transferSyntaxForDataset())?.transferSyntax
        guard let read = DCMHost.reader?.object(data: bytes, transferSyntax: syntax,
                                                decodingPixelData: decodingPixelData, lastGroup: lastGroup) else { return nil }
        byteOffset?.pointee = Int32(truncatingIfNeeded: end)
        return read
    }

    func read(_ container: DCMDataContainer?, lengthToRead: Int32, byteOffset: UnsafeMutablePointer<Int32>?,
              lastGroup: UInt16) -> Int32 {
        guard let read = DCMObject.object(readingFrom: container, lengthToRead: lengthToRead, byteOffset: byteOffset,
                                          decodingPixelData: false, lastGroup: lastGroup) else {
            byteOffset?.pointee = -1
            return -1
        }
        add(attributesOf: read)
        return byteOffset?.pointee ?? Int32(truncatingIfNeeded: container?.dicomData.length ?? 0)
    }

    @objc(initWithDataContainer:lengthToRead:byteOffset:characterSet:decodingPixelData:)
    public convenience init?(dataContainer container: DCMDataContainer?, lengthToRead: Int32,
                             byteOffset: UnsafeMutablePointer<Int32>?, characterSet: DICOMCharacterSet?,
                             decodingPixelData: Bool) {
        self.init(taking: DCMObject.object(readingFrom: container, lengthToRead: lengthToRead, byteOffset: byteOffset,
                                           decodingPixelData: decodingPixelData, lastGroup: 0xFFFF))
        if specificCharacterSet == nil, let characterSet { setCharacterSet(characterSet) }
    }

    /// Reads on, into this object; answers the offset reached, or -1 (the
    /// 0xFFFFFFFF of the former class) when the bytes are not a dataset.
    @objc(readDataSet:lengthToRead:byteOffset:)
    public func readDataSet(_ container: DCMDataContainer?, lengthToRead: Int32,
                            byteOffset: UnsafeMutablePointer<Int32>?) -> Int32 {
        read(container, lengthToRead: lengthToRead, byteOffset: byteOffset, lastGroup: 0xFFFF)
    }

    // The steps of the former parser a subclass could call or override. The
    // first two read the tag at the container's position; the others answered
    // nothing in the former class either, the parsing being in -readDataSet:.

    @objc(getGroup:)
    public func getGroup(_ container: DCMDataContainer?) -> Int32 { Int32(container?.nextUnsignedShort() ?? 0) }

    @objc(getElement:)
    public func getElement(_ container: DCMDataContainer?) -> Int32 { Int32(container?.nextUnsignedShort() ?? 0) }

    @objc(length:)
    public func length(_ container: DCMDataContainer?) -> Int32 { 0 }

    @objc(getvr:forTag:isExplicit:)
    public func getvr(_ container: DCMDataContainer?, for tag: DICOMAttributeTag?, isExplicit: Bool) -> String { "" }

    @objc(getValues:)
    public func getValues(_ container: DCMDataContainer?) -> NSMutableArray { NSMutableArray() }

    @objc(newAttributeForAttributeTag:vr:length:data:specificCharacterSet:isExplicit:forImplicitUseOW:)
    public func newAttribute(for tag: DICOMAttributeTag?, vr: String?, length: Int32, data: DCMDataContainer?,
                             specificCharacterSet: DICOMCharacterSet?, isExplicit: Bool,
                             forImplicitUseOW: Bool) -> Unmanaged<DCMAttribute>? {
        nil
    }

    /// The items of a sequence, read from the container into `attribute`.
    /// The reader builds the sequences with the dataset, so nothing is read
    /// here and the offset stays where it was.
    @objc(readNewSequenceAttribute:dicomData:byteOffset:lengthToRead:specificCharacterSet:)
    public func readNewSequenceAttribute(_ attribute: DCMAttribute?, dicomData container: DCMDataContainer?,
                                         byteOffset: UnsafeMutablePointer<Int32>?, lengthToRead: Int32,
                                         specificCharacterSet: DICOMCharacterSet?) -> Int32 {
        FormerSDKNotice.inert("DCMObject", "-readNewSequenceAttribute:dicomData:byteOffset:lengthToRead:specificCharacterSet:",
                              because: "the DICOM reader builds a sequence with its dataset")
        return byteOffset?.pointee ?? 0
    }
}
