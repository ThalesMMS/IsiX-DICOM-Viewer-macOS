/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Accelerate
import Foundation

/// A convolution kernel - the sharpen and smoothing filters of the viewer -
/// applied to an image, its edges extended.
public struct ImageConvolution {
    /// Up to 5 × 5 weights, row by row.
    public var weights: [Float]
    /// 3 or 5.
    public var size: Int
    /// The sum the weights are divided by; zero leaves them as they are.
    public var normalization: Float

    public init(weights: UnsafePointer<Float>, size: Int, normalization: Float) {
        self.weights = Array(UnsafeBufferPointer(start: weights, count: 25))
        self.size = size
        self.normalization = normalization
    }

    /// The filtered grey image, in a new buffer the caller frees. Its first
    /// row is the first pixel's value repeated, which keeps the edge free of
    /// the NaN values the filter could leave there.
    public func filtered(_ pixels: UnsafePointer<Float>, width: Int, height: Int) -> UnsafeMutablePointer<Float>? {
        guard let result = malloc(height &* width &* MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self) else {
            return nil
        }
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: pixels), height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size)
        var destination = vImage_Buffer(data: result, height: vImagePixelCount(height),
                                         width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size)
        let kernel = normalization != 0 ? weights.map { $0 / normalization } : weights
        let first = pixels.pointee
        let error = kernel.withUnsafeBufferPointer {
            vImageConvolve_PlanarF(&source, &destination, nil, 0, 0, $0.baseAddress!, UInt32(size), UInt32(size), 0,
                                   vImage_Flags(kvImageDoNotTile + kvImageEdgeExtend))
        }
        result.update(repeating: first, count: width)
        if error != 0 { NSLog("Error applyConvolutionOnImage = %d", Int32(truncatingIfNeeded: error)) }
        return result
    }

    /// The filtered colour image (ARGB, alpha left as it is), in a new buffer
    /// the caller frees. The weights are whole numbers here, and the sum a
    /// whole divisor.
    public func filtered(argb pixels: UnsafeRawPointer, width: Int, height: Int) -> UnsafeMutableRawPointer? {
        guard let result = malloc(height &* width &* 4) else { return nil }
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: pixels), height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size)
        var destination = vImage_Buffer(data: result, height: vImagePixelCount(height),
                                         width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size)
        var whole = [Int16](repeating: 0, count: 25)
        for index in 0..<(size * size) { whole[index] = Int16(truncatingIfNeeded: ImageWindow.cInt(weights[index])) }
        let divisor = ImageWindow.cInt(normalization)
        let error = whole.withUnsafeBufferPointer {
            vImageConvolve_ARGB8888(&source, &destination, nil, 0, 0, $0.baseAddress!, UInt32(size), UInt32(size), divisor, nil,
                                    vImage_Flags(kvImageDoNotTile + kvImageLeaveAlphaUnchanged + kvImageEdgeExtend))
        }
        if error != 0 { NSLog("Error applyConvolutionOnImage = %d", Int32(truncatingIfNeeded: error)) }
        return result
    }
}
