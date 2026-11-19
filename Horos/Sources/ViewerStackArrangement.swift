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

/// The arrangement of a 2D viewer's slices along their normal, from every
/// slice, once -computeIntervalFlipNow: has settled the stack's direction.
///
/// A 3D reconstruction builds its volume from the first slice up, at one
/// interval. A stack still out of order along its normal is sorted when the
/// viewer flips now - a CT sorted by acquisition date whose first slices share
/// the time of one rotation, two acquisitions numbered alike - and a stack in
/// order whose slices are not evenly spaced gets the mean interval, from its
/// first slice to its last, where the step from slice 1 to 2 measured one gap.
/// The order is IsiXImaging's SliceStackOrder; here the viewer's slices, files
/// and ROIs are moved.
@MainActor struct ViewerStackArrangement {

    unowned let viewer: ViewerController

    /// The order of `slices` along their normal.
    func order(of slices: [DCMPix]) -> SliceStackOrder {
        SliceStackOrder(origins: slices.map(Self.origin), orientations: slices.map(Self.orientation))
    }

    /// Gives every slice of every movie frame `interval`.
    func setSliceInterval(_ interval: Double) {
        for x in 0..<viewer.horos_movieCount {
            for pix in viewer.horos_pixArray(x) { pix.sliceInterval = interval }
        }
    }

    /// Sorts a stack out of order when `flipNow`, or gives a stack in order
    /// that is irregularly spaced its mean interval.
    func arrange(flipNow: Bool) {
        let current = Int(viewer.horos_curMovieIndex)
        if flipNow, case .unordered = order(of: viewer.horos_pixArray(current)).arrangement {
            sortAlongNormal()
            setSliceInterval(order(of: viewer.horos_pixArray(current)).meanInterval3D)
            NSLog("---- slices sorted along their normal for a 3D reconstruction")
            return
        }
        let slices = viewer.horos_pixArray(current)
        let stack = order(of: slices)
        guard stack.isMonotonic, let first = slices.first else { return }
        let regularity = SliceSpacingRegularity(origins: slices.flatMap(Self.origin), normal: Array(Self.orientation(first)[6...8]),
                                                pixelSpacing: min(first.pixelSpacingX, first.pixelSpacingY))
        if regularity.isIrregular {
            setSliceInterval(stack.arrangement == .descending ? -stack.meanInterval3D : stack.meanInterval3D)
        }
    }

    /// Sorts each movie frame whose slices are out of order along their
    /// normal, by its own positions: its volume buffer, slices, files, ROIs
    /// and ROIs as read move together, as -reverseSeries: moves them. The
    /// image on screen stays on screen.
    private func sortAlongNormal() {
        let current = Int(viewer.horos_curMovieIndex)
        let shown = Int(viewer.horos_imageView?.curImage ?? 0)
        var places: [Int]?
        for x in 0..<viewer.horos_movieCount {
            let slices = viewer.horos_pixArray(x)
            guard case .unordered(let sorting) = order(of: slices).arrangement, let pixList = viewer.horos_pixList(at: x),
                  let first = slices.first, let volume = first.fImage,
                  slices.allSatisfy({ $0.pheight == first.pheight && $0.pwidth == first.pwidth }) else { continue }
            let count = sorting.count, sliceFloats = first.pwidth * first.pheight
            SliceStack.reorderSlices(volume, order: sorting, sliceFloatCount: sliceFloats)
            for (place, slice) in sorting.enumerated() { slices[slice].fImage = volume + place * sliceFloats }
            for list in [pixList, viewer.horos_fileList(at: x), viewer.horos_roiList(at: x), viewer.horos_copyRoiList(at: x)] {
                guard let list, list.count == count else { continue }
                list.setArray(sorting.map { list.object(at: $0) })
            }
            for i in 0..<count {
                guard let pix = pixList.object(at: i) as? DCMPix else { continue }
                viewerSetArrayPix(pix, pixList, Int(truncatingIfNeeded: i))
                pix.id = i
            }
            if x == current { places = SliceStackOrder.inverse(of: sorting) }
        }

        guard let places else { return }
        if places.indices.contains(viewer.horos_subCtrlMaskID) { viewer.horos_subCtrlMaskID = places[viewer.horos_subCtrlMaskID] }
        if places.indices.contains(shown) {
            viewer.horos_imageView?.setIndex(Int(truncatingIfNeeded: places[shown]))
            viewer.adjustSlider()
        }
    }

    private static func origin(_ pix: DCMPix) -> [Double] {
        [pix.originX, pix.originY, pix.originZ]
    }

    private static func orientation(_ pix: DCMPix) -> [Double] {
        var vectors = [Double](repeating: 0, count: 9)
        pix.orientationDouble(&vectors)
        return vectors
    }
}
