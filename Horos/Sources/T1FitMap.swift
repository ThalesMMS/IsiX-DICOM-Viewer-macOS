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
import IsiXDICOMDataset
import IsiXImaging

/// Plugins ▸ Image Filters ▸ T1 Fit Map: the T1 map, in milliseconds, of the
/// inversion recovery or variable flip angle series a 2D viewer shows, opened
/// in a new viewer. The fit and its rules are IsiXImaging's T1Fitting.
///
/// The app registers the filter under its title after the plugins have
/// loaded, only when none of them declares that title, and
/// HorosNativeFilterMenus gives it its item only while the filter registered
/// under the title is this class. A former plugin of the same title that is
/// installed and loads therefore keeps its own item and runs instead.
@objc(IsiXT1FitMapFilter)
public final class T1FitMapFilter: NSObject {
    /// The title of the menu item and of the filter in the plugin registry.
    public static let menuTitle = "T1 Fit Map"

    /// Why the last run made no map, in English; empty when it made one.
    @objc public private(set) var lastReason = ""
    /// The acquisition of each slice of the last map: `inversionRecovery` or `variableFlipAngle`.
    @objc public private(set) var lastMethods: [String] = []
    /// The voxels of the last map by what became of them.
    @objc public private(set) var lastFittedCount = 0
    @objc public private(set) var lastBelowThresholdCount = 0
    @objc public private(set) var lastNotConvergedCount = 0
    @objc public private(set) var lastOutOfBoundsCount = 0
    @objc public var viewerController: AnyObject?

    @objc public func prepareFilter(_ viewer: Any?) -> Int {
        viewerController = viewer as AnyObject?
        return 0
    }

    /// Maps the viewer's series. A series that cannot be mapped is explained
    /// in an alert of its own, and 0 is answered so that the host does not
    /// add its generic one; `lastReason` then says why.
    @objc public func filterImage(_ menuName: String?) -> Int {
        guard let viewer = viewerController as? ViewerController else {
            lastReason = "T1 Fit Map needs a 2D viewer."
            return 0
        }
        let outcome = MainActor.assumeIsolated { ViewerT1FitMap(viewer: viewer).run() }
        lastReason = outcome.reason
        lastMethods = outcome.methods.map(\.rawValue)
        lastFittedCount = outcome.counts.fitted
        lastBelowThresholdCount = outcome.counts.belowThreshold
        lastNotConvergedCount = outcome.counts.notConverged
        lastOutOfBoundsCount = outcome.counts.outOfBounds
        return 0
    }
}

/// The T1 map of the series a 2D viewer shows. The images of each slice are
/// grouped as the T2 fit map groups its echoes (per slice across movie frames,
/// otherwise by position), each image's inversion time, repetition time and
/// flip angle are read from its file, and IsiXImaging's T1Fitting fits them.
@MainActor struct ViewerT1FitMap {

    unowned let viewer: ViewerController

    struct Outcome: Sendable {
        var reason = ""
        var methods: [T1Fitting.Method] = []
        var counts = T1Fitting.Counts()
    }

    /// Fits every slice, opens the map in a new viewer and answers what
    /// became of the voxels, or explains in an alert why there is no map.
    func run() -> Outcome {
        let images = ViewerT2FitMap(viewer: viewer)
        let probe = images.pix(at: T1Fitting.Coordinate(movie: 0, slice: 0))
        let reader = AcquisitionReader()
        let result = T1Fitting.map(groups: images.groups(), size: probe.map { (width: $0.pwidth, height: $0.pheight) }) { coordinate in
            guard let pix = images.pix(at: coordinate) else { return nil }
            // The samples are copied only from an image of the first one's
            // size: those are the only ones the fit can read.
            let width = probe?.pwidth ?? 0, height = probe?.pheight ?? 0
            let samples = pix.pwidth == width && pix.pheight == height
                ? pix.fImage.map { Array(UnsafeBufferPointer(start: $0, count: width * height)) } : nil
            return T1Fitting.Image(width: pix.pwidth, height: pix.pheight, acquisition: reader.acquisition(of: pix), samples: samples)
        }

        switch result {
        case .failure(let refusal):
            return refuse(Self.message(for: refusal), reason: "\(refusal)")
        case .success(let map):
            let files = map.templates.compactMap { images.file(at: $0) }
            guard files.count == map.templates.count else {
                return refuse(NSLocalizedString("T1 Fit Map needs the original files of the series to present the map.", comment: ""),
                              reason: "missingFiles")
            }
            let summary = Self.summary(of: map)
            NSLog("T1 Fit Map: %@", summary as NSString)
            open(map, templates: map.templates.compactMap { images.pix(at: $0) }, files: files, summary: summary)
            return Outcome(methods: map.methods, counts: map.counts)
        }
    }

    /// The map in a new 2D viewer, with the window of its whole range and
    /// what became of the voxels as its subtitle.
    private func open(_ map: T1Fitting.SeriesMap, templates: [DCMPix], files: [Any], summary: String) {
        let pixels = map.width * map.height
        // The DCMPix copies point into `volume`, which the new viewer keeps.
        let volume = map.volume.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress, length: $0.count) }
        let first = volume.mutableBytes.assumingMemoryBound(to: Float.self)
        let maps: [DCMPix] = templates.enumerated().compactMap { index, template in
            guard let copy = template.copy() as? DCMPix else { return nil }
            copy.echotime = nil
            copy.fImage = first + index * pixels
            copy.id = index
            copy.tot = templates.count
            copy.computePixMinPixMax()
            return copy
        }
        guard maps.count == files.count else { return }
        let lists = (pixels: NSMutableArray(array: maps), files: NSMutableArray(array: files))
        guard let created = ViewerController.newWindow(lists.pixels, lists.files, volume) else { return }
        // +newWindow::: hands over the +1 of the viewer's alloc; the viewer
        // releases itself when its window closes.
        _ = Unmanaged.passRetained(created)
        created.setPostprocessed(true)
        created.needsDisplayUpdate()
        created.imageView()?.setWLWW(0, 0)
        created.window?.subtitle = summary
    }

    private func refuse(_ message: String, reason: String) -> Outcome {
        HorosAlertPanel.run(title: T1FitMapFilter.menuTitle, message: message,
                            defaultButton: nil, alternateButton: nil, otherButton: nil)
        return Outcome(reason: reason)
    }

    static func message(for refusal: T1Fitting.Refusal) -> String {
        switch refusal {
        case .noSeries:
            return NSLocalizedString("T1 Fit Map needs a 2D viewer showing an inversion recovery or variable flip angle MR series.", comment: "")
        case .sizeMismatch:
            return NSLocalizedString("T1 Fit Map needs images that all have pixels and the same width and height.", comment: "")
        case .noMethod:
            return NSLocalizedString("T1 Fit Map needs, for each slice, images at three or more different inversion times (inversion recovery) or at two or more different flip angles with one repetition time (variable flip angle).", comment: "")
        }
    }

    /// The acquisition and what became of the voxels, for the map's subtitle.
    static func summary(of map: T1Fitting.SeriesMap) -> String {
        var names: [String] = []
        for method in map.methods where !names.contains(name(of: method)) { names.append(name(of: method)) }
        return String(format: NSLocalizedString("%1$@: %2$ld of %3$ld voxels fitted; %4$ld below the signal threshold, %5$ld not converged, %6$ld out of bounds", comment: "Subtitle of a T1 map: the acquisition, then the voxel counts"),
                      names.joined(separator: ", ") as NSString, map.counts.fitted, map.counts.total,
                      map.counts.belowThreshold, map.counts.notConverged, map.counts.outOfBounds)
    }

    private static func name(of method: T1Fitting.Method) -> String {
        switch method {
        case .inversionRecovery: return NSLocalizedString("Inversion recovery", comment: "T1 map acquisition")
        case .variableFlipAngle: return NSLocalizedString("Variable flip angle", comment: "T1 map acquisition")
        }
    }
}

/// The acquisition of each image, read from its file: the inversion time is
/// not among what DCMPix keeps, and an enhanced MR states its inversion times
/// per frame. The file read last is kept, since the frames of an enhanced
/// object follow one another. Where the file gives no repetition time or
/// flip angle, the ones DCMPix read are taken.
@MainActor private final class AcquisitionReader {
    private var last: (path: String, dataset: DCMObject?)?

    func acquisition(of pix: DCMPix) -> T1Fitting.Acquisition {
        var acquisition = dataset(at: pix.srcFile).map { T1Fitting.acquisition(in: $0, frame: pix.frameNo) } ?? T1Fitting.Acquisition()
        if acquisition.repetitionTime == nil { acquisition.repetitionTime = T1Fitting.decimal(pix.repetitiontime) }
        if acquisition.flipAngle == nil { acquisition.flipAngle = T1Fitting.decimal(pix.flipAngle) }
        return acquisition
    }

    private func dataset(at path: String?) -> DCMObject? {
        guard let path else { return nil }
        if let last, last.path == path { return last.dataset }
        // Up to the functional groups (group 5200); the pixel data is not read.
        let dataset = DCMObject.object(contentsOfFile: path, decodingPixelData: false, lastGroup: 0x5200)
        last = (path, dataset)
        return dataset
    }
}
