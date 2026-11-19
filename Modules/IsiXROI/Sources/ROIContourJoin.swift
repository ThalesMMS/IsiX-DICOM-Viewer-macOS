//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

/// Which ROI of another image a finished contour takes its name from.
///
/// Volume, renaming and propagation group a series' ROIs by name, so a
/// lesion outlined slice by slice, or every few slices for the missing ROIs
/// to be generated in between, is one object when its contours share a name.
/// The images are walked one distance at a time, nearest first: the nearest
/// distance with a ROI the contour covers decides, and the ROIs further away
/// are not measured.
public enum ROIContourJoin {
    /// The name the contour takes, or nil when it keeps its own: no image has
    /// a ROI it covers, or the one chosen already has its name.
    ///
    /// - Parameters:
    ///   - current: the contour's own name.
    ///   - neighbours: the other images, nearest first, as
    ///     `ROIEditingSession.joinedImages` gives them.
    ///   - candidates: the named ROIs of an image the contour may join, each
    ///     with its contour; none for an image that is not compared.
    ///   - chosen: the index of the candidate the contour covers best among
    ///     those of one distance, given with that distance, or a negative
    ///     number when it covers none.
    public static func name<Contour>(current: String?, neighbours: [ROIEditingSession.JoinedImage],
                                     candidates: (_ image: Int) -> [(name: String, contour: Contour)],
                                     chosen: (_ contours: [Contour], _ distances: [Int]) -> Int) -> String? {
        var next = 0
        while next < neighbours.count {
            let distance = neighbours[next].distance
            var found: [(name: String, contour: Contour)] = []
            while next < neighbours.count, neighbours[next].distance == distance {
                found += candidates(neighbours[next].image)
                next += 1
            }

            let index = chosen(found.map(\.contour), [Int](repeating: distance, count: found.count))
            if index < 0 {
                continue
            }
            return ROIEditingSession.joinedName(candidate: index, names: found.map(\.name), current: current)
        }
        return nil
    }
}
