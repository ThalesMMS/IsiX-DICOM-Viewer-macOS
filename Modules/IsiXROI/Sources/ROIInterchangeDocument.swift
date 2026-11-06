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

/// The open JSON document regions of interest are exported to and imported
/// from, as it is written: its keys are the names of the properties below,
/// sorted, an absent optional is left out, and the text is pretty printed.
/// Released versions read and wrote this form; it does not change.
///
/// The document is values only. Matching it against a loaded series and
/// turning its records into ROIs is the application's.
public struct ROIInterchangeDocument: Codable, Sendable, Equatable {
    public static let formatIdentifier = "org.horosproject.roi-interchange"
    /// The newest version written and read. Version 2 identifies physical
    /// Lengths, so that older readers reject the document instead of
    /// flattening their endpoints into a single image plane.
    public static let formatVersion = 2
    public static let fileExtension = "json"
    public static let pixelCoordinateSystem = "image pixels: x right, y down, origin at the top-left corner of pixel (0,0), one unit per pixel"
    public static let patientCoordinateSystem = "DICOM patient coordinates (LPS), millimetres"

    public var format: String
    public var version: Int
    public var generator: String?
    public var created: String?
    public var coordinateSystems: CoordinateSystems
    public var series: Series
    public var images: [Image]

    public init(format: String = ROIInterchangeDocument.formatIdentifier, version: Int, generator: String?, created: String?,
                coordinateSystems: CoordinateSystems = CoordinateSystems(), series: Series, images: [Image]) {
        self.format = format
        self.version = version
        self.generator = generator
        self.created = created
        self.coordinateSystems = coordinateSystems
        self.series = series
        self.images = images
    }

    /// The two coordinate systems the points of a document are given in.
    public struct CoordinateSystems: Codable, Sendable, Equatable {
        public var pixel: String
        public var patient: String

        public init(pixel: String = ROIInterchangeDocument.pixelCoordinateSystem,
                    patient: String = ROIInterchangeDocument.patientCoordinateSystem) {
            self.pixel = pixel
            self.patient = patient
        }
    }

    /// The identity of the series the ROIs were drawn on.
    public struct Series: Codable, Sendable, Equatable {
        public var studyInstanceUID: String?
        public var seriesInstanceUID: String?
        public var frameOfReferenceUID: String?
        public var modality: String?
        public var seriesDescription: String?

        public init(studyInstanceUID: String? = nil, seriesInstanceUID: String? = nil, frameOfReferenceUID: String? = nil,
                    modality: String? = nil, seriesDescription: String? = nil) {
            self.studyInstanceUID = studyInstanceUID
            self.seriesInstanceUID = seriesInstanceUID
            self.frameOfReferenceUID = frameOfReferenceUID
            self.modality = modality
            self.seriesDescription = seriesDescription
        }
    }

    /// One image of the series that holds ROIs, its identity and geometry.
    public struct Image: Codable, Sendable, Equatable {
        public var index: Int
        public var temporalIndex: Int?
        public var sopInstanceUID: String?
        public var frame: Int?
        public var instanceNumber: Int?
        public var rows: Int
        public var columns: Int
        public var pixelSpacing: [Double]
        public var sliceThickness: Double?
        public var sliceLocation: Double?
        public var imagePositionPatient: [Double]?
        public var imageOrientationPatient: [Double]?
        public var rois: [Region]

        public init(index: Int, temporalIndex: Int?, sopInstanceUID: String?, frame: Int?, instanceNumber: Int?,
                    rows: Int, columns: Int, pixelSpacing: [Double], sliceThickness: Double?, sliceLocation: Double?,
                    imagePositionPatient: [Double]?, imageOrientationPatient: [Double]?, rois: [Region]) {
            self.index = index
            self.temporalIndex = temporalIndex
            self.sopInstanceUID = sopInstanceUID
            self.frame = frame
            self.instanceNumber = instanceNumber
            self.rows = rows
            self.columns = columns
            self.pixelSpacing = pixelSpacing
            self.sliceThickness = sliceThickness
            self.sliceLocation = sliceLocation
            self.imagePositionPatient = imagePositionPatient
            self.imageOrientationPatient = imageOrientationPatient
            self.rois = rois
        }
    }

    /// The mask of a brush ROI: one byte per pixel, nonzero inside, in base 64.
    public struct Brush: Codable, Sendable, Equatable {
        public var width: Int
        public var height: Int
        public var originX: Int
        public var originY: Int
        public var maskBase64: String

        public init(width: Int, height: Int, originX: Int, originY: Int, maskBase64: String) {
            self.width = width
            self.height = height
            self.originX = originX
            self.originY = originY
            self.maskBase64 = maskBase64
        }
    }

    /// One region of interest of an image.
    public struct Region: Codable, Sendable, Equatable {
        public var name: String
        public var type: String?
        public var typeCode: Int?
        public var comments: String?
        public var points: [[Double]]
        public var pointsPatient: [[Double]]?
        public var volumeLength: VolumeLength?
        public var rect: [Double]?
        public var thickness: Double?
        public var opacity: Double?
        public var color: [Double]?
        public var isSpline: Bool?
        public var groupID: Double?
        public var brush: Brush?

        public init(name: String, type: String?, typeCode: Int?, comments: String?, points: [[Double]],
                    pointsPatient: [[Double]]?, volumeLength: VolumeLength?, rect: [Double]?, thickness: Double?,
                    opacity: Double?, color: [Double]?, isSpline: Bool?, groupID: Double?, brush: Brush?) {
            self.name = name
            self.type = type
            self.typeCode = typeCode
            self.comments = comments
            self.points = points
            self.pointsPatient = pointsPatient
            self.volumeLength = volumeLength
            self.rect = rect
            self.thickness = thickness
            self.opacity = opacity
            self.color = color
            self.isSpline = isSpline
            self.groupID = groupID
            self.brush = brush
        }
    }

    /// The image a physical Length's endpoint was placed on.
    public struct EndpointReference: Codable, Sendable, Equatable {
        public var sopInstanceUID: String
        public var frame: Int
        public var generated: Bool
        public var imagePositionPatient: [Double]
        public var imageOrientationPatient: [Double]
        public var pixelSpacing: [Double]
    }

    /// A physical Length: its two endpoints in patient coordinates and the
    /// images they were placed on (version 2).
    public struct VolumeLength: Codable, Sendable, Equatable {
        public var version: Int
        public var id: String
        public var a: [Double]
        public var b: [Double]
        public var series: String
        public var frameOfReference: String
        public var temporalIndex: Int
        public var referenceA: EndpointReference
        public var referenceB: EndpointReference
        public var storageSOPInstanceUID: String?
        public var storageFrame: Int?

        /// Why a Length cannot be kept.
        public enum Defect: Error, Sendable, Equatable {
            /// Its endpoints or its identity are missing, not finite or the same point.
            case endpoints
            /// The geometry of an endpoint's image is not usable.
            case referenceGeometry

            public var reason: String {
                switch self {
                case .endpoints: return "Invalid patient-space Length endpoints or identity."
                case .referenceGeometry: return "Invalid Length endpoint reference geometry."
                }
            }
        }

        /// What makes the Length unusable, nil when it is valid.
        public var defect: Defect? {
            guard version == 1, !id.isEmpty, !series.isEmpty, !frameOfReference.isEmpty,
                  temporalIndex >= 0, a.count == 3, b.count == 3,
                  a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite),
                  zip(a, b).reduce(0, { $0 + pow($1.0 - $1.1, 2) }) > 1e-12 else {
                return .endpoints
            }
            for reference in [referenceA, referenceB] {
                guard !reference.sopInstanceUID.isEmpty, reference.frame >= 0,
                      reference.imagePositionPatient.count == 3,
                      reference.imageOrientationPatient.count == 6,
                      reference.pixelSpacing.count == 2,
                      reference.imagePositionPatient.allSatisfy(\.isFinite),
                      reference.imageOrientationPatient.allSatisfy(\.isFinite),
                      reference.pixelSpacing.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                    return .referenceGeometry
                }
            }
            return nil
        }

        /// The Length as the payload a ROI keeps: its JSON object, once it
        /// is valid.
        public func validatedPayload() throws -> [String: Any] {
            if let defect { throw defect }
            return try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] ?? [:]
        }

        /// The Length a ROI's payload holds. The archives of earlier versions
        /// restore the "generated" flags as the numbers 0 and 1: they are read
        /// as booleans first.
        public static func from(payload: [String: Any]) throws -> VolumeLength {
            var normalized = payload
            for key in ["referenceA", "referenceB"] {
                if var reference = normalized[key] as? [String: Any],
                   let generated = reference["generated"] as? NSNumber {
                    reference["generated"] = generated.boolValue
                    normalized[key] = reference
                }
            }
            return try JSONDecoder().decode(VolumeLength.self, from: JSONSerialization.data(withJSONObject: normalized))
        }
    }

    /// The version a document of these images is written with: 2 when one of
    /// them holds a physical Length, 1 otherwise.
    public static func version(for images: [Image]) -> Int {
        images.contains(where: { $0.rois.contains(where: { $0.volumeLength != nil }) }) ? 2 : 1
    }

    /// The date and time a document is written at, as it records it.
    public static func timestamp(_ date: Date = Date()) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// The document as it is written: pretty printed, its keys sorted.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// The document `data` holds; a DecodingError says where it is not one.
    public static func decoded(from data: Data) throws -> ROIInterchangeDocument {
        try JSONDecoder().decode(ROIInterchangeDocument.self, from: data)
    }

    /// Where and why `error` refused a document, in the words an import
    /// error shows.
    public static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let p = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return p.isEmpty ? "document" : p
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing key \"\(key.stringValue)\" in \(path(context))."
        case .typeMismatch(_, let context):
            return "wrong value type at \(path(context)): \(context.debugDescription)"
        case .valueNotFound(_, let context):
            return "missing value at \(path(context))."
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return error.localizedDescription
        }
    }
}
