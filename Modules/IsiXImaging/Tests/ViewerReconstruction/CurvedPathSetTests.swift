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
import Testing
@testable import IsiXImaging

struct CurvedPathSetTests {
    private func archive(_ text: String) -> Data { Data(("bplist-not: " + text).utf8) }

    @Test func severalPathsAreWrittenAndReadBackWithTheirNamesAndTheOneShown() throws {
        var set = CurvedPathSet()
        #expect(set.current == nil && set.fileData(defaultName: "Path") == nil)
        #expect(set.nextName(generic: "Path") == "LM")
        set.store(archive("first"), defaultName: "Path")
        #expect(set.names == ["Path"] && set.selected == 0)
        #expect(set.add(name: set.nextName(generic: "Path"), path: archive("lm"), fallback: "Path") == "LM")
        #expect(set.add(name: "LAD", path: archive("lad"), fallback: "Path") == "LAD")
        #expect(set.add(name: "LAD", path: archive("lad again"), fallback: "Path") == "LAD 2")
        #expect(set.add(name: "   ", path: archive("unnamed"), fallback: "Path") == "Path 2")
        #expect(set.selected == 4 && set.nextName(generic: "Path") == "LCx")
        set.select(2)
        set.store(archive("lad, moved"), defaultName: "Path")
        set.rename(1, to: "LAD", fallback: "Path")
        #expect(set.names == ["Path", "LAD 3", "LAD", "LAD 2", "Path 2"])
        set.rename(1, to: "Left main", fallback: "Path")
        set.rename(2, to: "LAD", fallback: "Path")
        #expect(set.names[1] == "Left main" && set.names[2] == "LAD")

        let file = try #require(set.fileData(defaultName: "Path"))
        let read = CurvedPathSet(fileData: file, defaultName: "Path")
        #expect(read == set && read.current == CurvedPathSet.Entry(name: "LAD", path: archive("lad, moved")))

        // Removing the path shown shows the one before it; removing one before it keeps the one shown.
        var fewer = read
        fewer.remove(2)
        #expect(fewer.names == ["Path", "Left main", "LAD 2", "Path 2"] && fewer.current?.name == "Left main")
        fewer.remove(0)
        #expect(fewer.current?.name == "Left main" && fewer.selected == 0)
        fewer.remove(7)
        #expect(fewer.entries.count == 3)
        for _ in 0..<3 { fewer.remove(0) }
        #expect(fewer.entries.isEmpty && fewer.selected == 0 && fewer.current == nil)
    }

    @Test func aFileOfOnePathIsTheFormerFileAndIsReadAsOnePath() throws {
        // What a window wrote before: the archive of its path, and nothing else.
        let former = archive("the only path")
        let read = CurvedPathSet(fileData: former, defaultName: "Path")
        #expect(read.names == ["Path"] && read.current?.path == former && read.selected == 0)
        // Written again, it is that file: a reader of the former format opens it.
        #expect(read.fileData(defaultName: "Path") == former)
        // A real archive is a property list too, and is still one path.
        let keyed = try PropertyListSerialization.data(fromPropertyList: ["$archiver": "NSKeyedArchiver", "$objects": ["$null"]], format: .binary, options: 0)
        #expect(CurvedPathSet(fileData: keyed, defaultName: "Path").entries == [CurvedPathSet.Entry(name: "Path", path: keyed)])
        // One path with a name of its own is kept with its name.
        var named = read
        named.rename(0, to: "RCA", fallback: "Path")
        let file = try #require(named.fileData(defaultName: "Path"))
        #expect(file != former && CurvedPathSet(fileData: file, defaultName: "Path") == named)
    }

    @Test func theTubeKeepsTheVoxelsNearThePathsAndNoOthers() throws {
        // 40 x 40 x 30 voxels of 0.5 mm, its axes turned: columns along y, rows along -x.
        let grid = VesselTube.Grid(width: 40, height: 40, depth: 30, origin: SIMD3(10, -5, 2),
                                   column: SIMD3(0, 0.5, 0), row: SIMD3(-0.5, 0, 0), slice: SIMD3(0, 0, 0.5))
        func place(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Double> { grid.origin + Double(x) * grid.column + Double(y) * grid.row + Double(z) * grid.slice }
        // A path along the slices through the middle, bent once, and a second one of a single point.
        let bent = [place(10, 20, 2), place(10, 20, 15), place(25, 20, 27)]
        let point = [place(34, 5, 5)]
        let radius = 2.0
        let mask = try #require(VesselTube.mask(of: grid, around: [bent, point], radius: radius))
        #expect(mask.count == 40 * 40 * 30)
        func distance(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
            let along = b - a, t = min(max(simd_dot(p - a, along) / simd_length_squared(along), 0), 1)
            return simd_length(p - (a + t * along))
        }
        var inside = 0, wrong = 0
        for z in 0..<30 {
            for y in 0..<40 {
                for x in 0..<40 {
                    let p = place(x, y, z)
                    let near = min(distance(p, bent[0], bent[1]), distance(p, bent[1], bent[2]), simd_length(p - point[0])) <= radius
                    if near { inside += 1 }
                    if (mask[(z * 40 + y) * 40 + x] == 1) != near { wrong += 1 }
                }
            }
        }
        #expect(wrong == 0 && inside > 1500 && inside < 40 * 40 * 30 / 4, "\(wrong) voxels wrong, \(inside) inside")

        // What is outside the tube leaves the volume: a bright chamber beside the path is gone, the vessel stays.
        var volume = [Float](repeating: 40, count: mask.count)
        for z in 0..<30 { for y in 0..<12 { for x in 0..<40 where x < 30 { volume[(z * 40 + y) * 40 + x] = 500 } } }
        volume[(10 * 40 + 20) * 40 + 10] = 400
        volume.withUnsafeMutableBufferPointer { VesselTube.keep(mask, of: $0, elsewhere: -1024) }
        #expect(volume[(10 * 40 + 20) * 40 + 10] == 400 && volume[(10 * 40 + 3) * 40 + 3] == -1024 && volume.filter { $0 == 500 }.isEmpty)
        #expect(volume.filter { $0 > -1024 }.count == inside)

        // No tube without a radius, and none around a grid that spans no space.
        #expect(VesselTube.mask(of: grid, around: [bent], radius: 0) == nil)
        var flat = grid
        flat.slice = flat.column
        #expect(VesselTube.mask(of: flat, around: [bent], radius: 2) == nil)
        #expect(VesselTube.mask(of: grid, around: [], radius: 2)?.contains(1) == false)
    }
}
