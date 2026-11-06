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

// The colours every 2D view gives a fused PET series in the "B/W Inverse" PET
// CLUT mode, where the PET viewer itself shows inverted grey levels: the stored
// colour table the "PET Blending CLUT" preference names. The app keeps one set
// of three tables of 256 entries for all the views (+PETredTable and the others
// hand their addresses to plugins) and fills it from this value.

/// The PET blending table of the fused series.
public struct PETBlendingTable: Sendable, Equatable {
    /// The PET CLUT mode ("PET Clut Mode") in which a fused series is drawn
    /// with this table rather than with its own.
    public static let fusedSeriesMode = "B/W Inverse"

    public let colours: ColorLookupTable

    public init(colours: ColorLookupTable) {
        self.colours = colours
    }

    /// The table of a stored colour table preset (the dictionary of "Red",
    /// "Green" and "Blue" the "CLUT" preference holds by name), read as
    /// ColorLookupTable reads a preset; the grey levels without a preset, or
    /// when one of its channels is missing, is shorter than 256 or holds
    /// something that is not a number.
    public init(preset: [String: Any]?) {
        self.colours = preset.flatMap { ColorLookupTable(preset: $0 as NSDictionary) } ?? .greyLevels
    }

    /// Whether a fused series is drawn with the PET blending table in the PET
    /// CLUT mode `mode`.
    public static func drawsFusedSeries(inPETCLUTMode mode: String?) -> Bool {
        mode == fusedSeriesMode
    }
}
