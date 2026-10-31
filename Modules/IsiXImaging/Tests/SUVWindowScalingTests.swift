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

// The windows of a conversion to SUV, against the code the 2D viewer ran before
// SUVWindowScaling: `formerConversion` is the window part of the viewer's
// -convertPETtoSUV, with the slice on screen, the slices' default windows and
// the DEFAULTPETWLWW preference turned into arguments. Values are compared bit
// for bit.

private struct FormerResult: Equatable {
    var savedWL: [UInt32]
    var savedWW: [UInt32]
    var viewWindow: [UInt32]?
    var fromSeries: Bool
}

private func formerConversion(currentConverted: Bool, currentFactor: Double, savedWL: [Float], savedWW: [Float],
                              cwl: Float, cww: Float, defaultPETWLWW: Int) -> FormerResult {
    var updatewlww = false
    var updatefactor = 1.0
    if currentConverted == false {
        updatewlww = true
        updatefactor = currentFactor
    }
    let wl = savedWL.map { Float(Double($0) * updatefactor) }
    let ww = savedWW.map { Float(Double($0) * updatefactor) }
    var view: [UInt32]?
    var fromSeries = false
    if updatewlww {
        if defaultPETWLWW != 0 {
            fromSeries = true
        } else {
            view = [Float(Double(cwl) * updatefactor).bitPattern, Float(Double(cww) * updatefactor).bitPattern]
        }
    }
    return FormerResult(savedWL: wl.map(\.bitPattern), savedWW: ww.map(\.bitPattern), viewWindow: view, fromSeries: fromSeries)
}

private func currentConversion(currentConverted: Bool, currentFactor: Double, savedWL: [Float], savedWW: [Float],
                               cwl: Float, cww: Float, defaultPETWLWW: Int) -> FormerResult {
    let scaling = SUVWindowScaling(currentSliceFactor: currentConverted ? nil : currentFactor)
    let windowing = PETWindowing(mode: defaultPETWLWW, percentFrom: 10, percentTo: 90, suvFrom: 0, suvTo: 6)
    var view: [UInt32]?
    var fromSeries = false
    switch scaling.viewWindow(current: (cwl, cww), windowing: windowing) {
    case .unchanged: break
    case .fromSeries: fromSeries = true
    case .window(let level, let width): view = [level.bitPattern, width.bitPattern]
    }
    return FormerResult(savedWL: savedWL.map { scaling.scaled($0).bitPattern }, savedWW: savedWW.map { scaling.scaled($0).bitPattern },
                        viewWindow: view, fromSeries: fromSeries)
}

/// A reproducible sequence of values, so that a failure can be replayed.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Test func conversionScalesTheWindowsAsTheViewerDid() {
    var random = SplitMix(state: 1702)
    let factors: [Double] = [0, 1, 0.000_123_4, 0.5, 1.0 / 3.0, 7.25, 1e-7, 1e6, .nan, .infinity]
    for mode in -1...4 {
        for converted in [false, true] {
            for factor in factors {
                let count = Int.random(in: 1...6, using: &random)
                let savedWL = (0..<count).map { _ in Float.random(in: -2000...40000, using: &random) }
                let savedWW = (0..<count).map { _ in Float.random(in: 0...80000, using: &random) }
                let cwl = Float.random(in: -1000...30000, using: &random)
                let cww = Float.random(in: 0...60000, using: &random)
                let former = formerConversion(currentConverted: converted, currentFactor: factor, savedWL: savedWL, savedWW: savedWW,
                                              cwl: cwl, cww: cww, defaultPETWLWW: mode)
                let current = currentConversion(currentConverted: converted, currentFactor: factor, savedWL: savedWL, savedWW: savedWW,
                                                cwl: cwl, cww: cww, defaultPETWLWW: mode)
                #expect(former == current, "mode \(mode), converted \(converted), factor \(factor)")
            }
        }
    }
}

@Test func aSliceAlreadyInSUVLeavesEveryWindow() {
    let scaling = SUVWindowScaling(currentSliceFactor: nil)
    #expect(scaling.factor == 1)
    #expect(!scaling.rescalesView)
    #expect(scaling.scaled(123.456).bitPattern == Float(123.456).bitPattern)
    #expect(scaling.viewWindow(current: (40, 400), windowing: .stored) == .unchanged)
    #expect(scaling.viewWindow(current: (40, 400), windowing: .suv(from: 0, to: 6)) == .unchanged)
}

@Test func theSheetConversionKeepsThePreferenceValues() {
    #expect(SUVWindowScaling.SheetConversion(rawValue: 0) == .leaveValues)
    #expect(SUVWindowScaling.SheetConversion(rawValue: 1) == .convertPixels)
    #expect(SUVWindowScaling.SheetConversion(rawValue: 2) == .displaySUV)
    #expect(SUVWindowScaling.SheetConversion(rawValue: 3) == nil)
    #expect(SUVWindowScaling.SheetConversion(rawValue: -1) == nil)
}

@Test func dosesConvertAsTheSheetDid() {
    var random = SplitMix(state: 2026)
    for _ in 0..<500 {
        let megabecquerels = Float.random(in: 0...2000, using: &random)
        #expect(SUVWindowScaling.becquerels(megabecquerels: megabecquerels).bitPattern
                == Float(Double(megabecquerels) * 1000000.0).bitPattern)
        let becquerels = Float.random(in: 0...2e9, using: &random)
        #expect(SUVWindowScaling.megabecquerelsText(becquerels) == String(format: "%2.3f", Double(becquerels) / 1000000.0))
    }
    #expect(SUVWindowScaling.megabecquerelsText(370_000_000) == "370.000")
    #expect(SUVWindowScaling.megabecquerelsText(0) == "0.000")
}
