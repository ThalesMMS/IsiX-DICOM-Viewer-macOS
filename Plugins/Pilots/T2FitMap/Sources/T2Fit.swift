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

/// The mono-exponential T2 fit, apart from the viewer and the plugin API.
///
/// Per pixel, a least-squares line through ln(max(S - background, 1)) against
/// the echo time in seconds; T2 in milliseconds is 1000 / -slope, capped at
/// 2000 ms, and 0 where the signal does not decay (slope >= 0) or the fit is
/// undefined. Echoes with a non-positive echo time are left out.
enum T2Fit {
    static let cap = 2000.0
    static let factor = 1000.0

    struct Failure: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// Slope and intercept of the least-squares line, or nil when undefined.
    static func line(x: [Double], y: [Double]) -> (slope: Double, intercept: Double)? {
        let count = min(x.count, y.count)
        guard count >= 2 else { return nil }
        var sumX = 0.0, sumXX = 0.0, sumXY = 0.0, sumY = 0.0
        for index in 0..<count {
            guard x[index].isFinite, y[index].isFinite else { return nil }
            sumX += x[index]
            sumXX += x[index] * x[index]
            sumXY += x[index] * y[index]
            sumY += y[index]
        }
        let n = Double(count)
        let denominator = n * sumXX - sumX * sumX
        guard denominator != 0, denominator.isFinite else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denominator
        let intercept = (sumY * sumXX - sumX * sumXY) / denominator
        guard slope.isFinite, intercept.isFinite else { return nil }
        return (slope, intercept)
    }

    /// T2 in milliseconds of one pixel's echo signals.
    static func t2(signals: [Double], echoTimes: [Double], background: Double = 0) -> Double {
        var x: [Double] = []
        var y: [Double] = []
        for (signal, te) in zip(signals, echoTimes) where te > 0 && signal.isFinite {
            x.append(te / 1000)
            y.append(log(max(signal - background, 1)))
        }
        guard x.count >= 2, let fit = line(x: x, y: y), fit.slope < 0 else { return 0 }
        let value = min(factor / -fit.slope, cap)
        return value.isFinite ? value : 0
    }

    /// The T2 map of one location: `echoes[e][pixel]` with `echoTimes[e]` in ms.
    /// Checks `isCancelled` every row and stops with `CancellationError`.
    static func map(echoes: [[Float]], echoTimes: [Double], width: Int, height: Int,
                    isCancelled: () -> Bool = { false }) throws -> [Float] {
        let count = width * height
        guard width > 0, height > 0 else { throw Failure(reason: "T2 Fit Map needs a non-empty multi-echo series.") }
        guard echoes.count >= 2 else { throw Failure(reason: "T2 Fit Map needs at least two echoes at each location.") }
        guard echoTimes.count == echoes.count, echoTimes.filter({ $0 > 0 }).count >= 2 else {
            throw Failure(reason: "T2 Fit Map needs at least two positive echo times (TE).")
        }
        guard echoes.allSatisfy({ $0.count == count }) else {
            throw Failure(reason: "T2 Fit Map frames must share the same width and height.")
        }
        var result = [Float](repeating: 0, count: count)
        var signals = [Double](repeating: 0, count: echoes.count)
        for row in 0..<height {
            if isCancelled() { throw CancellationError() }
            for column in 0..<width {
                let pixel = row * width + column
                for echo in echoes.indices { signals[echo] = Double(echoes[echo][pixel]) }
                result[pixel] = Float(t2(signals: signals, echoTimes: echoTimes))
            }
        }
        return result
    }

    /// The echoes of each location. A 4D series has its echoes as phases: one
    /// location per slice. Otherwise the slices that share an image position
    /// (within 1e-4 mm) are the echoes of one location, in series order; when
    /// some location would have a single image, the whole series is taken as
    /// the echoes of one location.
    static func locations(sliceCount: Int, phaseCount: Int,
                          position: (Int) -> (Double, Double, Double)) -> [[(slice: Int, phase: Int)]] {
        if phaseCount > 1 {
            return (0..<sliceCount).map { slice in (0..<phaseCount).map { (slice, $0) } }
        }
        var origins: [(Double, Double, Double)] = []
        var groups: [[(slice: Int, phase: Int)]] = []
        for slice in 0..<sliceCount {
            let origin = position(slice)
            if let index = origins.firstIndex(where: { abs($0.0 - origin.0) < 1e-4 && abs($0.1 - origin.1) < 1e-4 && abs($0.2 - origin.2) < 1e-4 }) {
                groups[index].append((slice, 0))
            } else {
                origins.append(origin)
                groups.append([(slice, 0)])
            }
        }
        if groups.contains(where: { $0.count < 2 }) {
            return [(0..<sliceCount).map { ($0, 0) }]
        }
        return groups
    }
}
