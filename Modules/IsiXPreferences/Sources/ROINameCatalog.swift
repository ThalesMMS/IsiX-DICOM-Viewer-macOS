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

/// The preferences of the ROIs a 2D viewer keeps and names: whether they are
/// saved with the series, whether erasing their content asks first, and the
/// names its ROI menus offer.
public enum ROINameCatalog {
    /// The ROIs of a series are saved with it and read back when it opens.
    public static let savesROIs = ViewerPreferences.savesROIs

    /// Erase Content does not ask before it rewrites the pixels of the series
    /// (its warning's "Do not ask again"). Absent, it asks.
    public static let skipsEraseContentWarning = PreferenceKey<Bool>("ROIVolumeEraseContentSkipWarning")

    /// What separates the default names from those found in the series.
    public static let separator = "-"

    /// The names a viewer offers: `defaults`, then, when its ROIs have other
    /// names, the separator and those names, each once, in the order they
    /// come. A ROI without a name has nothing to offer.
    public static func names(defaults: [String], found: some Sequence<String?>) -> [String] {
        var names = defaults
        var known = Set(defaults)
        var first = true
        for case let name? in found where !known.contains(name) {
            if first { names.append(separator) }
            first = false
            names.append(name)
            known.insert(name)
            known.insert(separator)
        }
        return names
    }
}
