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

/// The ROIs of a series out to a spreadsheet: one CSV row per ROI with its
/// measurements and pixel statistics and, when asked for, a second CSV with
/// every point of every ROI. The app reads the values from the ROIs and their
/// images; the files are written from these rules alone.
///
/// The format, which does not follow the user's locale:
///
/// - RFC 4180: fields separated by commas, records ended by CRLF, a field
///   holding a comma, a quote, a carriage return or a line feed quoted, with
///   its quotes doubled. UTF-8 with a byte order mark, so that a spreadsheet
///   reads accented names as UTF-8.
/// - Numbers with a dot as decimal separator and a fixed number of decimals:
///   4 for areas and lengths, 3 for the statistics and the coordinates. A
///   value that does not apply, or is not finite, is an empty field.
/// - The ROI file starts with `roiHeader`:
///   `ROI` the number of the ROI, from 1, which the points file refers to;
///   `Series` the series description; `Series Instance UID`;
///   `Image` the image number the viewer shows, from 1;
///   `Instance Number`; `Type` the ROI's kind, in English (`typeName`);
///   `Name`; `Area` in `Unit`² for the closed shapes; `Length` in `Unit` for
///   a Length; `Unit` `cm`, or `px` for an image without pixel spacing;
///   `Mean`, `SD` (sample standard deviation, n - 1), `Min`, `Max` of the
///   pixel values inside the ROI, in the image's own values (HU, SUV…).
/// - The points file starts with `pointHeader`:
///   `ROI`, `Image`, `Name` as in the ROI file; `Point` its number in the ROI,
///   from 1; `X (px)` and `Y (px)` on the image; `Patient X (mm)`,
///   `Patient Y (mm)`, `Patient Z (mm)` in the patient coordinates of DICOM.
///   A length measured between two images has patient points only.
public enum ROICSVExport {

    /// What the measurements of a row are in.
    public enum Unit: String, Sendable, Equatable {
        /// Areas in cm², lengths in cm.
        case centimetre = "cm"
        /// Areas in pixels², lengths in pixels: the image has no pixel spacing.
        case pixel = "px"
    }

    /// The pixel values inside a ROI.
    public struct Statistics: Sendable, Equatable {
        public var mean: Double
        public var deviation: Double
        public var minimum: Double
        public var maximum: Double

        public init(mean: Double, deviation: Double, minimum: Double, maximum: Double) {
            self.mean = mean
            self.deviation = deviation
            self.minimum = minimum
            self.maximum = maximum
        }
    }

    /// One point of a ROI: on the image, in the patient, or both.
    public struct Point: Sendable, Equatable {
        public var x: Double?
        public var y: Double?
        public var patient: [Double]?

        public init(x: Double?, y: Double?, patient: [Double]?) {
            self.x = x
            self.y = y
            self.patient = patient
        }
    }

    /// One ROI, with what the files say of it.
    public struct Entry: Sendable, Equatable {
        public var seriesDescription: String
        public var seriesInstanceUID: String
        /// The image number the viewer shows, from 1.
        public var image: Int
        public var instanceNumber: Int?
        /// The ROI's ToolMode value.
        public var typeCode: Int
        public var name: String
        public var area: Double?
        public var length: Double?
        public var unit: Unit
        public var statistics: Statistics?
        public var points: [Point]

        public init(seriesDescription: String, seriesInstanceUID: String, image: Int, instanceNumber: Int?,
                    typeCode: Int, name: String, area: Double?, length: Double?, unit: Unit,
                    statistics: Statistics?, points: [Point]) {
            self.seriesDescription = seriesDescription
            self.seriesInstanceUID = seriesInstanceUID
            self.image = image
            self.instanceNumber = instanceNumber
            self.typeCode = typeCode
            self.name = name
            self.area = area
            self.length = length
            self.unit = unit
            self.statistics = statistics
            self.points = points
        }
    }

    public static let roiHeader = ["ROI", "Series", "Series Instance UID", "Image", "Instance Number", "Type", "Name",
                                   "Area", "Length", "Unit", "Mean", "SD", "Min", "Max"]

    public static let pointHeader = ["ROI", "Image", "Name", "Point", "X (px)", "Y (px)",
                                     "Patient X (mm)", "Patient Y (mm)", "Patient Z (mm)"]

    // MARK: - Kinds of ROI

    /// ToolMode's values of the kinds a ROI can be.
    public enum TypeCode {
        public static let length = 5, rectangle = 6, oval = 9, openPolygon = 10, closedPolygon = 11
        public static let angle = 12, text = 13, arrow = 14, pencil = 15, point3D = 16, point = 19
        public static let brush = 20, layer = 24, axis = 26, dynamicAngle = 27, curved = 28, tagt = 29
    }

    /// The kinds whose area is measured, as -[ROI roiArea] measures them.
    public static func hasArea(typeCode: Int) -> Bool {
        [TypeCode.rectangle, TypeCode.oval, TypeCode.openPolygon, TypeCode.closedPolygon, TypeCode.pencil,
         TypeCode.brush, TypeCode.axis, TypeCode.dynamicAngle].contains(typeCode)
    }

    /// The kinds whose length is measured: a Length.
    public static func hasLength(typeCode: Int) -> Bool {
        typeCode == TypeCode.length
    }

    /// The kinds whose label shows the statistics of the pixels inside.
    public static func hasStatistics(typeCode: Int) -> Bool {
        hasArea(typeCode: typeCode) || typeCode == TypeCode.tagt
    }

    /// The `Type` column: the kind in English, whatever the language of the app.
    public static func typeName(_ code: Int) -> String {
        switch code {
        case TypeCode.length: return "Length"
        case TypeCode.rectangle: return "Rectangle"
        case TypeCode.oval: return "Oval"
        case TypeCode.openPolygon: return "Open Polygon"
        case TypeCode.closedPolygon: return "Closed Polygon"
        case TypeCode.angle: return "Angle"
        case TypeCode.text: return "Text"
        case TypeCode.arrow: return "Arrow"
        case TypeCode.pencil: return "Pencil"
        case TypeCode.point3D: return "3D Point"
        case TypeCode.point: return "Point"
        case TypeCode.brush: return "Brush"
        case TypeCode.layer: return "Layer"
        case TypeCode.axis: return "Axis"
        case TypeCode.dynamicAngle: return "Dynamic Angle"
        case TypeCode.curved: return "Curved"
        case TypeCode.tagt: return "TAGT"
        default: return "Type \(code)"
        }
    }

    // MARK: - Fields

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// `value` with `decimals` decimals and a dot, in any locale; empty for
    /// nil or a value that is not finite. A negative value that rounds to
    /// zero is written as zero.
    public static func number(_ value: Double?, decimals: Int) -> String {
        guard let value, value.isFinite else { return "" }
        let text = String(format: "%.\(max(decimals, 0))f", locale: posix, value)
        if text.hasPrefix("-"), text.dropFirst().allSatisfy({ $0 == "0" || $0 == "." }) {
            return String(text.dropFirst())
        }
        return text
    }

    /// One field of a record: quoted when it holds a comma, a quote, a
    /// carriage return or a line feed, with its quotes doubled. CRLF is one
    /// Character in Swift, and is tested as such.
    public static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" || $0 == "\r\n" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The text of a file: its records, each ended by CRLF.
    public static func csv(_ rows: [[String]]) -> String {
        rows.map { $0.map(field).joined(separator: ",") + "\r\n" }.joined()
    }

    /// The bytes of a file: UTF-8 with the byte order mark.
    public static func data(_ text: String) -> Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
    }

    // MARK: - Records

    /// The records of the ROI file, the header first.
    public static func roiRows(_ entries: [Entry]) -> [[String]] {
        var rows = [roiHeader]
        for (index, entry) in entries.enumerated() {
            let s = entry.statistics
            rows.append(["\(index + 1)", entry.seriesDescription, entry.seriesInstanceUID, "\(entry.image)",
                         entry.instanceNumber.map { "\($0)" } ?? "", typeName(entry.typeCode), entry.name,
                         number(entry.area, decimals: 4), number(entry.length, decimals: 4), entry.unit.rawValue,
                         number(s?.mean, decimals: 3), number(s?.deviation, decimals: 3),
                         number(s?.minimum, decimals: 3), number(s?.maximum, decimals: 3)])
        }
        return rows
    }

    /// The records of the points file, the header first.
    public static func pointRows(_ entries: [Entry]) -> [[String]] {
        var rows = [pointHeader]
        for (index, entry) in entries.enumerated() {
            for (n, point) in entry.points.enumerated() {
                let patient = point.patient?.count == 3 ? point.patient : nil
                rows.append(["\(index + 1)", "\(entry.image)", entry.name, "\(n + 1)",
                             number(point.x, decimals: 3), number(point.y, decimals: 3),
                             number(patient?[0], decimals: 3), number(patient?[1], decimals: 3),
                             number(patient?[2], decimals: 3)])
            }
        }
        return rows
    }

    /// The ROI file of `entries`.
    public static func roiFile(_ entries: [Entry]) -> Data {
        data(csv(roiRows(entries)))
    }

    /// The points file of `entries`.
    public static func pointFile(_ entries: [Entry]) -> Data {
        data(csv(pointRows(entries)))
    }

    /// Where the points file goes: beside the ROI file, its name followed by
    /// " points" (`Liver ROIs.csv`, `Liver ROIs points.csv`).
    public static func pointsFileURL(for url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent(base + " points").appendingPathExtension("csv")
    }
}
