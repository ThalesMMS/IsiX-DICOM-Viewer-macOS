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

/// What generating the missing ROIs of one name came to: ROIs are morphed
/// into the images between two images that hold a ROI of that name, so the
/// command has nothing to do when one image alone holds one or when no image
/// between the first and the last is without. The viewer tells these apart
/// from a failure of the morphing itself.
public enum ROIMissingGeneration: Sendable, Equatable {
    /// ROIs were generated.
    case generated
    /// One image alone holds a ROI of the name: there is no second ROI to
    /// morph towards. ROIs of the same object under another name are the
    /// usual reason.
    case singleImage
    /// Every image between the first and the last with a ROI of the name
    /// holds one already.
    case nothingMissing
    /// Nothing could be generated: no ROI of the name outlines an area, or
    /// the contours could not be morphed.
    case notGenerated

    /// The outcome for a name whose ROIs that outline an area, the generated
    /// ones left out, lie on `sourceImages` (in any order, an image once per
    /// ROI), after a generation that left `generatedCount` ROIs.
    public static func outcome(sourceImages: [Int], generatedCount: Int) -> Self {
        if generatedCount > 0 { return .generated }
        let images = Set(sourceImages).sorted()
        switch images.count {
        case 0: return .notGenerated
        case 1: return .singleImage
        default: return zip(images, images.dropFirst()).contains { $0 + 1 < $1 } ? .notGenerated : .nothingMissing
        }
    }
}
