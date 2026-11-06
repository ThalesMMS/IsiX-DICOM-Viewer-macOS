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

/// The time-attenuation curve of one ROI over the phases of a 4D series.
struct EnhancementCurve: Sendable, Equatable {
    struct Sample: Sendable, Equatable {
        /// Seconds since the first phase was acquired, or the phase index when
        /// the images carry no acquisition time.
        var time: Double
        var minimum: Double
        var mean: Double
        var maximum: Double
    }

    var roi: IsiXROIID
    var name: String
    var samples: [Sample]

    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// The ROIs a curve is drawn for: the closed shapes with an area.
    static func measurable(_ roi: IsiXROI) -> Bool {
        switch roi.kind {
        case .rectangle, .oval, .polygon, .brush: return true
        default: return false
        }
    }

    /// The time of each phase: acquisition times relative to the first phase
    /// when every phase has one, otherwise 0, 1, 2, ...
    static func times(_ dates: [Date?]) -> [Double] {
        guard let first = dates.first ?? nil, dates.allSatisfy({ $0 != nil }) else {
            return dates.indices.map(Double.init)
        }
        return dates.map { $0!.timeIntervalSince(first) }
    }

    /// The curves of the measurable ROIs of the viewer's current slice, from
    /// the application's statistics of each ROI laid on that slice in every phase.
    @MainActor
    static func curves(in viewer: IsiXViewer) throws -> [EnhancementCurve] {
        let series = try viewer.series()
        guard series.phaseCount >= 2 else {
            throw Failure(reason: "ROI Enhancement needs a dynamic (4D) series with at least two phases.")
        }
        let slice = series.currentSlice
        let rois = try viewer.rois(slice: slice, phase: series.currentPhase).filter(measurable)
        var curves: [EnhancementCurve] = []
        let dates = try (0..<series.phaseCount).map { try viewer.attributes(slice: slice, phase: $0).acquisitionDate }
        let times = times(dates)
        for roi in rois {
            var samples: [Sample] = []
            for phase in 0..<series.phaseCount {
                let statistics = try viewer.statistics(of: roi.id, slice: slice, phase: phase)
                samples.append(Sample(time: times[phase], minimum: statistics.minimum, mean: statistics.mean, maximum: statistics.maximum))
            }
            // A ROI without area measures nothing.
            if let area = try viewer.statistics(of: roi.id).area, area > 0 {
                curves.append(EnhancementCurve(roi: roi.id, name: roi.name.isEmpty ? "ROI" : roi.name, samples: samples))
            }
        }
        guard !curves.isEmpty else { throw Failure(reason: "ROI Enhancement needs at least one ROI with area on the current slice.") }
        return curves
    }
}
