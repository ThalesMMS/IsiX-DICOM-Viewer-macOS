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

/// Where the annotations of an image view read what their fields show. The
/// view answers each question only when a field shown at the current level
/// asks it, once per field, so a value that costs something to read (the SUV,
/// a volume check of the series) is read only when it is shown.
public protocol AnnotationValueSource {
    /// Whether the view's annotation level shows the element of `token`.
    func shows(_ token: String) -> Bool
    /// Whether the view's own annotation level shows the patient's name.
    func showsPatientName() -> Bool
    /// The pixels of the image, across and down.
    func imageSize() -> (width: Int, height: Int)
    /// The value under the mouse; nil for a view that does not show it (an
    /// exported view, or another view with a name).
    func pixelProbe() -> AnnotationPixelProbe?
    /// The zoom shown, 1 for 100 %.
    func zoom() -> Float
    /// The rotation shown, in degrees.
    func rotation() -> Float
    /// The image's place in the series.
    func imagePosition() -> AnnotationImagePosition
    /// The patient position of the mouse; nil for a view with a name.
    func millimetrePosition() -> AnnotationMillimetrePosition?
    /// The window of the image.
    func windowLevel() -> AnnotationWindowLevel
    /// The slice's thickness and location, and the image's positions.
    func slice() -> AnnotationSlice
    /// The thickness and the middle location of the thick slab the image is drawn with.
    func thickSlab() -> (thickness: Float, location: Float)
    /// The name of the patient of the current image; nil when it has none.
    func patientName() -> String?
}

/// The value under the mouse, in the image and in the image fused with it.
public struct AnnotationPixelProbe: Sendable, Equatable {
    /// A pixel's value: grey, or the three components of a colour image.
    public enum Value: Sendable, Equatable {
        case grey(Float)
        case colour(red: Int, green: Int, blue: Int)
    }

    public struct Reading: Sendable, Equatable {
        /// The mouse, in pixels of the image.
        public var x: Float, y: Float
        public var value: Value
        /// Whether the image's values are SUV already.
        public var suvConverted: Bool
        /// The SUV shown on a line of its own: nil when the image does not show
        /// it, has none, or its values are SUV already.
        public var suv: Float?

        public init(x: Float, y: Float, value: Value, suvConverted: Bool, suv: Float?) {
            self.x = x
            self.y = y
            self.value = value
            self.suvConverted = suvConverted
            self.suv = suv
        }
    }

    public var image: Reading
    /// The image fused with it, when there is one.
    public var fused: Reading?

    public init(image: Reading, fused: Reading?) {
        self.image = image
        self.fused = fused
    }
}

/// The image's place in the series.
public struct AnnotationImagePosition: Sendable, Equatable {
    /// The index of the image, from 0.
    public var current: Int
    public var count: Int
    /// The images of the thick slab, 1 without one.
    public var stack: Int
    /// Whether the series is shown in reverse order.
    public var flipped: Bool
    /// The step between the second and the third image's origins, given only
    /// when the series is one volume of more than two images: its direction
    /// names the way the images go.
    public var step: (x: Double, y: Double, z: Double)?

    public init(current: Int, count: Int, stack: Int, flipped: Bool, step: (x: Double, y: Double, z: Double)?) {
        self.current = current
        self.count = count
        self.stack = stack
        self.flipped = flipped
        self.step = step
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.current == b.current && a.count == b.count && a.stack == b.stack && a.flipped == b.flipped
            && a.step?.x == b.step?.x && a.step?.y == b.step?.y && a.step?.z == b.step?.z
    }
}

/// The patient position of the mouse.
public struct AnnotationMillimetrePosition: Sendable, Equatable {
    public var x: Float, y: Float, z: Float
    /// Whether the image is a plane in space, shown with z.
    public var isPlane: Bool
    /// The image's pixel spacing across: below 0.2 mm a position under 1 mm is shown in micrometres.
    public var pixelSpacingX: Double

    public init(x: Float, y: Float, z: Float, isPlane: Bool, pixelSpacingX: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.isPlane = isPlane
        self.pixelSpacingX = pixelSpacingX
    }
}

/// The window of the image.
public struct AnnotationWindowLevel: Sendable, Equatable {
    public var level: Float, width: Float
    /// Whether the image is windowed as PET: its window is also shown in
    /// percent of the series' maximum.
    public var windowsAsPET: Bool
    public var maximumOfSeries: Float

    public init(level: Float, width: Float, windowsAsPET: Bool, maximumOfSeries: Float) {
        self.level = level
        self.width = width
        self.windowsAsPET = windowsAsPET
        self.maximumOfSeries = maximumOfSeries
    }
}

/// The slice's thickness and location, and the image's positions.
public struct AnnotationSlice: Sendable, Equatable {
    public var thickness: Double, location: Double
    /// The images of the thick slab, 1 without one.
    public var stack: Int
    /// View Position (0018,5101) and Patient Position (0018,5100), when the image has them.
    public var viewPosition: String?, patientPosition: String?

    public init(thickness: Double, location: Double, stack: Int, viewPosition: String?, patientPosition: String?) {
        self.thickness = thickness
        self.location = location
        self.stack = stack
        self.viewPosition = viewPosition
        self.patientPosition = patientPosition
    }
}

/// The texts of the annotations in the viewer's language: formats whose
/// arguments the fields give. `english` is the catalogue's own keys.
public struct AnnotationPhrases: Sendable, Equatable {
    public var imageSize = "Image size: %ld x %ld"
    public var viewSize = "View size: %ld x %ld"
    public var mouseColour = "X: %d px Y: %d px Value: R:%ld G:%ld B:%ld"
    public var mouseGrey = "X: %d px Y: %d px Value: %2.2f %@"
    public var fusedColour = "Fused Image : X: %d px Y: %d px Value: R:%ld G:%ld B:%ld"
    public var fusedGrey = "Fused Image : X: %d px Y: %d px Value: %2.2f %@"
    public var suv = "SUV: %.2f"
    public var fusedSUV = "SUV (fused image): %.2f"
    public var zoom = "Zoom: %0.0f%%"
    public var angle = " Angle: %0.0f"
    public var imageRange = "Im: %ld-%ld/%ld %@"
    public var image = "Im: %ld/%ld %@"
    public var windowLevelDecimals = "WL: %0.4f WW: %0.4f"
    public var windowLevel = "WL: %d WW: %d"
    public var windowPercent = "From: %d %% (%0.2f) to: %d %% (%0.2f)"
    public var thicknessMicronsLocationMicrons = "Thickness: %0.2f %cm Location: %0.2f %cm"
    public var thicknessMicrons = "Thickness: %0.2f %cm Location: %0.2f mm"
    public var thickness = "Thickness: %0.2f mm Location: %0.2f mm"
    public var position = "Position: %@ "
    public var letters = OrientationLetters.english

    public init() {}

    public static let english = AnnotationPhrases()
}
