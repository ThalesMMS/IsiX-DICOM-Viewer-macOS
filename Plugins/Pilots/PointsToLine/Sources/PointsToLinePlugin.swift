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

/// PointsToLine on the plugin API version 1: takes the first two point ROIs
/// of the series (other than the ones it made) and adds a point ROI every
/// millimetre along the straight line from the second to the first, each on
/// the slice nearest to it. The points it adds are named "generated".
public final class PointsToLinePlugin: IsiXPlugin, CustomStringConvertible {
    static let generatedName = "generated"

    private let log = Logger(subsystem: "org.isix.pilot.points-to-line", category: "pilot")
    private let journal = Mutex<[String]>([])

    public nonisolated var description: String { journal.withLock { $0.joined(separator: "\n") } }

    public init() {}

    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    public func activate(with context: IsiXPluginContext) throws {
        try context.register(IsiXCommand(id: "points-to-line", title: "PointsToLine",
                                         placement: .roiTools, requirement: .viewer)) { [weak self] invocation in
            guard let viewer = invocation.viewer else { throw IsiXPluginError.viewerClosed }
            try self?.run(viewer)
        }
        note("activated \(context.info.identifier) \(context.info.version)")
    }

    private func note(_ line: String) {
        journal.withLock { $0.append(line) }
        log.notice("PointsToLine: \(line, privacy: .public)")
    }

    func run(_ viewer: IsiXViewer) throws {
        let series = try viewer.series()
        let phase = series.currentPhase
        var geometries: [IsiXImageGeometry] = []
        var points: [IsiXROI] = []
        for slice in 0..<series.sliceCount {
            geometries.append(try viewer.geometry(slice: slice, phase: phase))
            points += try viewer.rois(slice: slice, phase: phase).filter { $0.kind == .point && $0.name != Self.generatedName }
        }
        guard points.count >= 2, let first = points[0].patientPoints.first, let second = points[1].patientPoints.first else {
            throw Failure(reason: "PointsToLine needs two point ROIs in the series.")
        }
        let placements = LinePoints.placements(from: second, to: first, geometries: geometries)
        for placement in placements {
            _ = try viewer.addROI(IsiXROIDraft(kind: .point, points: [placement.pixel], name: Self.generatedName,
                                               slice: placement.slice, phase: phase))
        }
        viewer.setNeedsDisplay()
        let distance = (first - second).length
        let worstPlane = placements.map { abs($0.distanceFromPlane) }.max() ?? 0
        note(String(format: "line %.4f mm from slice %d to slice %d: %d points on slices %d-%d, largest distance to the slice plane %.4f mm",
                    distance, points[1].slice, points[0].slice, placements.count,
                    placements.map(\.slice).min() ?? -1, placements.map(\.slice).max() ?? -1, worstPlane))
    }
}
