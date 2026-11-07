//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The ROIs of a series copied for another viewer, one list per image. A ROI
// shown on every image of the series is one object in every list (an alias),
// and the archive stores it once, with the image it was made on: copying it
// once per list would turn one ROI into as many ROIs as images. So each object
// is copied once, and its copy goes wherever the object was.

/// A copy of the ROI lists of a series, one list per image.
public enum ROISliceListCopy {

    /// The lists of `slices` with each object replaced by its copy, in the same
    /// order. An object found in several places is copied once and its copy is
    /// put in each of them; one that `make` gives no copy of is left out
    /// everywhere it was.
    public static func copy<Item: AnyObject>(_ slices: [[Item]], making make: (Item) -> Item?) -> [[Item]] {
        var copies: [ObjectIdentifier: Item?] = [:]
        return slices.map { slice in
            slice.compactMap { item -> Item? in
                let key = ObjectIdentifier(item)
                if let made = copies[key] { return made }
                let made = make(item)
                copies[key] = made
                return made
            }
        }
    }
}
