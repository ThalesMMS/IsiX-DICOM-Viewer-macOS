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

/// A diffusion-weighted image at a b-value that was not acquired, computed
/// from the ones that were.
///
/// Each voxel's signal is taken to fall with the b-value as
/// `S(b) = S0 · exp(−b · ADC)`. Its logarithm is a straight line in b, fitted
/// by least squares over the b-values acquired: the slope gives the ADC and
/// the line, read at the b-value asked for, the signal there. With two
/// b-values the line passes through both, which is the usual two-point
/// formula. The model is the mono-exponential one of a computed DWI; it does
/// not describe perfusion at very low b-values nor kurtosis at very high ones.
///
/// Which images are one slice's, the fit of a slice, the numbers the dialog
/// reads and writes, and how the result is stored as 16-bit pixels are here;
/// the viewer's images and the series written are the application's.
public enum SyntheticDiffusion {

    /// Why a series has no synthetic image.
    public enum Refusal: Error, Equatable, Sendable {
        /// The viewer shows no image.
        case noImages
        /// Images of one slice differ in width or height, or have no pixels.
        case sizeMismatch
        /// A slice has images at fewer than two different b-values.
        case tooFewBValues
        /// An image of a single stack has no other image at its position.
        case unpairedPositions
        /// An image has no b-value.
        case missingBValue
    }

    /// The b-value asked for when none was before, in s/mm².
    public static let defaultBValue = 1600.0

    // MARK: - The images of each slice

    /// The images of each slice in a viewer of several movie frames, one
    /// b-value per frame: for each slice of the first frame, its image in
    /// every frame.
    public static func slices(movieCount: Int, sliceCount: Int) -> [[T2FitMapping.Coordinate]] {
        T2FitMapping.groups(movieCount: movieCount, sliceCount: sliceCount)
    }

    /// The images of each slice in a single stack that holds every b-value,
    /// by the images' origins (equal within 1e-4 mm on each axis), in the
    /// order each position first appears. A position with a single image has
    /// nothing to be fitted with.
    public static func slices(origins: [SIMD3<Double>]) -> Result<[[T2FitMapping.Coordinate]], Refusal> {
        guard !origins.isEmpty else { return .failure(.noImages) }
        var slices: [[T2FitMapping.Coordinate]] = []
        for (index, origin) in origins.enumerated() {
            let coordinate = T2FitMapping.Coordinate(movie: 0, slice: index)
            if let found = slices.firstIndex(where: { sameOrigin(origins[$0[0].slice], origin) }) {
                slices[found].append(coordinate)
            } else {
                slices.append([coordinate])
            }
        }
        return slices.contains { $0.count < 2 } ? .failure(.unpairedPositions) : .success(slices)
    }

    private static func sameOrigin(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
        abs(a.x - b.x) < 1e-4 && abs(a.y - b.y) < 1e-4 && abs(a.z - b.z) < 1e-4
    }

    // MARK: - The fit

    /// One image of a slice: its b-value in s/mm² and its samples.
    public struct Acquisition: Sendable {
        public let bValue: Double
        public let samples: [Float]

        public init(bValue: Double, samples: [Float]) {
            self.bValue = bValue
            self.samples = samples
        }
    }

    /// The image of one slice at the b-value `target`, from its images at
    /// the b-values acquired, each of `pixels` samples.
    ///
    /// A voxel is fitted over its positive signals. With fewer than two of
    /// them at different b-values there is no line, and the voxel is 0. A
    /// signal that rises with the b-value, as noise does, would give a
    /// negative ADC and a computed signal above everything measured: its ADC
    /// is taken as 0, the mean of the logarithms.
    public static func image(of acquisitions: [Acquisition], pixels: Int, at target: Double) -> Result<[Float], Refusal> {
        guard pixels > 0, !acquisitions.isEmpty else { return .failure(.noImages) }
        guard acquisitions.allSatisfy({ $0.samples.count == pixels }) else { return .failure(.sizeMismatch) }
        guard Set(acquisitions.map(\.bValue)).count >= 2 else { return .failure(.tooFewBValues) }

        let bValues = acquisitions.map(\.bValue)
        var image = [Float](repeating: 0, count: pixels)
        for pixel in 0..<pixels {
            var count = 0.0, sumB = 0.0, sumLog = 0.0
            var lowest = Double.infinity, highest = -Double.infinity
            for (index, acquisition) in acquisitions.enumerated() {
                let signal = acquisition.samples[pixel]
                guard signal > 0, signal.isFinite else { continue }
                count += 1
                sumB += bValues[index]
                sumLog += log(Double(signal))
                lowest = min(lowest, bValues[index])
                highest = max(highest, bValues[index])
            }
            guard count >= 2, highest > lowest else { continue }
            let meanB = sumB / count, meanLog = sumLog / count
            var covariance = 0.0, variance = 0.0
            for (index, acquisition) in acquisitions.enumerated() {
                let signal = acquisition.samples[pixel]
                guard signal > 0, signal.isFinite else { continue }
                let distance = bValues[index] - meanB
                covariance += distance * (log(Double(signal)) - meanLog)
                variance += distance * distance
            }
            let coefficient = max(0, -covariance / variance)
            let value = exp(meanLog - coefficient * (target - meanB))
            image[pixel] = value.isFinite ? Float(value) : 0
        }
        return .success(image)
    }

    /// The image of a slice whose header and geometry the synthetic one
    /// takes: the one at the highest b-value, the closest to what is computed.
    public static func template(of bValues: [Double]) -> Int? {
        bValues.indices.max { bValues[$0] < bValues[$1] }
    }

    // MARK: - What the dialog reads and writes

    /// The b-values written in `text`, separated by commas, semicolons or
    /// spaces: nil when it holds none, or anything that is not a number of 0
    /// or more.
    public static func bValues(in text: String) -> [Double]? {
        let words = text.split { $0 == "," || $0 == ";" || $0.isWhitespace }
        guard !words.isEmpty else { return nil }
        var values: [Double] = []
        for word in words {
            guard let value = bValue(in: String(word)) else { return nil }
            values.append(value)
        }
        return values
    }

    /// The b-value written in `text`: a number of 0 or more, nil otherwise.
    public static func bValue(in text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let value = Double(trimmed), value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// `bValues` as the dialog shows them, "0, 50, 800"; one that is not
    /// known leaves a "?" for the user to replace.
    public static func text(of bValues: [Double?]) -> String {
        bValues.map { $0.map(text(of:)) ?? "?" }.joined(separator: ", ")
    }

    /// One b-value without a fraction it does not have: "1600", "62.5".
    public static func text(of bValue: Double) -> String {
        bValue == bValue.rounded() && abs(bValue) < 1e15 ? String(Int64(bValue)) : String(bValue)
    }

    /// The description of the series of the image at `bValue`, until the
    /// user writes another. It goes into the DICOM files as it is.
    public static func seriesName(bValue: Double) -> String {
        "Synthetic DWI b" + text(of: bValue)
    }

    /// What the files say the synthetic image was made from.
    public static func derivationDescription(target: Double, from bValues: [Double]) -> String {
        let acquired = Set(bValues).sorted().map(text(of:)).joined(separator: ", ")
        return "Synthetic DWI b=\(text(of: target)) s/mm2, mono-exponential fit of b=\(acquired)"
    }

    /// Siemens names a diffusion sequence with its b-value ("*ep_b800t"),
    /// and the synthetic image is written over the header of an acquired
    /// one: `name` with the b-value computed in that place, nil when it
    /// carries none and stays as it is.
    public static func sequenceName(_ name: String, at target: Double) -> String? {
        guard let range = name.range(of: #"_b(\d+)"#, options: .regularExpression) else { return nil }
        return name.replacingCharacters(in: range, with: "_b" + text(of: target.rounded()))
    }

    // MARK: - Storage

    /// The rescale slope the image is stored with, as 16-bit unsigned pixels,
    /// from the highest value of the series: 1 for the signals of a usual
    /// diffusion series, which are stored rounded as the acquired ones are;
    /// a power of ten above it for values 16 bits cannot hold, and below it
    /// for values so small that rounding them would leave a few grey levels.
    public static func storedSlope(maximum: Float) -> Float {
        guard maximum.isFinite, maximum > 0 else { return 1 }
        var slope: Float = 1
        if maximum > 65535 {
            while maximum / slope > 65535 { slope *= 10 }
        } else if maximum < 100 {
            while slope > 0.0001, maximum / (slope / 10) <= 65535 { slope /= 10 }
        }
        return slope
    }

    /// `samples` as the pixels stored with `slope`: rounded, within 16 bits.
    public static func stored(_ samples: [Float], slope: Float) -> [UInt16] {
        samples.map { sample in
            let value = (sample / slope).rounded()
            return value.isFinite ? UInt16(min(max(value, 0), 65535)) : 0
        }
    }
}
