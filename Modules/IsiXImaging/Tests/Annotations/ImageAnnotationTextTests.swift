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
import Testing
@testable import IsiXImaging

/// The rules of the custom annotations and of the encapsulated documents on
/// their own. The comparison with the Objective-C they replaced is
/// tests/test-dcmpix-annotations-documents-rtstruct.py.
struct ImageAnnotationTextTests {
    private let templates: NSDictionary = [
        "CT": ["TopLeft": [], "sameAsDefault": 0],
        "MR": ["TopLeft": [], "sameAsDefault": 1],
        "PT": ["TopLeft": [], "sameAsDefault": "1"],
        "Default": ["MiddleLeft": [], "sameAsDefault": 0],
    ]

    @Test func aModalityHasItsOwnTemplateUnlessItIsTheDefaultOne() {
        #expect(ImageAnnotationText.template(forModality: "CT", in: templates)?.object(forKey: "TopLeft") != nil)
        for modality in ["MR", "PT", "US", nil] as [String?] {
            #expect(ImageAnnotationText.template(forModality: modality, in: templates)?.object(forKey: "MiddleLeft") != nil)
        }
        #expect(ImageAnnotationText.template(forModality: "CT", in: nil) == nil)
    }

    @Test func theRepetitionAndEchoTimesComeFromTheReadingToSixDigits() {
        #expect(ImageAnnotationText.readField(group: 0x18, element: 0x80) == .repetitionTime)
        #expect(ImageAnnotationText.readField(group: 0x18, element: 0x81) == .echoTime)
        #expect(ImageAnnotationText.readField(group: 0x10, element: 0x10) == nil)
        #expect(ImageAnnotationText.decimal(("2500.123456" as NSString).floatValue) == "2500.12")
        #expect(ImageAnnotationText.decimal(12.5) == "12.5")
    }

    @Test func valuesAreJoinedAndAnEmptyOneIsADash() {
        #expect(ImageAnnotationText.joined([]) == nil)
        #expect(ImageAnnotationText.joined(["0.703125", "0.703125"]) == "0.703125 / 0.703125")
        #expect(ImageAnnotationText.shown(nil) == ("-", false))
        #expect(ImageAnnotationText.shown("") == ("-", false))
        #expect(ImageAnnotationText.shown("AXIAL") == ("AXIAL", true))
    }

    @Test func manualTextIsFollowedByASpace() {
        #expect(ImageAnnotationText.manual(nil) == "- ")
        #expect(ImageAnnotationText.manual("") == "- ")
        #expect(ImageAnnotationText.manual("TR") == "TR ")
    }

    @Test func theSpecialFieldsAreKnownByEitherName() {
        let special = { ImageAnnotationText.special($0, localizedActualAge: "Idade", localizedAgeAtAcquisition: "Idade no exame") }
        #expect(special("Patient's Actual Age") == .actualAge)
        #expect(special("Idade") == .actualAge)
        #expect(special("Patient's Age At Acquisition") == .ageAtAcquisition)
        #expect(special("Idade no exame") == .ageAtAcquisition)
        #expect(special("Something else") == .other)
        #expect(special(nil) == .other)
    }
}

struct EncapsulatedDocumentTests {
    @Test func theKindComesFromTheSOPClass() {
        let kind = { EncapsulatedDocument.kind(sopClassUID: $0, pdfStorage: "1.2.840.10008.5.1.4.1.1.104.1", cdaStorage: "1.2.840.10008.5.1.4.1.1.104.2") }
        #expect(kind("1.2.840.10008.5.1.4.1.1.104.1") == .pdf)
        #expect(kind("1.2.840.10008.5.1.4.1.1.104.2") == .cda)
        #expect(kind("1.2.840.10008.5.1.4.1.1.88.33") == .structuredReport)
        #expect(kind("1.2.840.10008.5.1.4.1.1.2") == .other)
        #expect(kind(nil) == .other)
    }

    @Test func aReportIsRenderedNextToTheOthersByTheFileName() {
        let paths = EncapsulatedDocument.renderings(of: "/data/DATABASE/12/sr.dcm", in: "/tmp/horos")
        #expect(paths.xml == "/tmp/horos/dicomsr_osirix/sr.dcm.xml")
        #expect(paths.pdf == "/tmp/horos/dicomsr_osirix/sr.dcm.xml.pdf")
    }
}
