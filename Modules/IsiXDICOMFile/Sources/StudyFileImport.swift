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
import UniformTypeIdentifiers

/// The rules of turning image files (JPEG, PNG, TIFF) into DICOM Secondary
/// Capture images and PDF files into DICOM Encapsulated PDF documents of an
/// existing study: which files are taken, how the new series and their
/// instances are numbered, and the attributes each object carries, built from
/// the study's patient and study values so that the database files the
/// objects under that study.
public enum StudyFileImport {

    /// What a file becomes.
    public enum Kind: Sendable, Equatable, Hashable {
        /// A Secondary Capture image, one per file.
        case image
        /// An Encapsulated PDF document, one per file.
        case pdf
    }

    /// The types the file panel offers: JPEG, PNG, TIFF and PDF.
    public static let acceptedTypes: [UTType] = [.jpeg, .png, .tiff, .pdf]

    /// The kind a file becomes, from the type its extension names; nil for
    /// any other file, a DICOM file or a folder name among them.
    public static func kind(ofPath path: String) -> Kind? {
        let fileExtension = (path as NSString).pathExtension
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else { return nil }
        if type.conforms(to: .pdf) { return .pdf }
        if [UTType.jpeg, .png, .tiff].contains(where: { type.conforms(to: $0) }) { return .image }
        return nil
    }

    /// The files of a request, sorted as the Finder sorts their names, each
    /// once; `refused` keeps the files of no accepted kind.
    public struct Selection: Sendable, Equatable {
        public var images: [String] = []
        public var pdfs: [String] = []
        public var refused: [String] = []

        public init(images: [String] = [], pdfs: [String] = [], refused: [String] = []) {
            self.images = images
            self.pdfs = pdfs
            self.refused = refused
        }

        public var isEmpty: Bool { images.isEmpty && pdfs.isEmpty }
    }

    public static func selection(of paths: [String]) -> Selection {
        var seen = Set<String>()
        let unique = paths.filter { seen.insert($0).inserted }.sorted {
            let order = ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent)
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
        var selection = Selection()
        for path in unique {
            switch kind(ofPath: path) {
            case .image: selection.images.append(path)
            case .pdf: selection.pdfs.append(path)
            case nil: selection.refused.append(path)
            }
        }
        return selection
    }

    /// Whether files dropped on a study are converted into it: only when
    /// every one of them is an accepted image or PDF. Anything else (a DICOM
    /// file, a folder, a database, a mix) goes to the import as before.
    public static func convertsDrop(of paths: [String]) -> Bool {
        !paths.isEmpty && paths.allSatisfy { kind(ofPath: $0) != nil }
    }

    // MARK: - Numbering

    /// The application numbers the series it generates itself from 5000 up
    /// (exports, the annotation and ROI SRs, pasted images): a converted
    /// series follows the study's acquired series, below those.
    public static let generatedSeriesNumbers = 5000

    /// The numbers of `count` new series, ascending: each above every number
    /// below `generatedSeriesNumbers` the study has, and taken by no series
    /// of it.
    public static func newSeriesNumbers(existing: [Int], count: Int) -> [Int] {
        var used = Set(existing)
        var next = max(existing.filter { $0 < generatedSeriesNumbers }.max() ?? 0, 0) + 1
        var numbers: [Int] = []
        while numbers.count < count {
            if !used.contains(next) {
                numbers.append(next)
                used.insert(next)
            }
            next += 1
        }
        return numbers
    }

    /// The description of the new series of a kind.
    public static func seriesDescription(of kind: Kind) -> String {
        switch kind {
        case .image: return "Imported images"
        case .pdf: return "Imported PDF"
        }
    }

    /// The title of the document made of `path`: its name without the extension.
    public static func documentTitle(ofPath path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    // MARK: - Attributes

    /// An attribute written in a converted object, by its tag (group << 16 |
    /// element). Text is UTF-8: the objects declare ISO_IR 192.
    public struct Attribute: Sendable, Equatable {
        public let tag: UInt32
        public let value: String

        public init(_ tag: UInt32, _ value: String) {
            self.tag = tag
            self.value = value
        }
    }

    /// A patient or study value the converted objects carry.
    public enum StudyField: CaseIterable, Sendable, Hashable {
        case patientName, patientID, patientBirthDate, patientSex
        case studyInstanceUID, studyID, studyDate, studyTime, accessionNumber, studyDescription, referringPhysicianName

        public var tag: UInt32 {
            switch self {
            case .patientName: return 0x0010_0010
            case .patientID: return 0x0010_0020
            case .patientBirthDate: return 0x0010_0030
            case .patientSex: return 0x0010_0040
            case .studyInstanceUID: return 0x0020_000d
            case .studyID: return 0x0020_0010
            case .studyDate: return 0x0008_0020
            case .studyTime: return 0x0008_0030
            case .accessionNumber: return 0x0008_0050
            case .studyDescription: return 0x0008_1030
            case .referringPhysicianName: return 0x0008_0090
            }
        }
    }

    /// The patient and study values of the study the files go into.
    public struct StudyValues: Sendable, Equatable {
        public private(set) var values: [StudyField: String]

        public init(_ values: [StudyField: String]) {
            self.values = values.filter { !$0.value.isEmpty }
        }

        public subscript(field: StudyField) -> String { values[field] ?? "" }

        /// The values of a DICOM file of the study (`source`, text as the
        /// file has it, the name with its components) over those of the
        /// study's record (`record`), which fill what the file lacks. The file
        /// made the record, so its patient identity is the one the database
        /// matches a new file against. The Study Instance UID is the record's:
        /// it names the study the files go into.
        public static func merged(source: [StudyField: String], record: [StudyField: String]) -> StudyValues {
            var merged: [StudyField: String] = [:]
            for field in StudyField.allCases {
                let first = field == .studyInstanceUID ? record[field] : source[field]
                let second = field == .studyInstanceUID ? source[field] : record[field]
                if let first, !first.isEmpty {
                    merged[field] = first
                } else if let second, !second.isEmpty {
                    merged[field] = second
                }
            }
            return StudyValues(merged)
        }

        /// Whether the objects can be filed under a study: they need its UID.
        public var identifiesStudy: Bool { !self[.studyInstanceUID].isEmpty }
    }

    /// The new series an object belongs to.
    public struct Series: Sendable, Equatable {
        public let uid: String
        public let number: Int
        public let description: String

        public init(uid: String, number: Int, description: String) {
            self.uid = uid
            self.number = number
            self.description = description
        }
    }

    /// Secondary Capture Image Storage.
    public static let secondaryCaptureStorage = "1.2.840.10008.5.1.4.1.1.7"
    /// Encapsulated PDF Storage.
    public static let encapsulatedPDFStorage = "1.2.840.10008.5.1.4.1.1.104.1"

    /// YYYYMMDD and HHMMSS of `date` in `timeZone`.
    static func dateAndTime(_ date: Date, timeZone: TimeZone) -> (date: String, time: String) {
        (DICOMDateTimeText.date(date, timeZone: timeZone),
         String(DICOMDateTimeText.time(date, fraction: false, timeZone: timeZone).prefix(6)))
    }

    /// The attributes of the object of kind `kind` numbered `instanceNumber`
    /// in `series`, made at `created`, for the study `study`: its SOP class,
    /// the patient and study modules from the study's values (type 2 values
    /// the study lacks are written empty), the series and the instance, and
    /// the conversion (a workstation, WSD). A PDF also carries its title,
    /// `documentTitle`. The pixel module of an image is imagePixelAttributes'.
    /// The SOP Instance UID is the writer's.
    public static func attributes(of kind: Kind, study: StudyValues, series: Series, instanceNumber: Int,
                                  documentTitle: String, created: Date,
                                  timeZone: TimeZone = DICOMDateTimeText.defaultTimeZone) -> [Attribute] {
        let now = dateAndTime(created, timeZone: timeZone)
        var attributes = [
            Attribute(0x0008_0005, "ISO_IR 192"),
            Attribute(0x0008_0016, kind == .image ? secondaryCaptureStorage : encapsulatedPDFStorage),
            Attribute(0x0008_0060, kind == .image ? "OT" : "DOC"),
            Attribute(0x0008_0064, "WSD"),
            Attribute(0x0008_0070, "IsiX DICOM Viewer"),
        ]
        attributes += StudyField.allCases.map { Attribute($0.tag, study[$0]) }
        attributes += [
            Attribute(0x0020_000e, series.uid),
            Attribute(0x0020_0011, String(series.number)),
            Attribute(0x0008_103e, series.description),
            Attribute(0x0008_0021, now.date),
            Attribute(0x0008_0031, now.time),
            Attribute(0x0020_0013, String(instanceNumber)),
            Attribute(0x0008_0023, now.date),
            Attribute(0x0008_0033, now.time),
        ]
        switch kind {
        case .image:
            attributes += [
                Attribute(0x0008_0008, "DERIVED\\SECONDARY"),
                Attribute(0x0018_1012, now.date), // Date of Secondary Capture
                Attribute(0x0018_1014, now.time), // Time of Secondary Capture
                Attribute(0x0020_0020, ""), // Patient Orientation, type 2: unknown
            ]
        case .pdf:
            attributes += [
                Attribute(0x0042_0010, documentTitle),
                Attribute(0x0028_0301, "NO"), // Burned In Annotation
            ]
        }
        return attributes
    }

    /// The largest number of rows or columns a DICOM image can say (US).
    public static let maximumImageSide = 65535

    /// Why an image of `width` × `height` cannot become a Secondary Capture,
    /// nil when it can.
    public static func imageRefusal(width: Int, height: Int) -> String? {
        if width <= 0 || height <= 0 { return "The image has no pixels." }
        if width > maximumImageSide || height > maximumImageSide {
            return "The image is larger than \(maximumImageSide) pixels on a side."
        }
        return nil
    }

    /// The pixel module of an image of 8-bit samples, `samplesPerPixel` 1
    /// (grey, MONOCHROME2) or 3 (RGB, colour by pixel), stored row by row
    /// from the top left.
    public static func imagePixelAttributes(width: Int, height: Int, samplesPerPixel: Int) -> [Attribute] {
        var attributes = [
            Attribute(0x0028_0002, String(samplesPerPixel)),
            Attribute(0x0028_0004, samplesPerPixel == 3 ? "RGB" : "MONOCHROME2"),
            Attribute(0x0028_0010, String(height)),
            Attribute(0x0028_0011, String(width)),
            Attribute(0x0028_0100, "8"),
            Attribute(0x0028_0101, "8"),
            Attribute(0x0028_0102, "7"),
            Attribute(0x0028_0103, "0"),
        ]
        if samplesPerPixel == 3 {
            attributes.append(Attribute(0x0028_0006, "0"))
        }
        return attributes
    }
}
