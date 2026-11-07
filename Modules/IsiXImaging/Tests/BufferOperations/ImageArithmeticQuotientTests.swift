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

// The division of the fusion panel: the ratio of two images of one size, pixel
// by pixel, on synthetic images, with the pixels that have no quotient.

private func quotient(_ input: [Float], _ other: [Float], width: Int, height: Int,
                      offset: CGPoint = .zero) -> [Float] {
    let result = input.withUnsafeBufferPointer { a in
        other.withUnsafeBufferPointer { b in
            ImageArithmetic.quotient(a.baseAddress!, b.baseAddress!, width: width, height: height, offset: offset)
        }
    }
    guard let result else { return [] }
    defer { free(result) }
    return Array(UnsafeBufferPointer(start: result, count: width * height))
}

struct ImageArithmeticQuotientTests {
    @Test func eachPixelIsDividedByThePixelOfTheOtherImage() {
        // A T2-like decay over a 4 × 3 grid, divided by a constant and a ramp.
        let width = 4, height = 3
        let input = (0..<width * height).map { Float(1000 - 25 * $0) }
        let other = (0..<width * height).map { Float(2 + $0 % width) }
        let result = quotient(input, other, width: width, height: height)
        #expect(result == zip(input, other).map { $0 / $1 })
        #expect(quotient([6, -6, 1.5], [3, 3, -0.5], width: 3, height: 1) == [2, -2, -3])
    }

    @Test func aPixelDividedByZeroIsZeroAndNeverInfiniteOrNaN() {
        let input: [Float] = [5, -5, 0, .nan, 1, .infinity, 3e38, 7]
        let other: [Float] = [0, -0.0, 0, 2, .nan, 1, 1e-10, 7]
        let result = quotient(input, other, width: 4, height: 2)
        #expect(ImageArithmetic.undefinedQuotient == 0)
        #expect(result.allSatisfy { $0.isFinite })
        // Divided by zero (signed or not, 0 ÷ 0 included), a NaN on either side,
        // an infinite dividend and a quotient past Float's range: all zero.
        #expect(result == [0, 0, 0, 0, 0, 0, 0, 1])
    }

    @Test func aShiftedQuotientIsZeroWhereTheOtherImageHasNoPixel() {
        let a: [Float] = [10, 20, 30, 40, 50, 60], b: [Float] = [2, 4, 5, 8, 10, 0]
        // The other image lies under (x, y) at (x - 1, y): the first column has none.
        #expect(quotient(a, b, width: 3, height: 2, offset: CGPoint(x: 1, y: 0)) == [0, 10, 7.5, 0, 6.25, 6])
        // At (x, y + 1): the last row has none, and 30 ÷ 0 is zero too.
        #expect(quotient(a, b, width: 3, height: 2, offset: CGPoint(x: 0, y: 1)) == [1.25, 2, 0, 0, 0, 0])
    }
}
