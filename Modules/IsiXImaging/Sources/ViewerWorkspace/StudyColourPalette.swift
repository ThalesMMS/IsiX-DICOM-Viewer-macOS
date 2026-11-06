//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

/// One colour of a study: device RGB components, opaque.
public struct StudyColour: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The components as single-precision literals give them (0.4f is not 0.4): the
    /// former table wrote every component so, except one blue.
    static func singlePrecision(_ red: Float, _ green: Float, _ blue: Float) -> StudyColour {
        StudyColour(red: Double(red), green: Double(green), blue: Double(blue))
    }
}

/// The colours that tell the studies of the displayed viewers apart, in the
/// order they are given out: the frame of each image and the box of the study
/// in the series list take the colour of their study's rank.
public struct StudyColourPalette: Sendable {
    /// The colours, in their order.
    public let colours: [StudyColour]

    public init(colours: [StudyColour]) {
        self.colours = colours
    }

    /// The twelve colours of the 2D viewers. Every component is a
    /// single-precision value except the blue of the last colour, a
    /// double-precision 0.6, as the table always had them.
    public static let viewers = StudyColourPalette(colours: [
        .singlePrecision(0.4, 0.4, 0.0), .singlePrecision(0.4, 0.0, 0.4), .singlePrecision(0.0, 0.4, 0.4),
        .singlePrecision(0.4, 0.0, 0.0), .singlePrecision(0.0, 0.4, 0.0), .singlePrecision(0.0, 0.0, 0.4),
        .singlePrecision(0.3, 0.5, 0.0), .singlePrecision(0.3, 0.0, 0.6), .singlePrecision(0.0, 0.5, 0.6),
        .singlePrecision(0.3, 0.0, 0.0), .singlePrecision(0.0, 0.5, 0.0),
        StudyColour(red: Double(Float(0.0)), green: Double(Float(0.0)), blue: 0.6),
    ])
}
