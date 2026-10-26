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

/// The list identifies a displayed series by a shared colour, number, or both.
@objc(HorosSeriesListIdentification)
public final class SeriesListIdentification: NSObject {
    @objc public static let defaultsKey = "SeriesListIdentificationMode"

    public static func mode(in defaults: UserDefaults) -> Int {
        let value = defaults.integer(forKey: defaultsKey)
        return (0...2).contains(value) ? value : 0
    }

    @objc(showsColorsIn:)
    public static func showsColors(in defaults: UserDefaults) -> Bool {
        mode(in: defaults) != 1
    }

    @objc(showsNumbersIn:)
    public static func showsNumbers(in defaults: UserDefaults) -> Bool {
        mode(in: defaults) != 0
    }

    @objc(windowLabelForNumber:)
    public static func windowLabel(number: Int) -> String {
        String(number)
    }

    /// Opaque contrasting colours stay readable over any image and appearance.
    public static var badgeBackgroundColor: NSColor { .black }
    public static var badgeTextColor: NSColor { .white }
}
