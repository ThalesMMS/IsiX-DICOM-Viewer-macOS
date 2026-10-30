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
import IsiXPluginKit
import os
import Synchronization

/// T2 Fit Map on the plugin API version 1: fits T2 per pixel over the echoes
/// of a multi-echo series and opens the map, in milliseconds, in a new viewer
/// placed where the first echo of each location is.
///
/// The echoes are read as copies on the main actor; the fit runs in a task,
/// off the main actor, on those copies. Closing the source viewer cancels the
/// task, and a map that finishes after the viewer closed is not opened.
public final class T2FitMapPlugin: IsiXPlugin, CustomStringConvertible {
    private let log = Logger(subsystem: "org.isix.pilot.t2-fit-map", category: "pilot")
    private let journal = Mutex<[String]>([])
    private var context: IsiXPluginContext?
    private var observation: IsiXObservation?
    private var running: [IsiXViewerID: IsiXTask] = [:]

    public nonisolated var description: String { journal.withLock { $0.joined(separator: "\n") } }

    public init() {}

    public func activate(with context: IsiXPluginContext) throws {
        self.context = context
        try context.register(IsiXCommand(id: "t2-fit-map", title: "T2 Fit Map",
                                         placement: .imageFilters, requirement: .viewer)) { [weak self] invocation in
            guard let viewer = invocation.viewer else { throw IsiXPluginError.viewerClosed }
            try self?.start(viewer)
        }
        observation = try context.observe([.viewerWillClose]) { [weak self] event in
            guard case .viewerWillClose(let id) = event, let task = self?.running.removeValue(forKey: id) else { return }
            task.cancel()
            self?.note("viewer closed: fit cancelled")
        }
        note("activated \(context.info.identifier) \(context.info.version)")
    }

    public func deactivate() {
        observation = nil
        running.removeAll()
        context = nil
    }

    private func note(_ line: String) {
        journal.withLock { $0.append(line) }
        log.notice("T2FitMap: \(line, privacy: .public)")
    }

    /// One location: where its map goes, and its echoes.
    private struct Location: Sendable {
        var slice: Int
        var phase: Int
        var echoes: [[Float]]
        var echoTimes: [Double]
    }

    func start(_ viewer: IsiXViewer) throws {
        guard let context else { throw IsiXPluginError.pluginInactive }
        guard running[viewer.id] == nil else {
            throw T2Fit.Failure(reason: "T2 Fit Map is already running on this viewer.")
        }
        let series = try viewer.series()
        let groups = T2Fit.locations(sliceCount: series.sliceCount, phaseCount: series.phaseCount) { slice in
            let position = (try? viewer.geometry(slice: slice, phase: 0))?.imagePosition
            return (position?.x ?? .nan, position?.y ?? .nan, position?.z ?? .nan)
        }
        var columns = 0, rows = 0
        var gathered: [Location] = []
        for group in groups {
            var location = Location(slice: group[0].slice, phase: group[0].phase, echoes: [], echoTimes: [])
            for member in group {
                let image = try viewer.image(slice: member.slice, phase: member.phase)
                guard let pixels = image.scalarPixels else {
                    throw T2Fit.Failure(reason: "T2 Fit Map needs a grayscale series.")
                }
                if columns == 0 { (columns, rows) = (pixels.width, pixels.height) }
                guard pixels.width == columns, pixels.height == rows else {
                    throw T2Fit.Failure(reason: "T2 Fit Map frames must share the same width and height.")
                }
                location.echoes.append(pixels.samples)
                location.echoTimes.append(image.attributes.echoTime ?? 0)
            }
            gathered.append(location)
        }
        let (width, height, locations) = (columns, rows, gathered)
        let viewerID = viewer.id
        let task = try context.startTask(named: "T2 Fit Map") { [weak self] progress in
            var maps: [[Float]] = []
            do {
                for (index, location) in locations.enumerated() {
                    maps.append(try T2Fit.map(echoes: location.echoes, echoTimes: location.echoTimes,
                                              width: width, height: height, isCancelled: { progress.isCancelled || Task.isCancelled }))
                    progress.report(Double(index + 1) / Double(locations.count))
                }
            } catch {
                await MainActor.run { [weak self] in self?.finish(viewerID, maps: nil, locations: locations, width: width, height: height, error: error) }
                return
            }
            let result = maps
            await MainActor.run { [weak self] in self?.finish(viewerID, maps: result, locations: locations, width: width, height: height, error: nil) }
        }
        running[viewerID] = task
        note("fitting \(locations.count) locations of \(locations.first?.echoes.count ?? 0) echoes, \(width)x\(height)")
    }

    private func finish(_ viewerID: IsiXViewerID, maps: [[Float]]?, locations: [Location], width: Int, height: Int, error: (any Error)?) {
        running[viewerID] = nil
        if let error {
            note(error is CancellationError ? "fit cancelled" : "fit failed: \(error.localizedDescription)")
            return
        }
        guard let maps, let context else { return }
        do {
            // The source viewer may have closed while the fit ran: then nothing opens.
            guard let viewer = try context.viewer(withID: viewerID) else {
                note("source viewer closed before the map was ready: nothing opened")
                return
            }
            let images = try zip(locations, maps).map { location, map in
                IsiXDerivedImage(sourceSlice: location.slice, sourcePhase: location.phase,
                                 pixels: try IsiXPixelBuffer(width: width, height: height, samples: map))
            }
            let mapViewer = try viewer.openDerivedSeries(IsiXDerivedSeries(images: images))
            let all = maps.joined()
            let valid = all.filter { $0 > 0 }.count
            let capped = all.filter { $0 >= Float(T2Fit.cap) }.count
            note(String(format: "opened map viewer %@: %d images, %d valid pixels, %d at the cap, max %.4f ms",
                        mapViewer.id.description, maps.count, valid, capped, all.max() ?? 0))
        } catch {
            note("could not open the map: \(error.localizedDescription)")
        }
    }
}
