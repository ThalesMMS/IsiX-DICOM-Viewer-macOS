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
import Testing
@testable import IsiXImaging

// The T1 fit on synthetic curves of known T1: the inversion recovery
// magnitudes |A − B·exp(−TI/T1)| and the spoiled gradient echo signals
// M0·sinα·(1 − E1)/(1 − cosα·E1), E1 = exp(−TR/T1), with and without noise,
// the voxels that fail and how they are counted, the choice of the method
// from the images' acquisition, and the reading of that acquisition from a
// classic or an enhanced MR data set.

private let inversionTimes: [Double] = [50, 100, 200, 400, 800, 1600, 3200]
private let flipAngles: [Double] = [2, 5, 10, 15, 20]
private let repetitionTime = 15.0

private func inversionRecovery(t1: Double, a: Double = 1000, b: Double = 2000, times: [Double] = inversionTimes) -> [Double] {
    times.map { abs(a - b * exp(-$0 / t1)) }
}

private func spoiledGradientEcho(t1: Double, m0: Double = 1000, angles: [Double] = flipAngles, tr: Double = repetitionTime) -> [Double] {
    let e1 = exp(-tr / t1)
    return angles.map { angle in
        let radians = angle * .pi / 180
        return m0 * sin(radians) * (1 - e1) / (1 - cos(radians) * e1)
    }
}

/// A repeatable noise of standard deviation about `sigma`: the sum of twelve
/// uniform draws of a linear congruential generator, centred.
private struct Noise {
    var state: UInt64
    mutating func next(_ sigma: Double) -> Double {
        var sum = 0.0
        for _ in 0..<12 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            sum += Double(state >> 11) / Double(1 << 53)
        }
        return (sum - 6) * sigma
    }
}

private func relativeError(_ value: Double, _ expected: Double) -> Double { abs(value - expected) / expected }

struct T1FittingTests {

    // MARK: Inversion recovery

    @Test(arguments: [100.0, 300, 800, 1500, 3000])
    func inversionRecoveryRecoversT1(_ t1: Double) throws {
        let model = T1Fitting.InversionRecovery(inversionTimes: inversionTimes)
        let fit = try model.fit(inversionRecovery(t1: t1)).get()
        #expect(relativeError(fit.t1, t1) < 1e-4, "T1 \(t1): \(fit.t1)")
        #expect(relativeError(fit.a, 1000) < 1e-4)
        #expect(relativeError(fit.b, 2000) < 1e-4)
    }

    @Test func inversionRecoveryRestoresPolarityWithAnImperfectInversion() throws {
        // B = 1.7·A, the null point between two samples, and the times in no order.
        let times: [Double] = [3200, 50, 800, 400, 100, 1600, 200]
        let fit = try T1Fitting.InversionRecovery(inversionTimes: times)
            .fit(inversionRecovery(t1: 600, a: 800, b: 1360, times: times)).get()
        #expect(relativeError(fit.t1, 600) < 1e-4)
        #expect(relativeError(fit.b / fit.a, 1.7) < 1e-4)
    }

    @Test func inversionRecoveryWithANullAtASample() throws {
        // TI = T1·ln 2 is the null of a perfect inversion: that sample is 0.
        let t1 = 400 / log(2.0)
        let fit = try T1Fitting.InversionRecovery(inversionTimes: inversionTimes).fit(inversionRecovery(t1: t1)).get()
        #expect(relativeError(fit.t1, t1) < 1e-4)
    }

    @Test func inversionRecoveryWithNoise() throws {
        var noise = Noise(state: 1)
        let model = T1Fitting.InversionRecovery(inversionTimes: inversionTimes)
        for t1 in [300.0, 800, 1500] {
            let samples = inversionRecovery(t1: t1).map { abs($0 + noise.next(10)) }
            let fit = try model.fit(samples).get()
            #expect(relativeError(fit.t1, t1) < 0.05, "T1 \(t1): \(fit.t1)")
        }
    }

    @Test func inversionRecoveryOutsideTheBounds() {
        let model = T1Fitting.InversionRecovery(inversionTimes: inversionTimes + [12_000, 30_000])
        let samples = inversionRecovery(t1: 20_000, times: inversionTimes + [12_000, 30_000])
        #expect(model.fit(samples).map { $0.t1 } == .failure(.outOfBounds))
    }

    @Test func inversionRecoveryNeedsThreeFiniteSamples() {
        let model = T1Fitting.InversionRecovery(inversionTimes: [100, 400, 1600])
        #expect(model.fit([500, .nan, 900]).map { $0.t1 } == .failure(.belowThreshold))
        #expect(T1Fitting.InversionRecovery(inversionTimes: [100, 400]).fit([500, 900]).map { $0.t1 } == .failure(.belowThreshold))
    }

    // MARK: Variable flip angle

    @Test(arguments: [300.0, 800, 1500, 3000])
    func variableFlipAngleRecoversT1(_ t1: Double) throws {
        let model = T1Fitting.VariableFlipAngle(flipAnglesDegrees: flipAngles, repetitionTime: repetitionTime)
        let signals = spoiledGradientEcho(t1: t1)
        let linear = try #require(model.despot1(signals))
        #expect(relativeError(linear.t1, t1) < 1e-6, "DESPOT1 is exact without noise")
        let fit = try model.fit(signals).get()
        #expect(relativeError(fit.t1, t1) < 1e-6)
        #expect(relativeError(fit.m0, 1000) < 1e-6)
    }

    @Test func variableFlipAngleWithTwoAngles() throws {
        let fit = try T1Fitting.VariableFlipAngle(flipAnglesDegrees: [3, 17], repetitionTime: 10)
            .fit(spoiledGradientEcho(t1: 1200, angles: [3, 17], tr: 10)).get()
        #expect(relativeError(fit.t1, 1200) < 1e-6)
    }

    @Test func variableFlipAngleRefinesTheLinearFitUnderNoise() throws {
        var noise = Noise(state: 7)
        let model = T1Fitting.VariableFlipAngle(flipAnglesDegrees: flipAngles, repetitionTime: repetitionTime)
        for t1 in [500.0, 1000, 2000] {
            let signals = spoiledGradientEcho(t1: t1).map { $0 + noise.next(0.2) }
            let fit = try model.fit(signals).get()
            #expect(relativeError(fit.t1, t1) < 0.05, "T1 \(t1): \(fit.t1)")
            // The refined fit leaves no larger a residual than DESPOT1's.
            let linear = try #require(model.despot1(signals))
            func residual(_ t1: Double, _ m0: Double) -> Double {
                zip(signals, spoiledGradientEcho(t1: t1, m0: m0)).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
            }
            #expect(residual(fit.t1, fit.m0) <= residual(linear.t1, linear.m0) * (1 + 1e-9))
        }
    }

    @Test func variableFlipAngleStartsFromTheGridWithoutALinearFit() throws {
        let model = T1Fitting.VariableFlipAngle(flipAnglesDegrees: flipAngles, repetitionTime: repetitionTime)
        // Signals that grow as sin²α give a DESPOT1 slope above 1.
        let growing = flipAngles.map { 1000 * pow(sin($0 * .pi / 180), 2) }
        #expect(model.despot1(growing) == nil)
        switch model.fit(growing) {
        case .success(let fit): #expect(T1Fitting.t1BoundsMilliseconds.contains(fit.t1))
        case .failure(let failure): #expect(failure != .belowThreshold)
        }
    }

    // MARK: The fit itself

    @Test func levenbergMarquardtGivesUpAMinimumAtInfinity() {
        // 1/p against 0: every step lowers the cost, none reaches a minimum.
        let outcome = LevenbergMarquardt.minimize(start: SIMD3(1, 0, 0), parameterCount: 2, observed: [0, 0],
                                                  isAdmissible: { $0.x > 0 }) { p, _ in
            (1 / p.x, SIMD3(-1 / (p.x * p.x), 0, 0))
        }
        #expect(!outcome.converged)
    }

    // MARK: Choosing the method

    @Test func theMethodComesFromTheAcquisition() {
        typealias A = T1Fitting.Acquisition
        let ir = [100.0, 400, 1600].map { A(inversionTime: $0, repetitionTime: 5000, flipAngle: 90) }
        #expect(T1Fitting.method(for: ir) == .inversionRecovery)
        let twoTimes = [100.0, 400, 400].map { A(inversionTime: $0, repetitionTime: 5000, flipAngle: 90) }
        #expect(T1Fitting.method(for: twoTimes) == nil)
        let vfa = [3.0, 17].map { A(repetitionTime: 15, flipAngle: $0) }
        #expect(T1Fitting.method(for: vfa) == .variableFlipAngle)
        // A VFA series with one inversion time on every image is still VFA.
        let vfaWithTI = [3.0, 10, 17].map { A(inversionTime: 0, repetitionTime: 15, flipAngle: $0) }
        #expect(T1Fitting.method(for: vfaWithTI) == .variableFlipAngle)
        let twoRepetitions = [A(repetitionTime: 15, flipAngle: 3), A(repetitionTime: 20, flipAngle: 17)]
        #expect(T1Fitting.method(for: twoRepetitions) == nil)
        let oneAngle = [A(repetitionTime: 15, flipAngle: 10), A(repetitionTime: 15, flipAngle: 10)]
        #expect(T1Fitting.method(for: oneAngle) == nil)
        let missingAngle = [A(repetitionTime: 15, flipAngle: 3), A(repetitionTime: 15)]
        #expect(T1Fitting.method(for: missingAngle) == nil)
        #expect(T1Fitting.method(for: []) == nil)
    }

    // MARK: Reading the acquisition

    @Test func decimalStringsAreRead() {
        #expect(T1Fitting.decimal(" 15.5 ") == 15.5)
        #expect(T1Fitting.decimal("900\\1200") == 900)
        #expect(T1Fitting.decimal("") == nil)
        #expect(T1Fitting.decimal(nil) == nil)
        #expect(T1Fitting.decimal("abc") == nil)
    }

    @Test func aClassicImageGivesItsOwnAttributes() {
        let dataset = FakeDataset(["InversionTime": "900 ", "RepetitionTime": NSNumber(value: 5000.0), "FlipAngle": "90"])
        #expect(T1Fitting.acquisition(in: dataset, frame: 0)
                == T1Fitting.Acquisition(inversionTime: 900, repetitionTime: 5000, flipAngle: 90))
        #expect(T1Fitting.acquisition(in: FakeDataset(), frame: 0) == T1Fitting.Acquisition())
    }

    @Test func anEnhancedImageGivesItsFrameThenTheSharedAttributes() {
        let frames = [150.0, 600].map { time in
            FakeDataset(sequences: ["MRModifierSequence": [FakeDataset(["InversionTimes": NSNumber(value: time)])]])
        }
        let shared = FakeDataset(sequences: ["MRTimingAndRelatedParametersSequence": [
            FakeDataset(["RepetitionTime": "6000", "FlipAngle": NSNumber(value: 180.0)])]])
        let dataset = FakeDataset(sequences: ["Per-frameFunctionalGroupsSequence": frames,
                                              "SharedFunctionalGroupsSequence": [shared]])
        #expect(T1Fitting.acquisition(in: dataset, frame: 1)
                == T1Fitting.Acquisition(inversionTime: 600, repetitionTime: 6000, flipAngle: 180))
        #expect(T1Fitting.acquisition(in: dataset, frame: 0).inversionTime == 150)
        #expect(T1Fitting.acquisition(in: dataset, frame: 5).inversionTime == nil)
    }

    // MARK: A slice and a series

    /// A width × height slice of four quadrants of known T1 and a last row of
    /// background, one image per acquisition.
    private func phantom(_ t1s: [Double], width: Int = 8, height: Int = 9,
                         signal: (Double) -> [Double]) -> [[Float]] {
        var images: [[Float]] = []
        for y in 0..<height {
            for x in 0..<width {
                let curve = y == height - 1 ? signal(t1s[0]).map { _ in 0.0 } : signal(t1s[(y < 4 ? 0 : 2) + (x < 4 ? 0 : 1)])
                if images.isEmpty { images = curve.map { _ in [] } }
                for (index, value) in curve.enumerated() { images[index].append(Float(value)) }
            }
        }
        return images
    }

    @Test func anInversionRecoverySliceMapsItsQuadrantsAndCountsTheBackground() throws {
        let t1s = [250.0, 700, 1300, 2400]
        let images = phantom(t1s) { inversionRecovery(t1: $0) }
        let acquisitions = inversionTimes.map { T1Fitting.Acquisition(inversionTime: $0, repetitionTime: 10_000, flipAngle: 90) }
        let slice = try T1Fitting.fitSlice(signals: images, acquisitions: acquisitions, width: 8, height: 9).get()
        #expect(slice.method == .inversionRecovery)
        #expect(slice.counts == T1Fitting.Counts(fitted: 64, belowThreshold: 8))
        for y in 0..<8 {
            for x in 0..<8 {
                let expected = t1s[(y < 4 ? 0 : 2) + (x < 4 ? 0 : 1)]
                #expect(relativeError(Double(slice.t1Milliseconds[y * 8 + x]), expected) < 1e-4)
            }
        }
        #expect(slice.t1Milliseconds[(8 * 8)...].allSatisfy { $0 == 0 })
    }

    @Test func aFlipAngleSliceMapsItsQuadrants() throws {
        let t1s = [400.0, 900, 1600, 2800]
        let images = phantom(t1s) { spoiledGradientEcho(t1: $0) }
        let acquisitions = flipAngles.map { T1Fitting.Acquisition(repetitionTime: repetitionTime, flipAngle: $0) }
        let slice = try T1Fitting.fitSlice(signals: images, acquisitions: acquisitions, width: 8, height: 9).get()
        #expect(slice.method == .variableFlipAngle)
        #expect(slice.counts == T1Fitting.Counts(fitted: 64, belowThreshold: 8))
        #expect(relativeError(Double(slice.t1Milliseconds[0]), 400) < 1e-5)
        #expect(relativeError(Double(slice.t1Milliseconds[7 * 8 + 7]), 2800) < 1e-5)
    }

    @Test func aVoxelUnderTheThresholdOrOutsideTheBoundsIsZeroAndCounted() throws {
        let times = [100.0, 400, 1600, 6400, 25_600]
        let acquisitions = times.map { T1Fitting.Acquisition(inversionTime: $0) }
        let curves = [inversionRecovery(t1: 800, times: times),
                      inversionRecovery(t1: 800, a: 40, b: 80, times: times),   // 4% of the slice's peak
                      inversionRecovery(t1: 30_000, times: times)]
        let images = times.indices.map { index in curves.map { Float($0[index]) } }
        let slice = try T1Fitting.fitSlice(signals: images, acquisitions: acquisitions, width: 3, height: 1).get()
        #expect(slice.counts == T1Fitting.Counts(fitted: 1, belowThreshold: 1, outOfBounds: 1))
        #expect(relativeError(Double(slice.t1Milliseconds[0]), 800) < 1e-4)
        #expect(slice.t1Milliseconds[1] == 0 && slice.t1Milliseconds[2] == 0)
    }

    @Test func aSliceIsRefusedWithoutAMethodOrWithImagesOfAnotherSize() {
        let acquisitions = [T1Fitting.Acquisition(inversionTime: 100), T1Fitting.Acquisition(inversionTime: 400)]
        #expect(T1Fitting.fitSlice(signals: [[1], [2]], acquisitions: acquisitions, width: 1, height: 1).map { $0.method }
                == .failure(.noMethod))
        #expect(T1Fitting.fitSlice(signals: [[1], [2, 3]], acquisitions: acquisitions, width: 1, height: 1).map { $0.method }
                == .failure(.sizeMismatch))
        #expect(T1Fitting.fitSlice(signals: [], acquisitions: [], width: 1, height: 1).map { $0.method } == .failure(.noSeries))
    }

    @Test func aSeriesOfTwoSlicesIsMappedSliceAfterSlice() throws {
        // Seven inversion times stacked per slice, two slice positions, as a
        // single stack: grouped by position as the T2 fit map groups echoes.
        let positions = [SIMD3<Double>(0, 0, 0), SIMD3<Double>(0, 0, 5)]
        var origins: [SIMD3<Double>] = []
        var stack: [T1Fitting.Image] = []
        for time in inversionTimes {
            for (slice, origin) in positions.enumerated() {
                let t1 = slice == 0 ? 500.0 : 1100
                let value = Float(abs(1000 - 2000 * exp(-time / t1)))
                origins.append(origin)
                stack.append(T1Fitting.Image(width: 2, height: 1, acquisition: .init(inversionTime: time), samples: [value, value]))
            }
        }
        let groups = T2FitMapping.groups(origins: origins)
        #expect(groups.count == 2)
        var read: [Int] = []
        let map = try T1Fitting.map(groups: groups, size: (width: 2, height: 1)) { coordinate in
            read.append(coordinate.slice)
            return stack[coordinate.slice]
        }.get()
        #expect(read == groups.flatMap { $0.map(\.slice) })
        #expect(map.templates == [T1Fitting.Coordinate(movie: 0, slice: 0), T1Fitting.Coordinate(movie: 0, slice: 1)])
        #expect(map.methods == [.inversionRecovery, .inversionRecovery])
        #expect(map.counts == T1Fitting.Counts(fitted: 4))
        #expect(map.volume.count == 4)
        #expect(relativeError(Double(map.volume[0]), 500) < 1e-4 && relativeError(Double(map.volume[3]), 1100) < 1e-4)
    }

    @Test func aSeriesStopsAtTheFirstSliceThatCannotBeFitted() {
        let groups = [[T1Fitting.Coordinate(movie: 0, slice: 0), .init(movie: 0, slice: 1)],
                      [.init(movie: 0, slice: 2), .init(movie: 0, slice: 3)]]
        var read: [Int] = []
        let outcome = T1Fitting.map(groups: groups, size: (width: 1, height: 1)) { coordinate in
            read.append(coordinate.slice)
            return T1Fitting.Image(width: 1, height: 1, acquisition: .init(inversionTime: 100), samples: [1])
        }
        #expect(outcome.map { $0.counts } == .failure(.noMethod))
        #expect(read == [0, 1])
        #expect(T1Fitting.map(groups: [], size: (width: 1, height: 1)) { _ in nil }.map { $0.counts } == .failure(.noSeries))
        #expect(T1Fitting.map(groups: groups, size: (width: 1, height: 1)) { _ in
            T1Fitting.Image(width: 2, height: 1, acquisition: .init(), samples: [1, 1])
        }.map { $0.counts } == .failure(.sizeMismatch))
    }
}
