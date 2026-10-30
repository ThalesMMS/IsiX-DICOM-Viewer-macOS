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

// Values worked out by hand; the comparison with the Objective-C++ reader these
// rules came from runs on files, outside the package, in tests/.
@Suite struct DICOMImportRulesTests {

    @Test func sliceLocationFollowsTheDominantAxis() {
        let origin = [10.0, 20.0, 30.0]
        #expect(DICOMImportRules.sliceLocation(origin: origin, orientation: [1, 0, 0, 0, 1, 0]) == 30)   // axial
        #expect(DICOMImportRules.sliceLocation(origin: origin, orientation: [1, 0, 0, 0, 0, -1]) == 20)  // coronal
        #expect(DICOMImportRules.sliceLocation(origin: origin, orientation: [0, 1, 0, 0, 0, -1]) == 10)  // sagittal
        #expect(DICOMImportRules.sliceLocation(origin: origin, orientation: [0, 0, 0, 0, 0, 0]) == 0)    // no axis wins
        #expect(DICOMImportRules.sliceLocation(origin: [1], orientation: [1, 0, 0, 0, 1, 0]) == 0)
    }

    @Test func imageIdentifiersArePaddedNumbers() {
        #expect(DICOMImportRules.imageIdentifier(instanceNumber: 7) == "    7")
        #expect(DICOMImportRules.imageIdentifier(instanceNumber: 123456) == "123456")
        #expect(DICOMImportRules.imageIdentifier(sliceLocation: -12.34) == " 9876")
        #expect(DICOMImportRules.imageIdentifier(sliceLocation: .nan) == "    0")
        #expect(DICOMImportRules.needsLocationIdentifier(nil))
        #expect(DICOMImportRules.needsLocationIdentifier("99999"))
        #expect(!DICOMImportRules.needsLocationIdentifier("   12"))
        #expect(DICOMImportRules.cInt(1e20) == Int32.max)
        #expect(DICOMImportRules.cInt(-3.9) == -3)
    }

    @Test func cardiacTimeComesFromScanOptions() {
        func time(_ text: String) -> Int { DICOMImportRules.cardiacTime(scanOptions: Array(text.utf8)) }
        #expect(time("TP12") == 12)
        #expect(time("TP3x") == 3)
        #expect(time("TPx1") == -1)
        #expect(time("TP1") == -1)        // shorter than four
        #expect(time("XP12") == -1)
    }

    @Test func seriesGroupingIsBuiltInOrder() {
        var grouping = DICOMImportRules.SeriesGrouping()
        grouping.seriesInstanceUID = "1.2.3"
        grouping.seriesNumber = "4"
        #expect(grouping.identifier == "00000004 1.2.3")
        grouping.cardiacTime = 5
        grouping.separateCardiac4D = true
        grouping.modality = "CT"
        grouping.imageType = "AXIAL"
        grouping.seriesDescription = "Chest"
        grouping.useSeriesDescription = true
        grouping.hiddenSOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
        grouping.echoTime = "90"
        grouping.splitMultiEchoMR = true
        #expect(grouping.identifier == "00000004 1.2.3 05 AXIAL Chest 1.2.840.10008.5.1.4.1.1.7 TE-90")
        grouping.modality = "SC"
        grouping.seriesNumber = nil
        grouping.seriesInstanceUID = nil
        grouping.patientName = "DOE"
        #expect(grouping.identifier == "DOE AXIAL Chest 1.2.840.10008.5.1.4.1.1.7 TE-90")
    }

    @Test func pixelProblemsAreNamed() {
        typealias Rules = DICOMImportRules
        #expect(Rules.pixelDataProblem(columns: 0, rows: 10, bitsAllocated: 8, samplesPerPixel: 1, frames: 1,
                                       pixels: .encapsulated) == "it declares a picture of 0 x 10")
        #expect(Rules.pixelDataProblem(columns: 4, rows: 4, bitsAllocated: 16, samplesPerPixel: 1, frames: 2,
                                       pixels: .native(length: 63)) == "its pixel data is 63 bytes where 64 are needed for 4x4")
        #expect(Rules.pixelDataProblem(columns: 4, rows: 4, bitsAllocated: 16, samplesPerPixel: 1, frames: 2,
                                       pixels: .native(length: 64)) == nil)
        #expect(Rules.pixelDataProblem(columns: 4, rows: 4, bitsAllocated: 0, samplesPerPixel: 1, frames: 1,
                                       pixels: .native(length: 1)) == nil)
        #expect(Rules.pixelDataProblem(columns: 4, rows: 4, bitsAllocated: 8, samplesPerPixel: 1, frames: 1,
                                       pixels: .native(length: 0)) == "its pixel data is empty")
        #expect(Rules.pixelDataProblem(columns: 4, rows: 4, bitsAllocated: 8, samplesPerPixel: 1, frames: 1,
                                       pixels: .absent(floatPixels: false, doubleFloatPixels: false, icon: (2, 3)))
                == "its only picture is a 2 x 3 preview icon in Icon Image Sequence (0088,0200), not the 4 x 4 image it declares")
        #expect(Rules.pixelDataProblem(columns: 4, rows: 4, bitsAllocated: 8, samplesPerPixel: 1, frames: 1,
                                       pixels: .absent(floatPixels: true, doubleFloatPixels: false, icon: nil))?
            .hasPrefix("its pixels are in Float Pixel Data") == true)
        #expect(Rules.pixelDataProblem(columns: 4, rows: 4, bitsAllocated: 8, samplesPerPixel: 1, frames: 1,
                                       pixels: .absent(floatPixels: false, doubleFloatPixels: false, icon: nil))
                == "it carries no pixel data at all")
    }

    @Test func subsampledColourIsTwoSamplesPerPixel() {
        typealias Rules = DICOMImportRules
        // 64 x 48 YBR_FULL_422 at 8 bits: Y Y Cb Cr for each pair of pixels.
        for photometric in ["YBR_FULL_422", "YBR_PARTIAL_422 ", "ybr_full_422"] {
            #expect(Rules.storedSamplesPerPixel(3, photometricInterpretation: photometric) == 2)
            #expect(Rules.pixelDataProblem(columns: 64, rows: 48, bitsAllocated: 8, samplesPerPixel: 3,
                                           photometricInterpretation: photometric, frames: 1,
                                           pixels: .native(length: 6144)) == nil)
        }
        #expect(Rules.pixelDataProblem(columns: 64, rows: 48, bitsAllocated: 8, samplesPerPixel: 3,
                                       photometricInterpretation: "YBR_FULL_422", frames: 2,
                                       pixels: .native(length: 6144)) == "its pixel data is 6144 bytes where 12288 are needed for 64x48")
        // Every other layout stores what it declares.
        for photometric in ["RGB", "YBR_FULL", "YBR_ICT", "PALETTE COLOR", ""] {
            #expect(Rules.storedSamplesPerPixel(3, photometricInterpretation: photometric) == 3)
        }
        #expect(Rules.storedSamplesPerPixel(3, photometricInterpretation: nil) == 3)
        #expect(Rules.storedSamplesPerPixel(1, photometricInterpretation: "YBR_FULL_422") == 1)
        #expect(Rules.pixelDataProblem(columns: 64, rows: 48, bitsAllocated: 8, samplesPerPixel: 3,
                                       photometricInterpretation: "RGB", frames: 1, pixels: .native(length: 6144))
                == "its pixel data is 6144 bytes where 9216 are needed for 64x48")
    }
}
