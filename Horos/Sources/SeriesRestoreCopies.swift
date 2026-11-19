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
import IsiXImaging

/// The slices of a series read again from their files to give pixels back to
/// it (the restoring fill of the scissors and of the ROIs), brought to what
/// was done to the whole series since it was read: a file gives the values
/// and the place of its acquisition, and the series may hold SUV, or the
/// slices of a tilted gantry resampled onto one plane. Pixels copied back as
/// the files have them would be of another unit, or of another place.
@MainActor enum SeriesRestoreCopies {

    /// Converts and corrects `copies`, one per slice of `slices` and in their
    /// order, as the series was; false when a copy has no pixels or cannot
    /// be corrected, and the copies are then of no use.
    static func match(_ copies: [DCMPix], to slices: [DCMPix]) -> Bool {
        guard copies.count == slices.count, let first = slices.first, let last = slices.last else { return false }

        for (copy, slice) in zip(copies, slices) where slice.suvConverted && !copy.suvConverted {
            guard let pixels = copy.fImage else { return false }
            PETSUVConversion.scale(pixels, count: copy.pheight * copy.pwidth, by: slice.factorPET2SUV)
            copy.suvConverted = true
            copy.factorPET2SUV = slice.factorPET2SUV
        }

        // The correction leaves one slice where its file puts it: a series
        // whose first and last slices are both there was not corrected, and
        // its other copies are decoded only when the fill reads them.
        let origin: (DCMPix) -> [Double] = { [$0.originX, $0.originY, $0.originZ] }
        let moved: (DCMPix, DCMPix) -> Bool = { copy, slice in
            zip(origin(copy), origin(slice)).contains { abs($0 - $1) > 0.01 }
        }
        guard slices.count > 1, let firstCopy = copies.first, let lastCopy = copies.last,
              moved(firstCopy, first) || moved(lastCopy, last) else { return true }

        var orientation = [Double](repeating: 0, count: 9)
        first.orientationDouble(&orientation)
        guard let model = GantryTiltCorrection.modelSlice(fileOrigins: copies.map(origin), origins: slices.map(origin),
                                                          orientation: orientation) else { return false }
        return GantryTiltSlices(slices: copies).correct(onto: model, progress: {})
    }
}
