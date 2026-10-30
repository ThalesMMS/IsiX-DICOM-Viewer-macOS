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

/// Identifies one ROI for as long as it exists in its viewer.
public struct IsiXROIID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    @_spi(IsiXHost)
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

public enum IsiXROIKind: Hashable, Sendable {
    case point
    /// A straight measurement between two points.
    case line
    case rectangle
    case oval
    /// A closed polygon.
    case polygon
    /// An open polygon.
    case polyline
    case angle
    case text
    /// A painted mask. A plugin creates one from an `IsiXROIMask`
    /// (`IsiXROIDraft(mask:)`); its mask is not read back.
    case brush
    case other
}

/// A ROI, copied when it was read.
public struct IsiXROI: Hashable, Sendable {
    public var id: IsiXROIID
    public var kind: IsiXROIKind
    public var name: String
    public var comment: String
    public var slice: Int
    public var phase: Int
    /// The ROI's points in pixel units of its image. A rectangle and an oval
    /// have two: opposite corners of their bounding box.
    public var points: [IsiXPixelPoint]
    /// The same points in the patient coordinate system, in millimetres.
    public var patientPoints: [IsiXVector3]
    /// Whether the ROI is selected in its viewer.
    public var isSelected: Bool
    /// Whether the viewer shows the ROI's text box, with its name and measurements.
    public var showsTextBox: Bool

    @_spi(IsiXHost)
    public init(id: IsiXROIID, kind: IsiXROIKind, name: String, comment: String, slice: Int, phase: Int,
                points: [IsiXPixelPoint], patientPoints: [IsiXVector3], isSelected: Bool = false, showsTextBox: Bool = true) {
        self.id = id
        self.kind = kind
        self.name = name
        self.comment = comment
        self.slice = slice
        self.phase = phase
        self.points = points
        self.patientPoints = patientPoints
        self.isSelected = isSelected
        self.showsTextBox = showsTextBox
    }
}

/// Changes to an existing ROI, for `IsiXViewer.updateROI(_:_:)`. A property
/// left nil keeps its value.
public struct IsiXROIUpdate: Hashable, Sendable {
    /// The new points, in pixel units, as many as the ROI's kind takes (see
    /// `IsiXROIDraft`). A rectangle or an oval given `.polygon` as `kind`
    /// becomes the closed polygon of these points, as when the application
    /// rotates one; no other change of kind is accepted.
    public var points: [IsiXPixelPoint]?
    public var kind: IsiXROIKind?
    public var name: String?
    public var comment: String?
    /// Selects or deselects the ROI; other ROIs keep their selection.
    public var isSelected: Bool?
    public var showsTextBox: Bool?

    public init(points: [IsiXPixelPoint]? = nil, kind: IsiXROIKind? = nil, name: String? = nil, comment: String? = nil,
                isSelected: Bool? = nil, showsTextBox: Bool? = nil) {
        self.points = points
        self.kind = kind
        self.name = name
        self.comment = comment
        self.isSelected = isSelected
        self.showsTextBox = showsTextBox
    }
}

/// The pixels of a brush ROI: `width` x `height` values by rows, non-zero
/// inside, whose first value is the pixel at `column`, `row` of the image.
public struct IsiXROIMask: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let column: Int
    public let row: Int
    public let values: [UInt8]

    /// Throws `IsiXPluginError.invalidROI` when the sizes do not match the values.
    public init(width: Int, height: Int, column: Int = 0, row: Int = 0, values: [UInt8]) throws {
        guard width > 0, height > 0, values.count == width * height else {
            throw IsiXPluginError.invalidROI("A mask of \(width) x \(height) needs \(max(width, 0) * max(height, 0)) values, not \(values.count).")
        }
        self.width = width
        self.height = height
        self.column = column
        self.row = row
        self.values = values
    }

    /// The number of pixels inside.
    public var count: Int { values.reduce(0) { $0 + ($1 != 0 ? 1 : 0) } }
}

/// A ROI to create. Points are in pixel units; a rectangle and an oval take
/// two opposite corners of their bounding box, a point one, a line two, and a
/// polygon or polyline at least two. A brush ROI takes a mask and no points.
public struct IsiXROIDraft: Hashable, Sendable {
    public var kind: IsiXROIKind
    public var points: [IsiXPixelPoint]
    public var name: String?
    /// The slice to put the ROI on; the viewer's current slice when nil.
    public var slice: Int?
    /// The phase of a 4D series; the viewer's current phase when nil.
    public var phase: Int?
    /// The pixels of a brush ROI; nil for the other kinds.
    public var mask: IsiXROIMask?

    public init(kind: IsiXROIKind, points: [IsiXPixelPoint], name: String? = nil, slice: Int? = nil, phase: Int? = nil) {
        self.kind = kind
        self.points = points
        self.name = name
        self.slice = slice
        self.phase = phase
    }

    /// A brush ROI of the pixels of `mask` that are inside the image.
    public init(mask: IsiXROIMask, name: String? = nil, slice: Int? = nil, phase: Int? = nil) {
        self.init(kind: .brush, points: [], name: name, slice: slice, phase: phase)
        self.mask = mask
    }
}

/// Measurements of a ROI on the pixels of its image, computed by the host.
public struct IsiXROIStatistics: Hashable, Sendable {
    public var mean: Double
    public var standardDeviation: Double
    public var minimum: Double
    public var maximum: Double
    public var sum: Double
    /// The enclosed area in square millimetres, for closed shapes.
    public var area: Double?
    /// The length in millimetres, for lines and polylines.
    public var length: Double?

    @_spi(IsiXHost)
    public init(mean: Double, standardDeviation: Double, minimum: Double, maximum: Double, sum: Double,
                area: Double?, length: Double?) {
        self.mean = mean
        self.standardDeviation = standardDeviation
        self.minimum = minimum
        self.maximum = maximum
        self.sum = sum
        self.area = area
        self.length = length
    }
}
