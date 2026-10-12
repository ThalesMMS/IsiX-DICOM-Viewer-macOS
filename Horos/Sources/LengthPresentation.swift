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

import Foundation

/// The unit a measured length is shown in.
@objc(HorosLengthUnit)
public enum LengthUnit: Int {
    /// By size: µm below 0.01 cm, mm below 1 cm, cm from 1 cm.
    case automatic = 0
    case millimetres = 1
    case centimetres = 2
}

/// How every length measurement is written on screen: the 2D Length, polygon
/// and curve lengths, the Length between images, the Volume Rendering Length.
/// Two preferences choose the unit and the number of decimal places. They
/// change only what is shown: exported values keep their own units.
@objc(HorosLengthPresentation)
public final class LengthPresentation: NSObject {
    @objc public static let unitKey = "ROILengthUnit"
    @objc public static let decimalsKey = "ROILengthDecimals"
    @objc public static let defaultDecimals = 3
    @objc public static let maximumDecimals = 3
    /// Posted when either preference changes, for views that keep a copy of
    /// the text instead of writing it at each drawing.
    @objc public static let changedNotification = "HorosLengthPresentationDidChange"

    /// The text of a length given in millimetres. `micrometres` lets the
    /// automatic unit go below a millimetre's tenth; a renderer that draws
    /// only ASCII passes false and gets millimetres instead.
    public static func format(millimetres: Double, unit: LengthUnit, decimals: Int,
                              micrometres: Bool = true) -> String {
        let places = min(max(decimals, 0), maximumDecimals)
        switch unit {
        case .millimetres:
            return number(millimetres, places) + " mm"
        case .centimetres:
            return number(millimetres / 10, places) + " cm"
        case .automatic:
            let centimetres = abs(millimetres) / 10
            // A micrometre count has at most one decimal, as it always had:
            // three would claim nanometres.
            if micrometres && centimetres < 0.01 {
                return number(millimetres * 1000, min(places, 1)) + " \u{00B5}m"
            }
            if centimetres < 1 {
                return number(millimetres, places) + " mm"
            }
            return number(millimetres / 10, places) + " cm"
        }
    }

    /// A length measured on an image without a pixel spacing.
    public static func format(pixels: Double, decimals: Int) -> String {
        number(pixels, min(max(decimals, 0), maximumDecimals)) + " pix"
    }

    private static func number(_ value: Double, _ places: Int) -> String {
        String(format: "%.*f", places, value)
    }

    // MARK: - With the preferences

    @objc public static var unit: LengthUnit {
        LengthUnit(rawValue: UserDefaults.standard.integer(forKey: unitKey)) ?? .automatic
    }

    /// An absent key is the default, not zero places.
    @objc public static var decimals: Int {
        guard let value = UserDefaults.standard.object(forKey: decimalsKey) as? NSNumber else { return defaultDecimals }
        return min(max(value.intValue, 0), maximumDecimals)
    }

    @objc(stringWithMillimetres:)
    public static func string(millimetres: Double) -> String {
        format(millimetres: millimetres, unit: unit, decimals: decimals)
    }

    @objc(stringWithCentimetres:)
    public static func string(centimetres: Double) -> String {
        format(millimetres: centimetres * 10, unit: unit, decimals: decimals)
    }

    @objc(asciiStringWithCentimetres:)
    public static func asciiString(centimetres: Double) -> String {
        format(millimetres: centimetres * 10, unit: unit, decimals: decimals, micrometres: false)
    }

    @objc(stringWithPixels:)
    public static func string(pixels: Double) -> String {
        format(pixels: pixels, decimals: decimals)
    }
}
