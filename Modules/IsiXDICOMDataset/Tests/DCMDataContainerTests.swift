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
import Synchronization
import XCTest
@testable import IsiXDICOMDataset

/// Stand-ins for the host's DICOM reader and writer, found by the names the
/// model looks up. The writer makes a recognizable stream instead of DICOM;
/// the reader keeps what it was asked and answers an object with one value.
@objc(HorosDCMTKObject)
final class StandInReader: NSObject, DCMReading {
    struct Asked {
        var data: Data?
        var syntax: String?
        var group: UInt16 = 0
    }
    static let asked = Mutex(Asked())
    static var lastData: Data? { asked.withLock { $0.data } }
    static var lastSyntax: String? { asked.withLock { $0.syntax } }
    static var lastGroup: UInt16 { asked.withLock { $0.group } }

    private static func made() -> DCMObject {
        let object = DCMObject()
        object.setAttribute(DCMAttribute(attributeTag: DICOMAttributeTag(group: 0x0010, element: 0x0020), vr: "LO",
                                         values: NSMutableArray(array: ["READ"])))
        return object
    }

    static func object(contentsOfFile path: String, decodingPixelData: Bool, lastGroup: UInt16) -> DCMObject? {
        asked.withLock { $0.group = lastGroup }
        return path.hasSuffix("absent") ? nil : made()
    }

    static func object(data: Data, transferSyntax: String?, decodingPixelData: Bool, lastGroup: UInt16) -> DCMObject? {
        asked.withLock { $0 = Asked(data: data, syntax: transferSyntax, group: lastGroup) }
        return data.isEmpty ? nil : made()
    }
}

@objc(IsiXDCMTKObjectWriter)
final class StandInWriter: NSObject, DCMWriting {
    static let asked = Mutex<(aet: String?, quality: Int32)>((nil, -1))
    static var lastAET: String? { asked.withLock { $0.aet } }
    static var lastQuality: Int32 { asked.withLock { $0.quality } }

    static func write(_ object: DCMObject, toFile path: String, transferSyntax: String?, quality: Int32, aet: String?) -> Bool {
        asked.withLock { $0 = (aet, quality) }
        var stream = Data(count: 128)
        stream.append(Data("DICM".utf8))
        stream.append(Data("META+".utf8))
        stream.append(dataset(of: object, transferSyntax: transferSyntax, quality: quality) ?? Data())
        return FileManager.default.createFile(atPath: path, contents: stream)
    }

    static func dataset(of object: DCMObject, transferSyntax: String?, quality: Int32) -> Data? {
        Data("SET[\(transferSyntax ?? "nil")]\(object.attributes.count)".utf8)
    }

    static func object(byConverting object: DCMObject, toTransferSyntax transferSyntax: String, quality: Int32) -> DCMObject? {
        object
    }
}

/// The classes of the former SDK the module has again: the container of
/// bytes, the functions on value representations, the three subclasses of
/// DCMObject, and what DCMObject and DCMAttribute do with a container.
final class DCMDataContainerTests: XCTestCase {

    private func sampleObject() -> DCMObject {
        let object = DCMObject(transferSyntax: .explicitVRLittleEndianTransferSyntax(), characterSet: nil, isSequence: false)
        object.setAttribute(DCMAttribute(attributeTag: DICOMAttributeTag(group: 0x0008, element: 0x0000), vr: "UL",
                                         values: NSMutableArray(array: [NSNumber(value: 4)])))
        object.setAttribute(DCMAttribute(attributeTag: DICOMAttributeTag(group: 0x0010, element: 0x0020), vr: "LO",
                                         values: NSMutableArray(array: ["ID"])))
        return object
    }

    private func patientID(of object: DCMObject) -> String? {
        object.attribute(for: DICOMAttributeTag(group: 0x0010, element: 0x0020))?.value() as? String
    }

    func testRuntimeNamesAndAncestry() {
        for name in ["DCMDataContainer", "DCMValueRepresentation", "DCMLimitedObject", "DCMObjectDBImport",
                     "DCMObjectPixelDataImport"] {
            XCTAssertNotNil(NSClassFromString(name), name)
        }
        for name in ["DCMLimitedObject", "DCMObjectDBImport", "DCMObjectPixelDataImport"] {
            XCTAssertTrue(class_getSuperclass(NSClassFromString(name)) === DCMObject.self, name)
        }
        XCTAssertTrue(class_getSuperclass(DCMDataContainer.self) === NSObject.self)
    }

    func testValueRepresentations() {
        XCTAssertTrue(DCMValueRepresentation.isValidVR("PN"))
        XCTAssertFalse(DCMValueRepresentation.isValidVR("ZZ"))
        XCTAssertFalse(DCMValueRepresentation.isValidVR(nil))
        XCTAssertTrue(DCMValueRepresentation.isShortValueLengthVR("US"))
        XCTAssertFalse(DCMValueRepresentation.isShortValueLengthVR("OB"))
        XCTAssertFalse(DCMValueRepresentation.isShortValueLengthVR("SQ"))
        XCTAssertTrue(DCMValueRepresentation.isAffectedBySpecificCharacterSet("LO"))
        XCTAssertFalse(DCMValueRepresentation.isAffectedBySpecificCharacterSet("UI"))
    }

    func testPrimitivesRoundTrip() throws {
        let container = DCMDataContainer(data: Data(), transferSyntax: .explicitVRLittleEndianTransferSyntax())
        container.addUnsignedShort(0x0010)
        container.addSignedShort(-2)
        container.addUnsignedLong(0xDEADBEEF)
        container.addSignedLong(-5)
        container.addFloat(1.5)
        container.addDouble(-2.25)
        container.addString("ABC")
        container.addStringWithZeroPadding("1.2")
        XCTAssertEqual(container.length, 2 + 2 + 4 + 4 + 4 + 8 + 4 + 4)
        XCTAssertEqual(container.nextUnsignedShort(), 0x0010)
        XCTAssertEqual(container.nextSignedShort(), -2)
        XCTAssertEqual(container.nextUnsignedLong(), 0xDEADBEEF)
        XCTAssertEqual(container.nextSignedLong(), -5)
        XCTAssertEqual(container.nextFloat(), 1.5)
        XCTAssertEqual(container.nextDouble(), -2.25)
        XCTAssertEqual(container.nextString(withLength: 4), "ABC")
        XCTAssertEqual(container.nextString(withLength: 4), "1.2")
        XCTAssertFalse(container.dataRemaining())
        XCTAssertNotNil(container.testForLength(1))
    }

    func testBigEndianReading() {
        let container = DCMDataContainer(data: Data([0x00, 0x10, 0x00, 0x00, 0x00, 0x02]),
                                         transferSyntax: .explicitVRBigEndianTransferSyntax())
        XCTAssertFalse(container.isLittleEndian())
        XCTAssertEqual(container.nextUnsignedShort(), 0x0010)
        XCTAssertEqual(container.nextUnsignedLong(), 2)
    }

    func testSyntaxIsReadFromPartTenBytes() throws {
        var stream = Data(count: 128)
        stream.append(Data("DICM".utf8))
        stream.append(Data([0x02, 0x00, 0x00, 0x00, 0x55, 0x4C, 0x04, 0x00, 0, 0, 0, 0]))
        let container = try XCTUnwrap(DCMDataContainer(data: stream))
        XCTAssertEqual(container.offset, 132)
        XCTAssertEqual(container.position, 132)
        XCTAssertEqual(container.transferSyntaxInUse(), DCMTransferSyntax.explicitVRLittleEndianTransferSyntax())
        XCTAssertNil(DCMDataContainer(data: Data([1, 2])))
        XCTAssertNil(DCMDataContainer(data: nil))
    }

    func testObjectIsWrittenAsPartTenOrAsDataset() {
        let object = sampleObject()
        let whole = DCMDataContainer.dataContainer()
        XCTAssertTrue(object.write(to: whole, with: nil, asDICOM3: true))
        let bytes = whole.dicomData as Data
        XCTAssertEqual(bytes.subdata(in: 128..<132), Data("DICM".utf8))
        XCTAssertEqual(String(decoding: bytes.suffix(from: 132), as: UTF8.self), "META+SET[1.2.840.10008.1.2.1]1")
        XCTAssertEqual(StandInWriter.lastAET, "OSIRIX")
        // The group length went with the write, as in the former class.
        XCTAssertNil(object.attribute(for: DICOMAttributeTag(group: 0x0008, element: 0x0000)))

        let kept = sampleObject()
        let bare = DCMDataContainer.dataContainer()
        XCTAssertTrue(kept.write(to: bare, with: .implicitVRLittleEndianTransferSyntax(), quality: 2, asDICOM3: false,
                                 strippingGroupLengthLength: false))
        XCTAssertEqual(String(decoding: bare.dicomData as Data, as: UTF8.self), "SET[1.2.840.10008.1.2]2")
        XCTAssertEqual(bare.transferSyntaxForDataset(), DCMTransferSyntax.implicitVRLittleEndianTransferSyntax())
        XCTAssertNotNil(kept.attribute(for: DICOMAttributeTag(group: 0x0008, element: 0x0000)))

        let named = DCMDataContainer.dataContainer()
        XCTAssertTrue(sampleObject().write(to: named, with: nil, quality: 1, asDICOM3: true, aet: "PLUGIN",
                                           strippingGroupLengths: true))
        XCTAssertEqual(StandInWriter.lastAET, "PLUGIN")
        XCTAssertEqual(StandInWriter.lastQuality, 1)
        XCTAssertFalse(object.write(to: nil, with: nil, asDICOM3: true))
    }

    func testObjectIsReadFromAContainer() throws {
        let dataset = Data("0123456789".utf8)
        let container = DCMDataContainer(data: dataset, transferSyntax: .implicitVRLittleEndianTransferSyntax())
        var offset: Int32 = 2
        let object = try XCTUnwrap(DCMObject(dataContainer: container, lengthToRead: 5, byteOffset: &offset,
                                             characterSet: nil, decodingPixelData: false))
        XCTAssertEqual(StandInReader.lastData, Data("23456".utf8))
        XCTAssertEqual(StandInReader.lastSyntax, "1.2.840.10008.1.2")
        XCTAssertEqual(offset, 7)
        XCTAssertEqual(patientID(of: object), "READ")

        let more = sampleObject()
        XCTAssertEqual(more.readDataSet(container, lengthToRead: -1, byteOffset: &offset), 10)
        XCTAssertEqual(StandInReader.lastData, Data("789".utf8))
        XCTAssertEqual(patientID(of: more), "READ")
        XCTAssertEqual(more.readDataSet(container, lengthToRead: -1, byteOffset: &offset), -1)
        XCTAssertEqual(offset, -1)
    }

    func testSubclassesAnswerTheirOwnClass() throws {
        XCTAssertTrue(DCMObjectDBImport.object(withContentsOfFile: #filePath, decodingPixelData: false) is DCMObjectDBImport)
        XCTAssertTrue(DCMObjectPixelDataImport.object(withContentsOfFile: #filePath, decodingPixelData: false)
                        is DCMObjectPixelDataImport)
        XCTAssertNil(DCMObjectDBImport.object(withContentsOfFile: "/nonexistent/absent", decodingPixelData: false))
        let limited = try XCTUnwrap(DCMLimitedObject.object(withContentsOfFile: #filePath, lastGroup: 0x0020))
        XCTAssertEqual(StandInReader.lastGroup, 0x0020)
        XCTAssertEqual(patientID(of: limited), "READ")
        XCTAssertNotNil(DCMLimitedObject(data: Data([1]), lastGroup: 0x0008))
        XCTAssertEqual(StandInReader.lastGroup, 0x0008)
        XCTAssertNil(DCMLimitedObject(data: nil, lastGroup: 0x0008))
        var tag = Array("0010,0020".utf8CString)
        XCTAssertTrue(DCMObjectDBImport().isNeededAttribute(&tag))
    }

    func testAttributeWritesAndReadsItself() throws {
        let explicit = DCMTransferSyntax.explicitVRLittleEndianTransferSyntax()
        let container = DCMDataContainer(data: Data(), transferSyntax: explicit)
        let rows = DCMAttribute(attributeTag: DICOMAttributeTag(group: 0x0028, element: 0x0010), vr: "US",
                                values: NSMutableArray(array: [NSNumber(value: 512)]))
        XCTAssertTrue(rows.write(to: container, with: explicit))
        XCTAssertEqual([UInt8](container.dicomData as Data), [0x28, 0x00, 0x10, 0x00, 0x55, 0x53, 0x02, 0x00, 0x00, 0x02])
        let uid = DCMAttribute(attributeTag: DICOMAttributeTag(group: 0x0008, element: 0x0018), vr: "UI",
                               values: NSMutableArray(array: ["1.2.3"]))
        XCTAssertTrue(uid.write(to: container, with: explicit))
        XCTAssertEqual(container.dicomData.length, 10 + 8 + 6)

        XCTAssertEqual(container.nextUnsignedShort(), 0x0028)
        XCTAssertEqual(container.nextUnsignedShort(), 0x0010)
        XCTAssertEqual(container.nextString(withLength: 2), "US")
        let length = container.nextUnsignedShort()
        let read = DCMAttribute.attribute(with: DICOMAttributeTag(group: 0x0028, element: 0x0010), vr: "US",
                                          length: Int(length), data: container, specificCharacterSet: nil,
                                          isExplicit: true, forImplicitUseOW: false)
        XCTAssertEqual(read.values as? [NSNumber], [512])
        _ = container.skipLength(8)
        XCTAssertEqual(DCMAttribute(attributeTag: nil, vr: "UI", values: nil).values(forVR: "UI", length: 6, data: container)
                        as? [String], ["1.2.3"])

        let implicit = DCMDataContainer(data: Data(), transferSyntax: .implicitVRLittleEndianTransferSyntax())
        rows.writeBase(to: implicit, transferSyntax: .implicitVRLittleEndianTransferSyntax())
        XCTAssertEqual([UInt8](implicit.dicomData as Data), [0x28, 0x00, 0x10, 0x00, 0x02, 0x00, 0x00, 0x00])
    }
}
