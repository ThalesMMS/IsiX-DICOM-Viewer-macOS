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
import XCTest
@testable import IsiXDICOMDataset

/// The model without a host: what it computes itself. Reading, writing and
/// decoding encapsulated pixels need the DCMTK adapter and are checked by the
/// tests of tests/ against the Debug build.
final class DCMDatasetTests: XCTestCase {

    func testTransferSyntaxesWithoutDCMTK() throws {
        let big = DCMTransferSyntax.explicitVRBigEndianTransferSyntax()
        XCTAssertEqual(big.name, "ExplicitVRBigEndian")
        XCTAssertFalse(big.isLittleEndian)
        XCTAssertFalse(big.isEncapsulated)
        let implicit = DCMTransferSyntax.implicitVRLittleEndianTransferSyntax()
        XCTAssertFalse(implicit.isExplicit)
        XCTAssertTrue(DCMTransferSyntax.rleLosslessTransferSyntax().isEncapsulated)
        let unknown = try XCTUnwrap(DCMTransferSyntax(ts: "1.2.3"))
        XCTAssertEqual(unknown.name, "Unknown Syntax")
        XCTAssertNil(DCMTransferSyntax(ts: ""))
        XCTAssertEqual(DCMTransferSyntax(ts: "1.2.840.10008.1.2.1"), DCMTransferSyntax.explicitVRLittleEndianTransferSyntax())
    }

    func testValueLengthFollowsTheVR() {
        func length(_ vr: String, _ values: [Any]) -> Int {
            DCMAttribute(attributeTag: DICOMAttributeTag(group: 0x0009, element: 0x0010), vr: vr,
                         values: NSMutableArray(array: values)).valueLength
        }
        XCTAssertEqual(length("US", [1, 2, 3]), 6)
        XCTAssertEqual(length("FD", [1.5]), 8)
        XCTAssertEqual(length("DA", [DICOMCalendarDate.calendarDate(), DICOMCalendarDate.calendarDate()]), 17)
        XCTAssertEqual(length("OB", [Data(count: 5), Data(count: 3)]), 8)
        XCTAssertEqual(length("LO", ["Ab", "Ç"]), 4)
        XCTAssertEqual(DCMSequenceAttribute(attributeTag: nil).valueLength, 0xFFFFFFFF)
    }

    func testAnonymizedStringsAreStable() {
        let object = DCMObject(transferSyntax: nil, characterSet: DICOMCharacterSet(code: "ISO_IR 100"), isSequence: false)
        let first = object.anonymizeString("DOE^JANE")
        XCTAssertEqual(first, object.anonymizeString("DOE^JANE"))
        XCTAssertEqual(first?.count, 8)
        XCTAssertNotEqual(first, object.anonymizeString("DOE^JOHN"))
    }

    func testPaletteFramesBecomeRGB() {
        let object = DCMObject()
        object.setAttributeValues(NSMutableArray(object: "PALETTE COLOR"), forName: "PhotometricInterpretation")
        for (name, table) in [("Red", [0, 255]), ("Green", [10, 20]), ("Blue", [30, 40])] {
            object.setAttributeValues(NSMutableArray(array: [2, 0, 8]), forName: "\(name)PaletteColorLookupTableDescriptor")
            object.setAttributeValues(NSMutableArray(object: Data(table.map { UInt8($0) })),
                                      forName: "\(name)PaletteColorLookupTableData")
        }
        for (name, value) in [("Rows", 1), ("Columns", 3), ("BitsStored", 8), ("BitsAllocated", 8), ("SamplesperPixel", 1)] {
            object.setAttributeValues(NSMutableArray(object: value), forName: name)
        }
        let pixels = DCMPixelDataAttribute(attributeTag: DICOMAttributeTag.tag(withName: "PixelData"), vr: "OB",
                                           values: NSMutableArray(object: Data([0, 1, 7])), object: object,
                                           transferSyntax: DCMTransferSyntax.explicitVRLittleEndianTransferSyntax(),
                                           frameSource: nil)
        object.setAttribute(pixels)
        // Values past the last entry take the last.
        XCTAssertEqual(pixels.decodeFrame(at: 0) as Data?, Data([0, 10, 30, 255, 20, 40, 255, 20, 40]))
        XCTAssertNil(pixels.decodeFrame(at: 1))
    }

    func testYBRFullBecomesRGB() {
        let object = DCMObject()
        let pixels = DCMPixelDataAttribute(attributeTag: nil, vr: "OB", values: NSMutableArray(), object: object,
                                           transferSyntax: nil, frameSource: nil)
        pixels.rows = 1
        pixels.columns = 2
        let rgb = pixels.convertYBrToRGB(Data([128, 128, 128, 255, 128, 128]) as NSData, kind: "YBR_FULL", isPlanar: false)
        XCTAssertEqual(rgb as Data?, Data([128, 128, 128, 255, 255, 255]))
        XCTAssertNil(pixels.convertYBrToRGB(Data(count: 6) as NSData, kind: "YBR_FULL_422", isPlanar: true))
    }

    func testSecondaryCaptureClassesFollowTheBitDepth() {
        XCTAssertEqual(DCMObject.secondaryCaptureObject(withBitDepth: 8, samplesPerPixel: 3, numberOfFrames: 2)
            .attributeValue(withName: "SOPClassUID") as? String, "1.2.840.10008.5.1.4.1.1.7.4")
        XCTAssertEqual(DCMObject.secondaryCaptureObject(withBitDepth: 16, samplesPerPixel: 1, numberOfFrames: 2)
            .attributeValue(withName: "SOPClassUID") as? String, "1.2.840.10008.5.1.4.1.1.7.3")
        XCTAssertEqual(DCMObject.secondaryCaptureObject(withBitDepth: 8, samplesPerPixel: 1, numberOfFrames: 1)
            .attributeValue(withName: "SOPClassUID") as? String, "1.2.840.10008.5.1.4.1.1.7")
        let pdf = DCMObject.encapsulatedPDF(Data("%PDF".utf8))
        XCTAssertEqual(pdf.attributeValue(withName: "MIMETypeOfEncapsulatedDocument") as? String, "application/pdf")
        XCTAssertEqual((pdf.attributeValue(withName: "SOPInstanceUID") as? String)?.hasPrefix("1.3.6.1.4.1.19291.2.1.3."), true)
    }
}
