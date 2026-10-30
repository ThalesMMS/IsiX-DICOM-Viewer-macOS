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

/// Identifies one viewer window for as long as the application runs.
public struct IsiXViewerID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    @_spi(IsiXHost)
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString }
}

/// Where a viewer is in its series.
public struct IsiXSlicePosition: Hashable, Sendable {
    public var slice: Int
    public var phase: Int

    public init(slice: Int, phase: Int) {
        self.slice = slice
        self.phase = phase
    }
}

/// A 2D viewer, as a plugin reaches it.
///
/// The handle does not keep the viewer open: once the user closes it,
/// `isOpen` is false and every call throws `IsiXPluginError.viewerClosed`.
/// What it returns are copies the plugin owns. Nothing it returns points into
/// the viewer's memory, so a plugin can keep and use them after the viewer
/// closes, and read them off the main actor.
@MainActor
public final class IsiXViewer {
    public nonisolated let id: IsiXViewerID
    let backend: any IsiXViewerBackend
    private let capabilities: Set<IsiXCapability>
    /// The plugin's registrations, for the overlays it adds; nil for a handle
    /// the host made itself.
    let registry: ObservationRegistry?

    @_spi(IsiXHost)
    public convenience init(backend: any IsiXViewerBackend, capabilities: Set<IsiXCapability>) {
        self.init(backend: backend, capabilities: capabilities, registry: nil)
    }

    init(backend: any IsiXViewerBackend, capabilities: Set<IsiXCapability>, registry: ObservationRegistry?) {
        self.id = backend.viewerID
        self.backend = backend
        self.capabilities = capabilities
        self.registry = registry
    }

    public var isOpen: Bool { backend.isOpen }

    func require(_ capability: IsiXCapability) throws {
        guard capabilities.contains(capability) else { throw IsiXPluginError.capabilityNotDeclared(capability) }
        guard backend.isOpen else { throw IsiXPluginError.viewerClosed }
    }

    // MARK: series and images

    public func series() throws -> IsiXSeriesSummary {
        try require(.viewerRead)
        return try backend.seriesSummary()
    }

    public func currentPosition() throws -> IsiXSlicePosition {
        try require(.viewerRead)
        return try backend.currentPosition()
    }

    /// Shows another slice of the current phase.
    public func setCurrentSlice(_ slice: Int) throws {
        try require(.viewerRead)
        try backend.setCurrentSlice(slice)
    }

    /// Shows another phase of a 4D series, at the same slice.
    public func setCurrentPhase(_ phase: Int) throws {
        try require(.viewerRead)
        try backend.setCurrentPhase(phase)
    }

    /// A copy of one image: the current slice and phase when nil.
    public func image(slice: Int? = nil, phase: Int? = nil) throws -> IsiXImage {
        try require(.viewerRead)
        return try backend.image(slice: slice, phase: phase)
    }

    /// The geometry of one image, without copying its pixels: the current
    /// slice and phase when nil.
    public func geometry(slice: Int? = nil, phase: Int? = nil) throws -> IsiXImageGeometry {
        try require(.viewerRead)
        return try backend.geometry(slice: slice, phase: phase)
    }

    /// The attributes of one image, without copying its pixels: the current
    /// slice and phase when nil.
    public func attributes(slice: Int? = nil, phase: Int? = nil) throws -> IsiXImageAttributes {
        try require(.viewerRead)
        return try backend.attributes(slice: slice, phase: phase)
    }

    public func windowLevel() throws -> IsiXWindowLevel {
        try require(.viewerRead)
        return try backend.windowLevel()
    }

    public func setWindowLevel(_ windowLevel: IsiXWindowLevel) throws {
        try require(.viewerWrite)
        try backend.setWindowLevel(windowLevel)
    }

    /// Replaces the pixels of the image `image` was read from, in memory, and
    /// redraws. The source files are not changed.
    ///
    /// Throws `staleImage` if that image changed or was replaced since it was
    /// read, and `dimensionMismatch` unless `pixels` has the same size and
    /// format as `image.pixels`.
    public func commit(_ pixels: IsiXPixelData, replacing image: IsiXImage) throws {
        try require(.viewerWrite)
        guard image.viewerID == id else { throw IsiXPluginError.staleImage }
        switch (pixels, image.pixels) {
        case (.float32(let new), .float32(let old)) where new.width == old.width && new.height == old.height && new.channels == old.channels:
            break
        case (.rgba8(let new), .rgba8(let old)) where new.width == old.width && new.height == old.height && new.channels == old.channels:
            break
        default:
            throw IsiXPluginError.dimensionMismatch
        }
        try backend.commit(pixels, replacing: image.version)
    }

    /// Opens a new viewer that shows `series`, and returns it. Each image
    /// takes the place, geometry, patient and study of the image of this
    /// viewer it names; the series stays in memory. Throws
    /// `dimensionMismatch` unless every image has its source's width and
    /// height, and one channel, and when a source is a colour image.
    public func openDerivedSeries(_ series: IsiXDerivedSeries) throws -> IsiXViewer {
        try require(.viewerWrite)
        guard !series.images.isEmpty else { throw IsiXPluginError.hostFailure("A derived series needs at least one image.") }
        guard series.images.allSatisfy({ $0.pixels.channels == 1 }) else { throw IsiXPluginError.dimensionMismatch }
        return IsiXViewer(backend: try backend.openDerivedSeries(series), capabilities: capabilities, registry: registry)
    }

    // MARK: ROIs

    /// The ROIs of one image: the current slice and phase when nil.
    public func rois(slice: Int? = nil, phase: Int? = nil) throws -> [IsiXROI] {
        try require(.roi)
        return try backend.rois(slice: slice, phase: phase)
    }

    public func addROI(_ draft: IsiXROIDraft) throws -> IsiXROI {
        try require(.roi)
        return try backend.addROI(draft)
    }

    public func removeROI(_ id: IsiXROIID) throws {
        try require(.roi)
        try backend.removeROI(id)
    }

    /// Changes a ROI in place: its identifier stays the same. Returns the ROI
    /// as it is afterwards. Throws `roiNotFound` once the ROI is gone, and
    /// `invalidROI` for points its kind cannot take or a change of kind other
    /// than a rectangle or an oval becoming a polygon.
    @discardableResult
    public func updateROI(_ id: IsiXROIID, _ update: IsiXROIUpdate) throws -> IsiXROI {
        try require(.roi)
        return try backend.updateROI(id, update)
    }

    public func statistics(of id: IsiXROIID) throws -> IsiXROIStatistics {
        try require(.roi)
        return try backend.statistics(of: id)
    }

    /// Measures the ROI on another image of this viewer: its outline, as it
    /// lies on its own image, laid on the image at `slice` and `phase`, as for
    /// a curve of the same region over the phases of a 4D series.
    public func statistics(of id: IsiXROIID, slice: Int, phase: Int) throws -> IsiXROIStatistics {
        try require(.roi)
        return try backend.statistics(of: id, slice: slice, phase: phase)
    }

    /// Redraws the viewer.
    public func setNeedsDisplay() {
        guard backend.isOpen else { return }
        backend.setNeedsDisplay()
    }
}
