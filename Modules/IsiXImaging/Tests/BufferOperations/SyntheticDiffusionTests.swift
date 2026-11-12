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
import simd
@testable import IsiXImaging

// The diffusion-weighted image computed at a b-value that was not acquired:
// the fit of each voxel against signals made from a known decay, the images
// of each slice, the numbers of the dialog and the pixels stored.

/// The signal of a tissue of `adc` mm²/s whose signal without diffusion
/// weighting is `s0`, at `b` s/mm².
private func signal(_ s0: Double, _ adc: Double, _ b: Double) -> Float {
    Float(s0 * exp(-b * adc))
}

private func acquisitions(_ bValues: [Double], _ voxels: [(s0: Double, adc: Double)]) -> [SyntheticDiffusion.Acquisition] {
    bValues.map { b in SyntheticDiffusion.Acquisition(bValue: b, samples: voxels.map { signal($0.s0, $0.adc, b) }) }
}

struct SyntheticDiffusionTests {
    // Prostate-like tissues: normal peripheral zone, a restricted lesion, fluid.
    private let voxels: [(s0: Double, adc: Double)] = [(1200, 0.0016), (900, 0.0006), (2000, 0.0030)]

    // MARK: The fit

    @Test func aMonoExponentialDecayIsRecoveredAtTheBValueAskedFor() throws {
        for bValues in [[0.0, 800], [50.0, 800], [0.0, 50, 800], [0.0, 50, 400, 800, 1000]] {
            let image = try SyntheticDiffusion.image(of: acquisitions(bValues, voxels), pixels: voxels.count, at: 1600).get()
            for (index, voxel) in voxels.enumerated() {
                let expected = signal(voxel.s0, voxel.adc, 1600)
                #expect(abs(image[index] - expected) <= max(0.01, expected * 1e-3), "\(bValues) voxel \(index)")
            }
        }
    }

    @Test func twoBValuesGiveTheTwoPointFormula() throws {
        let low: Float = 1000, high: Float = 400
        let image = try SyntheticDiffusion.image(of: [.init(bValue: 0, samples: [low]), .init(bValue: 800, samples: [high])],
                                                 pixels: 1, at: 1600).get()
        let adc = log(Double(low) / Double(high)) / 800
        #expect(abs(Double(image[0]) - Double(low) * exp(-1600 * adc)) < 1e-2)
        // b1600 is as far from b800 as b800 is from b0: the same ratio again.
        #expect(abs(image[0] - high * high / low) < 1e-2)
    }

    @Test func theImageAtAnAcquiredBValueOfAnExactDecayIsThatImage() throws {
        let acquired = acquisitions([0, 50, 800], voxels)
        let image = try SyntheticDiffusion.image(of: acquired, pixels: voxels.count, at: 800).get()
        for index in voxels.indices {
            #expect(abs(image[index] - acquired[2].samples[index]) < 0.05)
        }
    }

    @Test func aBValueBelowTheAcquiredOnesIsExtrapolatedToo() throws {
        let image = try SyntheticDiffusion.image(of: acquisitions([50, 800], voxels), pixels: voxels.count, at: 0).get()
        for (index, voxel) in voxels.enumerated() {
            #expect(abs(image[index] - Float(voxel.s0)) < Float(voxel.s0) * 1e-3)
        }
    }

    @Test func theOrderOfTheImagesDoesNotMatter() throws {
        let ordered = acquisitions([0, 50, 800], voxels), shuffled = [ordered[2], ordered[0], ordered[1]]
        let first = try SyntheticDiffusion.image(of: ordered, pixels: voxels.count, at: 1400).get()
        let second = try SyntheticDiffusion.image(of: shuffled, pixels: voxels.count, at: 1400).get()
        for index in voxels.indices { #expect(abs(first[index] - second[index]) < 1e-3) }
    }

    @Test func aSignalThatRisesWithTheBValueDoesNotGrowBeyondWhatWasMeasured() throws {
        // Noise: 4 at b0, 9 at b800. A line through them would give 20 at b1600.
        let image = try SyntheticDiffusion.image(of: [.init(bValue: 0, samples: [4]), .init(bValue: 800, samples: [9])],
                                                 pixels: 1, at: 1600).get()
        #expect(abs(image[0] - 6) < 1e-3) // the geometric mean, an ADC of 0
        #expect(image[0] <= 9)
    }

    @Test func aVoxelWithoutTwoPositiveSignalsAtDifferentBValuesIsZero() throws {
        let image = try SyntheticDiffusion.image(of: [.init(bValue: 0, samples: [0, 500, 300, -3, .nan, 200]),
                                                      .init(bValue: 800, samples: [0, 0, 0, 100, 100, 80]),
                                                      .init(bValue: 800, samples: [0, 0, 120, 90, 100, 90])],
                                                 pixels: 6, at: 1600).get()
        // Nothing; one signal; one at b0 and one at b800; two, both at b800; the same; all three.
        #expect(image[0] == 0 && image[1] == 0)
        #expect(image[2] > 0)
        #expect(image[3] == 0 && image[4] == 0)
        #expect(image[5] > 0 && image[5] < 90)
    }

    @Test func repeatedBValuesAreAveragedByTheFit() throws {
        // Three directions at b800, 380, 400 and 421 (their geometric mean is 400).
        let image = try SyntheticDiffusion.image(of: [.init(bValue: 0, samples: [1000]), .init(bValue: 800, samples: [380]),
                                                      .init(bValue: 800, samples: [400]), .init(bValue: 800, samples: [421])],
                                                 pixels: 1, at: 1600).get()
        #expect(abs(image[0] - 160) < 0.5)
    }

    @Test func aSliceThatCannotBeFittedIsRefused() {
        typealias Acquisition = SyntheticDiffusion.Acquisition
        #expect(SyntheticDiffusion.image(of: [], pixels: 4, at: 1600) == .failure(.noImages))
        #expect(SyntheticDiffusion.image(of: [Acquisition(bValue: 0, samples: [1, 2])], pixels: 0, at: 1600) == .failure(.noImages))
        #expect(SyntheticDiffusion.image(of: [Acquisition(bValue: 0, samples: [1, 2]), Acquisition(bValue: 800, samples: [1])],
                                         pixels: 2, at: 1600) == .failure(.sizeMismatch))
        #expect(SyntheticDiffusion.image(of: [Acquisition(bValue: 800, samples: [1, 2]), Acquisition(bValue: 800, samples: [1, 2])],
                                         pixels: 2, at: 1600) == .failure(.tooFewBValues))
        #expect(SyntheticDiffusion.image(of: [Acquisition(bValue: 800, samples: [1, 2])], pixels: 2, at: 1600) == .failure(.tooFewBValues))
    }

    @Test func theTemplateIsTheImageAtTheHighestBValue() {
        #expect(SyntheticDiffusion.template(of: [0, 50, 800]) == 2)
        #expect(SyntheticDiffusion.template(of: [1000, 0, 500]) == 0)
        #expect(SyntheticDiffusion.template(of: []) == nil)
    }

    // MARK: The images of each slice

    @Test func aFourDimensionalViewerHasOneImageOfEachSlicePerFrame() {
        let slices = SyntheticDiffusion.slices(movieCount: 3, sliceCount: 2)
        #expect(slices.count == 2)
        #expect(slices[1].map(\.movie) == [0, 1, 2] && slices[1].allSatisfy { $0.slice == 1 })
    }

    @Test func aSingleStackIsPairedByPosition() throws {
        // Three b-values over two positions, stacked b-value after b-value, then position after position.
        let first = SIMD3<Double>(0, 0, 0), second = SIMD3<Double>(0, 0, 5)
        for origins in [[first, second, first, second, first, second], [first, first, first, second, second, second]] {
            let slices = try SyntheticDiffusion.slices(origins: origins).get()
            #expect(slices.count == 2 && slices.allSatisfy { $0.count == 3 })
            for slice in slices {
                #expect(Set(slice.map { origins[$0.slice] }).count == 1)
            }
        }
    }

    @Test func aStackWithAnUnpairedPositionIsRefused() {
        let origins = [SIMD3<Double>(0, 0, 0), SIMD3<Double>(0, 0, 5), SIMD3<Double>(0, 0, 0)]
        #expect(SyntheticDiffusion.slices(origins: origins) == .failure(.unpairedPositions))
        #expect(SyntheticDiffusion.slices(origins: (0..<4).map { SIMD3<Double>(0, 0, Double($0)) }) == .failure(.unpairedPositions))
        #expect(SyntheticDiffusion.slices(origins: []) == .failure(.noImages))
    }

    // MARK: The dialog's numbers

    @Test func bValuesAreReadFromALineOfNumbers() {
        #expect(SyntheticDiffusion.bValues(in: "0, 50, 800") == [0, 50, 800])
        #expect(SyntheticDiffusion.bValues(in: " 0;50 800 ") == [0, 50, 800])
        #expect(SyntheticDiffusion.bValues(in: "62.5,1000") == [62.5, 1000])
        for refused in ["", "  ", "0, ?, 800", "0, -50", "b800", "1e3", "0,5,0x10", "٠"] {
            #expect(SyntheticDiffusion.bValues(in: refused) == nil, "\(refused)")
        }
        #expect(SyntheticDiffusion.bValue(in: " 1600 ") == 1600)
        #expect(SyntheticDiffusion.bValue(in: "1600 s/mm") == nil)
        #expect(SyntheticDiffusion.bValue(in: "") == nil)
    }

    @Test func bValuesAreWrittenAsTheyAreRead() {
        #expect(SyntheticDiffusion.text(of: [0, 50, 800]) == "0, 50, 800")
        #expect(SyntheticDiffusion.text(of: [0, nil, 62.5]) == "0, ?, 62.5")
        #expect(SyntheticDiffusion.bValues(in: SyntheticDiffusion.text(of: [0, 50, 1000.5])) == [0, 50, 1000.5])
        #expect(SyntheticDiffusion.seriesName(bValue: 1600) == "Synthetic DWI b1600")
        #expect(SyntheticDiffusion.seriesName(bValue: 62.5) == "Synthetic DWI b62.5")
        #expect(SyntheticDiffusion.derivationDescription(target: 1600, from: [800, 0, 50, 800])
                == "Synthetic DWI b=1600 s/mm2, mono-exponential fit of b=0, 50, 800")
    }

    @Test func aSequenceNameThatCarriesABValueCarriesTheComputedOne() {
        #expect(SyntheticDiffusion.sequenceName("*ep_b1000t", at: 1600) == "*ep_b1600t")
        #expect(SyntheticDiffusion.sequenceName("ep_b0", at: 1400.4) == "ep_b1400")
        #expect(SyntheticDiffusion.sequenceName("ep2d_diff", at: 1600) == nil)
        #expect(BValueSplit.sequenceNameBValue(SyntheticDiffusion.sequenceName("*ep_b800t", at: 1600)) == 1600)
    }

    // MARK: Storage

    @Test func usualSignalsAreStoredRoundedWithASlopeOfOne() {
        #expect(SyntheticDiffusion.storedSlope(maximum: 100) == 1)
        #expect(SyntheticDiffusion.storedSlope(maximum: 2500) == 1)
        #expect(SyntheticDiffusion.storedSlope(maximum: 65535) == 1)
        #expect(SyntheticDiffusion.storedSlope(maximum: 0) == 1)
        #expect(SyntheticDiffusion.storedSlope(maximum: .nan) == 1)
        #expect(SyntheticDiffusion.stored([0, 0.4, 0.5, 159.6, 70000, -3, .nan, .infinity], slope: 1) == [0, 0, 1, 160, 65535, 0, 0, 0])
    }

    @Test func valuesTooLargeOrTooSmallForSixteenBitsAreScaled() {
        #expect(SyntheticDiffusion.storedSlope(maximum: 70000) == 10)
        #expect(SyntheticDiffusion.storedSlope(maximum: 3_000_000) == 100)
        // The smallest slope that still holds the highest value.
        #expect(abs(SyntheticDiffusion.storedSlope(maximum: 99) - 0.01) < 1e-9)
        #expect(abs(SyntheticDiffusion.storedSlope(maximum: 3.5) - 0.0001) < 1e-9)
        #expect(abs(SyntheticDiffusion.storedSlope(maximum: 0.002) - 0.0001) < 1e-9)
        for maximum: Float in [70000, 3_000_000, 99, 3.5, 6.6] {
            let slope = SyntheticDiffusion.storedSlope(maximum: maximum)
            let stored = SyntheticDiffusion.stored([maximum, maximum / 2], slope: slope)
            #expect(Float(stored[0]) * slope <= maximum * 1.001 && Float(stored[0]) * slope >= maximum * 0.99, "\(maximum)")
            #expect(stored[0] > 600, "\(maximum)")
        }
    }
}
