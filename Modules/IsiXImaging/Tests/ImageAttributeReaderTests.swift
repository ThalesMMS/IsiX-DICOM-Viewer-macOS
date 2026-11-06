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

/// A data set held in a dictionary: a name maps to its values, or to items
/// when it is a sequence. Keys like `6000,3000` are names too.
final class FakeDataset: NSObject, DICOMAttributeSource {
    var values: [String: [Any]] = [:]
    var sequences: [String: [FakeDataset]] = [:]
    /// Attributes that are there but are not sequences, where one is asked for.
    var plainAttributes: Set<String> = []

    init(_ values: [String: Any] = [:], sequences: [String: [FakeDataset]] = [:]) {
        for (name, value) in values {
            self.values[name] = (value as? [Any]) ?? [value]
        }
        self.sequences = sequences
    }

    func attributeValue(withName name: String) -> Any? { values[name]?.first ?? sequences[name]?.first }
    func attributeArray(withName name: String) -> [Any]? { values[name] ?? sequences[name] }
    func attributeValue(forKey key: String) -> Any? { values[key]?.first }
    func attributeArray(forKey key: String) -> [Any]? { values[key] }
    func sequenceItems(withName name: String) -> Any? {
        if let items = sequences[name] { return items as NSArray }
        if plainAttributes.contains(name) || values[name] != nil { return NSObject() }
        return nil
    }
}

/// A DA/TM value, as the parser's date type answers.
final class FakeDate: NSObject {
    @objc let dateString: String?
    @objc let timeString: String?
    init(date: String? = nil, time: String? = nil) {
        dateString = date
        timeString = time
    }
}

func freshAttributes() -> ImageAttributes {
    var attributes = ImageAttributes()
    attributes.geometry.orientation = ImagePlaneGeometry.identityOrientation
    attributes.geometry.pixelRatio = 1
    attributes.rescale.slope = 1
    attributes.rescale.rescaleType = ""
    attributes.suv.decayFactor = 1
    return attributes
}

func read(_ dataset: FakeDataset, context: ImageAttributeReadingContext = ImageAttributeReadingContext()) throws -> ImageAttributeReader {
    var reader = ImageAttributeReader(attributes: freshAttributes(), context: context)
    try reader.readImage(from: dataset)
    return reader
}

@Suite struct ImagePlaneGeometryTests {
    @Test func identityHasAnAxialNormal() {
        #expect(ImagePlaneGeometry.identityOrientation == [1, 0, 0, 0, 1, 0, 0, 0, 1])
    }

    @Test func normalIsTheCrossProduct() {
        var geometry = ImagePlaneGeometry()
        geometry.orientation = [0, 1, 0, 0, 0, -1, 0, 0, 0]   // sagittal
        geometry.computeNormal()
        #expect(Array(geometry.orientation[6...]) == [-1, 0, 0])
        #expect(geometry.is3DPlane)
    }

    @Test func sliceLocationFollowsTheDominantAxis() {
        var geometry = ImagePlaneGeometry()
        geometry.orientation = ImagePlaneGeometry.identityOrientation
        geometry.originX = -100; geometry.originY = -50; geometry.originZ = 12.5
        geometry.pixelSpacingX = 0.5; geometry.pixelSpacingY = 0.5
        geometry.computeSliceLocation(width: 512, height: 512)
        #expect(geometry.sliceLocation == 12.5)

        geometry.orientation = [0, 1, 0, 0, 0, -1, 0, 0, 0]
        geometry.computeNormal()
        geometry.computeSliceLocation(width: 512, height: 512)
        // The centre pixel is (255.5, 255.5) from the origin along x; x is not moved by the cosines.
        #expect(geometry.sliceLocation == -100)
    }

    @Test func orientationIsNormalised() {
        let o = ImagePlaneGeometry.normalizedOrientation([2, 0, 0, 0, 0, 3])
        #expect(o == [1, 0, 0, 0, 0, 1, 0, -1, 0])
    }

    @Test func spacingIsSettled() {
        var geometry = ImagePlaneGeometry()
        geometry.pixelSpacingX = -0.4; geometry.pixelSpacingY = 0.8
        geometry.estimatedRadiographicMagnificationFactor = 2
        geometry.settlePixelSpacing()
        #expect(geometry.pixelSpacingX == 0.2 && geometry.pixelSpacingY == 0.4 && geometry.pixelRatio == 2)

        geometry.pixelSpacingX = 1e-6; geometry.pixelSpacingY = 1
        geometry.estimatedRadiographicMagnificationFactor = 0
        geometry.settlePixelSpacing()
        #expect(geometry.pixelSpacingX == 1 && geometry.pixelSpacingY == 1 && geometry.pixelRatio == 1)
    }
}

@Suite struct ImageAttributeReaderTests {
    let ct = FakeDataset([
        "Rows": NSNumber(value: 512), "Columns": NSNumber(value: 256),
        "BitsAllocated": NSNumber(value: 16), "BitsStored": NSNumber(value: 12), "PixelRepresentation": NSNumber(value: 1),
        "RescaleIntercept": "-1024", "RescaleSlope": "1", "RescaleType": "houndsfield unit",
        "WindowCenter": "40", "WindowWidth": "-400",
        "PixelSpacing": ["0.7", "0.6"], "SliceThickness": "1.25",
        "ImagePositionPatient": ["-120", "-100", "33.5"],
        "ImageOrientationPatient": ["1", "0", "0", "0", "1", "0"],
        "FrameofReferenceUID": "1.2.3",
        "PhotometricInterpretation": "MONOCHROME2",
    ])

    @Test func ctGeometryAndPixels() throws {
        let attributes = try read(ct).attributes
        #expect(attributes.pixels.height == 512 && attributes.pixels.width == 256)
        #expect(attributes.pixels.bitsStored == 12 && attributes.pixels.isSigned)
        #expect(attributes.rescale.intercept == -1024 && attributes.rescale.slope == 1 && attributes.rescale.rescaleType == "HU")
        #expect(attributes.storedWindow.level == 40 && attributes.storedWindow.width == 400)
        #expect(attributes.geometry.pixelSpacingY == 0.7 && attributes.geometry.pixelSpacingX == 0.6)
        #expect(attributes.geometry.pixelRatio == 0.7 / 0.6)
        #expect(attributes.geometry.originZ == 33.5 && attributes.geometry.isOriginDefined)
        #expect(attributes.geometry.orientation == [1, 0, 0, 0, 1, 0, 0, 0, 1])
        #expect(attributes.geometry.sliceLocation == 33.5)
        #expect(attributes.acquisition.frameOfReferenceUID == "1.2.3")
        #expect(!attributes.pixels.isRGB)
    }

    @Test func missingBitsStoredIsTheAllocatedWidth() throws {
        let attributes = try read(FakeDataset(["BitsAllocated": "16"])).attributes
        #expect(attributes.pixels.bitsStored == 16)
    }

    @Test func noPhotometricInterpretationIsNotPalette() throws {
        let attributes = try read(FakeDataset(["Rows": "4"])).attributes
        #expect(!attributes.pixels.isRGB)
        #expect(try read(FakeDataset(["PhotometricInterpretation": "PALETTE COLOR"])).attributes.pixels.isRGB)
    }

    @Test func mistypedValuesAreRefusedNotRaised() throws {
        let bytes = Data([1, 2, 3, 4]) as NSData
        let attributes = try read(FakeDataset(["WindowCenter": bytes, "RepetitionTime": bytes,
                                               "ImagePositionPatient": [bytes, bytes, bytes]])).attributes
        #expect(attributes.storedWindow.level == 0)
        #expect(attributes.acquisition.repetitionTime == nil)
        #expect(attributes.geometry.originX == 0 && attributes.geometry.isOriginDefined)
    }

    @Test func enhancedFrameKeepsItsOwnPosition() throws {
        func frame(_ z: String) -> FakeDataset {
            FakeDataset(sequences: ["PlanePositionSequence": [FakeDataset(["ImagePositionPatient": ["0", "0", z]])]])
        }
        let shared = FakeDataset(sequences: [
            "PlaneOrientationSequence": [FakeDataset(["ImageOrientationPatient": ["1", "0", "0", "0", "0", "-1"]])],
            "PixelMeasuresSequence": [FakeDataset(["PixelSpacing": ["0.5", "0.5"], "SliceThickness": "2"])],
            "FrameVOILUTSequence": [FakeDataset(["WindowCenter": "300", "WindowWidth": "1500"])],
            "PixelValueTransformationSequence": [FakeDataset(["RescaleIntercept": "-1000", "RescaleSlope": "2", "RescaleType": "US"])],
        ])
        let object = FakeDataset(["ImagePositionPatient": ["9", "9", "9"], "Rows": "64", "Columns": "64"],
                                 sequences: ["SharedFunctionalGroupsSequence": [shared],
                                             "Per-frameFunctionalGroupsSequence": [frame("10"), frame("20"), frame("30")]])
        var context = ImageAttributeReadingContext()
        context.numberOfFrames = 3
        context.frame = 2
        let attributes = try read(object, context: context).attributes
        #expect(attributes.geometry.originZ == 30 && attributes.geometry.originX == 0)
        #expect(attributes.geometry.orientation == [1, 0, 0, 0, 0, -1, 0, 1, 0])
        #expect(attributes.geometry.sliceThickness == 2 && attributes.geometry.pixelSpacingX == 0.5)
        #expect(attributes.storedWindow.level == 300 && attributes.storedWindow.width == 1500)
        #expect(attributes.rescale.intercept == -1000 && attributes.rescale.slope == 2)
        // The coronal normal points along y: the slice location is the centre's y.
        #expect(attributes.geometry.sliceLocation == 0)
    }

    @Test func enhancedFrameKeepsTheObjectsFrameOfReference() throws {
        let shared = FakeDataset(sequences: [
            "PlaneOrientationSequence": [FakeDataset(["ImageOrientationPatient": ["1", "0", "0", "0", "1", "0"]])],
        ])
        let frame = FakeDataset(sequences: [
            "PlanePositionSequence": [FakeDataset(["ImagePositionPatient": ["0", "0", "5"]])],
            "PlaneOrientationSequence": [FakeDataset(["ImageOrientationPatient": ["1", "0", "0", "0", "1", "0"]])],
        ])
        let object = FakeDataset(["FrameofReferenceUID": "1.2.3.4", "Rows": "8", "Columns": "8"],
                                 sequences: ["SharedFunctionalGroupsSequence": [shared], "Per-frameFunctionalGroupsSequence": [frame]])
        var context = ImageAttributeReadingContext()
        context.numberOfFrames = 1
        let attributes = try read(object, context: context).attributes
        #expect(attributes.acquisition.frameOfReferenceUID == "1.2.3.4")
        #expect(attributes.geometry.originZ == 5)

        // A nested item that does carry one still states it.
        let stating = FakeDataset(sequences: [
            "PlanePositionSequence": [FakeDataset(["ImagePositionPatient": ["0", "0", "5"], "FrameofReferenceUID": "5.6"])],
        ])
        let restated = FakeDataset(["FrameofReferenceUID": "1.2.3.4"], sequences: ["Per-frameFunctionalGroupsSequence": [stating]])
        #expect(try read(restated, context: context).attributes.acquisition.frameOfReferenceUID == "5.6")
    }

    @Test func sharedMRTimingGivesTheAcquisitionParameters() throws {
        let shared = FakeDataset(sequences: [
            "MRTimingAndRelatedParametersSequence": [FakeDataset(["RepetitionTime": "8.2", "FlipAngle": "15"])],
        ])
        let frame = FakeDataset(sequences: ["MREchoSequence": [FakeDataset(["EchoTime": "4.5"])]])
        let object = FakeDataset(["Rows": "8", "Columns": "8"],
                                 sequences: ["SharedFunctionalGroupsSequence": [shared], "Per-frameFunctionalGroupsSequence": [frame]])
        var context = ImageAttributeReadingContext()
        context.numberOfFrames = 1
        let acquisition = try read(object, context: context).attributes.acquisition
        #expect(acquisition.repetitionTime == "8.2" && acquisition.flipAngle == "15" && acquisition.echoTime == "4.5")
    }

    @Test func enhancedEchoTimeIsTheFramesEffectiveEchoTime() throws {
        func echo(_ value: Double) -> FakeDataset {
            FakeDataset(sequences: ["MREchoSequence": [FakeDataset(["EffectiveEchoTime": NSNumber(value: value)])]])
        }
        let shared = FakeDataset(sequences: ["MREchoSequence": [FakeDataset(["EffectiveEchoTime": NSNumber(value: 99.5)])]])
        let object = FakeDataset(["Rows": "8", "Columns": "8"],
                                 sequences: ["SharedFunctionalGroupsSequence": [shared],
                                             "Per-frameFunctionalGroupsSequence": [echo(10), echo(20.5), FakeDataset()]])
        var context = ImageAttributeReadingContext()
        context.numberOfFrames = 3
        var echoes: [String?] = []
        for frame in 0..<3 {
            context.frame = frame
            echoes.append(try read(object, context: context).attributes.acquisition.echoTime)
        }
        // The frame's own, and the shared one where the frame states none.
        #expect(echoes == ["10", "20.5", "99.5"])

        // A classic object keeps Echo Time.
        #expect(try read(FakeDataset(["EchoTime": "12"])).attributes.acquisition.echoTime == "12")
    }

    @Test func ophthalmicFrameReadsAllItsReferenceCoordinates() throws {
        let location = FakeDataset(["ReferencedSOPInstanceUID": "1.2.3.9", "ReferenceCoordinates": ["1.5", "2", "3", NSNumber(value: 4)]])
        let frame = FakeDataset(sequences: ["OphthalmicFrameLocationSequence": [location]])
        let object = FakeDataset(["Rows": "8", "Columns": "8"], sequences: ["Per-frameFunctionalGroupsSequence": [frame]])
        var context = ImageAttributeReadingContext()
        context.numberOfFrames = 1
        let attributes = try read(object, context: context).attributes
        #expect(attributes.acquisition.referenceCoordinates == [1.5, 2, 3, 4])
        #expect(attributes.acquisition.referencedSOPInstanceUID == "1.2.3.9")

        // Fewer than four values are not coordinates; nothing is taken, and nothing raises.
        let short = FakeDataset(sequences: ["Per-frameFunctionalGroupsSequence": [FakeDataset(sequences: [
            "OphthalmicFrameLocationSequence": [FakeDataset(["ReferenceCoordinates": ["1", "2"]])]])]])
        #expect(try read(short, context: context).attributes.acquisition.referenceCoordinates == [0, 0, 0, 0])
    }

    @Test func frame32768ReadsItsOwnItem() throws {
        let empty = FakeDataset()
        var frames = [FakeDataset](repeating: empty, count: 32_769)
        frames[32_768] = FakeDataset(sequences: ["PlanePositionSequence": [FakeDataset(["ImagePositionPatient": ["0", "0", "77"]])]])
        let object = FakeDataset(["Rows": "1", "Columns": "1"], sequences: ["Per-frameFunctionalGroupsSequence": frames])
        var context = ImageAttributeReadingContext()
        context.numberOfFrames = 32_769
        context.frame = 32_768
        #expect(try read(object, context: context).attributes.geometry.originZ == 77)
    }

    @Test func emptyFunctionalGroupRaisesAsBefore() {
        let shared = FakeDataset(sequences: ["PixelMeasuresSequence": []])
        let object = FakeDataset(sequences: ["SharedFunctionalGroupsSequence": [shared]])
        #expect(throws: AttributeReadException.self) { try read(object) }
    }

    @Test func overlayIsUnpacked() throws {
        var bits = Data(count: 8)
        bits[0] = 0b0000_0101   // pixels 0 and 2
        bits[3] = 0b1000_0000   // pixel 31
        let object = FakeDataset(["6002,3000": bits as NSData, "6002,0010": NSNumber(value: 2), "6002,0011": NSNumber(value: 32),
                                  "6002,0040": "G", "6002,0100": NSNumber(value: 1), "6002,0102": NSNumber(value: 0)])
        let reader = try read(object)
        let plane = reader.attributes.overlays[1]
        #expect(plane.isOn && plane.rows == 2 && plane.columns == 32 && plane.type == Int32(UInt8(ascii: "G")))
        guard case .some(.some(let pixels)) = plane.unpackedReplacement else {
            Issue.record("no bitmap")
            return
        }
        #expect(pixels.count == 64)
        #expect(pixels.indices.filter { pixels[$0] == 0xFF } == [0, 2, 31])
        #expect(!reader.attributes.overlays[0].isOn)
    }

    @Test func overlayOriginPlacesTheOverlay() throws {
        // Two rows of sixteen: pixel 0 (row 0, column 0) and pixel 17 (row 1, column 1).
        var bits = Data(count: 4)
        bits[0] = 0b0000_0001
        bits[2] = 0b0000_0010
        // Overlay Origin is row then column, one-based: row 3, column 7.
        let object = FakeDataset(["6000,3000": bits as NSData, "6000,0010": NSNumber(value: 2), "6000,0011": NSNumber(value: 16),
                                  "6000,0040": "G", "6000,0050": [NSNumber(value: 3), NSNumber(value: 7)],
                                  "6000,0100": NSNumber(value: 1), "6000,0102": NSNumber(value: 0)])
        let plane = try read(object).attributes.overlays[0]
        #expect(plane.origin == [6, 2])
        guard case .some(.some(let bitmap)) = plane.unpackedReplacement else {
            Issue.record("no bitmap")
            return
        }

        // Burnt into a 16 x 16 frame, the overlay starts at that row and column.
        let load = FrameLoad()
        load.setSamples(width: 16, height: 16, bitsAllocated: 16, bitsStored: 12, signed: false)
        load.setModalityLUT(slope: 1, offset: 0)
        let frame = Data(count: 16 * 16 * 2) as NSData
        let image = try bitmap.withUnsafeBufferPointer { pixels -> UnsafeMutablePointer<Float> in
            load.addOverlay(pixels.baseAddress, rows: plane.rows, columns: plane.columns, originX: plane.origin[0], originY: plane.origin[1])
            #expect(load.load(frame, of: FakeDataset(["PhotometricInterpretation": "MONOCHROME2"]), applyingVOILUT: nil))
            return try #require(load.image)
        }
        defer { free(image) }
        let set = (0..<256).filter { image[$0] != 0 }
        #expect(set == [2 * 16 + 6, 3 * 16 + 7])
    }

    @Test func suvTimesFollowThePreference() throws {
        let radiopharmaceutical = FakeDataset(["RadionuclideTotalDose": "370000000", "RadionuclideHalfLife": "6586",
                                               "RadiopharmaceuticalStartTime": FakeDate(time: "090000.000000")])
        let object = FakeDataset(["PatientsWeight": "70", "Units": "BQML", "DecayCorrection": "START",
                                  "SeriesDate": FakeDate(date: "20260101"), "SeriesTime": FakeDate(time: "100000"),
                                  "AcquisitionDate": FakeDate(date: "20260102"), "AcquisitionTime": FakeDate(time: "110000")],
                                 sequences: ["RadiopharmaceuticalInformationSequence": [radiopharmaceutical]])
        var context = ImageAttributeReadingContext()
        context.suvAcquisitionTimeField = 1
        let reader = try read(object, context: context)
        let suv = reader.attributes.suv
        #expect(suv.patientsWeight == 70 && suv.units == "BQML" && suv.decayCorrection == "START")
        #expect(suv.radionuclideTotalDose == 370_000_000 && suv.halflife == 6586)
        #expect(suv.acquisitionDateTime == "20260102110000")
        #expect(suv.radiopharmaceuticalStartDateTime == "20260102090000.000000")
        #expect(reader.needsTotalDoseCorrection)
    }

    @Test func detectorPlacesTheFrame() throws {
        let detector = FakeDataset(["ImagePositionPatient": ["1", "2", "3"], "ImageOrientationPatient": ["0", "0", "0", "0", "0", "0"]])
        let object = FakeDataset(["SpacingBetweenSlices": "4"], sequences: ["DetectorInformationSequence": [detector]])
        var context = ImageAttributeReadingContext()
        context.frame = 5
        let geometry = try read(object, context: context).attributes.geometry
        #expect(geometry.originZ == 23)
        #expect(geometry.orientation == [1, 0, 0, 0, 1, 0, 0, 0, 1])
    }

    @Test func shuttersAreReadWhenAsked() throws {
        let object = FakeDataset(["ShutterShape": ["RECTANGULAR", "POLYGONAL"], "Rows": "100", "Columns": "200",
                                  "ShutterLeftVerticalEdge": "10", "ShutterRightVerticalEdge": "110",
                                  "ShutterUpperHorizontalEdge": "5", "ShutterLowerHorizontalEdge": "55",
                                  "VerticesofthePolygonalShutter": ["1", "2", "3", "4"]])
        #expect(try read(object).attributes.shutter.enabled == false)
        var context = ImageAttributeReadingContext()
        context.useShutter = true
        let shutter = try read(object, context: context).attributes.shutter
        #expect(shutter.enabled && shutter.rect == CGRect(x: 10, y: 5, width: 100, height: 50))
        #expect(shutter.polygon == [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)])
    }

    @Test func ultrasoundRegionsGiveTheSpacing() throws {
        let region = FakeDataset(["RegionSpatialFormat": "1", "PhysicalUnitsXDirection": "3", "PhysicalUnitsYDirection": "3",
                                  "PhysicalDeltaX": "-0.02", "PhysicalDeltaY": "0.03", "ReferencePixelX0": "7"])
        let object = FakeDataset(["PixelSpacing": ["9", "9"]], sequences: ["SequenceofUltrasoundRegions": [region]])
        var context = ImageAttributeReadingContext()
        context.readsUltrasoundRegions = true
        let attributes = try read(object, context: context).attributes
        #expect(attributes.ultrasoundRegions?.count == 1)
        #expect(attributes.ultrasoundRegions?.first?.isReferencePixelX0Present == true)
        #expect(attributes.geometry.pixelSpacingX == 0.2 && attributes.geometry.pixelSpacingY == 0.3)
        #expect(attributes.geometry.pixelSpacingFromUltrasoundRegions)
    }

    @Test func databaseSizeIsComparedAndCut() throws {
        var context = ImageAttributeReadingContext()
        context.databaseSize = (height: 100, width: 100)
        context.hasExternallyOwnedPixels = true
        let reader = try read(FakeDataset(["Rows": "120", "Columns": "100"]), context: context)
        #expect(reader.attributes.pixels.height == 100)
        #expect(reader.databaseSizeUpdates == [["height": 120]])
    }
}
