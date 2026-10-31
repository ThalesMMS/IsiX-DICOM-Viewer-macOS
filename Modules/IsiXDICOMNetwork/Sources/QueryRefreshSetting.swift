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

/// The refresh interval of the Query window and of the automatic query, as the
/// preferences keep it: minutes when positive, seconds when negative, none for 0.
///
/// The window only offers a few seconds up to an hour, but the preference is
/// read as any integer: a corrupted or hand-written value can be as large as
/// `Int.max`, which no countdown can show and whose seconds do not fit an
/// `Int`. A value read from the preferences is kept within one day either way.
public enum QueryRefreshSetting {
    /// The longest interval kept, in minutes: one day.
    public static let longestMinutes = 24 * 60
    /// The longest interval kept in seconds, written as a negative setting: one day.
    public static let longestSeconds = 24 * 60 * 60

    /// `stored` within one day either way; 0 stays 0.
    public static func clamped(_ stored: Int) -> Int {
        min(max(stored, -longestSeconds), longestMinutes)
    }

    /// The time left, `seconds`, as the window's counter shows it: minutes and
    /// seconds of at least two digits each. Any count is shown without trapping.
    public static func countdownText(seconds: Int) -> String {
        let minutes = seconds / 60
        let rest = seconds % 60
        return String(format: "%2.2ld:%2.2ld", minutes, rest)
    }
}
