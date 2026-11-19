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
import Synchronization

/// How a slab's thickness is written and read, in millimetres: one text for
/// the slider's bubble, the thickness field and the annotation of a
/// reconstruction window, so the three never say different numbers for one
/// slab.
///
/// A thickness below 10 mm has up to two decimals and one from 10 mm has up
/// to one, a half going to the even digit, with the decimal separator the
/// user set for numbers in the system and no grouping: 0.625 mm reads «0.62»,
/// 12.375 mm «12.4» and 359 mm «359».
public enum SlabThicknessText {
    /// The number alone, as the thickness field shows it.
    public static func number(_ millimetres: Double, locale: Locale = .autoupdatingCurrent) -> String {
        guard millimetres.isFinite else { return "" }
        return write(millimetres, minimumDecimals: 0, maximumDecimals: abs(millimetres) < 10 ? 2 : 1, locale: locale)
    }

    /// The number and its unit, as the bubble and the annotation show it.
    public static func text(_ millimetres: Double, locale: Locale = .autoupdatingCurrent) -> String {
        guard millimetres.isFinite else { return "" }
        return number(millimetres, locale: locale) + " mm"
    }

    /// The thickness a text says: a number with a comma or a point for its
    /// decimals, whichever the language, no grouping, and «mm» after it or
    /// not. Nil for anything else.
    public static func value(of text: String) -> Double? {
        var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.lowercased().hasSuffix("mm") {
            digits = String(digits.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        digits = digits.replacingOccurrences(of: ",", with: ".")
        var seen = (digit: false, point: false)
        for (index, character) in digits.enumerated() {
            switch character {
            case "0"..."9": seen.digit = true
            case "." where !seen.point: seen.point = true
            case "+" where index == 0, "-" where index == 0: break
            default: return nil
            }
        }
        guard seen.digit, let value = Double(digits), value.isFinite else { return nil }
        return value
    }

    /// The thickness a window takes for one typed in its field, between its
    /// thin end and its thick one: the end itself when the value reads as the
    /// end does (0.62 typed where the thin end is 0.625 mm), else the number
    /// the field will show, so the slab is the thickness written.
    public static func fieldThickness(entered: Double, thinEnd: Double, maximum: Double, locale: Locale = .autoupdatingCurrent) -> Double {
        let top = max(thinEnd, maximum)
        guard entered.isFinite else { return thinEnd }
        let within = min(max(entered, thinEnd), top)
        let shown = number(within, locale: locale)
        if shown == number(thinEnd, locale: locale) { return thinEnd }
        if shown == number(top, locale: locale) { return top }
        return min(max(value(of: shown) ?? within, thinEnd), top)
    }

    /// The formatters of the numbers written, by locale and decimals: a text
    /// is asked at every change of image and every step of a drag, and making
    /// a formatter costs more than the rest.
    private static let formatters = Mutex<[String: NumberFormatter]>([:])

    /// A number with the decimal separator the user set for numbers in the
    /// system, which a format style does not read: it wrote a point for a
    /// region whose separator the user had changed to a comma.
    static func write(_ number: Double, minimumDecimals: Int, maximumDecimals: Int, locale: Locale) -> String {
        formatters.withLock { kept in
            // The locale that follows the user's settings is told from one of the same name: only it reads them.
            let key = "\(locale == .autoupdatingCurrent ? "*" : locale.identifier)/\(minimumDecimals)/\(maximumDecimals)"
            let formatter = kept[key] ?? {
                let made = NumberFormatter()
                made.locale = locale
                made.numberStyle = .decimal
                made.usesGroupingSeparator = false
                made.roundingMode = .halfEven
                made.minimumFractionDigits = minimumDecimals
                made.maximumFractionDigits = maximumDecimals
                kept[key] = made
                return made
            }()
            return formatter.string(from: number as NSNumber) ?? ""
        }
    }
}
