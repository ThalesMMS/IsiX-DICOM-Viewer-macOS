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
import IsiXImaging

/// The compression qualities a lossy transfer syntax is written with.
@objc(DCM_CompressionQuality)
public enum DCMCompressionQuality: Int32 {
    @objc(DCMLosslessQuality) case lossless = 0
    @objc(DCMHighQuality) case high
    @objc(DCMMediumQuality) case medium
    @objc(DCMLowQuality) case low
}

/// A DICOM dataset in memory: a file, an item of a sequence, or a list of
/// attributes for the network. Its attributes are keyed by tag ("0010,0010").
///
/// The model parses and writes nothing itself: reading goes to the host's
/// DCMTK reader, which builds DCMObjects from what DCMTK parsed, and writing
/// to its DCMTK writer (DCMHostServices.swift).
///
/// It is the DICOMAttributeSource the frame reading of IsiXImaging reads. The
/// conformance stays in this file, which the linker always loads with the
/// class: the frame reading reaches it only through the Objective-C runtime,
/// so in a file of its own nothing would pull it from the static library.
@objc(IsiXDCMObject)
public final class DCMObject: NSObject, NSCopying, DICOMAttributeSource {

    @objc public private(set) var attributes: NSMutableDictionary! = NSMutableDictionary()
    @objc public private(set) var transferSyntax: DCMTransferSyntax!
    @objc public private(set) var specificCharacterSet: DICOMCharacterSet!
    @objc public internal(set) var pixelDataIsDecoded = false
    @objc public var isSequence = false

    /// Nil without the attribute, the items of a sequence, the attribute
    /// itself when it is not one.
    @objc(isixSequenceItemsWithName:)
    public func sequenceItems(withName name: String) -> Any? {
        guard let attribute = attribute(withName: name) else { return nil }
        guard let sequence = attribute as? DCMSequenceAttribute else { return attribute }
        return sequence.sequence
    }

    // MARK: Making one

    @objc public override init() {
        super.init()
    }

    /// An empty object for a reader to fill: the transfer syntax and character
    /// set it was read with, and whether it is an item of a sequence.
    @objc(initWithTransferSyntax:characterSet:isSequence:)
    public init(transferSyntax syntax: DCMTransferSyntax?, characterSet: DICOMCharacterSet?, isSequence sequence: Bool) {
        transferSyntax = syntax
        specificCharacterSet = characterSet
        isSequence = sequence
        super.init()
    }

    /// A copy: the same attribute objects in a new dictionary.
    @objc(initWithObject:)
    public init(object: DCMObject) {
        specificCharacterSet = object.specificCharacterSet?.copy() as? DICOMCharacterSet
        attributes = object.attributes?.mutableCopy() as? NSMutableDictionary
        transferSyntax = object.transferSyntax?.copy() as? DCMTransferSyntax
        pixelDataIsDecoded = object.pixelDataIsDecoded
        super.init()
    }

    public func copy(with zone: NSZone? = nil) -> Any {
        DCMObject(object: self)
    }

    /// An empty object.
    @objc public class func dcmObject() -> DCMObject {
        DCMObject()
    }

    @objc(objectWithObject:)
    public class func object(with object: DCMObject) -> DCMObject {
        DCMObject(object: object)
    }

    // MARK: Reading, through the host

    /// The file at `path` as the host's DICOM reader (the DCMTK adapter) reads
    /// it, the pixel data left as stored; nil when it cannot be read.
    @objc(objectWithContentsOfFile:)
    public class func object(contentsOfFile path: String?) -> DCMObject? {
        object(contentsOfFile: path, decodingPixelData: false, lastGroup: 0xFFFF)
    }

    /// The same, decoding every frame at once when `decodePixelData` is true,
    /// and stopping after group `lastGroup` (0xFFFF reads everything).
    @objc(objectWithContentsOfFile:decodingPixelData:lastGroup:)
    public class func object(contentsOfFile path: String?, decodingPixelData: Bool, lastGroup: UInt16) -> DCMObject? {
        guard let path else { return nil }
        return DCMHost.reader?.object(contentsOfFile: path, decodingPixelData: decodingPixelData, lastGroup: lastGroup)
    }

    /// Nil when there is no file at `path`.
    @objc(objectWithContentsOfFile:decodingPixelData:)
    public class func object(withContentsOfFile path: String?, decodingPixelData: Bool) -> DCMObject? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return object(contentsOfFile: path, decodingPixelData: decodingPixelData, lastGroup: 0xFFFF)
    }

    /// A Part 10 stream.
    @objc(objectWithData:decodingPixelData:)
    public class func object(with data: Data, decodingPixelData: Bool) -> DCMObject? {
        DCMHost.reader?.object(data: data, transferSyntax: nil, decodingPixelData: decodingPixelData, lastGroup: 0xFFFF)
    }

    /// A bare dataset in `syntax`, as a network peer sends it.
    @objc(objectWithData:transferSyntax:)
    public class func object(with data: Data, transferSyntax syntax: DCMTransferSyntax?) -> DCMObject? {
        DCMHost.reader?.object(data: data, transferSyntax: syntax?.transferSyntax, decodingPixelData: false,
                               lastGroup: 0xFFFF)
    }

    @objc(objectWithContentsOfURL:decodingPixelData:)
    public class func object(withContentsOf url: URL, decodingPixelData: Bool) -> DCMObject? {
        if url.isFileURL {
            return object(withContentsOfFile: url.path, decodingPixelData: decodingPixelData)
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return object(with: data, decodingPixelData: decodingPixelData)
    }

    /// Whether `data` is a Part 10 file: DICM at offset 128.
    @objc(isDICOM:)
    public class func isDICOM(_ data: Data) -> Bool {
        guard data.count >= 132 else { return false }
        let start = data.startIndex
        return data[start + 128] == 0x44 && data[start + 129] == 0x49 && data[start + 130] == 0x43
            && data[start + 131] == 0x4D
    }

    /// Decodes every frame of the Pixel Data attribute, for a reader asked to;
    /// pixelDataIsDecoded then says whether it could.
    @objc public func decodePixelDataAttribute() {
        guard let pixels = attribute(withName: "PixelData") as? DCMPixelDataAttribute else { return }
        pixels.decodeData()
        pixelDataIsDecoded = pixels.isDecoded
    }

    // MARK: Attributes

    @objc(attributeForTag:)
    public func attribute(for tag: DICOMAttributeTag?) -> DCMAttribute! {
        guard let key = tag?.stringValue else { return nil }
        return attributes?.object(forKey: key) as? DCMAttribute
    }

    @objc(attributeWithName:)
    public func attribute(withName name: String?) -> DCMAttribute! {
        attribute(for: DICOMAttributeTag.tag(withName: name))
    }

    /// The first value of the named attribute.
    @objc(attributeValueWithName:)
    public func attributeValue(withName name: String) -> Any? {
        attribute(withName: name)?.value()
    }

    /// The first value of the attribute under a tag key ("0010,0010").
    @objc(attributeValueForKey:)
    public func attributeValue(forKey key: String) -> Any? {
        (attributes?.object(forKey: key) as? DCMAttribute)?.value()
    }

    @objc(attributeArrayWithName:)
    public func attributeArray(withName name: String) -> [Any]? {
        attribute(withName: name)?.values as? [Any]
    }

    @objc(attributeArrayForKey:)
    public func attributeArray(forKey key: String) -> [Any]? {
        (attributes?.object(forKey: key) as? DCMAttribute)?.values as? [Any]
    }

    @objc(setAttribute:)
    public func setAttribute(_ attribute: DCMAttribute?) {
        guard let attribute else { return }
        attributes?.setObject(attribute, forKey: (attribute.attrTag?.stringValue ?? "") as NSString)
    }

    /// Adds a value to the named attribute, making it when absent.
    @objc(addAttributeValue:forName:)
    public func addAttributeValue(_ value: Any?, forName name: String?) {
        guard let tag = DICOMAttributeTag.tag(withName: name) else {
            NSLog("*** tagname not found in dictionary: %@", name ?? "(null)")
            return
        }
        if let existing = attributes?.object(forKey: tag.stringValue!) as? DCMAttribute {
            existing.addValue(value as Any)
        } else {
            let attribute = DCMAttribute(attributeTag: tag)
            attribute.addValue(value as Any)
            attributes?.setObject(attribute, forKey: tag.stringValue! as NSString)
        }
    }

    /// Replaces the named attribute with one holding `values`.
    @objc(setAttributeValues:forName:)
    public func setAttributeValues(_ values: NSMutableArray?, forName name: String?) {
        guard let tag = DICOMAttributeTag.tag(withName: name) else {
            NSLog("*** tagname not found in dictionary: %@", name ?? "(null)")
            return
        }
        let attribute = DCMAttribute(attributeTag: tag)
        attribute.values = values
        attributes?.setObject(attribute, forKey: tag.stringValue! as NSString)
    }

    /// Sets the Specific Character Set of the object and of every attribute.
    @objc(setCharacterSet:)
    public func setCharacterSet(_ characterSet: DICOMCharacterSet?) {
        specificCharacterSet = characterSet
        for key in sortedKeys() {
            (attributes?.object(forKey: key) as? DCMAttribute)?.characterSet = characterSet
        }
    }

    func sortedKeys() -> [String] {
        ((attributes?.allKeys as? [String]) ?? []).sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The keys of the attributes that satisfy `test`.
    func keys(where test: (DCMAttribute) -> Bool) -> [Any] {
        var keys: [Any] = []
        attributes?.enumerateKeysAndObjects { key, value, _ in
            if let attribute = value as? DCMAttribute, test(attribute) {
                keys.append(key)
            }
        }
        return keys
    }

    // MARK: Editing

    /// Removes group 0002.
    @objc public func removeMetaInformation() {
        attributes?.removeObjects(forKeys: keys { $0.attrTag?.group == 0x0002 })
    }

    /// Removes every group length but the meta header's.
    @objc public func removeGroupLengths() {
        attributes?.removeObjects(forKeys: keys { $0.attrTag?.element == 0x0000 && $0.attrTag?.group != 0x0002 })
    }

    @objc public func removePrivateTags() {
        attributes?.removeObjects(forKeys: keys { ($0.attrTag?.group ?? 0) % 2 != 0 })
    }

    /// For a change of the pixel encapsulation or a rescaling of the pixels.
    @objc public func removePlanarAndRescaleAttributes() {
        for name in ["RescaleSlope", "RescaleIntercept", "PlanarConfiguration"] {
            if let key = DICOMAttributeTag.tag(withName: name)?.stringValue {
                attributes?.removeObject(forKey: key)
            }
        }
    }

    /// The meta header: File Meta Information Version, the Media Storage SOP
    /// Class and Instance UIDs (copied from the SOP ones when absent), the
    /// Transfer Syntax UID, the implementation, the source AE title and the
    /// group length.
    @objc(updateMetaInformationWithTransferSyntax:aet:)
    public func updateMetaInformation(withTransferSyntax ts: DCMTransferSyntax?, aet: String?) {
        var groupLength = 0
        func put(_ name: String, _ value: Any?) -> DCMAttribute {
            let tag = DICOMAttributeTag(name: name)
            let attribute = DCMAttribute(attributeTag: tag)
            if let value {
                attribute.addValue(value)
            }
            attributes?.setObject(attribute, forKey: (tag?.stringValue ?? "") as NSString)
            return attribute
        }

        groupLength += put("FileMetaInformationVersion", Data([0x00, 0x01]) as NSData).paddedLength + 4 + 4 + 4

        if let existing = attribute(withName: "MediaStorageSOPClassUID") {
            groupLength += 4 + 2 + 2 + existing.paddedLength
        } else if let sopClassUID = attributeValue(withName: "SOPClassUID") {
            groupLength += put("MediaStorageSOPClassUID", sopClassUID).paddedLength + 4 + 2 + 2
        }
        if let existing = attribute(withName: "MediaStorageSOPInstanceUID") {
            groupLength += 4 + 2 + 2 + existing.paddedLength
        } else if let sopInstanceUID = attributeValue(withName: "SOPInstanceUID") {
            groupLength += put("MediaStorageSOPInstanceUID", sopInstanceUID).paddedLength + 4 + 2 + 2
        }
        groupLength += put("TransferSyntaxUID", ts?.transferSyntax).paddedLength + 4 + 2 + 2
        groupLength += put("ImplementationClassUID", DCMObject.rootUID()).paddedLength + 4 + 2 + 2
        groupLength += put("ImplementationVersionName", "OSIRIX001").paddedLength + 4 + 2 + 2
        if let aet {
            _ = put("SourceApplicationEntityTitle", aet)
        }
        if let key = IsiXDICOMTagDictionaryNames.key(for: "SourceApplicationEntityTitle"),
           let source = attributes?.object(forKey: key) as? DCMAttribute {
            groupLength += 4 + 2 + 2 + source.paddedLength
        }
        _ = put("MetaElementGroupLength", NSNumber(value: Int32(groupLength)))
    }

    // MARK: Writing, through the host

    @objc(writeToFile:withTransferSyntax:quality:atomically:)
    public func write(toFile path: String, with ts: DCMTransferSyntax?, quality: Int32, atomically flag: Bool) -> Bool {
        write(toFile: path, with: ts, quality: quality, aet: "ISIX", atomically: flag)
    }

    /// Always atomic: DCMTK writes beside the destination and the file is
    /// moved over it. A nil `ts` keeps the object's own syntax.
    @objc(writeToFile:withTransferSyntax:quality:AET:atomically:)
    public func write(toFile path: String, with ts: DCMTransferSyntax?, quality: Int32, aet: String?,
                      atomically flag: Bool) -> Bool {
        DCMHost.writer?.write(self, toFile: path, transferSyntax: (ts ?? transferSyntax)?.transferSyntax,
                              quality: quality, aet: aet) ?? false
    }

    @objc(writeToURL:withTransferSyntax:quality:atomically:)
    public func write(to url: URL, with ts: DCMTransferSyntax?, quality: Int32, atomically flag: Bool) -> Bool {
        write(to: url, with: ts, quality: quality, aet: "ISIX", atomically: flag)
    }

    @objc(writeToURL:withTransferSyntax:quality:AET:atomically:)
    public func write(to url: URL, with ts: DCMTransferSyntax?, quality: Int32, aet: String?,
                      atomically flag: Bool) -> Bool {
        if url.isFileURL {
            return write(toFile: url.path, with: ts, quality: quality, aet: aet, atomically: flag)
        }
        let temporary = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        guard write(toFile: temporary, with: ts, quality: quality, aet: aet, atomically: true),
              let data = NSData(contentsOfFile: temporary) else { return false }
        return data.write(to: url, atomically: flag)
    }

    /// The dataset alone, for sending: no preamble, no meta header.
    @objc(writeDatasetWithTransferSyntax:quality:)
    public func writeDataset(with ts: DCMTransferSyntax?, quality: Int32) -> Data? {
        DCMHost.writer?.dataset(of: self, transferSyntax: (ts ?? transferSyntax)?.transferSyntax, quality: quality)
    }

    /// Every attribute is read: DCMTK reads the whole dataset.
    @objc(isNeededAttribute:)
    public func isNeededAttribute(_ tagString: UnsafeMutablePointer<CChar>?) -> Bool {
        true
    }

    // MARK: Sequences

    @objc public func referencedSeriesSequence() -> NSMutableArray! {
        (attribute(withName: "ReferencedSeriesSequence") as? DCMSequenceAttribute)?.sequenceItems
    }

    @objc(referencedImageSequenceForObject:)
    public func referencedImageSequence(for object: DCMObject) -> NSMutableArray! {
        (object.attribute(withName: "ReferencedImageSequence") as? DCMSequenceAttribute)?.sequenceItems
    }

    // MARK: Descriptions

    public override var description: String {
        sortedKeys().reduce("") { text, key in
            "\(text) \n\((attributes?.object(forKey: key) as? DCMAttribute)?.description ?? "(null)")"
        }
    }

    @objc public func readableDescription() -> String {
        sortedKeys().reduce("") { text, key in
            "\(text) \n\((attributes?.object(forKey: key) as? DCMAttribute)?.readableDescription() ?? "(null)")"
        }
    }

    @objc public func xmlNode() -> XMLNode {
        let elements = sortedKeys().compactMap { (attributes?.object(forKey: $0) as? DCMAttribute)?.xmlNode() }
        return XMLNode.element(withName: "item", children: elements, attributes: nil) as! XMLNode
    }

    @objc public var xmlDocument: XMLDocument! {
        let root = XMLElement(name: "DICOMObject")
        for key in sortedKeys() {
            if let attribute = attributes?.object(forKey: key) as? DCMAttribute {
                root.addChild(attribute.xmlNode())
            }
        }
        let document = XMLDocument(rootElement: root)
        do {
            try document.validate()
        } catch {
            NSLog("xml Document erorr:\n%@", (error as NSError).description)
        }
        return document
    }
}

/// The key the tag dictionary gives a name.
enum IsiXDICOMTagDictionaryNames {
    static func key(for name: String) -> String? {
        DICOMTagDictionary.sharedTagForNameDictionary()?.object(forKey: name) as? String
    }
}
