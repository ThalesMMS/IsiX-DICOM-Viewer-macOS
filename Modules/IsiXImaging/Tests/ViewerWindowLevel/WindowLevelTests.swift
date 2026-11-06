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

// The window level of the image views, against the code the views ran before
// these types: each `former…` function below is that code, copied from the
// view's methods with its stored properties turned into arguments
// (-mouseDraggedWindowLevel: and -mouseDraggedBlending: of DCMView, the
// override of OrthogonalMPRView, -reapplyWindowLevel, the window part of
// -updatePresentationStateFromSeriesOnlyImageLevel:scale:offset:,
// +findWLWWPreset::: and the hot keys 1 to 9 of -actionForHotKey:). Values
// are compared bit for bit.

private struct FormerStart {
    var wl: Float, ww: Float, min: Float, max: Float
}

/// DCMView's -mouseDraggedWindowLevel: (divisor 80), and -mouseDraggedBlending:
/// (divisor 100) with the fused image's start: the window it gave the image.
private func formerViewDrag(_ s: FormerStart, divisor: Double, current: CGPoint, start: CGPoint, slope: Float,
                            petLike: Bool, mode: Int, petMinimum: Int) -> (Float, Float) {
    var WWAdapter = Float(Double(s.ww) / divisor)
    if Double(WWAdapter) < 0.001 * Double(slope) { WWAdapter = Float(0.001 * Double(slope)) }
    if petLike {
        var startlevel: Float
        var endlevel: Float
        var eWW: Float = 0, eWL: Float = 0
        switch mode {
        case 0:
            eWL = Float(Double(s.wl) + (current.y - start.y) * Double(WWAdapter))
            eWW = Float(Double(s.ww) + (current.x - start.x) * Double(WWAdapter))
            if Double(eWW) < 0.1 { eWW = Float(0.1) }
        case 1:
            endlevel = Float(Double(s.max) + (current.y - start.y) * Double(WWAdapter))
            eWL = (endlevel - s.min) / 2 + Float(petMinimum)
            eWW = endlevel - s.min
            if Double(eWW) < 0.1 { eWW = Float(0.1) }
            if eWL - eWW / 2 < 0 { eWL = eWW / 2 }
        case 2:
            endlevel = Float(Double(s.max) + (current.y - start.y) * Double(WWAdapter))
            startlevel = Float(Double(s.min) + (current.x - start.x) * Double(WWAdapter))
            if startlevel < 0 { startlevel = 0 }
            eWL = startlevel + (endlevel - startlevel) / 2
            eWW = endlevel - startlevel
            if Double(eWW) < 0.1 { eWW = Float(0.1) }
            if eWL - eWW / 2 < 0 { eWL = eWW / 2 }
        default:
            break
        }
        return (eWL, eWW)
    }
    return (Float(Double(s.wl) + (current.y - start.y) * Double(WWAdapter)),
            Float(Double(s.ww) + (current.x - start.x) * Double(WWAdapter)))
}

/// OrthogonalMPRView's -mouseDraggedWindowLevel: without a fused view.
private func formerOrthogonalDrag(_ s: FormerStart, current: CGPoint, start: CGPoint,
                                  petLike: Bool, mode: Int, petMinimum: Int) -> (Float, Float) {
    var WWAdapter = Float(Double(s.ww) / 100.0)
    if Double(WWAdapter) < 0.001 { WWAdapter = Float(0.001) }
    if petLike {
        var startlevel: Float
        var endlevel: Float
        var eWW: Float = 5, eWL: Float = 5
        switch mode {
        case 0:
            eWL = Float(Double(s.wl) + Double(current.y - start.y) * Double(WWAdapter))
            eWW = Float(Double(s.ww) + Double(current.x - start.x) * Double(WWAdapter))
            if Double(eWW) < 0.1 { eWW = Float(0.1) }
        case 1:
            endlevel = Float(Double(s.max) + Double(current.y - start.y) * Double(WWAdapter))
            eWL = (endlevel - s.min) / 2 + Float(petMinimum)
            eWW = endlevel - s.min
            if Double(eWW) < 0.1 { eWW = Float(0.1) }
            if eWL - eWW / 2 < 0 { eWL = eWW / 2 }
        case 2:
            endlevel = Float(Double(s.max) + Double(current.y - start.y) * Double(WWAdapter))
            startlevel = Float(Double(s.min) + Double(current.x - start.x) * Double(WWAdapter))
            if startlevel < 0 { startlevel = 0 }
            eWL = startlevel + (endlevel - startlevel) / 2
            eWW = endlevel - startlevel
            if Double(eWW) < 0.1 { eWW = Float(0.1) }
            if eWL - eWW / 2 < 0 { eWL = eWW / 2 }
        default:
            break
        }
        return (eWL, eWW)
    }
    return (Float(Double(s.wl) + Double(current.y - start.y) * Double(WWAdapter)),
            Float(Double(s.ww) + Double(current.x - start.x) * Double(WWAdapter)))
}

/// -setStartWLWW: the start of a drag from a window.
private func formerStart(wl: Float, ww: Float) -> FormerStart {
    FormerStart(wl: wl, ww: ww, min: wl - ww / 2, max: wl + ww / 2)
}

private func same(_ a: (Float, Float), _ b: (level: Float, width: Float)) -> Bool {
    a.0.bitPattern == b.level.bitPattern && a.1.bitPattern == b.width.bitPattern
}

@Suite struct WindowLevelDragTests {
    static let windows: [(Float, Float)] = [(40, 400), (-500, 1400), (3.5, 6), (0, 0), (2_000, 0.02), (12_000, 30_000), (-1, 1)]
    static let moves: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 13.25, y: -7.5), CGPoint(x: -250, y: 180.5),
                                   CGPoint(x: 0.5, y: 1_000), CGPoint(x: -3, y: -3), CGPoint(x: 77.125, y: -0.25)]
    static let start = CGPoint(x: 101.5, y: 64.25)
    static let slopes: [Float] = [1, 0, 2.5, 0.01, 40]
    static let modes = [0, 1, 2, 3, -1]
    static let minimums = [0, 7, -20]

    @Test(arguments: [WindowLevelDrag.Variant.image, .fused, .orthogonalMPR])
    func everyVariantModeAndMoveGivesWhatTheViewGave(_ variant: WindowLevelDrag.Variant) {
        var compared = 0
        for (wl, ww) in Self.windows {
            let drag = WindowLevelDrag(variant: variant, level: wl, width: ww)
            let former = formerStart(wl: wl, ww: ww)
            #expect(drag.minimum == former.min && drag.maximum == former.max)
            for move in Self.moves {
                let current = CGPoint(x: Self.start.x + move.x, y: Self.start.y + move.y)
                let delta = CGVector(dx: current.x - Self.start.x, dy: current.y - Self.start.y)
                for slope in Self.slopes {
                    for petLike in [false, true] {
                        for mode in Self.modes {
                            for petMinimum in Self.minimums {
                                let expected: (Float, Float)
                                switch variant {
                                case .image:
                                    expected = formerViewDrag(former, divisor: 80.00, current: current, start: Self.start, slope: slope,
                                                              petLike: petLike, mode: mode, petMinimum: petMinimum)
                                case .fused:
                                    expected = formerViewDrag(former, divisor: 100.0, current: current, start: Self.start, slope: slope,
                                                              petLike: petLike, mode: mode, petMinimum: petMinimum)
                                case .orthogonalMPR:
                                    expected = formerOrthogonalDrag(former, current: current, start: Self.start,
                                                                    petLike: petLike, mode: mode, petMinimum: petMinimum)
                                }
                                let window = drag.window(delta: delta, mode: petLike ? mode : nil, petMinimum: petMinimum, slope: slope)
                                #expect(same(expected, window), "\(variant) wl \(wl) ww \(ww) move \(move) slope \(slope) PET \(petLike) mode \(mode)")
                                compared += 1
                            }
                        }
                    }
                }
            }
        }
        #expect(compared == Self.windows.count * Self.moves.count * Self.slopes.count * 2 * Self.modes.count * Self.minimums.count)
    }

    @Test func theStepsOfTheThreeViews() {
        #expect(WindowLevelDrag(variant: .image, level: 40, width: 400).step(slope: 1) == 5)
        #expect(WindowLevelDrag(variant: .fused, level: 40, width: 400).step(slope: 1) == 4)
        #expect(WindowLevelDrag(variant: .orthogonalMPR, level: 40, width: 400).step(slope: 1) == 4)
        // A narrow window still moves: by 0.001 of the slope, or 0.001 in the MPR views.
        #expect(WindowLevelDrag(variant: .image, level: 1, width: 0.01).step(slope: 20) == Float(0.02))
        #expect(WindowLevelDrag(variant: .orthogonalMPR, level: 1, width: 0.01).step(slope: 20) == Float(0.001))
        // An unknown mode gives 0 in the image views and 5 in the MPR views.
        #expect(WindowLevelDrag(variant: .image, level: 40, width: 400).window(delta: CGVector(dx: 1, dy: 1), mode: 9, petMinimum: 0, slope: 1) == (0, 0))
        #expect(WindowLevelDrag(variant: .orthogonalMPR, level: 40, width: 400).window(delta: CGVector(dx: 1, dy: 1), mode: 9, petMinimum: 0, slope: 1) == (5, 5))
    }
}

// MARK: - The view's window

/// The state -reapplyWindowLevel read and wrote.
private struct FormerView {
    var curWL: Float, curWW: Float, converted: Bool, factor: Float
}

/// -reapplyWindowLevel, without the final -changeWLWW:: of the image.
private func formerReapply(_ v: inout FormerView, suvConverted: Bool, is2DViewer: Bool, factorPET2SUV: Float) {
    if v.curWL != 0 && v.curWW != 0 && v.converted != suvConverted {
        if v.factor > 0 {
            if v.converted {
                v.curWL /= v.factor
                v.curWW /= v.factor
            } else {
                v.factor = 1.0
                if v.converted && is2DViewer {
                    v.factor = factorPET2SUV
                }
                v.curWL *= v.factor
                v.curWW *= v.factor
            }
        }
        v.converted = suvConverted
        v.factor = 1.0
        if v.converted && is2DViewer {
            v.factor = factorPET2SUV
        }
    }
}

@Suite struct WindowLevelStateTests {
    @Test func reapplyConvertsAsTheViewDid() {
        let levels: [Float] = [0, 40, -3.25, 1e-6]
        let widths: [Float] = [0, 400, 0.5]
        let factors: [Float] = [0, 1, 0.000_42, 2.5, -1]
        var compared = 0
        for wl in levels {
            for ww in widths {
                for converted in [false, true] {
                    for factor in factors {
                        for imageConverted in [false, true] {
                            for is2D in [false, true] {
                                for viewerFactor: Float in [0.000_37, 3, 0] {
                                    var former = FormerView(curWL: wl, curWW: ww, converted: converted, factor: factor)
                                    formerReapply(&former, suvConverted: imageConverted, is2DViewer: is2D, factorPET2SUV: viewerFactor)
                                    var state = WindowLevelState(level: wl, width: ww, suvConverted: converted, suvFactor: factor)
                                    state.reapply(imageSUVConverted: imageConverted) { is2D ? viewerFactor : 1 }
                                    #expect(state.level.bitPattern == former.curWL.bitPattern && state.width.bitPattern == former.curWW.bitPattern)
                                    #expect(state.suvConverted == former.converted && state.suvFactor.bitPattern == former.factor.bitPattern)
                                    compared += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(compared == 4 * 3 * 2 * 5 * 2 * 2 * 3)
    }

    @Test func mirrorTakesTheImagesWindow() {
        var state = WindowLevelState(level: 1, width: 2, suvConverted: true, suvFactor: 7)
        var asked = 0
        state.mirror(level: 40, width: 400, suvConverted: false) { asked += 1; return 3 }
        #expect(state == WindowLevelState(level: 40, width: 400, suvConverted: false, suvFactor: 1) && asked == 0)
        state.mirror(level: 4, width: 6, suvConverted: true) { asked += 1; return 3 }
        #expect(state == WindowLevelState(level: 4, width: 6, suvConverted: true, suvFactor: 3) && asked == 1)
        // Without an image the window is in the image's values and the factor stays.
        state.mirrorWithoutImage(level: 10, width: 20)
        #expect(state == WindowLevelState(level: 10, width: 20, suvConverted: false, suvFactor: 3))
    }
}

// MARK: - The PET window restored

/// What -updatePresentationStateFromSeriesOnlyImageLevel:scale:offset: gave
/// -setWLWW:: from the window it found: nil when it called nothing.
private func formerRestore(ww: Float, wl: Float, curWW: Float, curWL: Float, petLike: Bool, suvConverted: Bool,
                           maximum: Float, onlyImage: Bool, is2DViewer: Bool, factor: Float,
                           defaultPET: Int, from: Float, to: Float, fromSUV: Float, toSUV: Float) -> (Float, Float)? {
    var curWW = curWW, curWL = curWL
    if ww != 0 || wl != 0 {
        if ww != 0 {
            if petLike {
                switch defaultPET {
                case 0:
                    if !suvConverted {
                        curWW = ww
                        curWL = wl
                    } else if is2DViewer {
                        curWW = ww * factor
                        curWL = wl * factor
                    }
                case 1:
                    let from = ViewTransform.percentOfMaximum(maximum, from)
                    let to = ViewTransform.percentOfMaximum(maximum, to)
                    if to - from != 0 {
                        let window = ViewTransform.window(from: from, to: to)
                        curWW = window.width
                        curWL = window.level
                    }
                case 2:
                    if suvConverted {
                        if toSUV - fromSUV != 0 {
                            let window = ViewTransform.window(from: fromSUV, to: toSUV)
                            curWW = window.width
                            curWL = window.level
                        }
                    } else {
                        curWW = ww
                        curWL = wl
                    }
                default:
                    break
                }
            } else {
                curWW = ww
                curWL = wl
            }
            return (curWL, curWW)
        }
    } else if !onlyImage {
        if petLike {
            curWW = ww
            curWL = wl
            switch defaultPET {
            case 1:
                let window = ViewTransform.window(from: ViewTransform.percentOfMaximum(maximum, from),
                                                  to: ViewTransform.percentOfMaximum(maximum, to))
                curWW = window.width
                curWL = window.level
            case 2:
                if suvConverted {
                    let window = ViewTransform.window(from: fromSUV, to: toSUV)
                    curWW = window.width
                    curWL = window.level
                } else {
                    curWW = ww
                    curWL = wl
                }
            default:
                break
            }
            return (curWL, curWW)
        }
    }
    return nil
}

@Suite struct PETWindowingTests {
    @Test func restoresWhatTheViewRestored() {
        let stored: [(Float, Float)] = [(0, 0), (40, 400), (12, 0), (0, 30), (-2, 9.5)]
        let bounds: [(Float, Float, Float, Float)] = [(0, 100, 0, 6), (10, 10, 3, 3), (25, 70, 0.5, 8)]
        var compared = 0
        for (wl, ww) in stored {
            for mode in [0, 1, 2, 5] {
                for (from, to, fromSUV, toSUV) in bounds {
                    let windowing = PETWindowing(mode: mode, percentFrom: from, percentTo: to, suvFrom: fromSUV, suvTo: toSUV)
                    for petLike in [false, true] {
                        for suv in [false, true] {
                            for onlyImage in [false, true] {
                                for is2D in [false, true] {
                                    for maximum: Float in [0, 32_767, 1.5e6] {
                                        let factor: Float = 0.000_31
                                        let former = formerRestore(ww: ww, wl: wl, curWW: 77, curWL: 33, petLike: petLike, suvConverted: suv,
                                                                   maximum: maximum, onlyImage: onlyImage, is2DViewer: is2D, factor: factor,
                                                                   defaultPET: mode, from: from, to: to, fromSUV: fromSUV, toSUV: toSUV)
                                        let restored = windowing.restored(stored: (wl, ww), current: (33, 77), petLike: petLike, suvConverted: suv,
                                                                          seriesMaximum: maximum, imageOnly: onlyImage) { is2D ? factor : nil }
                                        if let former {
                                            #expect(restored.map { same(former, $0) } == true, "wl \(wl) ww \(ww) mode \(mode) PET \(petLike) SUV \(suv)")
                                        } else {
                                            #expect(restored == nil, "wl \(wl) ww \(ww) mode \(mode) PET \(petLike) SUV \(suv)")
                                        }
                                        compared += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(compared == 5 * 4 * 3 * 2 * 2 * 2 * 2 * 3)
    }

    @Test func theModesOfThePreference() {
        #expect(PETWindowing(mode: 0, percentFrom: 1, percentTo: 2, suvFrom: 3, suvTo: 4) == .stored)
        #expect(PETWindowing(mode: 1, percentFrom: 1, percentTo: 2, suvFrom: 3, suvTo: 4) == .percentOfMaximum(from: 1, to: 2))
        #expect(PETWindowing(mode: 2, percentFrom: 1, percentTo: 2, suvFrom: 3, suvTo: 4) == .suv(from: 3, to: 4))
        #expect(PETWindowing(mode: 3, percentFrom: 1, percentTo: 2, suvFrom: 3, suvTo: 4) == .unchanged)
    }
}

// MARK: - The presets

/// +findWLWWPreset::: before the catalog: the first preset of the dictionary's
/// keys with this window, then the image's full dynamic and default.
private func formerPresetName(_ wl: Float, _ ww: Float, _ presets: NSDictionary,
                              fullDynamic: (Float, Float)?, imageDefault: (Float, Float)?) -> WindowLevelPreset {
    var list: [(name: String, level: Float, width: Float)] = []
    for case let key as String in presets.allKeys {
        guard let value = presets.object(forKey: key) as? NSArray, value.count >= 2 else { continue }
        list.append((key, (value.object(at: 0) as? NSNumber)?.floatValue ?? 0, (value.object(at: 1) as? NSNumber)?.floatValue ?? 0))
    }
    return WindowLevelPreset.match(level: wl, width: ww, presets: list,
                                   fullDynamic: fullDynamic.map { (level: $0.0, width: $0.1) },
                                   imageDefault: imageDefault.map { (level: $0.0, width: $0.1) })
}

/// The names of -actionForHotKey: for the keys 1 to 9.
private func formerHotKeyNames(_ presets: NSDictionary) -> [String] {
    ((presets.allKeys as NSArray).sortedArray(using: #selector(NSString.caseInsensitiveCompare(_:))) as NSArray).compactMap { $0 as? String }
}

@Suite struct WindowLevelPresetCatalogTests {
    static func storedPresets() -> NSDictionary { [
        "CT - Pulmonary": [-500, 1400], "CT - Bone": [300, 1500], "CT - Brain": [50, 100], "CT - Abdomen": [40, 350],
        "VR - Endoscopy": [-300, 700], "bone wide": [300, 1500], "Écho": [40.5, 80.25], "mediastinum": [40, 350],
        "Broken": ["x"], "Short": [12],
    ] }

    /// The catalog the application builds from the dictionary, in its order.
    static func catalog(_ presets: NSDictionary) -> WindowLevelPresetCatalog {
        WindowLevelPresetCatalog(entries: presets.allKeys.compactMap { $0 as? String }.map { name in
            let value = presets.object(forKey: name) as? [NSNumber]
            let window = (value?.count ?? 0) >= 2 ? WindowLevelPresetCatalog.Window(level: value![0].floatValue, width: value![1].floatValue) : nil
            return WindowLevelPresetCatalog.Entry(name: name, window: window)
        })
    }

    @Test func namesTheWindowAsTheViewDid() {
        let stored = Self.storedPresets()
        let catalog = Self.catalog(stored)
        let windows: [(Float, Float)] = [(-500, 1400), (300, 1500), (40, 350), (40.5, 80.25), (12, 0), (1, 1), (100, 4000), (20, 30)]
        for (wl, ww) in windows {
            for pix in [false, true] {
                let fullDynamic: (Float, Float)? = pix ? (100, 4000) : nil
                let imageDefault: (Float, Float)? = pix ? (20, 30) : nil
                let name = catalog.name(matching: wl, width: ww, fullDynamic: fullDynamic.map { (level: $0.0, width: $0.1) },
                                        imageDefault: imageDefault.map { (level: $0.0, width: $0.1) })
                #expect(name == formerPresetName(wl, ww, stored, fullDynamic: fullDynamic, imageDefault: imageDefault))
            }
        }
        // Two presets of one window: the first in the dictionary's order names it.
        let first = stored.allKeys.compactMap { $0 as? String }.first { $0 == "CT - Bone" || $0 == "bone wide" }
        #expect(catalog.name(matching: 300, width: 1500, fullDynamic: nil, imageDefault: nil) == .named(first!))
    }

    @Test func theHotKeysCountThePresetsAsTheViewDid() {
        let stored = Self.storedPresets()
        let catalog = Self.catalog(stored)
        #expect(catalog.hotKeyOrder.map(\.name) == formerHotKeyNames(stored))
        #expect(catalog.hotKeyPreset(0)?.name == "bone wide")
        #expect(catalog.hotKeyPreset(1)?.name == "Broken" && catalog.hotKeyPreset(1)?.window == nil)
        for index in 0 ..< 9 {
            let names = formerHotKeyNames(stored)
            #expect(catalog.hotKeyPreset(index)?.name == (index < names.count ? names[index] : nil))
        }
        #expect(catalog.hotKeyPreset(-1) == nil && catalog.hotKeyPreset(stored.count) == nil)
        // An entry that is not a level and a width keeps its place and applies nothing.
        #expect(catalog.hotKeyOrder.first { $0.name == "Broken" }?.window == nil)
        // Names that differ only in case keep the order of their characters.
        let cased = WindowLevelPresetCatalog(entries: [.init(name: "lung", window: nil), .init(name: "Lung", window: nil), .init(name: "abd", window: nil)])
        #expect(cased.hotKeyOrder.map(\.name) == ["abd", "Lung", "lung"])
    }
}
