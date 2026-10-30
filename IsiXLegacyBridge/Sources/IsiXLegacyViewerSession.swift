//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// One viewer of the application as the kit's Objective-C classes reach it:
// a handle of the plugin API wrapped in Objective-C types. The pixels a legacy
// plugin reads and writes through -[DCMPix fImage] live here, in one buffer
// per phase that the plugin owns; -[ViewerController needsDisplayUpdate]
// commits the images whose pixels changed. Calls made off the main thread,
// as some legacy plugins made them, are carried to the main thread.

import AppKit
import IsiXPluginKit

/// What the kit's ViewerController answers, for the session to drive it.
@objc protocol IsiXLegacyControllerHooks: NSObjectProtocol {
    /// Pushes the ROI changes of the legacy lists and commits changed pixels.
    @objc(isixLegacyFlush) func isixLegacyFlush()
    /// The viewer shows another series: images and ROI lists are read again.
    @objc(isixLegacySeriesReplaced) func isixLegacySeriesReplaced()
}

/// Runs `body` on the main thread, waiting for it when called from another one.
func IsiXLegacyOnMain<T>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread { return MainActor.assumeIsolated { body() } }
    return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
}

/// The geometry and attributes of one image, in the legacy units.
@objc final class IsiXLegacyImageInfo: NSObject {
    @objc let columns: Int
    @objc let rows: Int
    /// Pixel Spacing: between columns (x) and between rows (y), in mm.
    @objc let spacingX: Double
    @objc let spacingY: Double
    @objc let originX: Double
    @objc let originY: Double
    @objc let originZ: Double
    /// Row direction, column direction and normal: nine cosines.
    @objc let orientation: [NSNumber]
    @objc let sliceThickness: Double
    @objc let sliceInterval: Double
    @objc let sliceLocation: Double
    @objc let slope: Double
    @objc let intercept: Double
    @objc let echoTime: String?
    @objc let repetitionTime: String?
    @objc let modality: String?
    @objc let sopInstanceUID: String?
    @objc let isSUV: Bool
    let geometry: IsiXImageGeometry

    init(geometry g: IsiXImageGeometry, attributes a: IsiXImageAttributes) {
        geometry = g
        columns = g.columns
        rows = g.rows
        spacingX = g.columnSpacing
        spacingY = g.rowSpacing
        originX = g.imagePosition.x
        originY = g.imagePosition.y
        originZ = g.imagePosition.z
        let n = g.normal
        orientation = (g.imageOrientation + [n.x, n.y, n.z]).map { NSNumber(value: $0) }
        sliceThickness = g.sliceThickness
        sliceInterval = g.sliceInterval
        sliceLocation = g.sliceLocation
        slope = a.rescaleSlope
        intercept = a.rescaleIntercept
        echoTime = a.echoTime.map { String($0) }
        repetitionTime = a.repetitionTime.map { String($0) }
        modality = a.modality
        sopInstanceUID = a.sopInstanceUID
        isSUV = a.isSUV
    }

    /// The patient point of a legacy pixel position: with `pixelCenter`, the
    /// centre of the first pixel is (0.5, 0.5), as the application draws ROIs.
    @objc func patientPoint(x: Double, y: Double, pixelCenter: Bool) -> [NSNumber] {
        let shift = pixelCenter ? 0.5 : 0
        let p = geometry.patientPoint(of: IsiXPixelPoint(x: x - shift, y: y - shift))
        return [p.x, p.y, p.z].map { NSNumber(value: $0) }
    }
}

/// Statistics of a ROI, in the legacy units: area in cm², length in cm.
@objc final class IsiXLegacyROIStatistics: NSObject {
    @objc let mean: Double
    @objc let deviation: Double
    @objc let minimum: Double
    @objc let maximum: Double
    @objc let total: Double
    @objc let areaCM2: Double
    @objc let lengthCM: Double

    init(_ s: IsiXROIStatistics) {
        mean = s.mean
        deviation = s.standardDeviation
        minimum = s.minimum
        maximum = s.maximum
        total = s.sum
        areaCM2 = (s.area ?? 0) / 100
        lengthCM = (s.length ?? 0) / 10
    }
}

/// The pixels of one phase: every image of the phase, one after the other,
/// four bytes per pixel (one Float32 sample, or ARGB for colour images), so
/// that the buffer of a series of equal images is the legacy volume.
@MainActor
private final class PhaseVolume {
    let base: UnsafeMutableRawPointer
    let offsets: [Int]
    let sizes: [(columns: Int, rows: Int)]
    /// The image each loaded slice was read from: what a commit replaces.
    var loaded: [IsiXImage?]

    init(sizes: [(columns: Int, rows: Int)]) {
        self.sizes = sizes
        var offsets: [Int] = []
        var total = 0
        for size in sizes {
            offsets.append(total)
            total += size.columns * size.rows * 4
        }
        self.offsets = offsets
        base = UnsafeMutableRawPointer.allocate(byteCount: max(total, 4), alignment: 16)
        base.initializeMemory(as: UInt8.self, repeating: 0, count: max(total, 4))
        loaded = Array(repeating: nil, count: sizes.count)
    }

    deinit { base.deallocate() }

    var isUniform: Bool { Set(sizes.map { "\($0.columns)x\($0.rows)" }).count <= 1 }

    func pointer(_ slice: Int) -> UnsafeMutableRawPointer { base + offsets[slice] }

    /// Copies the image's pixels into the slice's place.
    func store(_ image: IsiXImage, at slice: Int) {
        let destination = pointer(slice)
        switch image.pixels {
        case .float32(let buffer):
            buffer.withUnsafeBufferPointer { source in
                destination.copyMemory(from: source.baseAddress!, byteCount: source.count * 4)
            }
        case .rgba8(let buffer):
            let argb = destination.assumingMemoryBound(to: UInt8.self)
            buffer.withUnsafeBufferPointer { rgba in
                for index in 0..<(buffer.width * buffer.height) {
                    argb[index * 4] = rgba[index * 4 + 3]
                    argb[index * 4 + 1] = rgba[index * 4]
                    argb[index * 4 + 2] = rgba[index * 4 + 1]
                    argb[index * 4 + 3] = rgba[index * 4 + 2]
                }
            }
        @unknown default:
            break
        }
        loaded[slice] = image
    }

    /// The slice's pixels as the plugin API takes them, when they differ from
    /// the image they were read from.
    func changedPixels(_ slice: Int) throws -> IsiXPixelData? {
        guard let image = loaded[slice] else { return nil }
        let source = pointer(slice)
        switch image.pixels {
        case .float32(let old):
            let count = old.width * old.height
            let equal = old.withUnsafeBufferPointer { memcmp($0.baseAddress!, source, count * 4) == 0 }
            if equal { return nil }
            let samples = Array(UnsafeBufferPointer(start: source.assumingMemoryBound(to: Float.self), count: count))
            return .float32(try IsiXPixelBuffer(width: old.width, height: old.height, samples: samples))
        case .rgba8(let old):
            let count = old.width * old.height
            let argb = source.assumingMemoryBound(to: UInt8.self)
            var rgba = [UInt8](repeating: 0, count: count * 4)
            for index in 0..<count {
                rgba[index * 4] = argb[index * 4 + 1]
                rgba[index * 4 + 1] = argb[index * 4 + 2]
                rgba[index * 4 + 2] = argb[index * 4 + 3]
                rgba[index * 4 + 3] = argb[index * 4]
            }
            if rgba == old.samples { return nil }
            return .rgba8(try IsiXPixelBuffer(width: old.width, height: old.height, channels: 4, samples: rgba))
        @unknown default:
            return nil
        }
    }
}

/// One viewer of the application, for the kit's Objective-C classes.
@MainActor
@objc final class IsiXLegacyViewerSession: NSObject {
    let viewer: IsiXViewer
    /// The kit's ViewerController of this viewer, kept by the session so that
    /// the plugin always gets the same object; released when the viewer closes.
    @objc var legacyController: AnyObject?
    private var volumes: [Int: PhaseVolume] = [:]
    private var infos: [Int: [Int: IsiXLegacyImageInfo]] = [:]

    init(viewer: IsiXViewer) {
        self.viewer = viewer
    }

    private func attempt<T>(_ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            IsiXLegacyState.shared.record(error)
            return nil
        }
    }

    // MARK: viewers

    /// The open 2D viewers, frontmost first.
    @objc nonisolated class func openSessions() -> [IsiXLegacyViewerSession] {
        IsiXLegacyOnMain {
            let state = IsiXLegacyState.shared
            guard let viewers = (try? state.context?.openViewers()) ?? nil else { return [] }
            return viewers.map { state.session(for: $0) }
        }
    }

    @objc nonisolated class func frontmostSession() -> IsiXLegacyViewerSession? {
        IsiXLegacyOnMain {
            let state = IsiXLegacyState.shared
            return ((try? state.context?.frontmostViewer()) ?? nil).map { state.session(for: $0) }
        }
    }

    @objc nonisolated var isOpen: Bool { IsiXLegacyOnMain { viewer.isOpen } }

    /// The window to attach sheets to, while a command runs on this viewer.
    @objc nonisolated var window: NSWindow? { IsiXLegacyOnMain { IsiXLegacyState.shared.parentWindow(for: self) } }

    @objc nonisolated var identifier: String { viewer.id.description }

    func invalidate() {
        (legacyController as? IsiXLegacyControllerHooks)?.isixLegacySeriesReplaced()
        legacyController = nil
        volumes.removeAll()
        infos.removeAll()
    }

    /// The viewer shows another series: forget what was read of the former one.
    func seriesReplaced() {
        volumes.removeAll()
        infos.removeAll()
        (legacyController as? IsiXLegacyControllerHooks)?.isixLegacySeriesReplaced()
    }

    /// Reads again the images the plugin already read, in place, so a command
    /// sees the pixels as they are now.
    func reload() {
        guard viewer.isOpen else { return }
        for (phase, volume) in volumes {
            for slice in volume.loaded.indices where volume.loaded[slice] != nil {
                if let image = try? viewer.image(slice: slice, phase: phase),
                   image.geometry.columns == volume.sizes[slice].columns, image.geometry.rows == volume.sizes[slice].rows {
                    volume.store(image, at: slice)
                } else {
                    volume.loaded[slice] = nil
                }
            }
        }
    }

    /// After a command: the legacy lists pushed and changed pixels committed.
    func flush() {
        (legacyController as? IsiXLegacyControllerHooks)?.isixLegacyFlush()
    }

    // MARK: series and position

    @objc nonisolated var sliceCount: Int { IsiXLegacyOnMain { attempt { try viewer.series().sliceCount } ?? 0 } }
    @objc nonisolated var phaseCount: Int { IsiXLegacyOnMain { attempt { try viewer.series().phaseCount } ?? 1 } }
    @objc nonisolated var currentSlice: Int { IsiXLegacyOnMain { attempt { try viewer.currentPosition().slice } ?? 0 } }
    @objc nonisolated var currentPhase: Int { IsiXLegacyOnMain { attempt { try viewer.currentPosition().phase } ?? 0 } }
    @objc nonisolated var seriesDescription: String? { IsiXLegacyOnMain { attempt { try viewer.series().seriesDescription } ?? nil } }

    @objc nonisolated func setCurrentSlice(_ slice: Int) {
        IsiXLegacyOnMain { _ = attempt { try viewer.setCurrentSlice(slice) } }
    }

    @objc nonisolated func setCurrentPhase(_ phase: Int) {
        IsiXLegacyOnMain { _ = attempt { try viewer.setCurrentPhase(phase) } }
    }

    @objc nonisolated func info(slice: Int, phase: Int) -> IsiXLegacyImageInfo? {
        IsiXLegacyOnMain {
            if let known = infos[phase]?[slice] { return known }
            guard let info = attempt({ IsiXLegacyImageInfo(geometry: try viewer.geometry(slice: slice, phase: phase),
                                                          attributes: try viewer.attributes(slice: slice, phase: phase)) }) else { return nil }
            infos[phase, default: [:]][slice] = info
            return info
        }
    }

    // MARK: pixels

    private func volume(phase: Int) -> PhaseVolume? {
        if let volume = volumes[phase] { return volume }
        let count = sliceCount
        guard count > 0 else { return nil }
        var sizes: [(columns: Int, rows: Int)] = []
        for slice in 0..<count {
            guard let geometry = attempt({ try viewer.geometry(slice: slice, phase: phase) }) else { return nil }
            sizes.append((geometry.columns, geometry.rows))
        }
        let volume = PhaseVolume(sizes: sizes)
        volumes[phase] = volume
        return volume
    }

    private func loadedVolume(slice: Int, phase: Int) -> PhaseVolume? {
        guard let volume = volume(phase: phase), volume.sizes.indices.contains(slice) else { return nil }
        if volume.loaded[slice] == nil {
            guard let image = attempt({ try viewer.image(slice: slice, phase: phase) }) else { return nil }
            volume.store(image, at: slice)
        }
        return volume
    }

    /// The image's pixels, owned by the session: Float32 samples, or ARGB
    /// bytes for a colour image. Valid until the viewer closes.
    @objc nonisolated func pixels(slice: Int, phase: Int) -> UnsafeMutableRawPointer? {
        IsiXLegacyOnMain { loadedVolume(slice: slice, phase: phase)?.pointer(slice) }
    }

    @objc nonisolated func isColor(slice: Int, phase: Int) -> Bool {
        IsiXLegacyOnMain {
            guard let image = loadedVolume(slice: slice, phase: phase)?.loaded[slice] else { return false }
            if case .rgba8 = image.pixels { return true }
            return false
        }
    }

    /// Every image of the phase in one buffer, when they all have one size.
    @objc nonisolated func volumePixels(phase: Int) -> UnsafeMutableRawPointer? {
        IsiXLegacyOnMain {
            guard let volume = volume(phase: phase), volume.isUniform else { return nil }
            for slice in volume.sizes.indices where volume.loaded[slice] == nil {
                guard loadedVolume(slice: slice, phase: phase) != nil else { return nil }
            }
            return volume.base
        }
    }

    /// Commits every image whose pixels the plugin changed; returns how many.
    @objc nonisolated func commitChangedPixels() -> Int {
        IsiXLegacyOnMain {
            var committed = 0
            for (phase, volume) in volumes.sorted(by: { $0.key < $1.key }) {
                for slice in volume.loaded.indices {
                    guard let image = volume.loaded[slice] else { continue }
                    let ok: Bool? = attempt {
                        guard let pixels = try volume.changedPixels(slice) else { return false }
                        try viewer.commit(pixels, replacing: image)
                        // The committed image is what the next commit replaces.
                        volume.loaded[slice] = try viewer.image(slice: slice, phase: phase)
                        return true
                    }
                    if ok == true { committed += 1 }
                }
            }
            viewer.setNeedsDisplay()
            return committed
        }
    }

    // MARK: window level

    @objc nonisolated var windowCenter: Double { IsiXLegacyOnMain { attempt { try viewer.windowLevel().center } ?? 0 } }
    @objc nonisolated var windowWidth: Double { IsiXLegacyOnMain { attempt { try viewer.windowLevel().width } ?? 0 } }

    @objc nonisolated func setWindow(center: Double, width: Double) {
        IsiXLegacyOnMain { _ = attempt { try viewer.setWindowLevel(IsiXWindowLevel(center: center, width: width)) } }
    }

    // MARK: ROIs

    @objc nonisolated func rois(slice: Int, phase: Int) -> [IsiXLegacyROIState] {
        IsiXLegacyOnMain {
            attempt { try viewer.rois(slice: slice, phase: phase).map { IsiXLegacyROIState(roi: $0) } } ?? []
        }
    }

    /// Creates the ROI on the image; nil when the application refused it.
    @objc nonisolated func addROI(_ state: IsiXLegacyROIState, slice: Int, phase: Int) -> IsiXLegacyROIState? {
        IsiXLegacyOnMain {
            attempt {
                guard let draft = state.draft(slice: slice, phase: phase) else {
                    throw IsiXLegacyError("A plugin cannot create a ROI of this type.")
                }
                var created = try viewer.addROI(draft)
                let update = IsiXLegacyROIState(roi: created).update(to: state)
                if update != IsiXROIUpdate() { created = try viewer.updateROI(created.id, update) }
                return IsiXLegacyROIState(roi: created)
            }
        }
    }

    /// Brings the application's ROI to `state`; returns it as it is now.
    @objc nonisolated func updateROI(_ old: IsiXLegacyROIState, to state: IsiXLegacyROIState) -> IsiXLegacyROIState? {
        IsiXLegacyOnMain {
            guard let id = old.roi?.id else { return nil }
            let update = old.update(to: state)
            if update == IsiXROIUpdate() { return old }
            return attempt { IsiXLegacyROIState(roi: try viewer.updateROI(id, update)) }
        }
    }

    @objc nonisolated func removeROI(_ state: IsiXLegacyROIState) {
        IsiXLegacyOnMain {
            guard let id = state.roi?.id else { return }
            _ = attempt { try viewer.removeROI(id) }
        }
    }

    /// The ROI measured by the application on the image at `slice`, `phase`.
    @objc nonisolated func statistics(of state: IsiXLegacyROIState, slice: Int, phase: Int) -> IsiXLegacyROIStatistics? {
        IsiXLegacyOnMain {
            guard let roi = state.roi else { return nil }
            return attempt {
                let statistics = roi.slice == slice && roi.phase == phase
                    ? try viewer.statistics(of: roi.id) : try viewer.statistics(of: roi.id, slice: slice, phase: phase)
                return IsiXLegacyROIStatistics(statistics)
            }
        }
    }

    // MARK: new viewers

    /// Opens a new viewer on images the plugin computed: `pixels[i]` points to
    /// the Float32 samples of an image of the size of slice `slices[i]`,
    /// phase `phases[i]`, of this viewer, whose place it takes.
    @objc nonisolated func openDerivedSeries(slices: [NSNumber], phases: [NSNumber], pixels: [NSValue]) -> IsiXLegacyViewerSession? {
        IsiXLegacyOnMain {
            attempt {
                guard !slices.isEmpty, slices.count == phases.count, slices.count == pixels.count else {
                    throw IsiXLegacyError("A new series needs at least one image.")
                }
                var images: [IsiXDerivedImage] = []
                for index in slices.indices {
                    let slice = slices[index].intValue, phase = phases[index].intValue
                    let geometry = try viewer.geometry(slice: slice, phase: phase)
                    guard let pointer = pixels[index].pointerValue else { throw IsiXPluginError.dimensionMismatch }
                    let count = geometry.columns * geometry.rows
                    let samples = Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: Float.self), count: count))
                    images.append(IsiXDerivedImage(sourceSlice: slice, sourcePhase: phase,
                                                   pixels: try IsiXPixelBuffer(width: geometry.columns, height: geometry.rows, samples: samples)))
                }
                let opened = try viewer.openDerivedSeries(IsiXDerivedSeries(images: images))
                return IsiXLegacyState.shared.session(for: opened)
            }
        }
    }

    /// A new viewer with a copy of the current phase.
    @objc nonisolated func duplicateSeries() -> IsiXLegacyViewerSession? {
        IsiXLegacyOnMain {
            let phase = currentPhase
            var slices: [NSNumber] = [], phases: [NSNumber] = [], pointers: [NSValue] = []
            for slice in 0..<sliceCount {
                guard let pointer = pixels(slice: slice, phase: phase) else { return nil }
                slices.append(NSNumber(value: slice))
                phases.append(NSNumber(value: phase))
                pointers.append(NSValue(pointer: pointer))
            }
            return openDerivedSeries(slices: slices, phases: phases, pixels: pointers)
        }
    }
}
