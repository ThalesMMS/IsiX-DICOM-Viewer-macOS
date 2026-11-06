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

// The colour tables of a view against the code DCMView ran before this type:
// `FormerView.setCLUT` below is -setCLUT::: as the view wrote it, with its
// tables, colorTransfer and colour buffer turned into stored values.

private struct FormerView {
    var red = [UInt8](repeating: 0, count: 256), green = [UInt8](repeating: 0, count: 256), blue = [UInt8](repeating: 0, count: 256)
    var colorTransfer = false
    var holdsColourBuffer = false

    init(red: [UInt8], green: [UInt8], blue: [UInt8], colorTransfer: Bool, holdsColourBuffer: Bool) {
        self.red = red
        self.green = green
        self.blue = blue
        self.colorTransfer = colorTransfer
        self.holdsColourBuffer = holdsColourBuffer
    }

    /// -setCLUT::: before ColourTableState; returns whether it wrote the tables.
    mutating func setCLUT(_ r: [UInt8]?, _ g: [UInt8]?, _ b: [UInt8]?) -> Bool {
        var needUpdate = true
        if r == nil {
            if !holdsColourBuffer && colorTransfer == false { needUpdate = false }
        } else if red == r! && green == g! && blue == b! { needUpdate = false }

        if needUpdate {
            if let r, let g, let b {
                var BWCLUT = true
                for i in 0..<256 {
                    red[i] = r[i]
                    green[i] = g[i]
                    blue[i] = b[i]
                    if Int(red[i]) != i || Int(green[i]) != i || Int(blue[i]) != i { BWCLUT = false }
                }
                if BWCLUT {
                    colorTransfer = false
                    holdsColourBuffer = false
                } else {
                    colorTransfer = true
                }
            } else {
                colorTransfer = false
                holdsColourBuffer = false
                for i in 0..<256 {
                    red[i] = UInt8(truncatingIfNeeded: i)
                    green[i] = UInt8(truncatingIfNeeded: i)
                    blue[i] = UInt8(truncatingIfNeeded: i)
                }
            }
        }
        return needUpdate
    }
}

private let grey = (0..<256).map { UInt8($0) }
private let hot = (0..<256).map { UInt8(min(255, $0 * 3)) }
private let inverse = (0..<256).map { UInt8(255 - $0) }
private let almostGrey: [UInt8] = { var table = grey; table[200] = 201; return table }()

/// The new way: a view's tables as buffers, with the state and the colour buffer it holds.
private func setWithState(_ start: FormerView, _ request: ([UInt8], [UInt8], [UInt8])?) -> (FormerView, ColourTableState.Change) {
    var red = start.red, green = start.green, blue = start.blue
    var state = ColourTableState(colorTransfer: start.colorTransfer)
    let change: ColourTableState.Change = red.withUnsafeMutableBufferPointer { r in
        green.withUnsafeMutableBufferPointer { g in
            blue.withUnsafeMutableBufferPointer { b in
                let tables = ColourTableState.Tables(red: r.baseAddress!, green: g.baseAddress!, blue: b.baseAddress!)
                guard let request else { return state.set(tables, to: nil, holdsColourBuffer: start.holdsColourBuffer) }
                return request.0.withUnsafeBufferPointer { qr in
                    request.1.withUnsafeBufferPointer { qg in
                        request.2.withUnsafeBufferPointer { qb in
                            state.set(tables, to: ColourTableState.Request(red: qr.baseAddress!, green: qg.baseAddress!, blue: qb.baseAddress!),
                                      holdsColourBuffer: start.holdsColourBuffer)
                        }
                    }
                }
            }
        }
    }
    var after = start
    after.red = red
    after.green = green
    after.blue = blue
    after.colorTransfer = state.colorTransfer
    if change == .greyLevels { after.holdsColourBuffer = false }
    return (after, change)
}

@Suite struct ColourTableStateTests {

    @Test func setTablesAsTheViewDid() {
        let starts: [(String, FormerView)] = [
            ("grey levels", FormerView(red: grey, green: grey, blue: grey, colorTransfer: false, holdsColourBuffer: false)),
            ("grey levels with a colour buffer", FormerView(red: grey, green: grey, blue: grey, colorTransfer: false, holdsColourBuffer: true)),
            ("hot colours", FormerView(red: hot, green: inverse, blue: grey, colorTransfer: true, holdsColourBuffer: true)),
            ("hot colours, no buffer yet", FormerView(red: hot, green: inverse, blue: grey, colorTransfer: true, holdsColourBuffer: false)),
            ("inverse", FormerView(red: inverse, green: inverse, blue: inverse, colorTransfer: true, holdsColourBuffer: false)),
        ]
        let requests: [(String, ([UInt8], [UInt8], [UInt8])?)] = [
            ("grey asked as nil", nil),
            ("the identity", (grey, grey, grey)),
            ("hot colours", (hot, inverse, grey)),
            ("inverse", (inverse, inverse, inverse)),
            ("one entry off the identity", (grey, almostGrey, grey)),
        ]
        for (startName, start) in starts {
            for (requestName, request) in requests {
                var former = start
                let wrote = former.setCLUT(request?.0, request?.1, request?.2)
                let (after, change) = setWithState(start, request)
                #expect(after.red == former.red && after.green == former.green && after.blue == former.blue, "\(startName), \(requestName)")
                #expect(after.colorTransfer == former.colorTransfer, "\(startName), \(requestName)")
                #expect(after.holdsColourBuffer == former.holdsColourBuffer, "\(startName), \(requestName)")
                #expect((change != .unchanged) == wrote, "\(startName), \(requestName)")
            }
        }
    }

    @Test func greyLevelsAreTheIdentityOfEveryChannel() {
        #expect(ColorLookupTable.greyLevels.isGreyLevels)
        #expect(ColorLookupTable.greyLevels.red == grey && ColorLookupTable.greyLevels.blue == grey)
        #expect(!ColorLookupTable(red: grey, green: almostGrey, blue: grey).isGreyLevels)
        #expect(!ColorLookupTable(red: inverse, green: inverse, blue: inverse).isGreyLevels)
        grey.withUnsafeBufferPointer { g in
            almostGrey.withUnsafeBufferPointer { a in
                #expect(ColourTableState.isGreyLevels(red: g.baseAddress!, green: g.baseAddress!, blue: g.baseAddress!))
                #expect(!ColourTableState.isGreyLevels(red: g.baseAddress!, green: g.baseAddress!, blue: a.baseAddress!))
            }
        }
    }

    @Test func aGreyRequestOfAGreyViewWritesNothing() {
        var state = ColourTableState()
        var red = hot, green = hot, blue = hot
        let change = red.withUnsafeMutableBufferPointer { r in
            green.withUnsafeMutableBufferPointer { g in
                blue.withUnsafeMutableBufferPointer { b in
                    state.set(ColourTableState.Tables(red: r.baseAddress!, green: g.baseAddress!, blue: b.baseAddress!), to: nil, holdsColourBuffer: false)
                }
            }
        }
        // The former view took tables without a colour transfer as grey levels, whatever they held.
        #expect(change == .unchanged && red == hot && !state.colorTransfer)
    }

    @Test func writesATableIntoBuffers() {
        var red = [UInt8](repeating: 9, count: 256), green = red, blue = red
        red.withUnsafeMutableBufferPointer { r in
            green.withUnsafeMutableBufferPointer { g in
                blue.withUnsafeMutableBufferPointer { b in
                    ColorLookupTable(red: hot, green: inverse, blue: grey).write(to: ColourTableState.Tables(red: r.baseAddress!, green: g.baseAddress!,
                                                                                                          blue: b.baseAddress!))
                }
            }
        }
        #expect(red == hot && green == inverse && blue == grey)
    }
}
