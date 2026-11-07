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
import simd

/// The T1 map of an MR series: which of two acquisitions the series is, the
/// nonlinear fit of every voxel, and the maps of every slice laid one after
/// the other in the single buffer the viewer of the map shows.
///
/// Two acquisitions are fitted, chosen from what the images of a slice carry:
///
/// - inversion recovery, when the images have at least three different
///   inversion times (0018,0082): S(TI) = |A − B·exp(−TI/T1)|. The images are
///   magnitudes, so the sign the signal had before the null point is lost; it
///   is restored by fitting the signed curve A − B·exp(−TI/T1) with the
///   samples before the smallest one negated, and once more with the smallest
///   one negated too, and keeping the fit with the smaller residual;
/// - variable flip angle (spoiled gradient echo, SPGR or FLASH), when they have
///   no such inversion times but at least two different flip angles (0018,1314)
///   at one repetition time (0018,0080): S(α) = M0·sinα·(1 − E1)/(1 − cosα·E1),
///   E1 = exp(−TR/T1). The linearized DESPOT1 fit, S/sinα against S/tanα, a
///   line of slope E1, gives the starting point.
///
/// Each fit is refined by Levenberg–Marquardt on the sum of squared residuals.
/// The inversion recovery fit starts from the best of a grid of T1 values over
/// the bounds, A and B solved exactly for each; the flip angle fit starts from
/// DESPOT1, or from the same grid when DESPOT1 gives no E1 in (0, 1).
///
/// A voxel the fit does not map gets 0 in the map and is counted by its
/// failure (`Failure`): its largest sample below `signalThresholdFraction` of
/// the largest sample of the slice, a fit that does not converge in
/// `maximumIterations`, or a fitted T1 outside `t1BoundsMilliseconds` or with a
/// signal amplitude that is not positive. Times are in milliseconds, angles in
/// degrees, as DICOM gives them.
public enum T1Fitting {

    // MARK: - Rules

    /// The T1 values the map accepts, in milliseconds.
    public static let t1BoundsMilliseconds: ClosedRange<Double> = 1...10_000
    /// The fraction of the slice's largest sample under which a voxel is not fitted.
    public static let signalThresholdFraction = 0.05
    /// The Levenberg–Marquardt steps after which a voxel that has not
    /// converged is given up.
    public static let maximumIterations = 200
    /// Two inversion times or flip angles closer than this are the same one.
    static let distinctTolerance = 1e-3
    /// Two repetition times closer than this fraction of the first are the same one.
    static let repetitionTimeTolerance = 1e-3
    /// The T1 values the starting grid tries: log-spaced over the bounds.
    static let gridSize = 48

    /// The acquisition a slice is fitted as.
    public enum Method: String, Sendable, CaseIterable {
        case inversionRecovery
        case variableFlipAngle
    }

    /// Why a voxel has no T1.
    public enum Failure: Int, Error, Sendable, CaseIterable {
        /// Its largest sample is under the signal threshold, or it has fewer
        /// finite samples than the model has parameters.
        case belowThreshold = 1
        /// Levenberg–Marquardt reached no minimum in `maximumIterations`.
        case notConverged = 2
        /// The fitted T1 is outside `t1BoundsMilliseconds`, or the fitted
        /// signal amplitude (A and B, or M0) is not positive.
        case outOfBounds = 3
    }

    /// The voxels of a map by what became of them.
    public struct Counts: Sendable, Equatable {
        public var fitted = 0
        public var belowThreshold = 0
        public var notConverged = 0
        public var outOfBounds = 0

        public init(fitted: Int = 0, belowThreshold: Int = 0, notConverged: Int = 0, outOfBounds: Int = 0) {
            self.fitted = fitted
            self.belowThreshold = belowThreshold
            self.notConverged = notConverged
            self.outOfBounds = outOfBounds
        }

        public var failed: Int { belowThreshold + notConverged + outOfBounds }
        public var total: Int { fitted + failed }

        public mutating func record(_ result: Result<Double, Failure>) {
            switch result {
            case .success: fitted += 1
            case .failure(.belowThreshold): belowThreshold += 1
            case .failure(.notConverged): notConverged += 1
            case .failure(.outOfBounds): outOfBounds += 1
            }
        }

        public static func + (lhs: Counts, rhs: Counts) -> Counts {
            Counts(fitted: lhs.fitted + rhs.fitted, belowThreshold: lhs.belowThreshold + rhs.belowThreshold,
                   notConverged: lhs.notConverged + rhs.notConverged, outOfBounds: lhs.outOfBounds + rhs.outOfBounds)
        }
    }

    /// What an image says of its acquisition; nil where it says nothing.
    public struct Acquisition: Sendable, Equatable {
        public var inversionTime: Double?
        public var repetitionTime: Double?
        public var flipAngle: Double?

        public init(inversionTime: Double? = nil, repetitionTime: Double? = nil, flipAngle: Double? = nil) {
            self.inversionTime = inversionTime
            self.repetitionTime = repetitionTime
            self.flipAngle = flipAngle
        }
    }

    /// Why a series has no map. The app words each one for the user.
    public enum Refusal: Error, Sendable, Equatable {
        /// No image to fit.
        case noSeries
        /// The images have no pixels, or not the size of the first one.
        case sizeMismatch
        /// The images of a slice have neither three inversion times nor two
        /// flip angles at one repetition time.
        case noMethod
    }

    // MARK: - Choosing the acquisition

    /// The acquisition of a slice's images, or nil when they are neither.
    /// Inversion recovery needs an inversion time on every image, three of
    /// them different; variable flip angle needs a flip angle in (0°, 180°)
    /// and a positive repetition time on every image, two angles different and
    /// one repetition time. An inversion recovery series has one flip angle,
    /// so a series that carries both is the inversion recovery.
    public static func method(for acquisitions: [Acquisition]) -> Method? {
        guard !acquisitions.isEmpty else { return nil }
        let inversionTimes = acquisitions.compactMap { $0.inversionTime }.filter { $0.isFinite && $0 >= 0 }
        if inversionTimes.count == acquisitions.count, distinctCount(inversionTimes) >= 3 {
            return .inversionRecovery
        }
        let angles = acquisitions.compactMap { $0.flipAngle }.filter { $0.isFinite && $0 > 0 && $0 < 180 }
        let repetitions = acquisitions.compactMap { $0.repetitionTime }.filter { $0.isFinite && $0 > 0 }
        if angles.count == acquisitions.count, repetitions.count == acquisitions.count,
           distinctCount(angles) >= 2, let first = repetitions.first,
           repetitions.allSatisfy({ abs($0 - first) <= repetitionTimeTolerance * first }) {
            return .variableFlipAngle
        }
        return nil
    }

    private static func distinctCount(_ values: [Double]) -> Int {
        var seen: [Double] = []
        for value in values.sorted() where seen.last.map({ value - $0 > distinctTolerance }) ?? true {
            seen.append(value)
        }
        return seen.count
    }

    // MARK: - Reading the acquisition

    /// The first value of a decimal string (DS) as DICOM writes it: spaces
    /// around it and further values after a backslash are ignored.
    public static func decimal(_ text: String?) -> Double? {
        guard let first = text?.split(separator: "\\", omittingEmptySubsequences: false).first else { return nil }
        return Double(first.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
    }

    /// The acquisition of frame `frame` of a data set: each value from the
    /// data set itself (a classic image), else from the frame's item of the
    /// per-frame functional groups, else from the shared ones (an enhanced
    /// MR, where inversion times are MR Modifier's Inversion Times and the
    /// repetition time and flip angle MR Timing and Related Parameters').
    public static func acquisition(in dataset: DICOMAttributeSource, frame: Int) -> Acquisition {
        var groups: [DICOMAttributeSource] = []
        if case .items(let frames) = dataset.sequence(named: "Per-frameFunctionalGroupsSequence"),
           frame >= 0, frame < frames.count {
            groups.append(frames[frame])
        }
        if case .items(let shared) = dataset.sequence(named: "SharedFunctionalGroupsSequence"), let first = shared.first {
            groups.append(first)
        }
        func value(_ name: String, top: String, sequence: String) -> Double? {
            if let found = number(dataset.attributeValue(withName: top)) { return found }
            for group in groups {
                if case .items(let items) = group.sequence(named: sequence), let item = items.first,
                   let found = number(item.attributeValue(withName: name)) {
                    return found
                }
            }
            return nil
        }
        return Acquisition(inversionTime: value("InversionTimes", top: "InversionTime", sequence: "MRModifierSequence"),
                           repetitionTime: value("RepetitionTime", top: "RepetitionTime", sequence: "MRTimingAndRelatedParametersSequence"),
                           flipAngle: value("FlipAngle", top: "FlipAngle", sequence: "MRTimingAndRelatedParametersSequence"))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let object = ParsedValue.object(value) else { return nil }
        if let number = object as? NSNumber { return number.doubleValue.isFinite ? number.doubleValue : nil }
        if let text = object as? String { return decimal(text) }
        return nil
    }

    // MARK: - Inversion recovery

    /// The inversion recovery fit of a slice's inversion times: the times in
    /// increasing order and the starting grid, shared by every voxel.
    public struct InversionRecovery: Sendable {
        let order: [Int]
        let times: [Double]
        let grid: [(t1: Double, decays: [Double], sum: Double, sumOfSquares: Double)]

        public init(inversionTimes: [Double]) {
            order = inversionTimes.indices.sorted { inversionTimes[$0] < inversionTimes[$1] }
            let times = order.map { inversionTimes[$0] }
            self.times = times
            grid = T1Fitting.grid.map { t1 in
                let decays = times.map { exp(-$0 / t1) }
                return (t1, decays, decays.reduce(0, +), decays.reduce(0) { $0 + $1 * $1 })
            }
        }

        /// The fit of one voxel's magnitudes, in the order of the inversion
        /// times given: T1 in milliseconds, with A and B.
        public func fit(_ magnitudes: [Double]) -> Result<(t1: Double, a: Double, b: Double), Failure> {
            let samples = order.map { magnitudes.indices.contains($0) ? abs(magnitudes[$0]) : .nan }
            guard samples.count >= 3, samples.allSatisfy(\.isFinite) else { return .failure(.belowThreshold) }
            guard let smallest = samples.indices.min(by: { samples[$0] < samples[$1] }) else { return .failure(.belowThreshold) }

            var best: (parameters: SIMD3<Double>, cost: Double, converged: Bool)?
            for negated in [smallest, smallest + 1] where negated <= samples.count {
                let signed = samples.enumerated().map { $0.offset < negated ? -$0.element : $0.element }
                guard let start = start(signed) else { continue }
                let outcome = LevenbergMarquardt.minimize(start: start, parameterCount: 3, observed: signed,
                                                          isAdmissible: { $0.z > 0 && $0.z < 1e7 }) { p, index in
                    let decay = exp(-times[index] / p.z)
                    return (p.x - p.y * decay, SIMD3(1, -decay, -p.y * decay * times[index] / (p.z * p.z)))
                }
                if best.map({ outcome.cost < $0.cost }) ?? true { best = outcome }
            }
            guard let best else { return .failure(.notConverged) }
            guard best.converged else { return .failure(.notConverged) }
            let (a, b, t1) = (best.parameters.x, best.parameters.y, best.parameters.z)
            guard a > 0, b > 0, t1BoundsMilliseconds.contains(t1) else { return .failure(.outOfBounds) }
            return .success((t1, a, b))
        }

        /// The grid T1 whose exact A and B leave the smallest residual.
        private func start(_ signed: [Double]) -> SIMD3<Double>? {
            let n = Double(signed.count)
            let sumY = signed.reduce(0, +)
            var best: (SIMD3<Double>, Double)?
            for entry in grid {
                var sumYDecay = 0.0
                for index in signed.indices { sumYDecay += signed[index] * entry.decays[index] }
                // y = A − B·e: n·A − Σe·B = Σy and Σe·A − Σe²·B = Σy·e.
                let determinant = entry.sum * entry.sum - n * entry.sumOfSquares
                guard abs(determinant) > 1e-12 else { continue }
                let a = (entry.sum * sumYDecay - entry.sumOfSquares * sumY) / determinant
                let b = (n * sumYDecay - entry.sum * sumY) / determinant
                var cost = 0.0
                for index in signed.indices {
                    let residual = signed[index] - (a - b * entry.decays[index])
                    cost += residual * residual
                }
                if cost.isFinite, best.map({ cost < $0.1 }) ?? true { best = (SIMD3(a, b, entry.t1), cost) }
            }
            return best?.0
        }
    }

    // MARK: - Variable flip angle

    /// The variable flip angle fit of a slice's flip angles at one repetition
    /// time, shared by every voxel.
    public struct VariableFlipAngle: Sendable {
        let repetitionTime: Double
        let sines: [Double]
        let cosines: [Double]
        let grid: [(t1: Double, shapes: [Double], sumOfSquares: Double)]

        public init(flipAnglesDegrees: [Double], repetitionTime: Double) {
            self.repetitionTime = repetitionTime
            let radians = flipAnglesDegrees.map { $0 * .pi / 180 }
            let sines = radians.map { sin($0) }, cosines = radians.map { cos($0) }
            self.sines = sines
            self.cosines = cosines
            grid = T1Fitting.grid.map { t1 in
                let e1 = exp(-repetitionTime / t1)
                let shapes = sines.indices.map { sines[$0] * (1 - e1) / (1 - cosines[$0] * e1) }
                return (t1, shapes, shapes.reduce(0) { $0 + $1 * $1 })
            }
        }

        /// The linearized DESPOT1 fit: S/sinα = E1·S/tanα + M0·(1 − E1), a
        /// line through the samples. Nil when the slope is no E1 in (0, 1).
        public func despot1(_ signals: [Double]) -> (t1: Double, m0: Double)? {
            guard signals.count == sines.count, signals.count >= 2 else { return nil }
            let xs = signals.indices.map { signals[$0] * cosines[$0] / sines[$0] }
            let ys = signals.indices.map { signals[$0] / sines[$0] }
            let n = Double(xs.count)
            let sumX = xs.reduce(0, +), sumY = ys.reduce(0, +)
            let sumXX = xs.reduce(0) { $0 + $1 * $1 }
            let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
            let denominator = n * sumXX - sumX * sumX
            guard abs(denominator) > 1e-12 * max(1, sumXX * n) else { return nil }
            let e1 = (n * sumXY - sumX * sumY) / denominator
            let intercept = (sumY - e1 * sumX) / n
            guard e1.isFinite, e1 > 0, e1 < 1, intercept.isFinite else { return nil }
            return (-repetitionTime / log(e1), intercept / (1 - e1))
        }

        /// The fit of one voxel's signals, in the order of the flip angles
        /// given: T1 in milliseconds, with M0.
        public func fit(_ signals: [Double]) -> Result<(t1: Double, m0: Double), Failure> {
            guard signals.count == sines.count, signals.count >= 2, signals.allSatisfy(\.isFinite) else {
                return .failure(.belowThreshold)
            }
            guard let start = despot1(signals).map({ SIMD3($0.m0, $0.t1, 0) }) ?? gridStart(signals) else {
                return .failure(.notConverged)
            }
            let tr = repetitionTime
            let outcome = LevenbergMarquardt.minimize(start: start, parameterCount: 2, observed: signals,
                                                      isAdmissible: { $0.y > 0 && $0.y < 1e7 }) { p, index in
                let e1 = exp(-tr / p.y)
                let denominator = 1 - cosines[index] * e1
                let shape = sines[index] * (1 - e1) / denominator
                // ∂S/∂E1 = M0·sinα·(cosα − 1)/(1 − cosα·E1)², ∂E1/∂T1 = E1·TR/T1².
                let byE1 = p.x * sines[index] * (cosines[index] - 1) / (denominator * denominator)
                return (p.x * shape, SIMD3(shape, byE1 * e1 * tr / (p.y * p.y), 0))
            }
            guard outcome.converged else { return .failure(.notConverged) }
            let (m0, t1) = (outcome.parameters.x, outcome.parameters.y)
            guard m0 > 0, t1BoundsMilliseconds.contains(t1) else { return .failure(.outOfBounds) }
            return .success((t1, m0))
        }

        /// The grid T1 whose exact M0 leaves the smallest residual.
        private func gridStart(_ signals: [Double]) -> SIMD3<Double>? {
            let sumY2 = signals.reduce(0) { $0 + $1 * $1 }
            var best: (SIMD3<Double>, Double)?
            for entry in grid where entry.sumOfSquares > 0 {
                let sumYShape = zip(signals, entry.shapes).reduce(0) { $0 + $1.0 * $1.1 }
                let m0 = sumYShape / entry.sumOfSquares
                let cost = sumY2 - sumYShape * m0
                if cost.isFinite, best.map({ cost < $0.1 }) ?? true { best = (SIMD3(m0, entry.t1, 0), cost) }
            }
            return best?.0
        }
    }

    /// The starting T1 values, log-spaced from the lower bound to the upper one.
    static let grid: [Double] = {
        let low = log(t1BoundsMilliseconds.lowerBound), high = log(t1BoundsMilliseconds.upperBound)
        return (0..<gridSize).map { exp(low + (high - low) * Double($0) / Double(gridSize - 1)) }
    }()

    // MARK: - A slice

    /// The map of one slice: its acquisition, T1 per voxel (0 where the fit
    /// failed) and the voxels by what became of them.
    public struct SliceFit: Sendable, Equatable {
        public let method: Method
        public let t1Milliseconds: [Float]
        public let counts: Counts
    }

    /// Fits every voxel of a slice whose images are `signals` (one array of
    /// `width` × `height` samples per image) with `acquisitions` in the same
    /// order. Rows are fitted in parallel; the result does not depend on it.
    public static func fitSlice(signals: [[Float]], acquisitions: [Acquisition],
                                width: Int, height: Int) -> Result<SliceFit, Refusal> {
        let pixels = width * height
        guard width > 0, height > 0, !signals.isEmpty else { return .failure(.noSeries) }
        guard signals.count == acquisitions.count, signals.allSatisfy({ $0.count == pixels }) else {
            return .failure(.sizeMismatch)
        }
        guard let method = method(for: acquisitions) else { return .failure(.noMethod) }

        let largest = signals.reduce(0.0) { peak, image in
            image.reduce(peak) { $1.isFinite ? max($0, Double(abs($1))) : $0 }
        }
        let threshold = largest * signalThresholdFraction

        let fitVoxel: @Sendable ([Double]) -> Result<Double, Failure>
        switch method {
        case .inversionRecovery:
            let model = InversionRecovery(inversionTimes: acquisitions.map { $0.inversionTime ?? 0 })
            fitVoxel = { model.fit($0).map { $0.t1 } }
        case .variableFlipAngle:
            let model = VariableFlipAngle(flipAnglesDegrees: acquisitions.map { $0.flipAngle ?? 0 },
                                          repetitionTime: acquisitions[0].repetitionTime ?? 0)
            fitVoxel = { model.fit($0).map { $0.t1 } }
        }

        var map = [Float](repeating: 0, count: pixels)
        var rowCounts = [Counts](repeating: Counts(), count: height)
        map.withUnsafeMutableBufferPointer { output in
            rowCounts.withUnsafeMutableBufferPointer { counts in
                let rows = RowOutputs(t1: output, counts: counts)
                DispatchQueue.concurrentPerform(iterations: height) { row in
                    var samples = [Double](repeating: 0, count: signals.count)
                    var tally = Counts()
                    for column in 0..<width {
                        let pixel = row * width + column
                        var peak = 0.0
                        for image in signals.indices {
                            samples[image] = Double(signals[image][pixel])
                            if samples[image].isFinite { peak = max(peak, abs(samples[image])) }
                        }
                        let result: Result<Double, Failure> = largest > 0 && peak >= threshold
                            ? fitVoxel(samples) : .failure(.belowThreshold)
                        tally.record(result)
                        if case .success(let t1) = result { rows.t1[pixel] = Float(t1) }
                    }
                    rows.counts[row] = tally
                }
            }
        }
        return .success(SliceFit(method: method, t1Milliseconds: map, counts: rowCounts.reduce(Counts(), +)))
    }

    /// The map and the per-row counts of a slice, written by the rows fitted
    /// in parallel. Unchecked: each row writes only its own voxels and its
    /// own count, and both buffers outlive the parallel loop.
    private struct RowOutputs: @unchecked Sendable {
        let t1: UnsafeMutableBufferPointer<Float>
        let counts: UnsafeMutableBufferPointer<Counts>
    }

    // MARK: - A series

    /// An image of the viewer: the slice's image of one inversion time or
    /// flip angle.
    public typealias Coordinate = T2FitMapping.Coordinate

    /// One image as the fit reads it: its size, its acquisition and its
    /// samples (nil when it has none).
    public struct Image: Sendable {
        public let width: Int
        public let height: Int
        public let acquisition: Acquisition
        public let samples: [Float]?

        public init(width: Int, height: Int, acquisition: Acquisition, samples: [Float]?) {
            self.width = width
            self.height = height
            self.acquisition = acquisition
            self.samples = samples
        }
    }

    /// The maps of every slice one after the other, `width` × `height` values
    /// each, the first image of each slice, whose geometry its map takes, the
    /// acquisition of each slice and the voxels of all of them by what became
    /// of them.
    public struct SeriesMap: Sendable, Equatable {
        public let volume: [Float]
        public let width: Int
        public let height: Int
        public let templates: [Coordinate]
        public let methods: [Method]
        public let counts: Counts
    }

    /// Fits every slice of a series whose images are grouped by slice the way
    /// the T2 fit map groups its echoes (`T2FitMapping.groups`). `size` is the
    /// one of the series' first image (nil when it has none); every image must
    /// have it. The images are read one slice at a time, and only while every
    /// slice before it fitted.
    public static func map(groups: [[Coordinate]], size: (width: Int, height: Int)?,
                           image: (Coordinate) -> Image?) -> Result<SeriesMap, Refusal> {
        guard !groups.isEmpty, let size else { return .failure(.noSeries) }
        let (width, height) = size
        guard width > 0, height > 0 else { return .failure(.sizeMismatch) }
        let pixels = width * height

        var volume: [Float] = []
        volume.reserveCapacity(groups.count * pixels)
        var methods: [Method] = []
        var counts = Counts()
        for group in groups {
            var signals: [[Float]] = []
            var acquisitions: [Acquisition] = []
            for coordinate in group {
                guard let read = image(coordinate), read.width == width, read.height == height,
                      let samples = read.samples, samples.count == pixels else {
                    return .failure(.sizeMismatch)
                }
                signals.append(samples)
                acquisitions.append(read.acquisition)
            }
            switch fitSlice(signals: signals, acquisitions: acquisitions, width: width, height: height) {
            case .failure(let refusal):
                return .failure(refusal)
            case .success(let slice):
                volume.append(contentsOf: slice.t1Milliseconds)
                methods.append(slice.method)
                counts = counts + slice.counts
            }
        }
        return .success(SeriesMap(volume: volume, width: width, height: height,
                                  templates: groups.map { $0[0] }, methods: methods, counts: counts))
    }
}

/// A Levenberg–Marquardt minimization of Σ(yᵢ − f(p, i))² over two or three
/// parameters, with Marquardt's scaling of the damping by the diagonal of JᵀJ.
///
/// It has converged when the residual vanishes, when the gradient is
/// orthogonal to the residual (the cosine of every Jacobian column with the
/// residual below 1e-10), when an accepted step changes the cost by less than
/// 1e-14 of it or every parameter by less than 1e-10 of it, or when no step
/// lowers the cost any more and that cosine is below 1e-6. It has not when
/// `T1Fitting.maximumIterations` steps are taken without that, when no step
/// lowers the cost with the gradient still pointing somewhere, or when the
/// model gives a value that is not finite at the start.
enum LevenbergMarquardt {

    static func minimize(start: SIMD3<Double>, parameterCount: Int, observed: [Double],
                         isAdmissible: (SIMD3<Double>) -> Bool,
                         model: (SIMD3<Double>, Int) -> (value: Double, gradient: SIMD3<Double>))
        -> (parameters: SIMD3<Double>, cost: Double, converged: Bool) {
        func cost(_ p: SIMD3<Double>) -> Double? {
            var sum = 0.0
            for index in observed.indices {
                let residual = observed[index] - model(p, index).value
                sum += residual * residual
            }
            return sum.isFinite ? sum : nil
        }
        let active = SIMD3<Double>(1, 1, parameterCount > 2 ? 1 : 0)
        let scale = max(observed.reduce(0) { $0 + $1 * $1 }, .leastNormalMagnitude)
        var parameters = start
        guard isAdmissible(parameters), var current = cost(parameters) else {
            return (start, .infinity, false)
        }
        var lambda = 1e-3

        for _ in 0..<T1Fitting.maximumIterations {
            if current <= 1e-24 * scale { return (parameters, current, true) }
            var normal = simd_double3x3()
            var gradient = SIMD3<Double>()
            for index in observed.indices {
                let (value, row) = model(parameters, index)
                let jacobian = row * active
                let residual = observed[index] - value
                normal += simd_double3x3(columns: (jacobian * jacobian.x, jacobian * jacobian.y, jacobian * jacobian.z))
                gradient += jacobian * residual
            }
            let diagonal = SIMD3(normal[0][0], normal[1][1], normal[2][2])
            var cosine = 0.0
            for k in 0..<parameterCount where diagonal[k] > 0 {
                cosine = max(cosine, abs(gradient[k]) / (diagonal[k] * current).squareRoot())
            }
            if cosine <= 1e-10 { return (parameters, current, true) }

            var stepped = false
            while lambda <= 1e16 {
                var damped = normal
                for k in 0..<3 {
                    damped[k][k] += active[k] > 0 ? lambda * max(diagonal[k], 1e-300) : 1
                }
                let determinant = damped.determinant
                guard determinant.isFinite, determinant != 0 else { lambda *= 10; continue }
                let step = (damped.inverse * gradient) * active
                let candidate = parameters + step
                if step.x.isFinite, step.y.isFinite, step.z.isFinite, isAdmissible(candidate),
                   let next = cost(candidate), next < current {
                    let reduction = (current - next) / current
                    let small = (0..<parameterCount).allSatisfy { abs(step[$0]) <= 1e-10 * (abs(parameters[$0]) + 1e-10) }
                    parameters = candidate
                    current = next
                    lambda = max(lambda / 10, 1e-12)
                    stepped = true
                    if reduction <= 1e-14 || small { return (parameters, current, true) }
                    break
                }
                lambda *= 10
            }
            if !stepped { return (parameters, current, cosine <= 1e-6) }
        }
        return (parameters, current, false)
    }
}
