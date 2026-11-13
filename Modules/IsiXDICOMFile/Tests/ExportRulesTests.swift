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

@Suite struct SelectedFieldAnonymizationTests {

    typealias Rules = SelectedFieldAnonymization

    func facts(exists: Bool = false, pixel: Bool = false, vr: String = "", dictionary: String = "LO",
               policy: Int = 1) -> Rules.ElementFacts {
        Rules.ElementFacts(exists: exists, isPixelData: pixel, valueRepresentation: vr,
                           dictionaryValueRepresentation: dictionary, catalogPolicy: policy)
    }

    @Test func acceptsTheListedStorageClassesOnly() {
        #expect(Rules.isSupportedStorage("1.2.840.10008.5.1.4.1.1.2"))
        #expect(Rules.isSupportedStorage(Rules.directoryStorageClass))
        #expect(!Rules.isSupportedStorage("1.2.840.10008.5.1.4.1.1.2.2"))
        #expect(!Rules.isSupportedStorage(""))
        #expect(!Rules.isSupportedStorage(nil))
        #expect(Rules.supportedStorageClasses.count == 65)
    }

    @Test func privateGroupsAndCreatorsAreDCMTKs() {
        #expect(Rules.isPrivate(group: 0x0009))
        #expect(!Rules.isPrivate(group: 0x0007))
        #expect(!Rules.isPrivate(group: 0xffff))
        #expect(!Rules.isPrivate(group: 0x0010))
        #expect(Rules.isPrivateCreator(0x0009_0010))
        #expect(Rules.isPrivateCreator(0x0009_00ff))
        #expect(!Rules.isPrivateCreator(0x0009_1010))
        #expect(!Rules.isPrivateCreator(0x0009_000f))
        #expect(Rules.tagText(0x0010_0010) == "(0010,0010)")
        #expect(Rules.tagText(0x7fe0_0010) == "(7FE0,0010)")
        #expect(Rules.outputName(for: "IM1.dcm") == "anon_IM1.dcm")
    }

    @Test func replacementsFollowTheCatalogPolicy() {
        // Below group 8 nothing is replaced.
        #expect(Rules.replacement(for: 0x0002_0010, valueIsEmpty: true, facts: facts(policy: 2)) == .refuse)
        // A private element is only emptied, and only when present.
        #expect(Rules.replacement(for: 0x0009_1010, valueIsEmpty: true, facts: facts(exists: true, vr: "SQ")) == .clearExisting)
        #expect(Rules.replacement(for: 0x0009_1010, valueIsEmpty: false, facts: facts(exists: true)) == .refuse)
        #expect(Rules.replacement(for: 0x0009_1010, valueIsEmpty: true, facts: facts()) == .refuse)
        // A private creator is text, as LO.
        #expect(Rules.replacement(for: 0x0009_0010, valueIsEmpty: false, facts: facts(dictionary: "UN", policy: 0)) == .insertText)
        // Not in the catalog.
        #expect(Rules.replacement(for: 0x0010_0010, valueIsEmpty: false, facts: facts(policy: 0)) == .refuse)
        // An empty sequence only.
        #expect(Rules.replacement(for: 0x0008_1110, valueIsEmpty: true, facts: facts(policy: 3)) == .insertEmptySequence)
        #expect(Rules.replacement(for: 0x0008_1110, valueIsEmpty: false, facts: facts(policy: 3)) == .refuse)
        // Empty only.
        #expect(Rules.replacement(for: 0x7fe0_0010, valueIsEmpty: true,
                                  facts: facts(exists: true, pixel: true, vr: "OW", dictionary: "ox", policy: 2)) == .emptyPixelData)
        #expect(Rules.replacement(for: 0x0008_0000, valueIsEmpty: true, facts: facts(exists: true, vr: "UL", policy: 2)) == .clearExisting)
        #expect(Rules.replacement(for: 0x0008_0000, valueIsEmpty: true, facts: facts(dictionary: "UL", policy: 2)) == .insertEmpty)
        #expect(Rules.replacement(for: 0x0008_0000, valueIsEmpty: true, facts: facts(dictionary: "UN", policy: 2)) == .refuse)
        #expect(Rules.replacement(for: 0x0008_0000, valueIsEmpty: true, facts: facts(dictionary: "??", policy: 2)) == .refuse)
        #expect(Rules.replacement(for: 0x0008_0000, valueIsEmpty: false, facts: facts(dictionary: "UL", policy: 2)) == .refuse)
        // Text.
        #expect(Rules.replacement(for: 0x0010_0010, valueIsEmpty: false, facts: facts(exists: true, vr: "PN", dictionary: "PN")) == .putIntoExisting)
        #expect(Rules.replacement(for: 0x0010_0010, valueIsEmpty: false, facts: facts(dictionary: "PN")) == .insertText)
        #expect(Rules.replacement(for: 0x0010_0010, valueIsEmpty: false, facts: facts(exists: true, vr: "OB", dictionary: "PN")) == .refuse)
        #expect(Rules.replacement(for: 0x0028_0010, valueIsEmpty: false, facts: facts(dictionary: "US")) == .refuse)
    }

    @Test func textIsPlannedBeforeAnyCharacterSet() {
        func plan(_ text: String, vr: String = "PN", creator: Bool = false, declaration: String = "") -> Rules.TextPlan {
            let units = Array(text.utf16)
            return Rules.textPlan(utf8: Array(text.utf8), utf16: units, valueRepresentation: vr, privateCreator: creator,
                                  declaration: Array(declaration.utf8), isASCII: text.allSatisfy(\.isASCII))
        }
        #expect(Rules.textPlan(utf8: nil, utf16: [UInt16](), valueRepresentation: "PN", privateCreator: false,
                               declaration: [], isASCII: true) == .refuse)
        #expect(plan("") == .empty)
        #expect(plan("A\u{0}B") == .refuse)
        #expect(plan("A\u{1b}B") == .refuse)
        #expect(plan("A\u{85}B") == .refuse)
        #expect(plan("Name") == .foundation(useFallback: true))
        #expect(plan("Name", vr: "CS") == .foundation(useFallback: false))
        #expect(plan("Name", creator: true, declaration: "ISO_IR 100") == .foundation(useFallback: false))
        #expect(plan("José", declaration: "ISO_IR 100") == .declared(codeExtensions: false))
        #expect(plan("Name", declaration: "\\ISO 2022 IR 87") == .declared(codeExtensions: true))
        #expect(plan("José", declaration: "ISO 2022 IR 100") == .refuse)
        #expect(Rules.conversionDelimiters("PN") == "\\^=")
        #expect(Rules.conversionDelimiters("LT") == "")
        #expect(Rules.conversionDelimiters("LO") == "\\")
    }
}

@Suite struct DicomDirExportRulesTests {

    @Test func indexesSourceFilesOnly() {
        #expect(DicomDirExportRules.indexes(relativePath: "IMAGES/IM1"))
        #expect(DicomDirExportRules.indexes(relativePath: "DICOMDIR.TXT"))
        #expect(!DicomDirExportRules.indexes(relativePath: "DICOMDIR"))
        #expect(!DicomDirExportRules.indexes(relativePath: "DICOMDIR.BAK"))
        #expect(!DicomDirExportRules.indexes(relativePath: "IMAGES/.DS_Store"))
        #expect(!DicomDirExportRules.indexes(relativePath: "IMAGES/._IM1"))
        #expect(!DicomDirExportRules.indexes(relativePath: ".horos-zip-1234/archive.zip"))
        #expect(DicomDirExportRules.indexes(relativePath: "IMAGES/.horos-zip-1234"))
    }
}

@Suite struct DICOMDateTimeTextTests {

    @Test func writesTheContainingSecondAndItsFraction() {
        let utc = TimeZone(identifier: "UTC")!
        // 2026-10-28 13:45:07.25 UTC.
        let date = Date(timeIntervalSince1970: 1_793_195_107.25)
        #expect(DICOMDateTimeText.date(date, timeZone: utc) == "20261028")
        #expect(DICOMDateTimeText.time(date, fraction: false, timeZone: utc) == "134507.000000")
        #expect(DICOMDateTimeText.time(date, fraction: true, timeZone: utc) == "134507.250000")
        #expect(DICOMDateTimeText.parseDate("20261028", timeZone: utc) == Date(timeIntervalSince1970: 1_793_145_600))
        #expect(DICOMDateTimeText.parseDate("20261028XYZ", timeZone: utc) == Date(timeIntervalSince1970: 1_793_145_600))
        #expect(DICOMDateTimeText.parseDate("20261328", timeZone: utc) == nil)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let januaryFirst = calendar.date(from: DateComponents(year: calendar.component(.year, from: Date()), month: 1, day: 1))
        #expect(DICOMDateTimeText.parseDate("", timeZone: utc) == januaryFirst)
        let late = Date(timeIntervalSince1970: 1_793_195_107.9999996)
        #expect(DICOMDateTimeText.time(late, fraction: false, timeZone: utc) == "134507.000000")
    }
}

@Suite struct SecondaryCaptureExportTests {

    typealias Export = SecondaryCaptureExport

    @Test func refusesWhatItCannotWrite() {
        #expect(Export.refusal(samplesPerPixel: 1, bitsPerSample: 16) == nil)
        #expect(Export.refusal(samplesPerPixel: 3, bitsPerSample: 8) == nil)
        #expect(Export.refusal(samplesPerPixel: 4, bitsPerSample: 8)?.contains("sample per pixel") == true)
        #expect(Export.refusal(samplesPerPixel: 3, bitsPerSample: 16)?.contains("only 8 bits") == true)
        #expect(Export.refusal(samplesPerPixel: 1, bitsPerSample: 12)?.contains("unknown bits") == true)
        #expect(Export.bitLayout(bitsPerSample: 16)! == (15, 16))
    }

    @Test func premultipliesAlpha() {
        let rgba: [UInt8] = [200, 100, 50, 255, 200, 100, 50, 128, 10, 20, 30, 0]
        var rgb = [UInt8](repeating: 0, count: 9)
        rgba.withUnsafeBufferPointer { source in
            rgb.withUnsafeMutableBufferPointer { target in
                Export.premultipliedRGB(rgba: source.baseAddress!, rgb: target.baseAddress!, width: 3, height: 1)
            }
        }
        #expect(rgb == [200, 100, 50, 100, 50, 25, 0, 0, 0])
    }

    @Test func squaresAndTurns() {
        #expect(Export.squarePixelHeight(height: 101, spacingX: 0.5, spacingY: 1) == 202)
        #expect(Export.squarePixelHeight(height: 101, spacingX: 1, spacingY: 0.7) == 70)
        // An axial image turned: its rows become columns.
        let plane = Export.turnedPlane(.init(orientation: [1, 0, 0, 0, 1, 0], position: [10, 20, 30]),
                                       width: 4, spacingX: 0.5, spacingY: 2)
        #expect(plane.position == [10, 28, 30])
        #expect(plane.orientation.map { ($0 * 1e6).rounded() / 1e6 } == [0, -1, 0, 1, 0, 0])
        let none = Export.turnedPlane(.init(orientation: [0, 0, 0, 0, 1, 0], position: [1, 2, 3]),
                                      width: 4, spacingX: 1, spacingY: 1)
        #expect(none.position == [1, 2, 3])
        // 2 x 3 pixels turned into 3 x 2.
        var pixels: [UInt16] = [1, 2, 3, 4, 5, 6]
        let turned = pixels.withUnsafeMutableBytes {
            Export.turnPixels($0.baseAddress!, width: 2, height: 3, bitsPerSample: 16, samplesPerPixel: 1)
        }
        #expect(turned)
        #expect(pixels == [4, 1, 5, 2, 6, 3])
    }

    @Test func listsTheImageAttributes() {
        let image = Export.Image(width: 64, height: 32, samplesPerPixel: 1, bitsPerSample: 16, isSigned: false,
                                 offset: -1024, slope: 1, windowWidth: 400, windowLevel: 40, spacingX: 0.5, spacingY: 0.5,
                                 sliceThickness: 2.5, orientation: [1, 0, 0, 0, 1, 0], position: [1, 2, 3],
                                 slicePosition: nil)
        let edits = Export.imageEdits(image, instanceNumber: 7, modalityAsSource: true, sourceModality: "CT")
        #expect(edits.first == .remove(0x0002_0002))
        #expect(edits.contains(.put(0x0020_0013, "7")))
        #expect(edits.contains(.put(0x0028_0030, "0.500000\\0.500000")))
        #expect(edits.contains(.put(0x0020_0037, "1.000000\\0.000000\\0.000000\\0.000000\\1.000000\\0.000000")))
        #expect(edits.contains(.put(0x0028_1052, "-1024")))
        #expect(edits.contains(.put(0x0028_1054, "HU")))
        #expect(edits.contains(.put(0x0028_1050, "40")))
        #expect(!edits.contains(where: { if case .put(0x0020_1041, _) = $0 { return true }; return false }))
        let colour = Export.Image(width: 3, height: 3, samplesPerPixel: 3, bitsPerSample: 8, isSigned: false, offset: 0,
                                  slope: 1, windowWidth: -1, windowLevel: -1, spacingX: 0, spacingY: 0, sliceThickness: 0,
                                  orientation: [0, 0, 0, 0, 0, 0], position: nil, slicePosition: nil)
        let colourEdits = Export.imageEdits(colour, instanceNumber: 1, modalityAsSource: true, sourceModality: "CT")
        #expect(colourEdits.prefix(3) == [.put(0x0008_0060, "SC"), .putMeta(0x0002_0002, Export.secondaryCaptureStorage),
                                          .put(0x0008_0016, Export.secondaryCaptureStorage)])
        #expect(colourEdits.contains(.put(0x0028_0006, "0")))
        #expect(colourEdits.contains(.remove(0x0028_1052)))
        #expect(Export.pixelDataLength(colour).count == 27)
        #expect(Export.pixelDataLength(image) == (2048, true))
    }

    /// A picture of the screen is already in the polarity it showed: the
    /// source's Presentation LUT goes, shape or table. Stored values keep it.
    @Test func dropsThePresentationLUTOfTheSourceFromAPictureOfTheScreen() {
        func edits(samplesPerPixel: Int, bitsPerSample: Int, modalityAsSource: Bool) -> [Export.Edit] {
            let image = Export.Image(width: 8, height: 8, samplesPerPixel: samplesPerPixel, bitsPerSample: bitsPerSample,
                                     isSigned: false, offset: 0, slope: 1, windowWidth: 400, windowLevel: 40, spacingX: 0,
                                     spacingY: 0, sliceThickness: 0, orientation: [0, 0, 0, 0, 0, 0], position: nil,
                                     slicePosition: nil)
            return Export.imageEdits(image, instanceNumber: 1, modalityAsSource: modalityAsSource, sourceModality: "DX")
        }
        let shape = Export.Edit.remove(0x2050_0020), table = Export.Edit.remove(0x2050_0010)
        #expect(Export.sourcePresentationLUT.sorted() == [0x2050_0010, 0x2050_0020])
        for modalityAsSource in [false, true] {
            for samplesPerPixel in [1, 3] {
                let screen = edits(samplesPerPixel: samplesPerPixel, bitsPerSample: 8, modalityAsSource: modalityAsSource)
                #expect(screen.contains(shape) && screen.contains(table))
                #expect(!screen.contains(where: { if case .put(let tag, _) = $0 { return tag >> 16 == 0x2050 }; return false }))
            }
            for bitsPerSample in [16, 32] {
                let stored = edits(samplesPerPixel: 1, bitsPerSample: bitsPerSample, modalityAsSource: modalityAsSource)
                #expect(!stored.contains(shape) && !stored.contains(table))
            }
        }
    }

    /// Stored values written over a MONOCHROME1 source are MONOCHROME1 still;
    /// a picture of the screen, and anything over another source, is not.
    @Test func keepsThePhotometricInterpretationOfStoredValues() {
        func image(samplesPerPixel: Int = 1, bitsPerSample: Int) -> Export.Image {
            Export.Image(width: 8, height: 6, samplesPerPixel: samplesPerPixel, bitsPerSample: bitsPerSample, isSigned: false,
                         offset: 0, slope: 1, windowWidth: -1, windowLevel: -1, spacingX: 0, spacingY: 0, sliceThickness: 0,
                         orientation: [0, 0, 0, 0, 0, 0], position: nil, slicePosition: nil)
        }
        let inverted = Export.Source(modality: "DX", photometricInterpretation: "MONOCHROME1 ", rows: 6, columns: 8)
        #expect(Export.photometricInterpretation(image(bitsPerSample: 16), source: inverted) == "MONOCHROME1")
        #expect(Export.photometricInterpretation(image(bitsPerSample: 32), source: inverted) == "MONOCHROME1")
        #expect(Export.photometricInterpretation(image(bitsPerSample: 8), source: inverted) == "MONOCHROME2")
        #expect(Export.photometricInterpretation(image(samplesPerPixel: 3, bitsPerSample: 8), source: inverted) == "RGB")
        for other in ["MONOCHROME2", "PALETTE COLOR", "RGB", nil] {
            let source = Export.Source(modality: "CT", photometricInterpretation: other, rows: 6, columns: 8)
            #expect(Export.photometricInterpretation(image(bitsPerSample: 16), source: source) == "MONOCHROME2")
        }
        let edits = Export.imageEdits(image(bitsPerSample: 16), instanceNumber: 1, modalityAsSource: true, source: inverted)
        #expect(edits.contains(.put(0x0028_0004, "MONOCHROME1")) && !edits.contains(.put(0x0028_0004, "MONOCHROME2")))
        // A caller that knows only the modality of its source writes MONOCHROME2, as before.
        let former = Export.imageEdits(image(bitsPerSample: 16), instanceNumber: 1, modalityAsSource: true, sourceModality: "DX")
        #expect(former.contains(.put(0x0028_0004, "MONOCHROME2")))
    }

    /// The shutter and the overlay planes of the source stay only with an
    /// image that has the source's rows and columns.
    @Test func dropsTheShutterAndTheOverlaysOfAnotherMatrix() {
        func image(width: Int, height: Int, samplesPerPixel: Int = 1, bitsPerSample: Int) -> Export.Image {
            Export.Image(width: width, height: height, samplesPerPixel: samplesPerPixel, bitsPerSample: bitsPerSample,
                         isSigned: false, offset: 0, slope: 1, windowWidth: -1, windowLevel: -1, spacingX: 0, spacingY: 0,
                         sliceThickness: 0, orientation: [0, 0, 0, 0, 0, 0], position: nil, slicePosition: nil)
        }
        let source = Export.Source(modality: "DX", photometricInterpretation: "MONOCHROME1", rows: 512, columns: 400)
        let overlays = Array(stride(from: UInt16(0x6000), through: 0x601e, by: 2))
        let shutter = Export.displayShutter.map { Export.Edit.remove($0) }
        #expect(Export.displayShutter.contains(0x0018_1600) && Export.displayShutter.allSatisfy { $0 >> 16 == 0x0018 })
        // The source's own matrix, in stored values or in colour.
        for same in [image(width: 400, height: 512, bitsPerSample: 16), image(width: 400, height: 512, samplesPerPixel: 3, bitsPerSample: 8)] {
            #expect(Export.hasMatrix(of: source, same))
            #expect(Export.groupsRemoved(same, source: source) == [0x0028, 0x5200])
            let edits = Export.imageEdits(same, instanceNumber: 1, modalityAsSource: true, source: source)
            #expect(shutter.allSatisfy { !edits.contains($0) })
        }
        // A picture of the screen, a cropped image, rows and columns exchanged, a source without a matrix.
        let others: [(Export.Image, Export.Source)] = [
            (image(width: 1920, height: 841, bitsPerSample: 8), source), (image(width: 841, height: 841, samplesPerPixel: 3, bitsPerSample: 8), source),
            (image(width: 400, height: 392, bitsPerSample: 16), source), (image(width: 512, height: 400, bitsPerSample: 16), source),
            (image(width: 400, height: 512, bitsPerSample: 16), Export.Source(modality: "DX")),
        ]
        for (other, from) in others {
            #expect(!Export.hasMatrix(of: from, other))
            #expect(Export.groupsRemoved(other, source: from) == [0x0028, 0x5200] + overlays)
            let edits = Export.imageEdits(other, instanceNumber: 1, modalityAsSource: true, source: from)
            #expect(shutter.allSatisfy { edits.contains($0) })
        }
    }
}
