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

// The T2 fit map of a viewer's series, against the code the viewer ran before
// T2FitMapping: `FormerViewer` below is the former ViewerController (T2FitMap)
// category (-t2FitMapIndexGroups, -t2FitMapPixAtMovie:slice:,
// -t2FitMapFileAtMovie:slice: and -t2FitMapProcessCurrentSeries), copied with
// the viewer's movie frames turned into a stand-in. Both run the same fit, and
// what they give (the code, the reason, the maps and the images the map
// viewer takes its geometry from) is compared value for value.

/// An image of the stand-in viewer.
private struct Image {
    var origin = SIMD3<Double>(0, 0, 0)
    var width = 3
    var height = 2
    var echoTime: Float = 0
    var samples: [Float]? = nil
    var hasFile = true
}

/// What -t2FitMapProcessCurrentSeries gave, and the images of the new viewer.
private struct Presented: Equatable {
    var code: Int
    var reason: String
    var t2Milliseconds: [Float]
    var templates: [[Int]]
}

/// A fit that depends on every sample, echo time and size, and refuses a
/// single echo or an echo time of 99 as T2FitMap.fitSeries refuses.
private func stubFit(_ signals: [[Float]], _ echoTimes: [Double], _ width: Int, _ height: Int) -> T2FitMapping.Fit {
    if signals.count < 2 { return .init(code: 1, reason: "T2 Fit Map needs at least two echoes.", t2Milliseconds: []) }
    if echoTimes.contains(99) { return .init(code: 2, reason: "T2 Fit Map needs at least two positive echo times (TE).", t2Milliseconds: []) }
    var map = [Float](repeating: 0, count: width * height)
    for pixel in map.indices {
        var value = 0.0
        for echo in signals.indices { value += Double(signals[echo][pixel]) * (echoTimes[echo] + 1) }
        map[pixel] = Float(value / Double(width + height))
    }
    // A short map: the former code read 0 past its end.
    if echoTimes.contains(77) { map.removeLast() }
    return .init(code: 0, reason: "", t2Milliseconds: map)
}

/// The former category, over the stand-in's movie frames.
private struct FormerViewer {
    var movies: [[Image]]
    var current = 0
    var maxMovieIndex: Int { movies.count }

    func indexGroups() -> [[[Int]]] {
        if maxMovieIndex > 1 {
            let base = movies[0]
            var groups: [[[Int]]] = []
            for slice in 0..<base.count {
                var group: [[Int]] = []
                var movie = 0
                while movie < maxMovieIndex {
                    group.append([movie, slice])
                    movie += 1
                }
                groups.append(group)
            }
            return groups
        }
        let pixList = movies[current]
        var groups: [[[Int]]] = []
        for index in 0..<pixList.count {
            let pix = pixList[index]
            var found: Int? = nil
            for (g, group) in groups.enumerated() {
                let first = group[0][1]
                if sameOrigin(pixList[first], pix) {
                    found = g
                    break
                }
            }
            if let found {
                groups[found].append([0, index])
            } else {
                groups.append([[0, index]])
            }
        }
        for group in groups where group.count < 2 {
            _ = group
            return [(0..<pixList.count).map { [0, $0] }]
        }
        return groups
    }

    func pix(movie: Int, slice: Int) -> Image? {
        let list = maxMovieIndex > 1 ? movies[movie] : movies[current]
        return slice < list.count ? list[slice] : nil
    }

    func file(movie: Int, slice: Int) -> Bool? {
        pix(movie: movie, slice: slice).map(\.hasFile)
    }

    func process() -> Presented {
        let groups = indexGroups()
        let probe = pix(movie: 0, slice: 0)
        guard groups.count != 0, let probe else {
            return Presented(code: 3, reason: "T2 Fit Map needs an open multi-echo 2D viewer series, or prepared phantom frames.", t2Milliseconds: [], templates: [])
        }
        let width = probe.width, height = probe.height
        let pixels = width * height
        if width <= 0 || height <= 0 {
            return Presented(code: 3, reason: "T2 Fit Map needs a non-empty multi-echo series.", t2Milliseconds: [], templates: [])
        }
        var pixResult: [[Int]] = []
        var fileCount = 0
        var combined: [Float] = []
        for group in groups {
            var frames: [[Float]] = []
            var tes: [Double] = []
            for coordinate in group {
                guard let pix = pix(movie: coordinate[0], slice: coordinate[1]), pix.width == width, pix.height == height,
                      let samples = pix.samples else {
                    return Presented(code: 4, reason: "T2 Fit Map frames must share the same width and height.", t2Milliseconds: [], templates: [])
                }
                frames.append(Array(samples.prefix(pixels)))
                tes.append(Double(NSNumber(value: pix.echoTime).floatValue))
            }
            let fit = stubFit(frames, tes, width, height)
            if fit.code != 0 {
                return Presented(code: fit.code, reason: fit.reason, t2Milliseconds: [], templates: [])
            }
            let map = fit.t2Milliseconds
            var index = 0
            while index < pixels {
                combined.append(index < map.count ? map[index] : 0)
                index += 1
            }
            pixResult.append(group[0])
            if file(movie: group[0][0], slice: group[0][1]) == true { fileCount += 1 }
        }
        if fileCount != pixResult.count {
            return Presented(code: 3, reason: "T2 Fit Map needs the original files of the open series to present the map.", t2Milliseconds: combined, templates: [])
        }
        return Presented(code: 0, reason: "", t2Milliseconds: combined, templates: pixResult)
    }

    private func sameOrigin(_ a: Image, _ b: Image) -> Bool {
        fabs(a.origin.x - b.origin.x) < 1e-4 && fabs(a.origin.y - b.origin.y) < 1e-4 && fabs(a.origin.z - b.origin.z) < 1e-4
    }

    /// The same series through T2FitMapping, read the way the viewer reads it.
    func throughMapping() -> Presented {
        let groups = maxMovieIndex > 1
            ? T2FitMapping.groups(movieCount: maxMovieIndex, sliceCount: movies[0].count)
            : T2FitMapping.groups(origins: movies[current].map(\.origin))
        let probe = pix(movie: 0, slice: 0)
        let outcome = T2FitMapping.map(groups: groups, size: probe.map { (width: $0.width, height: $0.height) },
                                       echo: { coordinate in
                                           guard let image = pix(movie: coordinate.movie, slice: coordinate.slice) else { return nil }
                                           let matches = image.width == probe?.width && image.height == probe?.height
                                           return T2FitMapping.Echo(width: image.width, height: image.height,
                                                                    echoTimeMilliseconds: image.echoTime,
                                                                    samples: matches ? image.samples : nil)
                                       }, fit: stubFit)
        switch outcome {
        case let .refused(code, reason):
            return Presented(code: code, reason: reason, t2Milliseconds: [], templates: [])
        case let .mapped(volume, _, _, templates):
            if templates.contains(where: { file(movie: $0.movie, slice: $0.slice) != true }) {
                return Presented(code: 3, reason: T2FitMapping.missingFilesReason, t2Milliseconds: volume, templates: [])
            }
            return Presented(code: 0, reason: "", t2Milliseconds: volume, templates: templates.map { [$0.movie, $0.slice] })
        }
    }
}

/// An image at `origin` whose samples follow `seed`.
private func image(_ origin: SIMD3<Double>, te: Float, seed: Int, width: Int = 3, height: Int = 2,
                   samples: Bool = true, file: Bool = true) -> Image {
    Image(origin: origin, width: width, height: height, echoTime: te,
          samples: samples ? (0..<(width * height)).map { Float(($0 * 7 + seed * 13) % 23) + 0.5 } : nil, hasFile: file)
}

private let a = SIMD3<Double>(0, 0, 0), b = SIMD3<Double>(0, 0, 5), c = SIMD3<Double>(1, 2, 10)

private let cases: [(String, FormerViewer)] = [
    ("empty viewer", FormerViewer(movies: [[]])),
    ("echoes stacked per slice", FormerViewer(movies: [[image(a, te: 10, seed: 1), image(b, te: 10, seed: 2),
                                                        image(a, te: 20, seed: 3), image(b, te: 20, seed: 4),
                                                        image(a, te: 40, seed: 5), image(b, te: 40, seed: 6)]])),
    ("positions within 1e-4 mm", FormerViewer(movies: [[image(a, te: 10, seed: 1), image(a + 0.00005, te: 30, seed: 2),
                                                        image(c, te: 10, seed: 3), image(c - 0.00009, te: 30, seed: 4)]])),
    ("a position with one image: the whole stack", FormerViewer(movies: [[image(a, te: 10, seed: 1), image(a, te: 20, seed: 2),
                                                                          image(b, te: 30, seed: 3)]])),
    ("one image", FormerViewer(movies: [[image(a, te: 10, seed: 1)]])),
    ("several movie frames", FormerViewer(movies: [[image(a, te: 10, seed: 1), image(b, te: 10, seed: 2)],
                                                   [image(a, te: 25, seed: 3), image(b, te: 25, seed: 4)],
                                                   [image(a, te: 50, seed: 5), image(b, te: 50, seed: 6)]])),
    ("a movie frame shorter than the first", FormerViewer(movies: [[image(a, te: 10, seed: 1), image(b, te: 10, seed: 2)],
                                                                   [image(a, te: 25, seed: 3)]])),
    ("an echo of another size", FormerViewer(movies: [[image(a, te: 10, seed: 1), image(a, te: 20, seed: 2, width: 4)]])),
    ("an echo without samples", FormerViewer(movies: [[image(a, te: 10, seed: 1), image(a, te: 20, seed: 2, samples: false)]])),
    ("a first image without width", FormerViewer(movies: [[image(a, te: 10, seed: 1, width: 0), image(a, te: 20, seed: 2, width: 0)]])),
    ("a slice the fit refuses", FormerViewer(movies: [[image(a, te: 10, seed: 1), image(b, te: 10, seed: 2),
                                                       image(a, te: 20, seed: 3), image(b, te: 99, seed: 4)]])),
    ("a short map", FormerViewer(movies: [[image(a, te: 77, seed: 1), image(a, te: 20, seed: 2)]])),
    ("a slice without its file", FormerViewer(movies: [[image(a, te: 10, seed: 1), image(b, te: 10, seed: 2, file: false),
                                                        image(a, te: 20, seed: 3), image(b, te: 20, seed: 4)]])),
    ("a fractional echo time", FormerViewer(movies: [[image(a, te: 12.345678, seed: 1), image(a, te: 33.3, seed: 2)]])),
]

struct T2FitMappingTests {
    @Test(arguments: cases.indices)
    func theMapIsTheFormerOne(_ index: Int) {
        let (name, viewer) = cases[index]
        let former = viewer.process(), current = viewer.throughMapping()
        #expect(current == former, "\(name)")
    }

    @Test func theGroupsAreTheFormerOnes() {
        for (name, viewer) in cases {
            let groups = viewer.maxMovieIndex > 1
                ? T2FitMapping.groups(movieCount: viewer.maxMovieIndex, sliceCount: viewer.movies[0].count)
                : T2FitMapping.groups(origins: viewer.movies[0].map(\.origin))
            #expect(groups.map { $0.map { [$0.movie, $0.slice] } } == viewer.indexGroups(), "\(name)")
        }
    }

    @Test func eachSliceIsReadOnlyOnceTheSlicesBeforeItFitted() {
        var read: [T2FitMapping.Coordinate] = []
        let groups = [[T2FitMapping.Coordinate(movie: 0, slice: 0), .init(movie: 0, slice: 1)],
                      [.init(movie: 0, slice: 2), .init(movie: 0, slice: 3)]]
        let outcome = T2FitMapping.map(groups: groups, size: (width: 1, height: 1), echo: { coordinate in
            read.append(coordinate)
            return T2FitMapping.Echo(width: 1, height: 1, echoTimeMilliseconds: 99, samples: [1])
        }, fit: stubFit)
        #expect(outcome == .refused(code: 2, reason: "T2 Fit Map needs at least two positive echo times (TE)."))
        #expect(read == Array(groups[0]))
    }
}
