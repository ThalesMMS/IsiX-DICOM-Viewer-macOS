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

/// The parsing of the formats that are not DICOM on its own. The comparison with
/// the Objective-C reading it replaced is tests/test-dcmpix-non-dicom-formats.py.
struct NonDICOMFormatsTests {
    private func analyzeHeader(datatype: Int16, width: Int16, height: Int16, bigEndian: Bool) -> Data {
        var data = Data(count: 348)
        func put16(_ value: Int16, _ offset: Int) {
            let v = bigEndian ? UInt16(bitPattern: value).bigEndian : UInt16(bitPattern: value).littleEndian
            withUnsafeBytes(of: v) { data.replaceSubrange(offset..<offset + 2, with: $0) }
        }
        func putFloat(_ value: Float, _ offset: Int) {
            let v = bigEndian ? value.bitPattern.bigEndian : value.bitPattern.littleEndian
            withUnsafeBytes(of: v) { data.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        put16(4, 40)
        put16(width, 42)
        put16(height, 44)
        put16(datatype, 70)
        putFloat(0.75, 80)
        putFloat(1.25, 84)
        putFloat(3, 88)
        return data
    }

    @Test func anAnalyzeHeaderInTheOtherByteOrderIsSwapped() throws {
        let header = try #require(AnalyzeHeader(analyzeHeader(datatype: 4, width: 3, height: 2, bigEndian: true)))
        #expect(header.swapsBytes && header.width == 3 && header.height == 2 && header.datatype == 4)
        #expect(header.pixelSpacingX == 0.75 && header.pixelSpacingY == 1.25 && header.sliceThickness == 3)
        #expect(AnalyzeHeader(Data(count: 100)) == nil)
    }

    @Test func anAnalyzeFrameGoesThroughAShort() throws {
        let header = try #require(AnalyzeHeader(analyzeHeader(datatype: 8, width: 2, height: 1, bigEndian: false)))
        var image = Data()
        for value: UInt32 in [1, 2, 70_000, 65_535] { withUnsafeBytes(of: value.littleEndian) { image.append(contentsOf: $0) } }
        let frame = AnalyzeImage.frame(1, of: image, header: header, name: "a.hdr")
        #expect(frame.pixels == [Float(Int16(truncatingIfNeeded: 70_000)), -1])
        let short = AnalyzeImage.frame(2, of: image, header: header, name: "a.hdr")
        #expect(short.pixels == nil && short.messages == ["---- Analyze: a.hdr is shorter than frame 2 needs"])
    }

    @Test func anAnalyzeFloatFrameInEitherByteOrderHasTheSameValues() throws {
        let values: [Float] = [-1.5, 300.25, 0, 1e-3]
        var frames: [[Float]?] = []
        for bigEndian in [false, true] {
            let header = try #require(AnalyzeHeader(analyzeHeader(datatype: 16, width: 2, height: 2, bigEndian: bigEndian)))
            var image = Data()
            for value in values {
                let bits = bigEndian ? value.bitPattern.bigEndian : value.bitPattern.littleEndian
                withUnsafeBytes(of: bits) { image.append(contentsOf: $0) }
            }
            frames.append(AnalyzeImage.frame(0, of: image, header: header, name: "f.hdr").pixels)
        }
        #expect(frames == [values, values])
    }

    @Test func theNIfTIPlacementFollowsTheAxes() {
        // Identity: i left to right, j posterior to anterior: axial, both flipped.
        let axial = NIfTIImage.placement(i: NIfTIImage.leftToRight, j: NIfTIImage.posteriorToAnterior)
        #expect(axial == .init(stackAxis: 2, turns: 0, secondRowFromThird: false, flipsColumns: true, flipsRows: true))
        let sagittal = NIfTIImage.placement(i: NIfTIImage.anteriorToPosterior, j: NIfTIImage.superiorToInferior)
        #expect(sagittal.stackAxis == 0 && sagittal.turns == 2 && sagittal.flipsRows && !sagittal.flipsColumns)
        let coronal = NIfTIImage.placement(i: NIfTIImage.rightToLeft, j: NIfTIImage.inferiorToSuperior)
        #expect(coronal.stackAxis == 1 && coronal.secondRowFromThird && !coronal.flipsColumns && !coronal.flipsRows)
        #expect(NIfTIImage.placement(i: 0, j: 0) == .init(stackAxis: nil, turns: 0, secondRowFromThird: false,
                                                          flipsColumns: false, flipsRows: false))
    }

    @Test func nIfTIVoxelsBecomeFloatsOrColour() {
        let values: [UInt16] = [0, 40_000, 65_535]
        var floats = [Float](repeating: 0, count: 3)
        #expect(values.withUnsafeBytes { NIfTIImage.floats($0.baseAddress!, datatype: 512, count: 3, into: &floats) })
        #expect(floats == [0, 40_000, 65_535])
        #expect(!values.withUnsafeBytes { NIfTIImage.floats($0.baseAddress!, datatype: 32, count: 1, into: &floats) })
        let rgb: [UInt8] = [1, 2, 3, 4, 5, 6]
        var argb = [UInt8](repeating: 9, count: 8)
        NIfTIImage.argb(rgb, count: 2, into: &argb)
        #expect(argb == [0, 1, 2, 3, 0, 4, 5, 6])
        #expect(NIfTIImage.isNIfTI(magic: (110, 43, 49, 0)) && !NIfTIImage.isNIfTI(magic: (0, 0, 0, 0)))
        #expect(!NIfTIImage.dataFileHoldsVoxels(fileSize: 351, offset: 352, voxels: 0, bytesPerVoxel: 2))
        #expect(NIfTIImage.dataFileHoldsVoxels(fileSize: 362, offset: 352, voxels: 5, bytesPerVoxel: 2))
    }

    @Test func bioradNotesGiveTheSpacingAndEachNoteIsReadOnce() {
        var file = Data(count: 76)
        file.replaceSubrange(0..<6, with: [2, 0, 1, 0, 1, 0])
        file.replaceSubrange(14..<16, with: [1, 0])
        file.append(contentsOf: [10, 20])
        for text in ["AXIS_2 001 0 2.5e-01 microns", "Z_CORRECT_FACTOR = 0.5 0"] {
            file.append(Data(count: 16))
            file.append(text.data(using: .isoLatin1)!.padded(to: 80))
        }
        let bytes = NonDICOMFileBytes(file)
        let pic = BioradImage(header: bytes)
        #expect(pic.width == 2 && pic.height == 1 && pic.bytesPerPixel == 1)
        #expect(pic.samples(bytes, frame: 0, width: 2, height: 1) == [10, 20])
        let notes = pic.notes(bytes, width: 2, height: 1)
        #expect(notes.pixelSpacingX == 0.25 && notes.zCorrection == Double(Float(0.5)))
        #expect(notes.messages == ["Set zCorrection factor = 0.500000"])
    }

    @Test func bioradSixteenBitSamplesAreUnsigned() {
        var file = Data(count: 76)
        file.replaceSubrange(0..<6, with: [2, 0, 1, 0, 1, 0])
        file.append(contentsOf: [0x40, 0x9C, 0xFF, 0xFF])  // 40 000 and 65 535, little endian
        let bytes = NonDICOMFileBytes(file)
        let pic = BioradImage(header: bytes)
        #expect(pic.bytesPerPixel == 2)
        #expect(pic.samples(bytes, frame: 0, width: 2, height: 1) == [40_000, 65_535])
    }

    @Test func tiffColourOfGreyPixelsTurnsBackIntoGrey() {
        var rgba: [UInt8] = [7, 7, 7, 255, 9, 9, 9, 255]
        #expect(!TIFFSamples.argbInPlace(rgba: &rgba, byteCount: 8))
        #expect(rgba == [0, 7, 7, 7, 0, 9, 9, 9])
        rgba.withUnsafeMutableBytes { TIFFSamples.greyInPlace(argb: $0.baseAddress!, byteCount: 8) }
        #expect(rgba.withUnsafeBytes { Array($0.bindMemory(to: Int16.self).prefix(2)) } == [7, 9])
        let floats: [Float] = [-1, 1, 3]
        var range = (min: Float.greatestFiniteMagnitude, max: -Float.greatestFiniteMagnitude)
        TIFFSamples.fold(floats, count: 3, into: &range)
        var samples = [Int16](repeating: 0, count: 3)
        TIFFSamples.samples(float: floats, count: 3, range: range, into: &samples)
        #expect(samples == [0, 8000, 16000])
    }

    @Test func ybrFullBecomesRGBAndAPlanarKindOtherThanFullIsRefused() throws {
        let ybr: [UInt8] = [235, 128, 128, 16, 128, 128]
        let rgb = try #require(YBRConversion.rgb(ybr, width: 2, height: 1, kind: YBRConversion.full, planar: 0))
        defer { free(rgb) }
        #expect(Array(UnsafeBufferPointer(start: rgb, count: 6)) == [255, 255, 255, 0, 0, 0])
        #expect(YBRConversion.rgb(ybr, width: 2, height: 1, kind: YBRConversion.partial422, planar: 1) == nil)
    }

    @Test func aReadPastTheEndCopiesWhatIsThere() {
        let file = NonDICOMFileBytes(Data([1, 2, 3]))
        var buffer: [UInt8] = [9, 9, 9, 9]
        #expect(buffer.withUnsafeMutableBytes { file.read($0.baseAddress!, at: 1, count: 4) } == 2)
        #expect(buffer == [2, 3, 9, 9])
        // As fread into a variable already holding the fallback: only the low byte is replaced.
        #expect(file.uint16(at: 2, fallback: 0x0102) == 0x0103)
    }
}

private extension Data {
    func padded(to count: Int) -> Data {
        var data = self.prefix(count)
        data.append(Data(count: count - data.count))
        return Data(data)
    }
}
