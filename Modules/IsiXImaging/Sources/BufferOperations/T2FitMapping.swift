//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

/// The T2 fit map of a multi-echo series open in a 2D viewer: which images are
/// the echoes of one slice, and the maps of every slice laid one after the
/// other in the single buffer the viewer of the map shows.
///
/// The fit of one slice's echoes is the caller's (the log-linear fit of the
/// app's T2 Fit Map); the images are read through the caller too, one slice at
/// a time and only while every slice before it fitted, so that no more than
/// one slice's echoes are copied at once.
public enum T2FitMapping {

    /// An image of the viewer: its movie frame and its index in that frame.
    public struct Coordinate: Sendable, Hashable {
        public let movie: Int
        public let slice: Int

        public init(movie: Int, slice: Int) {
            self.movie = movie
            self.slice = slice
        }
    }

    /// One echo as the fit reads it: the image's size, its echo time as the
    /// image gives it, and its samples (nil when the image has none).
    public struct Echo: Sendable {
        public let width: Int
        public let height: Int
        public let echoTimeMilliseconds: Float
        public let samples: [Float]?

        public init(width: Int, height: Int, echoTimeMilliseconds: Float, samples: [Float]?) {
            self.width = width
            self.height = height
            self.echoTimeMilliseconds = echoTimeMilliseconds
            self.samples = samples
        }
    }

    /// What the fit of one slice gives: 0 and the map, or the code and the
    /// reason it refused.
    public struct Fit: Sendable {
        public let code: Int
        public let reason: String
        public let t2Milliseconds: [Float]

        public init(code: Int, reason: String, t2Milliseconds: [Float]) {
            self.code = code
            self.reason = reason
            self.t2Milliseconds = t2Milliseconds
        }
    }

    /// The map of every slice, or why there is none.
    public enum Outcome: Sendable, Equatable {
        /// The code of T2FitMap's errors and its reason.
        case refused(code: Int, reason: String)
        /// The maps one after the other, `width` × `height` values each, and
        /// the first echo of each slice, whose image the map takes its
        /// geometry from.
        case mapped(volume: [Float], width: Int, height: Int, templates: [Coordinate])
    }

    /// The reasons the series has no map before any fit runs.
    public static let noSeriesReason = "T2 Fit Map needs an open multi-echo 2D viewer series, or prepared phantom frames."
    public static let emptySeriesReason = "T2 Fit Map needs a non-empty multi-echo series."
    public static let sizeMismatchReason = "T2 Fit Map frames must share the same width and height."
    public static let missingFilesReason = "T2 Fit Map needs the original files of the open series to present the map."

    /// The echoes of a series of several movie frames: for each slice of the
    /// first frame, its image in every frame.
    public static func groups(movieCount: Int, sliceCount: Int) -> [[Coordinate]] {
        (0..<max(sliceCount, 0)).map { slice in
            (0..<max(movieCount, 0)).map { Coordinate(movie: $0, slice: slice) }
        }
    }

    /// The echoes of a single stack, by the images' origins (equal within
    /// 1e-4 mm on each axis), in the order each position first appears. When
    /// any position has a single image, the stack is not a set of echoes per
    /// slice, and the whole stack is one slice's echoes.
    public static func groups(origins: [SIMD3<Double>]) -> [[Coordinate]] {
        var groups: [[Coordinate]] = []
        for (index, origin) in origins.enumerated() {
            let coordinate = Coordinate(movie: 0, slice: index)
            if let found = groups.firstIndex(where: { sameOrigin(origins[$0[0].slice], origin) }) {
                groups[found].append(coordinate)
            } else {
                groups.append([coordinate])
            }
        }
        if groups.contains(where: { $0.count < 2 }) {
            return [origins.indices.map { Coordinate(movie: 0, slice: $0) }]
        }
        return groups
    }

    /// Fits every slice and lays the maps one after the other. `size` is the
    /// one of the series' first image (nil when it has none); every echo must
    /// have it. `fit` receives a slice's samples, its echo times in
    /// milliseconds, the width and the height.
    public static func map(groups: [[Coordinate]],
                           size: (width: Int, height: Int)?,
                           echo: (Coordinate) -> Echo?,
                           fit: ([[Float]], [Double], Int, Int) -> Fit) -> Outcome {
        guard !groups.isEmpty, let size else {
            return .refused(code: 3, reason: noSeriesReason)
        }
        let (width, height) = size
        guard width > 0, height > 0 else {
            return .refused(code: 3, reason: emptySeriesReason)
        }
        let pixels = width * height

        var volume: [Float] = []
        volume.reserveCapacity(groups.count * pixels)
        for group in groups {
            var signals: [[Float]] = []
            signals.reserveCapacity(group.count)
            var echoTimes: [Double] = []
            echoTimes.reserveCapacity(group.count)
            for coordinate in group {
                guard let image = echo(coordinate), image.width == width, image.height == height,
                      let samples = image.samples, samples.count == pixels else {
                    return .refused(code: 4, reason: sizeMismatchReason)
                }
                signals.append(samples)
                echoTimes.append(Double(image.echoTimeMilliseconds))
            }
            let result = fit(signals, echoTimes, width, height)
            if result.code != 0 {
                return .refused(code: result.code, reason: result.reason)
            }
            let map = result.t2Milliseconds
            for index in 0..<pixels {
                volume.append(index < map.count ? map[index] : 0)
            }
        }
        return .mapped(volume: volume, width: width, height: height, templates: groups.map { $0[0] })
    }

    private static func sameOrigin(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
        abs(a.x - b.x) < 1e-4 && abs(a.y - b.y) < 1e-4 && abs(a.z - b.z) < 1e-4
    }
}
