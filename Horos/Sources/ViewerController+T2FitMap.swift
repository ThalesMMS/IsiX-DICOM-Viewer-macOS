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

/*
 ViewerController+T2FitMap.m
 Horos
*/

import AppKit
import IsiXImaging

/// The ViewerController (T2FitMap) category, in Swift: the selectors
/// and <Horos/ViewerController+T2FitMap.h> are those of the former category,
/// which also adopted T2FitMapViewerProcessing. T2FitMapFilter sends
/// -t2FitMapProcessCurrentSeries by selector. Each hands over to the viewer's
/// ViewerT2FitMap.
extension ViewerController: @MainActor T2FitMapViewerProcessing {

    /// The echoes of each slice, as [movie frame, image index] pairs.
    @objc(t2FitMapIndexGroups)
    func t2FitMapIndexGroups() -> [[[Int]]] {
        ViewerT2FitMap(viewer: self).groups().map { $0.map { [$0.movie, $0.slice] } }
    }

    @objc(t2FitMapPixAtMovie:slice:)
    func t2FitMapPix(atMovie movie: Int, slice: UInt) -> DCMPix? {
        ViewerT2FitMap(viewer: self).pix(at: T2FitMapping.Coordinate(movie: movie, slice: Int(slice)))
    }

    @objc(t2FitMapFileAtMovie:slice:)
    func t2FitMapFile(atMovie movie: Int, slice: UInt) -> Any? {
        ViewerT2FitMap(viewer: self).file(at: T2FitMapping.Coordinate(movie: movie, slice: Int(slice)))
    }

    @objc(t2FitMapProcessCurrentSeries)
    public func t2FitMapProcessCurrentSeries() -> NSDictionary {
        let outcome = ViewerT2FitMap(viewer: self).processCurrentSeries()
        return ["code": NSNumber(value: outcome.code), "reason": outcome.reason, "t2Milliseconds": outcome.t2Milliseconds]
    }
}

/// The T2 fit map of the series a 2D viewer shows. Which images are the
/// echoes of a slice and how the maps are laid out are IsiXImaging's
/// T2FitMapping; each slice is fitted by T2FitMap.fitSeries. Here the viewer's
/// images are read and the map opens in a new viewer.
@MainActor struct ViewerT2FitMap {

    unowned let viewer: ViewerController

    /// The echo groups of the series on screen: per slice when it has several
    /// movie frames, otherwise by position.
    func groups() -> [[T2FitMapping.Coordinate]] {
        if viewer.maxMovieIndex() > 1 {
            return T2FitMapping.groups(movieCount: Int(viewer.maxMovieIndex()), sliceCount: list(viewer.pixList(0)).count)
        }
        let origins = list(viewer.pixList()).map { item -> SIMD3<Double> in
            guard let pix = item as? DCMPix else { return SIMD3(.nan, .nan, .nan) }
            return SIMD3(pix.originX, pix.originY, pix.originZ)
        }
        return T2FitMapping.groups(origins: origins)
    }

    /// The image of a movie frame (the one on screen for a single stack).
    func pix(at coordinate: T2FitMapping.Coordinate) -> DCMPix? {
        let images = list(viewer.maxMovieIndex() > 1 ? viewer.pixList(coordinate.movie) : viewer.pixList())
        return images.indices.contains(coordinate.slice) ? images[coordinate.slice] as? DCMPix : nil
    }

    /// The database image of a movie frame's image.
    func file(at coordinate: T2FitMapping.Coordinate) -> Any? {
        let files = list(viewer.maxMovieIndex() > 1 ? viewer.fileList(coordinate.movie) : viewer.fileList())
        return files.indices.contains(coordinate.slice) ? files[coordinate.slice] : nil
    }

    /// Fits every slice and opens the maps in a new viewer: the code (0 when
    /// the map opened), the reason and the maps one after the other, as
    /// T2FitMapFilter reads them.
    func processCurrentSeries() -> (code: Int, reason: String, t2Milliseconds: [Float]) {
        let probe = pix(at: T2FitMapping.Coordinate(movie: 0, slice: 0))
        let outcome = T2FitMapping.map(
            groups: groups(),
            size: probe.map { (width: $0.pwidth, height: $0.pheight) },
            echo: { coordinate in
                // The samples are copied only from an image of the first
                // one's size: those are the only ones the fit can read.
                guard let pix = pix(at: coordinate) else { return nil }
                let width = probe?.pwidth ?? 0, height = probe?.pheight ?? 0
                let samples = pix.pwidth == width && pix.pheight == height
                    ? pix.fImage.map { Array(UnsafeBufferPointer(start: $0, count: width * height)) } : nil
                return T2FitMapping.Echo(width: pix.pwidth, height: pix.pheight,
                                         echoTimeMilliseconds: (pix.echotime as NSString?)?.floatValue ?? 0, samples: samples)
            },
            fit: { signals, echoTimes, width, height in
                let result = T2FitMap.fitSeries(signals: signals, echoTimesMilliseconds: echoTimes, width: width, height: height)
                return T2FitMapping.Fit(code: result.code, reason: result.reason, t2Milliseconds: result.t2Milliseconds)
            })

        switch outcome {
        case let .refused(code, reason):
            return (code, reason, [])
        case let .mapped(volume, width, height, templates):
            let files = templates.compactMap { file(at: $0) }
            if files.count != templates.count {
                return (3, T2FitMapping.missingFilesReason, volume)
            }
            // The DCMPix copies point into `data`, which the new viewer keeps.
            let pixels = width * height
            let data = volume.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
            let first = data.mutableBytes.assumingMemoryBound(to: Float.self)
            let maps: [DCMPix] = templates.enumerated().compactMap { index, coordinate in
                guard let copy = pix(at: coordinate)?.copy() as? DCMPix else { return nil }
                copy.echotime = nil
                copy.fImage = first + index * pixels
                return copy
            }
            openViewer(maps, files, data)
            return (0, "", volume)
        }
    }

    private func list(_ items: Any?) -> [Any] {
        items as? [Any] ?? []
    }

    /// The map in a new 2D viewer, with the window of its whole range.
    ///
    /// The DCMPix copies point into `volume`, so the viewer has to receive that
    /// same NSMutableData. The parameter is Data in Swift, and the bridge does
    /// not promise to hand the same object back to Objective-C, so the message
    /// is sent through the method's implementation with the NSData itself. The
    /// controller comes back retained (+1, a new-family selector): the
    /// Objective-C left that reference to the window, which releases itself
    /// when it closes, and so does this.
    private func openViewer(_ maps: [DCMPix], _ files: [Any], _ volume: NSData) {
        typealias NewWindow = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, NSData) -> Unmanaged<ViewerController>
        let newWindow = NSSelectorFromString("newWindow:::")
        let send = unsafeBitCast(viewer.method(for: newWindow), to: NewWindow.self)
        let lists: (maps: AnyObject, files: AnyObject) = ((maps as NSArray).mutableCopy() as AnyObject, (files as NSArray).mutableCopy() as AnyObject)
        let created = send(viewer, newWindow, lists.maps, lists.files, volume).takeUnretainedValue()
        created.needsDisplayUpdate()
        created.imageView().setWLWW(0, 0)
    }
}
