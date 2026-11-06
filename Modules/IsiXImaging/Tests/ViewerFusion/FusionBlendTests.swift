//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Foundation
import Testing
@testable import IsiXImaging

// The fusion of a view and the PET blending table against the code DCMView ran
// before these types: `formerBlendingFactor` is the bound of -setBlendingFactor:,
// `formerPETBlendingCLUT` is +computePETBlendingCLUT with the "CLUT" and "PET
// Blending CLUT" preferences turned into arguments and the tables it allocated
// returned as arrays.

private func formerBlendingFactor(_ f: Float) -> Float {
    var factor = f
    if factor < -256 { factor = -256 }
    if factor > 256 { factor = 256 }
    return factor
}

private func formerPETBlendingCLUT(cluts: NSDictionary?, name: String?) -> ([UInt8], [UInt8], [UInt8]) {
    var red = [UInt8](repeating: 0, count: 256), green = red, blue = red
    var aCLUT: NSDictionary? = nil
    if let cluts, let name {
        aCLUT = cluts.object(forKey: name) as? NSDictionary
    }
    if let aCLUT {
        var array: NSArray?
        array = aCLUT.object(forKey: "Red") as? NSArray
        for i in 0..<256 { red[i] = UInt8(truncatingIfNeeded: (array?.object(at: i) as? NSNumber)?.intValue ?? 0) }
        array = aCLUT.object(forKey: "Green") as? NSArray
        for i in 0..<256 { green[i] = UInt8(truncatingIfNeeded: (array?.object(at: i) as? NSNumber)?.intValue ?? 0) }
        array = aCLUT.object(forKey: "Blue") as? NSArray
        for i in 0..<256 { blue[i] = UInt8(truncatingIfNeeded: (array?.object(at: i) as? NSNumber)?.intValue ?? 0) }
    } else {
        for i in 0..<256 {
            red[i] = UInt8(truncatingIfNeeded: i)
            green[i] = UInt8(truncatingIfNeeded: i)
            blue[i] = UInt8(truncatingIfNeeded: i)
        }
    }
    return (red, green, blue)
}

/// The offset of -mergeFused before FusionBlend, with the two views' placements as arguments
/// (+[DCMPix rotatePoint:aroundPoint:angle:] is ImagePlaneCoordinates.rotate).
private func formerMergeOffset(image: (CGPoint, Float, Bool, Bool), fused: (CGPoint, Float, Bool, Bool), scaleRatio: Float,
                               deg2rad: Double) -> CGPoint {
    var oo = fused.0
    oo.x *= CGFloat(scaleRatio)
    oo.y *= CGFloat(scaleRatio)
    if fused.2 { oo.x = -oo.x }
    if fused.3 { oo.y = -oo.y }
    oo = ImagePlaneCoordinates.rotate(oo, around: .zero, angle: Float(Double(-fused.1) * deg2rad))
    var cc = image.0
    cc.x *= CGFloat(scaleRatio)
    cc.y *= CGFloat(scaleRatio)
    if image.2 { cc.x = -cc.x }
    if image.3 { cc.y = -cc.y }
    cc = ImagePlaneCoordinates.rotate(cc, around: .zero, angle: Float(Double(-image.1) * deg2rad))
    oo.x -= cc.x
    oo.y -= cc.y
    oo.y = -oo.y
    return oo
}

private func preset(_ red: [Any], _ green: [Any], _ blue: [Any]) -> [String: Any] {
    ["Red": red, "Green": green, "Blue": blue, "Points": [0, 255], "Colors": [[0.0, 0.0, 0.0], [1.0, 1.0, 1.0]]]
}

/// The factory "PET" table of the preferences, and tables with numbers the viewer keeps to their low byte.
private func petTable() -> [String: Any] { preset((0..<256).map { $0 < 128 ? $0 * 2 : 255 }, (0..<256).map { $0 < 128 ? 0 : ($0 - 128) * 2 },
                              (0..<256).map { $0 < 64 ? $0 * 4 : max(0, 255 - ($0 - 64) * 4) }) }
private func wideNumbers() -> [String: Any] { preset((0..<256).map { $0 * 3 }, (0..<256).map { -$0 }, (0..<256).map { Double($0) + 0.75 }) }
private func longer() -> [String: Any] { preset(Array(0..<300), Array(0..<300).reversed(), Array(repeating: 7, count: 300)) }

@Suite struct FusionBlendTests {

    @Test func factorStaysWithinTheBoundsAsBefore() {
        for value: Float in [-1000, -256.5, -256, -12.25, 0, 0.5, 255.9, 256, 256.1, 1e9, -.infinity, .infinity] {
            #expect(FusionBlend.bounded(value) == formerBlendingFactor(value))
            var blend = FusionBlend()
            #expect(blend.setBoundedFactor(value) == formerBlendingFactor(value) && blend.factor == formerBlendingFactor(value))
        }
        #expect(FusionBlend.bounded(.nan).isNaN)
    }

    @Test func startsAsTheViewDid() {
        let blend = FusionBlend()
        #expect(blend.mode == 0 && blend.factor == 0.5 && blend.factorAtDragStart == 0)
    }

    @Test func aDragStartsFromTheFactor() {
        var blend = FusionBlend(mode: 2, factor: 40)
        blend.beginDrag()
        blend.factor = 90
        #expect(blend.factorAtDragStart == 40 && blend.factor == 90)
    }

    @Test func alphaTableOfTheMode() {
        for mode in 0...6 {
            for alpha: Float in [-256, -40, 0, 0.5, 100, 256] {
                #expect(FusionBlend(mode: mode).alphaTable(alpha: alpha) == ViewTransform.alphaTable(mode: mode, alpha: alpha))
            }
        }
    }

    @Test func mergeOffsetAsComputedBefore() {
        let deg2rad = Double.pi / 180
        let placements: [(CGPoint, Float, Bool, Bool)] = [(.zero, 0, false, false), (CGPoint(x: 12.5, y: -40), 0, false, false),
                                                          (CGPoint(x: -7.25, y: 31), 90, true, false), (CGPoint(x: 100, y: 3.5), -33.3, false, true),
                                                          (CGPoint(x: 0.1, y: 0.2), 270, true, true)]
        for image in placements {
            for fused in placements {
                for scaleRatio: Float in [1, 0.25, 3.7] {
                    let offset = FusionBlend.mergeOffset(image: .init(origin: image.0, rotation: image.1, xFlipped: image.2, yFlipped: image.3),
                                                         fused: .init(origin: fused.0, rotation: fused.1, xFlipped: fused.2, yFlipped: fused.3),
                                                         scaleRatio: scaleRatio, deg2rad: deg2rad)
                    let former = formerMergeOffset(image: image, fused: fused, scaleRatio: scaleRatio, deg2rad: deg2rad)
                    #expect(offset.x.bitPattern == former.x.bitPattern && offset.y.bitPattern == former.y.bitPattern)
                }
            }
        }
    }

    @Test func petBlendingTableAsComputedBefore() {
        let cluts: [String: Any] = ["PET": petTable(), "Wide": wideNumbers(), "Longer": longer()]
        for (stored, name) in [(cluts, "PET"), (cluts, "Wide"), (cluts, "Longer"), (cluts, "Missing"), (cluts, nil),
                               (nil, "PET"), ([:], "PET")] as [([String: Any]?, String?)] {
            let former = formerPETBlendingCLUT(cluts: stored.map { $0 as NSDictionary }, name: name)
            let entry = name.flatMap { stored?[$0] as? [String: Any] }
            let table = PETBlendingTable(preset: entry).colours
            #expect(table.red == former.0 && table.green == former.1 && table.blue == former.2, "\(name ?? "no name")")
        }
    }

    @Test func anIncompleteTableIsTheGreyLevels() {
        // The former code read a missing channel as zeros and raised on a short one; a table of
        // that form, which only a hand-edited preference holds, now gives the grey levels.
        let missingBlue: [String: Any] = ["Red": Array(0..<256), "Green": Array(0..<256)]
        let short = preset(Array(0..<10), Array(0..<256), Array(0..<256))
        let text = preset(Array(0..<256), Array(repeating: "x", count: 256), Array(0..<256))
        for entry in [missingBlue, short, text] {
            #expect(PETBlendingTable(preset: entry).colours.isGreyLevels)
        }
        #expect(PETBlendingTable(preset: nil).colours == .greyLevels)
    }

    @Test func fusedSeriesTakeTheTableOnlyInBWInverse() {
        #expect(PETBlendingTable.drawsFusedSeries(inPETCLUTMode: "B/W Inverse"))
        for mode in [nil, "", "PET", "b/w inverse", "B/W Inverse "] as [String?] {
            #expect(!PETBlendingTable.drawsFusedSeries(inPETCLUTMode: mode))
        }
    }
}
