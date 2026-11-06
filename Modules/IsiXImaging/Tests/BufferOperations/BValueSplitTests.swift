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

// The b-values of a diffusion series and their groups, against the grouping
// the app ran before BValueSplit (`formerGroups`, copied from the former
// DiffusionBValueSplit.groups), and the readers of each vendor's tag.

private func formerGroups(_ bValues: [Double?]) -> [(bValue: Double?, indices: [Int])] {
    var order: [Double] = []
    var byValue: [Double: [Int]] = [:]
    var unknown: [Int] = []
    for (index, value) in bValues.enumerated() {
        guard let value else { unknown.append(index); continue }
        let key = value.rounded()
        if byValue[key] == nil { order.append(key) }
        byValue[key, default: []].append(index)
    }
    var result = order.sorted().map { (bValue: Optional($0), indices: byValue[$0] ?? []) }
    if !unknown.isEmpty { result.append((bValue: nil, indices: unknown)) }
    return result.count >= 2 ? result : []
}

struct BValueSplitTests {
    @Test func theGroupsAreTheFormerOnes() {
        var generator = SystemRandomNumberGenerator()
        let values: [Double?] = [nil, 0, 0.4, 50, 499.6, 500, 800, 1000, 1000.2, 2000]
        for _ in 0..<500 {
            let count = Int.random(in: 0...24, using: &generator)
            let series = (0..<count).map { _ in values.randomElement(using: &generator)! }
            let current = BValueSplit.groups(series)
            let former = formerGroups(series)
            #expect(current.count == former.count, "\(series)")
            for (group, expected) in zip(current, former) {
                #expect(group.bValue == expected.bValue && group.indices == expected.indices, "\(series)")
            }
        }
    }

    @Test func eachVendorsTagGivesItsBValue() {
        func b(_ standard: Any? = nil, siemens: Any? = nil, ge: Any? = nil, philips: Any? = nil, sequence: Any? = nil) -> Double? {
            BValueSplit.bValue([standard, siemens, ge, philips, sequence])
        }
        #expect(BValueSplit.tags == ["0018,9087", "0019,100C", "0043,1039", "2001,1003", "0018,0024"])
        #expect(b(NSNumber(value: 800.0)) == 800)
        #expect(b(siemens: Data("500".utf8)) == 500)
        #expect(b(ge: "1000000800\\8\\0\\0") == 800)
        // An array as Objective-C gives it, and as Swift does.
        #expect(b(ge: [NSNumber(value: 1000)] as AnyObject) == 1000)
        #expect(b(ge: [NSNumber(value: 1000)]) == 1000)
        var philips = Float(1500).bitPattern.littleEndian
        #expect(b(philips: Data(bytes: &philips, count: 4)) == 1500)
        #expect(b(sequence: "*ep_b1000t") == 1000)
        #expect(b(sequence: "ep2d_diff") == nil)
        #expect(b() == nil)
    }
}
