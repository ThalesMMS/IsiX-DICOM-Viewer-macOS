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

/// Names identify objects across a series, so independent contours need a free
/// name even when the user supplied the base in ROI Defaults.
@objc(HorosROIName)
public final class ROIName: NSObject {
    @objc(availableNameFrom:existingNames:)
    public static func availableName(from base: String, existingNames: [String]) -> String {
        let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        // An explicitly empty default still requests an unnamed ROI.
        guard !base.isEmpty else { return "" }

        let suffix = base.utf8.reversed().prefix { $0 >= 48 && $0 <= 57 }.reversed()
        var digits = Array(suffix)
        let prefix: String
        if digits.isEmpty {
            prefix = base + " "
            digits = [49]
        } else {
            prefix = String(base.dropLast(digits.count))
        }

        // NSString equality matches the viewer's existing name comparisons.
        let used = NSSet(array: existingNames)
        var candidate = prefix + String(decoding: digits, as: UTF8.self)
        while used.contains(candidate) {
            // Increment decimal text directly: user-entered suffixes can exceed
            // a machine integer, and leading zeroes need not be discarded.
            var index = digits.count
            while index > 0 && digits[index - 1] == 57 {
                index -= 1
                digits[index] = 48
            }
            if index == 0 {
                digits.insert(49, at: 0)
            } else {
                digits[index - 1] += 1
            }
            candidate = prefix + String(decoding: digits, as: UTF8.self)
        }
        return candidate
    }
}
