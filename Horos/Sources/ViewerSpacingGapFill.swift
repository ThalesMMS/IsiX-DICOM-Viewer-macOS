//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import Accelerate
import IsiXImaging

/// A series with missing slice positions opened again in a new viewer, with
/// an empty slice at each missing position so that the slices are at one
/// interval, as the 3D viewers and the measurements need. Where the empty
/// slices go is IsiXImaging's SliceGapFill; here the viewer's slices are
/// copied, the empty ones made and the new viewer opened.
///
/// The empty slices invent nothing: each is a copy of the slice before it
/// with its pixels set to one defined value, the lowest value of the movie
/// frame (black in an RGB series), its origin on the line between its two
/// neighbours, and its missingPixelsReason set, which the viewer draws over
/// the image, so an inserted slice is never taken for an acquired one. Like a
/// reslice, the new viewer is postprocessed and its slices point at the files
/// of the originals: the empty slices at the file of the slice before them.
/// Nothing is written, and the series in the database is unchanged.
///
/// It is reached from 2D Viewer > Fill Spacing Gaps, an item of
/// ViewerStudyCommands, and from the Fill Gaps button of the irregular slice
/// interval warning (-displayAWarningIfNonTrueVolumicData).
@MainActor struct ViewerSpacingGapFill {

    unowned let viewer: ViewerController

    /// The irregular slice interval warning's second button.
    static var fillGapsButton: String {
        NSLocalizedString("Fill Gaps", comment: "Button of the irregular slice interval warning")
    }

    /// Fills the gaps when the irregular slice interval warning was answered
    /// with its Fill Gaps button.
    func fill(ifChosen response: Int) {
        if response == HorosAlertPanel.alternateResponse { fill() }
    }

    /// The text drawn over an inserted slice.
    static var emptySliceNotice: String {
        NSLocalizedString("Empty slice inserted to fill a spacing gap", comment: "shown over an empty slice")
    }

    /// The origins of the first movie frame's slices and their normal.
    private func geometry(of pixList: [DCMPix]) -> (origins: [SIMD3<Double>], normal: SIMD3<Double>) {
        var vectors = [Double](repeating: 0, count: 9)
        pixList.first?.orientationDouble(&vectors)
        return (pixList.map { SIMD3($0.originX, $0.originY, $0.originZ) }, SIMD3(vectors[6], vectors[7], vectors[8]))
    }

    /// The irregular slice interval warning's verdict on the first movie
    /// frame: the menu item is enabled only for irregular slices.
    var isIrregular: Bool {
        let pixList = viewer.horos_pixArray(0)
        guard pixList.count >= 3, let first = pixList.first else { return false }
        let (origins, normal) = geometry(of: pixList)
        let flat: [Double] = origins.flatMap { [$0.x, $0.y, $0.z] }
        let regularity = SliceIntervalRegularity.regularity(origins: flat, normal: [normal.x, normal.y, normal.z],
                                                            pixelSpacing: min(first.pixelSpacingX, first.pixelSpacingY))
        return regularity.isIrregular
    }

    func fill() {
        viewer.checkEverythingLoaded()

        let pixList = viewer.horos_pixArray(0)
        let (origins, normal) = geometry(of: pixList)
        let sameSize = pixList.allSatisfy { $0.pwidth == pixList[0].pwidth && $0.pheight == pixList[0].pheight }
        let outcome = sameSize ? SliceGapFill.plan(positions: SliceGapFill.positions(origins: origins, normal: normal)) : .refused(.tooFewSlices)

        switch outcome {
        case .fill(let plan):
            if !open(plan) {
                refuse(NSLocalizedString("Not enough memory", comment: ""))
            }
        case .noGaps:
            refuse(NSLocalizedString("No slice position is missing in this series: its spacing varies without leaving gaps that empty slices could fill.", comment: ""))
        case .refused(.notMultiple(_, let step)):
            refuse(String(format: NSLocalizedString("The gaps between these slices are not whole multiples of their interval (%.3f mm), so empty slices cannot make the spacing regular.", comment: ""), step))
        case .refused:
            refuse(NSLocalizedString("Empty slices can only be inserted in a stack of three or more slices of one size, each at its own position along one direction.", comment: ""))
        }
    }

    private func refuse(_ message: String) {
        HorosAlertPanel.runCritical(title: NSLocalizedString("Fill Spacing Gaps", comment: ""), message: message,
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    /// The new viewer, every movie frame filled by `plan`; false when a volume
    /// could not be allocated. Movie frames whose slice count differs from the
    /// first one's are left out: the plan places their slices.
    /// One movie frame of the new viewer: its slices, their files and the
    /// volume the slices point into.
    private struct Frame {
        let pixes: [DCMPix]
        let files: [Any]
        let volume: NSData
    }

    private func open(_ plan: SliceGapFill) -> Bool {
        let sliceCount = viewer.horos_pixArray(0).count
        var frames: [Frame] = []
        for movie in 0..<max(viewer.horos_movieCount, 1) {
            let pixList = viewer.horos_pixArray(movie)
            guard pixList.count == sliceCount else {
                NSLog("Fill Spacing Gaps: movie frame %ld has %ld slices, not %ld; left out", movie, pixList.count, sliceCount)
                continue
            }
            guard let frame = filledFrame(plan, pixList: pixList, files: viewer.horos_fileList(at: movie) as? [Any] ?? [],
                                          source: viewer.volumePtr(movie)) else { return false }
            frames.append(frame)
        }
        guard let first = frames.first else { return false }

        var wl: Float = 0, ww: Float = 0
        viewer.horos_imageView?.getWLWW(&wl, &ww)
        let clut = viewer.horos_curCLUTMenu

        // -newWindow::: and -addMovieSerie::: keep the arrays they are given as
        // the viewer's own lists of slices and files.
        guard let filled = viewer.newWindow(NSMutableArray(array: first.pixes), NSMutableArray(array: first.files), first.volume) else { return false }
        // -newWindow::: hands over the +1 of the viewer's alloc, which the
        // viewer releases itself when it closes.
        _ = Unmanaged.passRetained(filled)
        for frame in frames.dropFirst() { filled.addMovieSerie(NSMutableArray(array: frame.pixes), NSMutableArray(array: frame.files), frame.volume) }

        // The files of the empty slices are those of their neighbours: the
        // ROIs read from them do not belong to the empty slices.
        filled.roiDeleteAll(viewer)
        filled.setPostprocessed(true)
        filled.computeInterval()
        filled.setWindowTitle(viewer)
        filled.applyCLUTString(clut)
        filled.imageView()?.setWLWW(wl, ww)
        filled.imageView()?.setIndex(first.pixes.count / 2)
        filled.imageView()?.sendSyncMessage(0)
        filled.adjustSlider()
        filled.window?.makeKeyAndOrderFront(viewer)
        return true
    }

    /// One movie frame filled by `plan`: a volume of its own, a copy of each
    /// original slice pointing into it, an empty slice at each missing
    /// position, and the file of each.
    private func filledFrame(_ plan: SliceGapFill, pixList: [DCMPix], files: [Any], source: UnsafeMutablePointer<Float>?) -> Frame? {
        guard let first = pixList.first, let source, files.count == pixList.count else { return nil }
        let sliceFloats = first.pwidth * first.pheight
        let count = plan.slices.count
        let length = count * sliceFloats * MemoryLayout<Float>.size
        guard length > 0, let buffer = malloc(length)?.assumingMemoryBound(to: Float.self) else { return nil }
        let volume = NSData(bytesNoCopy: buffer, length: length, freeWhenDone: true)

        plan.fillVolume(source: source, sliceFloatCount: sliceFloats, into: buffer,
                        fillValue: first.isRGB ? 0 : minimum(source, count: pixList.count * sliceFloats))

        let origins = pixList.map { SIMD3($0.originX, $0.originY, $0.originZ) }
        let generatedName = NSLocalizedString("Spacing Gaps Filled", comment: "Window title suffix of a series with empty slices inserted")
        var pixes: [DCMPix] = [], newFiles: [Any] = []
        pixes.reserveCapacity(count)
        newFiles.reserveCapacity(count)
        for (index, slice) in plan.slices.enumerated() {
            let template: Int
            switch slice {
            case .original(let original): template = original
            case .empty(let after, _, _): template = after
            }
            guard let copy = pixList[template].copy() as? DCMPix else { return nil }
            copy.fImage = buffer + index * sliceFloats
            copy.id = index
            copy.tot = count
            copy.generatedName = generatedName
            if slice.isEmpty {
                let origin = SliceGapFill.origin(of: slice, origins: origins)
                var position = [origin.x, origin.y, origin.z]
                copy.setOriginDouble(&position)
                copy.computeSliceLocation()
                copy.missingPixelsReason = Self.emptySliceNotice
            }
            copy.sliceInterval = 0
            pixes.append(copy)
            newFiles.append(files[template])
        }
        return Frame(pixes: pixes, files: newFiles, volume: volume)
    }

    /// The lowest value of `count` floats from `pointer`.
    private func minimum(_ pointer: UnsafeMutablePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var lowest: Float = 0
        vDSP_minv(pointer, 1, &lowest, vDSP_Length(count))
        return lowest
    }
}
