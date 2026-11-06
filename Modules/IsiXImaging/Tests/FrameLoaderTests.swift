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

/// The frame loading on its own. The comparison with the Objective-C loading
/// it replaced, pixel by pixel, is tests/test-dcmpix-frame-loading.py.
struct FrameLoaderTests {
    private func load(_ bytes: [UInt8], layout: FrameLayout, dataset: FakeDataset,
                      external: UnsafeMutablePointer<Float>? = nil,
                      configure: (inout FrameLoader) -> Void = { _ in }) throws -> (FrameLoader, UnsafeMutablePointer<Float>?) {
        var photometry = FramePhotometry(bitsAllocated: layout.bitsAllocated, planarConfiguration: 0)
        try photometry.read(from: dataset, frameLength: bytes.count, width: layout.width, height: layout.height,
                            keepsNuclearMedicinePolarity: false, file: "/frames/test.dcm")
        var loader = FrameLoader(layout: layout, photometry: photometry, externalImage: external)
        configure(&loader)
        let image = bytes.withUnsafeBytes { loader.load($0) }
        return (loader, image)
    }

    private func words(_ values: [UInt16]) -> [UInt8] {
        values.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }

    @Test func signExtensionMatchesTheScalarFormulaForEveryWidth() {
        var generator = SystemRandomNumberGenerator()
        for bits in 1..<16 {
            for count in [0, 1, 3, 4, 5, 63, 64, 67] {
                let source = (0..<count).map { _ in UInt16.random(in: .min ... .max, using: &generator) }
                var result = [Int16](repeating: 0x5555, count: count)
                source.withUnsafeBytes { from in
                    result.withUnsafeMutableBytes { to in
                        FrameSamples.signExtend(from.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!, into: to.baseAddress ?? UnsafeMutableRawPointer(bitPattern: 1)!,
                                                count: count, bitsStored: bits)
                    }
                }
                let shift = 16 - bits
                let expected = source.map { Int16(truncatingIfNeeded: Int32(Int16(bitPattern: $0 << UInt16(shift))) / Int32(1 << shift)) }
                #expect(result == expected, "\(bits) bits, \(count) samples")
            }
        }
    }

    @Test func widensBytesIntoTheLowByteOfEachWord() {
        let source: [UInt8] = [0, 1, 127, 128, 255]
        var words = [UInt16](repeating: 0, count: 6)
        source.withUnsafeBytes { from in
            words.withUnsafeMutableBytes { FrameSamples.widen(from.baseAddress!, into: $0.baseAddress!, count: 5) }
        }
        #expect(words == [0, 1, 127, 128, 255, 0])
    }

    @Test func photometryReadsAMissingInterpretationAsRGBUntilTheSamplesSayGrey() throws {
        var photometry = FramePhotometry(bitsAllocated: 16, planarConfiguration: 1)
        try photometry.read(from: FakeDataset([:]), frameLength: 10, width: 2, height: 2,
                            keepsNuclearMedicinePolarity: false, file: nil)
        #expect(photometry.isRGB && photometry.planarConfiguration == 0)
        try photometry.read(from: FakeDataset(["SamplesperPixel": 1]), frameLength: 10, width: 2, height: 2,
                            keepsNuclearMedicinePolarity: false, file: nil)
        #expect(!photometry.isRGB)
    }

    @Test func paletteColourIsEightBitColourWhenTheFrameCarriesThreeSamples() throws {
        var photometry = FramePhotometry(bitsAllocated: 16, planarConfiguration: 0)
        try photometry.read(from: FakeDataset(["PhotometricInterpretation": "PALETTE COLOR", "SamplesperPixel": 1]),
                            frameLength: 12, width: 2, height: 2, keepsNuclearMedicinePolarity: false, file: nil)
        #expect(photometry.isRGB && photometry.bitsAllocated == 8)
    }

    @Test func monochromeOneIsInvertedExceptForPETAndOpacityNM() throws {
        func inverts(_ modality: String, opacity: Bool) throws -> Bool {
            var photometry = FramePhotometry(bitsAllocated: 16, planarConfiguration: 0)
            try photometry.read(from: FakeDataset(["PhotometricInterpretation": "MONOCHROME1", "Modality": modality]),
                                frameLength: 8, width: 2, height: 2, keepsNuclearMedicinePolarity: opacity, file: nil)
            return photometry.inverts
        }
        #expect(try inverts("CR", opacity: false))
        #expect(try !inverts("PT", opacity: false))
        #expect(try inverts("NM", opacity: false))
        #expect(try !inverts("NM", opacity: true))
    }

    @Test func aNumberForAnInterpretationRaisesAsTheMessageDid() {
        var photometry = FramePhotometry(bitsAllocated: 16, planarConfiguration: 0)
        #expect(throws: AttributeReadException.self) {
            try photometry.read(from: FakeDataset(["PhotometricInterpretation": 7]), frameLength: 8, width: 2, height: 2,
                                keepsNuclearMedicinePolarity: false, file: nil)
        }
    }

    @Test func unsignedSamplesGoThroughTheModalityLUT() throws {
        let layout = FrameLayout(width: 2, height: 2, bitsAllocated: 16, bitsStored: 12, isSigned: false, slope: 2, offset: -1024)
        let (_, image) = try load(words([0, 1, 2048, 4095]), layout: layout, dataset: FakeDataset(["PhotometricInterpretation": "MONOCHROME2"]))
        defer { free(image) }
        #expect(Array(UnsafeBufferPointer(start: image, count: 4)) == [-1024, -1022, 3072, 7166])
    }

    @Test func twelveBitSignedSamplesAreSignExtendedBeforeTheLUT() throws {
        let layout = FrameLayout(width: 2, height: 2, bitsAllocated: 16, bitsStored: 12, isSigned: true, slope: 1, offset: 0)
        let (_, image) = try load(words([0x0FFF, 0x0800, 0xF7FF, 0x0001]), layout: layout,
                                  dataset: FakeDataset(["PhotometricInterpretation": "MONOCHROME2"]))
        defer { free(image) }
        #expect(Array(UnsafeBufferPointer(start: image, count: 4)) == [-1, -2048, 2047, 1])
    }

    @Test func theVOILUTSeesTheSignExtendedSamples() throws {
        let layout = FrameLayout(width: 2, height: 1, bitsAllocated: 16, bitsStored: 12, isSigned: true, slope: 1, offset: 0)
        var seen: [UInt16] = []
        let (_, image) = try load(words([0x0FFF, 0x0002]), layout: layout, dataset: FakeDataset(["PhotometricInterpretation": "MONOCHROME2"])) {
            $0.voiLUT = { samples in
                seen = Array(UnsafeBufferPointer(start: samples, count: 2))
                samples[1] = 7
            }
        }
        defer { free(image) }
        #expect(seen == [0xFFFF, 2])
        #expect(Array(UnsafeBufferPointer(start: image, count: 2)) == [-1, 7])
    }

    @Test func aShortColourFrameIsBlackPastItsEndInTheSeriesBuffer() throws {
        let layout = FrameLayout(width: 2, height: 2, bitsAllocated: 8, bitsStored: 8, isSigned: false, slope: 1, offset: 0)
        let external = UnsafeMutablePointer<Float>.allocate(capacity: 4)
        defer { external.deallocate() }
        external.initialize(repeating: -7.5, count: 4)
        let (loader, image) = try load([1, 2, 3, 4, 5, 6, 7], layout: layout,
                                       dataset: FakeDataset(["PhotometricInterpretation": "RGB", "SamplesperPixel": 3]), external: external)
        #expect(image == external)
        #expect(loader.shortFrame == ShortFrame(carried: 7, needed: 12))
        let bytes = Array(UnsafeRawBufferPointer(start: external, count: 16))
        #expect(bytes == [255, 1, 2, 3, 255, 4, 5, 6] + [UInt8](repeating: 0, count: 8))
    }

    @Test func aShortThirtyTwoBitFrameIsZeroPastItsEnd() throws {
        let layout = FrameLayout(width: 2, height: 2, bitsAllocated: 32, bitsStored: 32, isSigned: false, slope: 1, offset: 0)
        let (_, image) = try load([5, 0, 0, 0, 6, 0], layout: layout,
                                  dataset: FakeDataset(["PhotometricInterpretation": "MONOCHROME2", "PixelRepresentation": 0])) {
            $0.thirtyTwoBitWordsAreIntegers = true
        }
        defer { free(image) }
        #expect(Array(UnsafeBufferPointer(start: image, count: 4)) == [5, 6, 0, 0])
    }

    @Test func thirtyTwoBitIntegersUseOneRoundingInDoublePrecision() throws {
        let layout = FrameLayout(width: 1, height: 1, bitsAllocated: 32, bitsStored: 32, isSigned: true, slope: 0.1, offset: 0.3)
        let value: Int32 = -123_456_789
        let bytes = withUnsafeBytes(of: value.littleEndian) { Array($0) }
        let (_, image) = try load(bytes, layout: layout, dataset: FakeDataset(["PhotometricInterpretation": "MONOCHROME2", "PixelRepresentation": 1]))
        defer { free(image) }
        #expect(image?.pointee == Float(Double(Float(0.3)).addingProduct(Double(value), Double(Float(0.1)))))
    }

    @Test func overlaysTakeTheTopOfTheStoredRange() throws {
        let layout = FrameLayout(width: 3, height: 2, bitsAllocated: 16, bitsStored: 12, isSigned: false, slope: 2, offset: -7)
        let bitmap: [UInt8] = [0xFF, 0, 0, 0xFF]
        let image = try bitmap.withUnsafeBufferPointer { pixels in
            try load(words([1, 1, 1, 1, 1, 1]), layout: layout, dataset: FakeDataset(["PhotometricInterpretation": "MONOCHROME2"])) {
                $0.overlays = [OverlayBitmap(pixels: pixels.baseAddress!, rows: 2, columns: 2, originX: 2, originY: 0)]
            }.1
        }
        defer { free(image) }
        #expect(Array(UnsafeBufferPointer(start: image, count: 6)) == [-5, -5, 8185, -5, -5, -5])
    }

    @Test func anObjectWithoutPixelDataIsAnEmptyPictureOfItsSize() {
        let external = UnsafeMutablePointer<Float>.allocate(capacity: 6)
        defer { external.deallocate() }
        external.initialize(repeating: 3, count: 6)
        #expect(FrameLoad.emptyImage(width: 3, height: 2, external: external) == external)
        #expect(Array(UnsafeBufferPointer(start: external, count: 6)) == [0, 0, 0, 0, 0, 0])
        #expect(FrameLoad.emptyImage(width: 0, height: 2, external: nil) == nil)
    }

    @Test func anRTDoseFrameIsOffsetByItsGridValue() throws {
        let dose = FakeDataset(["Modality": "RTDOSE", "GridFrameOffsetVector": ["0", "2.5"]])
        #expect(try FramePosition.gridFrameOffset(of: 1, in: dose) == 2.5)
        #expect(try FramePosition.gridFrameOffset(of: 0, in: FakeDataset(["Modality": "CT"])) == nil)
        #expect(throws: AttributeReadException.self) { try FramePosition.gridFrameOffset(of: 2, in: dose) }
    }
}
