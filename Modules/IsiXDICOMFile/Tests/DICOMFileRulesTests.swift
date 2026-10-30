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
@testable import IsiXDICOMFile

// Values worked out by hand. The comparison with the Objective-C the module
// replaced runs outside the package, in tests/.
@Suite struct DICOMFileRulesTests {
    private func cleaned(_ text: String) -> String {
        ImportedText.cleaned(text as NSString)! as String
    }

    @Test func statedCharacterSetFillsTheTable() {
        let latin1 = String.Encoding.isoLatin1.rawValue, utf8 = String.Encoding.utf8.rawValue
        let japanese = String.Encoding.iso2022JP.rawValue
        #expect(DICOMCharacterSet.encodings(forSpecificCharacterSet: "ISO_IR 192") == [UInt](repeating: utf8, count: 10))
        #expect(DICOMCharacterSet.encodings(forSpecificCharacterSet: "\\ISO 2022 IR 87")
                == [DICOMCharacterSet.encoding(forDICOMCharacterSet: "")] + [UInt](repeating: japanese, count: 9))
        let absent = DICOMCharacterSet.encodings(forSpecificCharacterSet: nil)
        #expect(absent == [DICOMCharacterSet.encoding(forDICOMCharacterSet: nil)] + [UInt](repeating: 0, count: 9))
        let tooMany = Array(repeating: "ISO_IR 100", count: 10).joined(separator: "\\")
        #expect(DICOMCharacterSet.encodings(forSpecificCharacterSet: tooMany) == absent)
        #expect(DICOMCharacterSet.encodings(forSpecificCharacterSet: "ISO_IR 100")[9] == latin1)
    }

    @Test func textIsCleanedAsBefore() {
        #expect(cleaned("DOE^JOHN") == "DOE JOHN")
        #expect(cleaned("A,B/C\r\n\"D\"") == "A B-C'D'")
        #expect(cleaned("a      b") == "a b")         // six spaces: two, then one
        #expect(cleaned("a    b") == "a b")           // four: two, then one
        #expect(cleaned("a     b") == "a  b")         // five: three, then two
        #expect(cleaned("name   ") == "name")
        #expect(cleaned("   ") == " ")                // the first character stays
        #expect(cleaned("") == "")
        // Outside ASCII the Foundation searches run, with the same result here.
        #expect(cleaned("JOSÉ^ÁLVARO  ") == "JOSÉ ÁLVARO")
        #expect(ImportedText.cleaned(nil) == nil)
    }

    @Test func cStringIsCleanedForLatin1Only() {
        var bytes = Array("A/B^C  ".utf8CString)
        bytes.withUnsafeMutableBufferPointer { buffer in
            ImportedText.cleanCString(buffer.baseAddress!, encoding: String.Encoding.isoLatin1.rawValue)
        }
        #expect(String(cString: bytes) == "A-B C")
        var other = Array("A/B ".utf8CString)
        other.withUnsafeMutableBufferPointer { buffer in
            ImportedText.cleanCString(buffer.baseAddress!, encoding: String.Encoding.utf8.rawValue)
        }
        #expect(String(cString: other) == "A/B ")
    }

    @Test func textIsDecodedAcrossEscapeSequences() {
        let latin1 = String.Encoding.isoLatin1.rawValue
        let encodings: [UInt] = [latin1, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        func decode(_ bytes: [UInt8]) -> String {
            let text = bytes.map { CChar(bitPattern: $0) } + [0]
            return text.withUnsafeBufferPointer { pointer in
                encodings.withUnsafeBufferPointer { list in
                    DICOMTextDecoding.decode(pointer.baseAddress!, encodings: list.baseAddress!) { term in
                        term == "ISO 2022 IR 144" ? String.Encoding.windowsCP1251.rawValue : latin1
                    } as String
                }
            }
        }
        #expect(decode(Array("DOE^JOHN".utf8)) == "DOE^JOHN")
        #expect(decode([0x4A, 0xC9]) == "JÉ")
        #expect(decode(Array("A=B".utf8)) == "A=B")
        #expect(decode([0x1B, 0x28, 0x42, 0x41]) == "A")
    }

    @Test func fileNamesGiveTheirTrailingNumber() {
        #expect(FileNameNumbering.trailingNumber(of: "scan0001")! == ("0001", 4))
        #expect(FileNameNumbering.trailingNumber(of: "scan12345")! == ("2345", 5))
        #expect(FileNameNumbering.trailingNumber(of: "x001")! == ("001", 1))
        #expect(FileNameNumbering.trailingNumber(of: "a12")! == ("12", 1))
        #expect(FileNameNumbering.trailingNumber(of: "7")! == ("7", 0))
        #expect(FileNameNumbering.trailingNumber(of: "image") == nil)
        #expect(FileNameNumbering.trailingNumber(of: "") == nil)
    }

    @Test func patientUIDJoinsTheWantedParts() {
        var settings = ImportSettings()
        #expect(PatientUIDRule.uid(name: "Doe^John-Paul=ドウ", patientID: "id-1", birthDate: "19700101",
                                   settings: settings) == "DOE JOHN PAUL-ID-1-19700101")
        #expect(PatientUIDRule.uid(name: nil, patientID: nil, birthDate: nil, settings: settings) == "(NULL)-(NULL)-")
        settings.usePatientBirthDateForUID = false
        settings.usePatientNameForUID = false
        #expect(PatientUIDRule.uid(name: "X", patientID: NSNumber(value: 12), birthDate: "1", settings: settings) == "-12-")
    }

    @Test func settingsReadFromADictionaryKeepWhatABOOLKept() {
        let settings = ImportSettings(dictionary: ["NOLOCALIZER": 256, "splitMultiEchoMR": "1",
                                                   "COMMENTSGROUP": 16, "combineProjectionSeriesMode": 2])
        #expect(settings.noLocalizer == false)
        #expect(settings.splitMultiEchoMR == true)
        #expect(settings.commentsGroup == 16)
        #expect(settings.combineProjectionSeriesMode == 2)
        #expect(settings.usePatientIDForUID == false)
        let store = ImportSettingsStore()
        #expect(store.settings == ImportSettings())
        store.load { settings }
        store.load { ImportSettings() }
        #expect(store.settings == settings)
        store.reset()
        #expect(store.settings == settings)
        store.load { ImportSettings() }
        #expect(store.settings == ImportSettings())
    }

    @Test func headersOfTheOtherFormats() {
        var analyze = Data(count: 348)
        analyze.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for (i, c) in "brain".utf8.enumerated() { bytes[14 + i] = c }
            for (i, c) in "20240102".utf8.enumerated() { bytes[293 + i] = c }
            let shorts: [(Int, Int16)] = [(40, 3), (42, 4), (44, 5), (46, 6), (70, 4)]
            for (offset, value) in shorts { raw.storeBytes(of: value.littleEndian, toByteOffset: offset, as: Int16.self) }
        }
        let header = AnalyzeImportHeader(analyze)!
        #expect(header.height == 4 && header.width == 5 && header.frames == 6)
        #expect(header.imageBytes == 4 * 5 * 6 * 2)
        #expect(String(decoding: header.databaseName, as: UTF8.self) == "brain")
        #expect(String(decoding: header.experimentDate, as: UTF8.self) == "20240102")
        #expect(AnalyzeImportHeader(Data(count: 10)) == nil)

        var biorad = Data(count: 76)
        biorad.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt16(64).littleEndian, toByteOffset: 0, as: UInt16.self)
            raw.storeBytes(of: UInt16(32).littleEndian, toByteOffset: 2, as: UInt16.self)
            raw.storeBytes(of: UInt16(40000).littleEndian, toByteOffset: 4, as: UInt16.self)
        }
        let pic = BioradImportHeader(biorad)
        #expect(pic.width == 64 && pic.height == 32 && pic.frames == 40000)

        #expect(NIfTIImportRules.voxelBytes(dimensions: [3, 4, 5, 0, 1, 1, 1, 1], bytesPerVoxel: 2) == 40)
        #expect(NIfTIImportRules.voxelBytes(dimensions: [8, 4, 5, 6, 1, 1, 1, 1], bytesPerVoxel: 2) == 0)
        #expect(NIfTIImportRules.voxelOffset(0, singleFile: true) == 348)
        #expect(NIfTIImportRules.voxelOffset(-5, singleFile: false) == 0)
        #expect(NIfTIImportRules.voxelOffset(.nan, singleFile: false) == 0)
    }

    @Test func fluoViewSeriesAreNamedByTheirPositions() {
        let dimensions = [FluoViewSeries.Dimension(name: "X", size: 512), .init(name: "Y", size: 512),
                          .init(name: "Z", size: 10), .init(name: "Ch", size: 2), .init(name: "T", size: 3)]
        #expect(FluoViewSeries.counts(dimensions) == (10, 6))
        #expect(FluoViewSeries.description(ofSeries: 0, dimensions) == "FV T 0, Ch 0")
        #expect(FluoViewSeries.description(ofSeries: 5, dimensions) == "FV T 2, Ch 1")
    }

    @Test func unusedFluoViewDimensionsOfSizeZeroLeaveTheSeries() {
        let unused = [FluoViewSeries.Dimension(name: "", size: 0), .init(name: "T", size: 0)]
        let stack = [FluoViewSeries.Dimension(name: "X", size: 6), .init(name: "Y", size: 4),
                     .init(name: "Z", size: 3), .init(name: "Ch", size: 2)] + unused
        #expect(FluoViewSeries.counts(stack) == (3, 2))
        #expect(FluoViewSeries.description(ofSeries: 0, stack) == "FV Ch 0")
        #expect(FluoViewSeries.description(ofSeries: 1, stack) == "FV Ch 1")
        let flat = [FluoViewSeries.Dimension(name: "X", size: 6), .init(name: "Y", size: 4),
                    .init(name: "Z", size: 0), .init(name: "Ch", size: 3)] + unused
        #expect(FluoViewSeries.counts(flat) == (1, 3))
        #expect(FluoViewSeries.description(ofSeries: 2, flat) == "FV Ch 2")
    }
}
