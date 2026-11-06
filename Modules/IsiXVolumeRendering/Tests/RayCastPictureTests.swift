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
@testable import IsiXVolumeRendering

/// The ray-cast image's words, and Metal's picture going into them.
struct RayCastPictureTests {

    @Test func theRegionHasItsOriginAtTheTop() {
        #expect(RayCastPicture.region(viewportWidth: 100, viewportHeight: 80, originX: 3, originY: 5, usedWidth: 40, usedHeight: 30)
                == [100, 80, 3, 45, 40, 30])
    }

    @Test func aCompositePictureBecomesFifteenBitWords() throws {
        // Two pixels, BGRA: blue 255, then red 51; opacities 1 and NaN.
        let bgra = Data([255, 0, 0, 255, 0, 0, 51, 255])
        var opacity: [Float] = [1, .nan]
        let scalar = Data(bytes: &opacity, count: 8)
        let picture = try #require(RayCastPicture.composite(bgra: bgra, opacity: scalar))
        let words = picture.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        #expect(words == [0, 0, 32767, 32767, UInt16((51 * 32767 + 127) / 255), 0, 0, 0])
        #expect(RayCastPicture.composite(bgra: Data([1, 2, 3]), opacity: scalar) == nil)
    }

    @Test func thePictureGoesInBottomRowFirstOverAClearedImage() {
        var image = [UInt16](repeating: 9, count: 3 * 2 * 4)
        let picture: [UInt16] = (0..<16).map { UInt16($0) }
        image.withUnsafeMutableBufferPointer { out in
            picture.withUnsafeBufferPointer { RayCastPicture.replace(out.baseAddress!, memoryWidth: 3, memoryHeight: 2,
                                                                     with: $0.baseAddress!, usedWidth: 2, usedHeight: 2) }
        }
        #expect(Array(image[0..<8]) == (8..<16).map { UInt16($0) } && Array(image[8..<12]) == [0, 0, 0, 0])
        #expect(Array(image[12..<20]) == (0..<8).map { UInt16($0) })
        let words = image.withUnsafeBufferPointer { RayCastPicture.inUseWords($0.baseAddress!, memoryWidth: 3, usedWidth: 2, usedHeight: 2) }
        #expect(words?.count == 32)
        #expect(RayCastPicture.inUseWords(nil, memoryWidth: 3, usedWidth: 2, usedHeight: 2) == nil)
    }

    @Test func fullDepthValuesAreRoundedClampedAndZeroForNoValue() {
        var image = [UInt16](repeating: 7, count: 2 * 2 * 4)
        let values: [Float] = [1.5, -1000, .nan, 1e9]
        image.withUnsafeMutableBufferPointer { out in
            values.withUnsafeBufferPointer {
                RayCastPicture.writeFullDepthProjection(out.baseAddress!, stride: 8, width: 2, height: 2,
                                                        values: $0.baseAddress!, offset: 1, factor: 2)
            }
        }
        // Top row (values 0 and 1) is the image's second row.
        #expect(image[11] == 5 && image[15] == 0 && image[3] == 0 && image[7] == 65535 && image[0] == 7)
    }
}
