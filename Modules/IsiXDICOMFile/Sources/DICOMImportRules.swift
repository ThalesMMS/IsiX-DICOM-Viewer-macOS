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

/// What the import makes of the attributes it reads from a DICOM file: the
/// slice location, the image and series identifiers, the cardiac phase, and
/// what it says of an object whose pixels are missing. Values come in as the
/// file holds them; nothing here reads a file.
public enum DICOMImportRules {

    // MARK: - Geometry

    /// The coordinate of `origin` along the axis the plane's normal mostly
    /// points along, 0 when no axis dominates (two components equal). The
    /// normal is the cross product of the row and column directions of
    /// `orientation` (Image Orientation (Patient), six values).
    public static func sliceLocation(origin: [Double], orientation: [Double]) -> Double {
        guard origin.count >= 3, orientation.count >= 6 else { return 0 }
        let normal = (orientation[1] * orientation[5] - orientation[2] * orientation[4],
                      orientation[2] * orientation[3] - orientation[0] * orientation[5],
                      orientation[0] * orientation[4] - orientation[1] * orientation[3])
        var location = 0.0
        if abs(normal.0) > abs(normal.1) && abs(normal.0) > abs(normal.2) { location = origin[0] }
        if abs(normal.1) > abs(normal.0) && abs(normal.1) > abs(normal.2) { location = origin[1] }
        if abs(normal.2) > abs(normal.0) && abs(normal.2) > abs(normal.1) { location = origin[2] }
        return location
    }

    // MARK: - Identifiers

    /// The image identifier of an Instance Number, "%5d".
    public static func imageIdentifier(instanceNumber: Int32) -> String {
        String(format: "%5d", instanceNumber)
    }

    /// The image identifier of a file whose Instance Number is missing or
    /// reaches 99999: 10000 plus ten times the slice location, truncated as C
    /// converts a double to an int on this processor (toward zero, saturated,
    /// NaN to 0).
    public static func imageIdentifier(sliceLocation location: Double) -> String {
        imageIdentifier(instanceNumber: cInt(10000 + location * 10.0))
    }

    /// Whether the image identifier read from the file is replaced by the one
    /// of the slice location: none, or one that reaches 99999.
    public static func needsLocationIdentifier(_ imageID: String?) -> Bool {
        guard let imageID else { return true }
        return (imageID as NSString).intValue >= 99999
    }

    /// The double-to-int conversion of the processor: toward zero, saturated
    /// at the bounds of Int32, NaN to 0.
    public static func cInt(_ value: Double) -> Int32 {
        if value.isNaN { return 0 }
        if value >= Double(Int32.max) { return Int32.max }
        if value <= Double(Int32.min) { return Int32.min }
        return Int32(value.rounded(.towardZero))
    }

    /// The cardiac phase of a Siemens cardiac series, from Scan Options: the
    /// one or two digits that follow "TP" at its start ("TP12", "TP3x"); -1
    /// when there are none.
    public static func cardiacTime(scanOptions: [UInt8]) -> Int {
        guard scanOptions.count >= 4, scanOptions[0] == UInt8(ascii: "T"), scanOptions[1] == UInt8(ascii: "P"),
              isDigit(scanOptions[2]) else { return -1 }
        let tens = Int(scanOptions[2] - UInt8(ascii: "0"))
        if isDigit(scanOptions[3]) { return tens * 10 + Int(scanOptions[3] - UInt8(ascii: "0")) }
        return tens
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    /// What the import groups a file's series under, before the localizer and
    /// multiframe rules: the Series Instance UID (or the patient's name when
    /// there is none), then, in this order and each when it applies, the
    /// cardiac phase, the series number, the image type, the series
    /// description, the SOP class of a hidden image class and the echo time.
    public struct SeriesGrouping {
        public var seriesInstanceUID: String?
        public var patientName: String?
        /// -1 when the file states none.
        public var cardiacTime: Int = -1
        public var separateCardiac4D = false
        public var modality: String?
        public var seriesNumber: String?
        public var imageType: String?
        public var seriesDescription: String?
        public var useSeriesDescription = false
        /// The SOP class, when it is one of the hidden image classes.
        public var hiddenSOPClassUID: String?
        public var echoTime: String?
        public var splitMultiEchoMR = false

        public init() {}

        /// The grouping identifier, as the import has always built it.
        public var identifier: String? {
            var identifier = seriesInstanceUID ?? patientName
            if cardiacTime != -1 && separateCardiac4D && modality != "SC" {
                identifier = String(format: "%@ %2.2d", describe(identifier), Int32(truncatingIfNeeded: cardiacTime))
            }
            if let seriesNumber {
                identifier = String(format: "%8.8d %@", (seriesNumber as NSString).intValue, describe(identifier))
            }
            if let imageType, useSeriesDescription {
                identifier = "\(describe(identifier)) \(imageType)"
            }
            if let seriesDescription, useSeriesDescription {
                identifier = "\(describe(identifier)) \(seriesDescription)"
            }
            if let hiddenSOPClassUID {
                identifier = "\(describe(identifier)) \(hiddenSOPClassUID)"
            }
            if let echoTime, splitMultiEchoMR {
                identifier = "\(describe(identifier)) TE-\(echoTime)"
            }
            return identifier
        }

        /// A missing value in a format: "(null)", as %@ printed nil.
        private func describe(_ value: String?) -> String { value ?? "(null)" }
    }

    // MARK: - Multiframe series

    /// Where a frame of a multiframe file lies: its Image Position (Patient),
    /// three values, and the Image Orientation (Patient) that serves it, six.
    public struct FramePlane: Equatable, Sendable {
        public var position: [Double]
        public var orientation: [Double]

        public init(position: [Double], orientation: [Double]) {
            self.position = position
            self.orientation = orientation
        }
    }

    /// What the import reads of a multiframe file to decide its series: the
    /// class, the size, and the plane of each frame that states its position,
    /// in the order of the file.
    public struct MultiframeLayout: Equatable, Sendable {
        public var sopClassUID: String?
        public var columns: Int
        public var rows: Int
        public var frames: Int
        public var planes: [FramePlane]

        public init(sopClassUID: String?, columns: Int, rows: Int, frames: Int, planes: [FramePlane]) {
            self.sopClassUID = sopClassUID
            self.columns = columns
            self.rows = rows
            self.frames = frames
            self.planes = planes
        }
    }

    /// The classes whose multiframe files are volumes: each frame a slice,
    /// placed by the functional groups. An acquisition in time (a functional
    /// or a diffusion series, a dynamic one) may come as one such file per
    /// volume, all of one Series Instance UID. The legacy converted classes
    /// are single-frame images put in one file with the same functional
    /// groups, which the reading takes the planes from whatever the class.
    public static let volumeMultiframeSOPClasses: Set<String> = [
        "1.2.840.10008.5.1.4.1.1.4.1", // Enhanced MR Image Storage
        "1.2.840.10008.5.1.4.1.1.2.1", // Enhanced CT Image Storage
        "1.2.840.10008.5.1.4.1.1.130", // Enhanced PET Image Storage
        "1.2.840.10008.5.1.4.1.1.4.4", // Legacy Converted Enhanced MR Image Storage
        "1.2.840.10008.5.1.4.1.1.2.2", // Legacy Converted Enhanced CT Image Storage
        "1.2.840.10008.5.1.4.1.1.128.1", // Legacy Converted Enhanced PET Image Storage
    ]

    /// The parts of a millimetre and of a direction cosine that two files of
    /// one acquisition may differ by and still lie in the same place: a
    /// hundredth of a millimetre, a thousandth of a cosine.
    static let positionSteps = 100.0, orientationSteps = 1000.0

    /// The series key of a multiframe file as it has always been: the file
    /// alone, by its image identifier and its SOP Instance UID after the
    /// grouping. A database indexed before volumes shared a key holds every
    /// multiframe file under this one.
    public static func formerMultiframeSeriesKey(grouping: String?, imageID: String?, sopInstanceUID: String?) -> String {
        "\(grouping ?? "(null)")-\(imageID ?? "(null)")-\(sopInstanceUID ?? "(null)")"
    }

    /// The series key that the multiframe files of one volume geometry share,
    /// nil for a file that keeps a series of its own. A file shares when its
    /// class is one of `volumeMultiframeSOPClasses`, every frame states its
    /// position, one orientation serves every frame and no two frames have the
    /// same slice location: one volume, which another file of the same
    /// grouping, size and planes repeats at another time. A cine, a file of
    /// several planes or of several phases, a segmentation and any other class
    /// do not.
    ///
    /// The key is the grouping, "volume", columns x rows x frames, and sixteen
    /// hexadecimal digits: the FNV-1a hash, of 64 bits, of the orientation in
    /// thousandths and of the positions in hundredths of a millimetre, the
    /// positions in the order of their slice locations. The same on every run
    /// and processor.
    public static func volumeSeriesKey(grouping: String?, layout: MultiframeLayout) -> String? {
        guard let sopClassUID = layout.sopClassUID, volumeMultiframeSOPClasses.contains(sopClassUID),
              layout.frames > 1, layout.columns > 0, layout.rows > 0, layout.planes.count == layout.frames,
              let first = layout.planes.first, let orientation = steps(first.orientation, count: 6, orientationSteps)
        else { return nil }
        var slices: [(location: Int64, position: [Int64])] = []
        for plane in layout.planes {
            guard steps(plane.orientation, count: 6, orientationSteps) == orientation,
                  let position = steps(plane.position, count: 3, positionSteps),
                  let location = steps([sliceLocation(origin: plane.position, orientation: plane.orientation)],
                                       count: 1, positionSteps)
            else { return nil }
            slices.append((location[0], position))
        }
        slices.sort { $0.location < $1.location }
        for index in slices.indices.dropFirst() where slices[index].location == slices[index - 1].location { return nil }
        let geometry = ([orientation] + slices.map(\.position))
            .map { $0.map(String.init).joined(separator: " ") }.joined(separator: "|")
        return "\(grouping ?? "(null)")-volume-\(layout.columns)x\(layout.rows)x\(layout.frames)-\(stableHash(geometry))"
    }

    /// The series key of a multiframe file: the one its volume shares, or the
    /// file's own.
    public static func multiframeSeriesKey(grouping: String?, imageID: String?, sopInstanceUID: String?,
                                           layout: MultiframeLayout) -> String {
        volumeSeriesKey(grouping: grouping, layout: layout)
            ?? formerMultiframeSeriesKey(grouping: grouping, imageID: imageID, sopInstanceUID: sopInstanceUID)
    }

    /// `values` in whole steps, `perUnit` of them to one, rounded to the
    /// nearest; nil unless there are `count` of them, all finite and small
    /// enough to count.
    private static func steps(_ values: [Double], count: Int, _ perUnit: Double) -> [Int64]? {
        guard values.count == count else { return nil }
        var whole: [Int64] = []
        for value in values {
            let scaled = (value * perUnit).rounded(.toNearestOrAwayFromZero)
            guard scaled.isFinite, abs(scaled) < 1e15 else { return nil }
            whole.append(Int64(scaled))
        }
        return whole
    }

    /// The FNV-1a hash, of 64 bits, of the UTF-8 of `text`, as sixteen
    /// hexadecimal digits. Swift's own hash changes from run to run, and this
    /// one is stored.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let digits = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }

    // MARK: - Pixels

    /// What is said of an object that declares a picture of `columns` x
    /// `rows`, from what the file carries; nil when nothing is wrong with it.
    public enum PixelData {
        /// The Pixel Data element is absent; what the object has instead.
        case absent(floatPixels: Bool, doubleFloatPixels: Bool, icon: (columns: UInt16, rows: UInt16)?)
        /// Native pixel data of `length` bytes.
        case native(length: UInt)
        /// Encapsulated pixel data, whose length says nothing.
        case encapsulated
    }

    /// The samples native pixel data stores per pixel, of the
    /// `samplesPerPixel` an object declares: two for YBR_FULL_422 and
    /// YBR_PARTIAL_422, whose chrominance is subsampled horizontally, so that
    /// two pixels are stored as Y Y Cb Cr (PS3.3 C.7.6.3.1.2) although three
    /// samples per pixel are declared; the declared number otherwise.
    public static func storedSamplesPerPixel(_ samplesPerPixel: Int, photometricInterpretation: String?) -> Int {
        guard samplesPerPixel == 3, let photometric = photometricInterpretation?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")).uppercased() else { return samplesPerPixel }
        return photometric == "YBR_FULL_422" || photometric == "YBR_PARTIAL_422" ? 2 : samplesPerPixel
    }

    /// The problem of a picture of `columns` x `rows`, whose samples are
    /// `bitsAllocated` bits and `samplesPerPixel` (each 0 when the file does
    /// not state it), laid out as `photometricInterpretation` says, in
    /// `frames` frames, carried as `pixels`.
    public static func pixelDataProblem(columns: UInt16, rows: UInt16, bitsAllocated: UInt16, samplesPerPixel: UInt16,
                                        photometricInterpretation: String? = nil,
                                        frames: Int, pixels: PixelData) -> String? {
        if rows == 0 || columns == 0 {
            return "it declares a picture of \(columns) x \(rows)"
        }
        switch pixels {
        case let .absent(floatPixels, doubleFloatPixels, icon):
            if floatPixels {
                return "its pixels are in Float Pixel Data (7fe0,0008), which this application does not read"
            }
            if doubleFloatPixels {
                return "its pixels are in Double Float Pixel Data (7fe0,0009), which this application does not read"
            }
            if let icon {
                return "its only picture is a \(icon.columns) x \(icon.rows) preview icon in "
                    + "Icon Image Sequence (0088,0200), not the \(columns) x \(rows) image it declares"
            }
            return "it carries no pixel data at all"
        case .native(let length):
            if length == 0 { return "its pixel data is empty" }
            guard bitsAllocated > 0, samplesPerPixel > 0 else { return nil }
            let samples = storedSamplesPerPixel(Int(samplesPerPixel), photometricInterpretation: photometricInterpretation)
            let expected = UInt64(rows) &* UInt64(columns) &* UInt64(samples)
                &* UInt64((Int(bitsAllocated) + 7) / 8) &* UInt64(truncatingIfNeeded: max(1, frames))
            if UInt64(length) < expected {
                return "its pixel data is \(length) bytes where \(expected) are needed for \(columns)x\(rows)"
            }
            return nil
        case .encapsulated:
            return nil
        }
    }

    /// The problem of an object that declares no picture and is of none of the
    /// kinds the application shows.
    public static func undisplayableObjectProblem(sopClassUID: String) -> String {
        "it is a \(sopClassUID) object, which this application keeps but cannot display"
    }
}
