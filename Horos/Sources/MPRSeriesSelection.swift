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

/// Which series the Series Selection item of the 3D MPR offers.
///
/// The 2D viewer decides whether a series can open in the MPR only once its
/// pixels are loaded (`-mprViewer:` asks the geometry decision, the volumic
/// check and the 4D refusal). The menu is built from the database, before any
/// pixel is read, so it applies the parts of those rules that the database
/// already knows and leaves out the series they refuse:
///
/// - a single image of one frame: the 2D disables its reconstruction item;
/// - slices of different matrix sizes: the geometry decision refuses them;
/// - every slice at the same location (a time series at one position, a
///   repeated scout): the 2D viewer does not take it for volumic data.
///
/// A series the database cannot judge (sizes or locations not stored) stays in
/// the menu, and opening it still goes through the full check of the 2D viewer.
enum MPRSeriesSelection {
    struct Slice {
        var width: Int?
        var height: Int?
        var sliceLocation: Double?
    }

    static func accepts(_ slices: [Slice]) -> Bool {
        guard slices.count >= 2 else { return false }

        let widths = Set(slices.compactMap(\.width))
        let heights = Set(slices.compactMap(\.height))
        if widths.count > 1 || heights.count > 1 { return false }

        let locations = slices.compactMap(\.sliceLocation)
        if locations.count == slices.count, let first = locations.first,
           locations.allSatisfy({ abs($0 - first) < 0.001 }) {
            return false
        }
        return true
    }
}
