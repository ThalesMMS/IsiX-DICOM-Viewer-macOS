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

/// The smallest plugin that uses the version 1 API end to end: three menu
/// commands that read an image with its geometry, measure it off the main
/// actor, create ROIs and commit a changed copy of the pixels, and an
/// observation of the viewer events.
///
/// Info.plist names it `IsiXPluginExample.ExamplePlugin`: module, then class.
public final class ExamplePlugin: IsiXPlugin, CustomStringConvertible {
    private let log = Logger(subsystem: "org.isix.plugin-example", category: "example")
    private var context: IsiXPluginContext?
    private var observation: IsiXObservation?
    private var running: [IsiXViewerID: IsiXTask] = [:]

    /// What the plugin did, one line per step, for whoever checks it.
    private let record = Mutex<[String]>([])

    public nonisolated var description: String { record.withLock { $0.joined(separator: "\n") } }

    public init() {}

    public func activate(with context: IsiXPluginContext) throws {
        self.context = context
        try context.register(IsiXCommand(id: "inspect-image", title: "IsiX Example: Inspect Image",
                                         placement: .imageFilters, requirement: .viewer)) { [weak self] invocation in
            try self?.inspect(invocation)
        }
        try context.register(IsiXCommand(id: "mark-centre", title: "IsiX Example: Mark Centre",
                                         placement: .roiTools, requirement: .viewer)) { [weak self] invocation in
            try self?.markCentre(invocation)
        }
        try context.register(IsiXCommand(id: "negate-slice", title: "IsiX Example: Negate Slice",
                                         placement: .imageFilters, requirement: .viewer)) { [weak self] invocation in
            try self?.negate(invocation)
        }
        observation = try context.observe([.viewerWillClose, .sliceChanged, .roiChanged]) { [weak self] event in
            self?.handle(event)
        }
        note("activated \(context.info.identifier) \(context.info.version)")
    }

    public func deactivate() {
        observation = nil
        running.removeAll()
        context = nil
        note("deactivated")
    }

    private func note(_ line: String) {
        record.withLock { $0.append(line) }
        log.notice("IsiXPluginExample: \(line, privacy: .public)")
    }

    private func viewer(_ invocation: IsiXCommandInvocation) throws -> IsiXViewer {
        guard let viewer = invocation.viewer else { throw IsiXPluginError.viewerClosed }
        return viewer
    }

    /// Reads the current image and its geometry on the main actor, then
    /// measures the copy in a task: the copy stays valid if the viewer closes.
    private func inspect(_ invocation: IsiXCommandInvocation) throws {
        let viewer = try viewer(invocation)
        let image = try viewer.image()
        let g = image.geometry
        let centre = g.patientPoint(of: IsiXPixelPoint(x: Double(g.columns - 1) / 2, y: Double(g.rows - 1) / 2))
        note(String(format: "image slice %d phase %d size %dx%d spacing %.4f/%.4f position %.3f,%.3f,%.3f orientation %@ centre %.3f,%.3f,%.3f",
                    image.slice, image.phase, g.columns, g.rows, g.rowSpacing, g.columnSpacing,
                    g.imagePosition.x, g.imagePosition.y, g.imagePosition.z,
                    g.imageOrientation.map { String(format: "%.4f", $0) }.joined(separator: ","),
                    centre.x, centre.y, centre.z))
        guard let pixels = image.scalarPixels else {
            note("image is colour")
            return
        }
        let viewerID = viewer.id
        let task = try context?.startTask(named: "Measure") { progress in
            var sum = 0.0, minimum = Double.infinity, maximum = -Double.infinity
            pixels.withUnsafeBufferPointer { samples in
                for (index, sample) in samples.enumerated() {
                    let value = Double(sample)
                    sum += value
                    minimum = min(minimum, value)
                    maximum = max(maximum, value)
                    if index % 65536 == 0 { progress.report(Double(index) / Double(samples.count)) }
                }
            }
            if Task.isCancelled { return }
            let mean = sum / Double(pixels.samples.count)
            await MainActor.run { [weak self] in
                self?.note(String(format: "pixels %d mean %.4f min %.4f max %.4f", pixels.samples.count, mean, minimum, maximum))
            }
        }
        running[viewerID] = task
    }

    /// A rectangle around the middle half of the image and a point at its
    /// centre, then the host's statistics of the rectangle.
    private func markCentre(_ invocation: IsiXCommandInvocation) throws {
        let viewer = try viewer(invocation)
        let image = try viewer.image()
        let w = Double(image.geometry.columns), h = Double(image.geometry.rows)
        let rectangle = try viewer.addROI(IsiXROIDraft(kind: .rectangle,
                                                       points: [IsiXPixelPoint(x: w / 4, y: h / 4), IsiXPixelPoint(x: 3 * w / 4, y: 3 * h / 4)],
                                                       name: "IsiX Example"))
        let point = try viewer.addROI(IsiXROIDraft(kind: .point, points: [IsiXPixelPoint(x: (w - 1) / 2, y: (h - 1) / 2)],
                                                   name: "IsiX Example centre"))
        let statistics = try viewer.statistics(of: rectangle.id)
        let listed = try viewer.rois().filter { $0.id == rectangle.id || $0.id == point.id }.count
        note(String(format: "roi %@ mean %.4f min %.4f max %.4f area %.4f listed %d point %.3f,%.3f,%.3f",
                    rectangle.id.description, statistics.mean, statistics.minimum, statistics.maximum,
                    statistics.area ?? -1, listed,
                    point.patientPoints.first?.x ?? .nan, point.patientPoints.first?.y ?? .nan, point.patientPoints.first?.z ?? .nan))
    }

    /// Negates a copy of the current slice and commits it to the viewer.
    private func negate(_ invocation: IsiXCommandInvocation) throws {
        let viewer = try viewer(invocation)
        let image = try viewer.image()
        guard var pixels = image.scalarPixels else {
            note("image is colour")
            return
        }
        pixels.withUnsafeMutableBufferPointer { samples in
            for index in samples.indices { samples[index] = -samples[index] }
        }
        try viewer.commit(.float32(pixels), replacing: image)
        do {
            try viewer.commit(.float32(pixels), replacing: image)
            note("second commit accepted")
        } catch IsiXPluginError.staleImage {
            note("negated slice \(image.slice); second commit refused as stale")
        }
    }

    private func handle(_ event: IsiXEvent) {
        switch event {
        case .viewerWillClose(let id):
            running.removeValue(forKey: id)?.cancel()
            note("viewer closing")
        case .sliceChanged(_, let position):
            note("slice \(position.slice)")
        case .roiChanged(_, _, let change):
            note("roi \(change)")
        default:
            break
        }
    }
}
