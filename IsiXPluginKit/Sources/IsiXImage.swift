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

/// A point or direction in the patient coordinate system (DICOM LPS), in millimetres.
public struct IsiXVector3: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static func + (a: IsiXVector3, b: IsiXVector3) -> IsiXVector3 { IsiXVector3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z) }
    public static func - (a: IsiXVector3, b: IsiXVector3) -> IsiXVector3 { IsiXVector3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z) }
    public static func * (a: IsiXVector3, s: Double) -> IsiXVector3 { IsiXVector3(x: a.x * s, y: a.y * s, z: a.z * s) }

    public func dot(_ b: IsiXVector3) -> Double { x * b.x + y * b.y + z * b.z }

    public func cross(_ b: IsiXVector3) -> IsiXVector3 {
        IsiXVector3(x: y * b.z - z * b.y, y: z * b.x - x * b.z, z: x * b.y - y * b.x)
    }

    public var length: Double { dot(self).squareRoot() }
}

/// A position on an image in pixel units: `x` counts columns and `y` rows, and
/// the centre of the first pixel is (0, 0), as DICOM places it.
public struct IsiXPixelPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Where an image lies in the patient, in DICOM terms.
///
/// The centre of the pixel at column `c`, row `r` is
/// `imagePosition + rowDirection * (c * columnSpacing) + columnDirection * (r * rowSpacing)`:
/// `rowDirection` and `columnDirection` are the six cosines of Image Orientation
/// (Patient) (0020,0037) in that order, `imagePosition` is Image Position
/// (Patient) (0020,0032), and the spacings are Pixel Spacing (0028,0030),
/// `rowSpacing` first.
public struct IsiXImageGeometry: Hashable, Sendable {
    public var columns: Int
    public var rows: Int
    /// Millimetres between the centres of adjacent columns.
    public var columnSpacing: Double
    /// Millimetres between the centres of adjacent rows.
    public var rowSpacing: Double
    public var imagePosition: IsiXVector3
    public var rowDirection: IsiXVector3
    public var columnDirection: IsiXVector3
    public var sliceThickness: Double
    /// Millimetres between this slice and the next one of the series, signed, or 0 for a single slice.
    public var sliceInterval: Double
    public var sliceLocation: Double

    public init(columns: Int, rows: Int, columnSpacing: Double, rowSpacing: Double, imagePosition: IsiXVector3,
                rowDirection: IsiXVector3, columnDirection: IsiXVector3, sliceThickness: Double,
                sliceInterval: Double, sliceLocation: Double) {
        self.columns = columns
        self.rows = rows
        self.columnSpacing = columnSpacing
        self.rowSpacing = rowSpacing
        self.imagePosition = imagePosition
        self.rowDirection = rowDirection
        self.columnDirection = columnDirection
        self.sliceThickness = sliceThickness
        self.sliceInterval = sliceInterval
        self.sliceLocation = sliceLocation
    }

    /// Image Orientation (Patient): the row direction, then the column direction.
    public var imageOrientation: [Double] {
        [rowDirection.x, rowDirection.y, rowDirection.z, columnDirection.x, columnDirection.y, columnDirection.z]
    }

    /// The unit normal of the image plane, row direction × column direction.
    public var normal: IsiXVector3 {
        let n = rowDirection.cross(columnDirection)
        let length = n.length
        return length > 0 ? n * (1 / length) : n
    }

    public func patientPoint(of point: IsiXPixelPoint) -> IsiXVector3 {
        imagePosition + rowDirection * (point.x * columnSpacing) + columnDirection * (point.y * rowSpacing)
    }

    /// The pixel position of the projection of `point` on the image plane.
    public func pixelPoint(of point: IsiXVector3) -> IsiXPixelPoint {
        let offset = point - imagePosition
        return IsiXPixelPoint(x: columnSpacing == 0 ? 0 : offset.dot(rowDirection) / columnSpacing,
                              y: rowSpacing == 0 ? 0 : offset.dot(columnDirection) / rowSpacing)
    }

    /// The signed distance of `point` from the image plane, along `normal`.
    public func distanceFromPlane(_ point: IsiXVector3) -> Double {
        (point - imagePosition).dot(normal)
    }
}

/// Pixels the plugin owns: a copy, valid for as long as the plugin keeps it,
/// whatever happens to the viewer it came from. Samples are row-major,
/// `channels` per pixel.
public struct IsiXPixelBuffer<Sample: Sendable & Equatable>: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let channels: Int
    public private(set) var samples: [Sample]

    /// Throws `IsiXPluginError.dimensionMismatch` unless there are
    /// `width * height * channels` samples.
    public init(width: Int, height: Int, channels: Int = 1, samples: [Sample]) throws {
        guard width > 0, height > 0, channels > 0, samples.count == width * height * channels else {
            throw IsiXPluginError.dimensionMismatch
        }
        self.width = width
        self.height = height
        self.channels = channels
        self.samples = samples
    }

    public subscript(column: Int, row: Int, channel: Int = 0) -> Sample {
        get { samples[(row * width + column) * channels + channel] }
        set { samples[(row * width + column) * channels + channel] = newValue }
    }

    /// The samples, for the duration of `body` only.
    public func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<Sample>) throws -> R) rethrows -> R {
        try samples.withUnsafeBufferPointer(body)
    }

    /// The samples, writable, for the duration of `body` only.
    public mutating func withUnsafeMutableBufferPointer<R>(_ body: (inout UnsafeMutableBufferPointer<Sample>) throws -> R) rethrows -> R {
        try samples.withUnsafeMutableBufferPointer(body)
    }
}

/// The pixels of an image.
public enum IsiXPixelData: Sendable, Equatable {
    /// One Float32 sample per pixel, in modality units: stored values after
    /// the rescale slope and intercept, or SUV when `IsiXImageAttributes.isSUV`.
    case float32(IsiXPixelBuffer<Float>)
    /// Colour images: four 8-bit samples per pixel, red, green, blue and alpha.
    case rgba8(IsiXPixelBuffer<UInt8>)
}

/// Identifies the state of one image when it was read. A commit is refused
/// unless the image is still in that state.
public struct IsiXImageVersion: Hashable, Sendable {
    public let viewer: IsiXViewerID
    public let slice: Int
    public let phase: Int
    let token: UInt64

    @_spi(IsiXHost)
    public init(viewer: IsiXViewerID, slice: Int, phase: Int, token: UInt64) {
        self.viewer = viewer
        self.slice = slice
        self.phase = phase
        self.token = token
    }

    @_spi(IsiXHost)
    public var hostToken: UInt64 { token }
}

/// What the plugin needs to interpret the pixels.
public struct IsiXImageAttributes: Hashable, Sendable {
    public var modality: String?
    public var studyInstanceUID: String?
    public var seriesInstanceUID: String?
    public var sopInstanceUID: String?
    /// Echo Time (0018,0081), in milliseconds.
    public var echoTime: Double?
    /// Repetition Time (0018,0080), in milliseconds.
    public var repetitionTime: Double?
    /// When the image was acquired: Acquisition Date and Time, or, without
    /// them, the Content, then Series, then Study Date and Time.
    public var acquisitionDate: Date?
    public var rescaleSlope: Double
    public var rescaleIntercept: Double
    /// Whether the samples are standardized uptake values rather than modality values.
    public var isSUV: Bool

    public init(modality: String? = nil, studyInstanceUID: String? = nil, seriesInstanceUID: String? = nil,
                sopInstanceUID: String? = nil, echoTime: Double? = nil, repetitionTime: Double? = nil,
                acquisitionDate: Date? = nil, rescaleSlope: Double = 1, rescaleIntercept: Double = 0, isSUV: Bool = false) {
        self.modality = modality
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.sopInstanceUID = sopInstanceUID
        self.echoTime = echoTime
        self.repetitionTime = repetitionTime
        self.acquisitionDate = acquisitionDate
        self.rescaleSlope = rescaleSlope
        self.rescaleIntercept = rescaleIntercept
        self.isSUV = isSUV
    }
}

/// One image of a viewer, copied: geometry, attributes and pixels. It stays
/// valid after the viewer closes and can be read on any thread.
public struct IsiXImage: Sendable {
    public let version: IsiXImageVersion
    public let geometry: IsiXImageGeometry
    public let attributes: IsiXImageAttributes
    public let pixels: IsiXPixelData

    public var viewerID: IsiXViewerID { version.viewer }
    public var slice: Int { version.slice }
    public var phase: Int { version.phase }

    /// The Float32 pixels, or nil for a colour image.
    public var scalarPixels: IsiXPixelBuffer<Float>? {
        if case .float32(let buffer) = pixels { return buffer }
        return nil
    }

    @_spi(IsiXHost)
    public init(version: IsiXImageVersion, geometry: IsiXImageGeometry, attributes: IsiXImageAttributes, pixels: IsiXPixelData) {
        self.version = version
        self.geometry = geometry
        self.attributes = attributes
        self.pixels = pixels
    }
}

public struct IsiXWindowLevel: Hashable, Sendable {
    public var center: Double
    public var width: Double

    public init(center: Double, width: Double) {
        self.center = center
        self.width = width
    }
}

/// The series a viewer shows, and where it is.
public struct IsiXSeriesSummary: Hashable, Sendable {
    public var sliceCount: Int
    /// Phases of a 4D series; 1 otherwise.
    public var phaseCount: Int
    public var currentSlice: Int
    public var currentPhase: Int
    public var studyInstanceUID: String?
    public var seriesInstanceUID: String?
    public var seriesDescription: String?
    public var modality: String?

    @_spi(IsiXHost)
    public init(sliceCount: Int, phaseCount: Int, currentSlice: Int, currentPhase: Int, studyInstanceUID: String?,
                seriesInstanceUID: String?, seriesDescription: String?, modality: String?) {
        self.sliceCount = sliceCount
        self.phaseCount = phaseCount
        self.currentSlice = currentSlice
        self.currentPhase = currentPhase
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.seriesDescription = seriesDescription
        self.modality = modality
    }
}

/// One image of a series a plugin computed from a viewer's images: Float32
/// samples placed where the source image is. The new image takes the source
/// image's size, geometry, patient and study; `pixels` must have the source
/// image's width and height and one channel.
public struct IsiXDerivedImage: Sendable, Equatable {
    public var sourceSlice: Int
    public var sourcePhase: Int
    public var pixels: IsiXPixelBuffer<Float>

    public init(sourceSlice: Int, sourcePhase: Int = 0, pixels: IsiXPixelBuffer<Float>) {
        self.sourceSlice = sourceSlice
        self.sourcePhase = sourcePhase
        self.pixels = pixels
    }
}

/// A series a plugin computed, to show in a new viewer with
/// `IsiXViewer.openDerivedSeries(_:)`. Nothing is written to disk or to the
/// database: the series lives in the new viewer's memory.
public struct IsiXDerivedSeries: Sendable, Equatable {
    /// In display order; at least one.
    public var images: [IsiXDerivedImage]
    /// The window level to show; the application chooses one from the pixels when nil.
    public var windowLevel: IsiXWindowLevel?

    public init(images: [IsiXDerivedImage], windowLevel: IsiXWindowLevel? = nil) {
        self.images = images
        self.windowLevel = windowLevel
    }
}
