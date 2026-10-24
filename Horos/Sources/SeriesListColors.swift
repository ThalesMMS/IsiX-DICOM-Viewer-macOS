//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// The backgrounds of the viewer's series list cells: a series shown in this
/// viewer, one fused with it, and a series of another study.
///
/// They were light pastels in either appearance, and the cells' titles take
/// the system's text colour: light text on a light fill in the dark
/// appearance. Each now has a dark shade there, as light as the title allows.
@objc(HorosSeriesListColors)
public final class SeriesListColors: NSObject {
    /// A series shown in this viewer (red).
    @objc public static let shown = dynamic(light: (252 / 255, 177 / 255, 141 / 255), dark: (0.55, 0.18, 0.10))
    /// A series fused with this viewer's (green).
    @objc public static let fused = dynamic(light: (195 / 255, 249 / 255, 145 / 255), dark: (0.16, 0.40, 0.12))
    /// A series of another study (grey).
    @objc public static let otherStudy = dynamic(light: (0.55, 0.55, 0.55), dark: (0.30, 0.30, 0.30))

    static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let shade = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(calibratedRed: shade.0, green: shade.1, blue: shade.2, alpha: 1)
        }
    }
}
