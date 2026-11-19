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

    // MARK: - Multiframe series

    private static let enhancedMR = "1.2.840.10008.5.1.4.1.1.4.1"
    private static let axial: [Double] = [1, 0, 0, 0, 1, 0]

    /// An axial stack of `frames` slices `spacing` mm apart, from z = `start`.
    private static func stack(_ frames: Int = 12, spacing: Double = 3, start: Double = 0, x: Double = -100,
                              orientation: [Double] = axial) -> [DICOMImportRules.FramePlane] {
        (0..<frames).map { .init(position: [x, -100, start + Double($0) * spacing], orientation: orientation) }
    }

    private static func layout(_ planes: [DICOMImportRules.FramePlane], sopClassUID: String? = enhancedMR, columns: Int = 64,
                               rows: Int = 64, frames: Int? = nil) -> DICOMImportRules.MultiframeLayout {
        .init(sopClassUID: sopClassUID, columns: columns, rows: rows, frames: frames ?? planes.count, planes: planes)
    }

    private static func volumeKey(_ layout: DICOMImportRules.MultiframeLayout, grouping: String? = "00000001 1.2.3") -> String? {
        DICOMImportRules.volumeSeriesKey(grouping: grouping, layout: layout)
    }

    @Test func aVolumeSharesItsSeriesKeyWithTheFilesOfItsGeometry() {
        // The key is stored: the same on every run and processor.
        #expect(Self.volumeKey(Self.layout(Self.stack())) == "00000001 1.2.3-volume-64x64x12-860ed26d0358f692")
        let coronal = (0..<3).map {
            DICOMImportRules.FramePlane(position: [-120.5, -5 + 2.5 * Double($0), 80.25], orientation: [1, 0, 0, 0, 0, -1])
        }
        #expect(Self.volumeKey(Self.layout(coronal, columns: 96, rows: 128), grouping: "00000007 1.2.3.4")
                == "00000007 1.2.3.4-volume-96x128x3-bc67c0cf68813c3c")
        #expect(DICOMImportRules.stableHash("") == "cbf29ce484222325")
        #expect(DICOMImportRules.stableHash("a") == "af63dc4c8601ec8c")

        // Another file of the acquisition: other pixels, another SOP Instance
        // UID and instance number, the same planes.
        let key = Self.volumeKey(Self.layout(Self.stack()))
        #expect(key != nil)
        #expect(DICOMImportRules.multiframeSeriesKey(grouping: "00000001 1.2.3", imageID: "    1", sopInstanceUID: "1.2.3.1",
                                                     layout: Self.layout(Self.stack())) == key)
        #expect(DICOMImportRules.multiframeSeriesKey(grouping: "00000001 1.2.3", imageID: "    2", sopInstanceUID: "1.2.3.2",
                                                     layout: Self.layout(Self.stack())) == key)
        // Written with the last digit of a float, and with its frames in another order.
        let rewritten = Self.stack().map {
            DICOMImportRules.FramePlane(position: $0.position.map { $0 + 0.0004 }, orientation: [1, 0.0002, 0, -0.0002, 1, 0])
        }
        #expect(Self.volumeKey(Self.layout(rewritten)) == key)
        #expect(Self.volumeKey(Self.layout(Self.stack().reversed())) == key)
        // The volume classes: enhanced MR, CT and PET and their legacy
        // converted classes, which state the planes the same way.
        for sopClassUID in ["1.2.840.10008.5.1.4.1.1.2.1", "1.2.840.10008.5.1.4.1.1.130", "1.2.840.10008.5.1.4.1.1.4.4",
                            "1.2.840.10008.5.1.4.1.1.2.2", "1.2.840.10008.5.1.4.1.1.128.1"] {
            #expect(Self.volumeKey(Self.layout(Self.stack(), sopClassUID: sopClassUID)) == key)
        }
        #expect(DICOMImportRules.volumeMultiframeSOPClasses.count == 6)
        // Another series, by any part of the grouping, is another key.
        #expect(Self.volumeKey(Self.layout(Self.stack()), grouping: "00000002 1.2.4") != key)
        #expect(Self.volumeKey(Self.layout(Self.stack()), grouping: nil)?.hasPrefix("(null)-volume-64x64x12-") == true)
    }

    @Test func filesOfAnotherGeometryHaveAnotherKey() {
        let key = Self.volumeKey(Self.layout(Self.stack()))
        let others = [
            Self.layout(Self.stack(), columns: 128),
            Self.layout(Self.stack(), rows: 128),
            Self.layout(Self.stack(11)),
            Self.layout(Self.stack(spacing: 3.1)),
            Self.layout(Self.stack(start: 1)),
            Self.layout(Self.stack(x: -99)),
            Self.layout(Self.stack(orientation: [0.999, 0.0447, 0, -0.0447, 0.999, 0])),
        ]
        var keys: Set<String> = []
        for other in others {
            let otherKey = Self.volumeKey(other)
            #expect(otherKey != nil)
            #expect(otherKey != key)
            if let otherKey { keys.insert(otherKey) }
        }
        #expect(keys.count == others.count)
    }

    @Test func whatIsNotOneVolumeKeepsASeriesOfItsOwn() {
        typealias Rules = DICOMImportRules
        func own(_ layout: Rules.MultiframeLayout) -> Bool {
            Rules.volumeSeriesKey(grouping: "00000001 1.2.3", layout: layout) == nil
                && Rules.multiframeSeriesKey(grouping: "00000001 1.2.3", imageID: "    4", sopInstanceUID: "1.2.3.9", layout: layout)
                    == "00000001 1.2.3-    4-1.2.3.9"
        }
        // No frame states its position (a cine, a loop), or not every frame does.
        #expect(own(Self.layout([], frames: 12)))
        #expect(own(Self.layout(Array(Self.stack().dropLast()), frames: 12)))
        // Positions repeated in the file: several phases, echoes or b-values in one file.
        #expect(own(Self.layout(Self.stack(6) + Self.stack(6))))
        #expect(own(Self.layout(Self.stack(11) + [Self.stack()[4]])))
        // Closer than a hundredth of a millimetre is the same place.
        #expect(own(Self.layout(Self.stack(2, spacing: 0.004))))
        // Several planes in one file, as a localizer has.
        var mixed = Self.stack()
        mixed[5].orientation = [1, 0, 0, 0, 0, -1]
        #expect(own(Self.layout(mixed)))
        // No axis leads the normal, so the frames have no slice location to tell them apart.
        #expect(own(Self.layout(Self.stack(orientation: [0, 0, 0, 0, 0, 0]))))
        // A class outside the list, positions or not: ultrasound, angiography,
        // a segmentation, a classic image, a secondary capture, none.
        for sopClassUID in ["1.2.840.10008.5.1.4.1.1.3.1", "1.2.840.10008.5.1.4.1.1.12.1", "1.2.840.10008.5.1.4.1.1.66.4",
                            "1.2.840.10008.5.1.4.1.1.4", "1.2.840.10008.5.1.4.1.1.2", "1.2.840.10008.5.1.4.1.1.7.3",
                            "1.2.840.10008.5.1.4.1.1.4.2", "1.2.840.10008.5.1.4.1.1.128", nil] {
            #expect(own(Self.layout(Self.stack(), sopClassUID: sopClassUID)))
        }
        // A single frame, no size, values that are no place.
        #expect(own(Self.layout(Self.stack(1))))
        #expect(own(Self.layout(Self.stack(), columns: 0)))
        #expect(own(Self.layout(Self.stack(), rows: 0)))
        var broken = Self.stack()
        broken[3].position[2] = .nan
        #expect(own(Self.layout(broken)))
        broken[3].position = [0, 0]
        #expect(own(Self.layout(broken)))
        broken = Self.stack()
        broken[0].orientation = [1, 0, 0, 0, .infinity, 0]
        #expect(own(Self.layout(broken)))
        // The former key prints what is missing as the format did.
        #expect(Rules.formerMultiframeSeriesKey(grouping: nil, imageID: nil, sopInstanceUID: nil) == "(null)-(null)-(null)")
    }
}
