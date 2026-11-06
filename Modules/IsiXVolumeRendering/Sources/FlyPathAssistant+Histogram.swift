/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork


import Accelerate
import Foundation

/// The thresholds of the lumen, from the input's histogram (the former
/// FlyAssistant+Histo category, by Benoit Deville, 2012): the interval around
/// the peak a value falls in, bounded by the histogram's local minima. The
/// histogram has one bin per unit of the input's range, smoothed by a 1 2 4 …
/// 4 2 1 kernel, in vImage's unsigned counts and with their unsigned
/// arithmetic, as the former code had them.
extension FlyPathAssistant {

    /// The input's smallest and largest values, NaN left out.
    func determineImageRange() {
        var low = Float.greatestFiniteMagnitude
        var high = -Float.greatestFiniteMagnitude
        let values = UnsafeBufferPointer(start: input, count: max(inputVolumeSize, 0))
        for value in values {
            if value < low { low = value }
            if value > high { high = value }
        }
        inputMinValue = low
        inputMaxValue = high
    }

    /// One bin per unit from the smallest value to the largest, by vImage.
    func computeHistogram() {
        let size = cUInt32(inputMaxValue - inputMinValue)
        inputHistogram?.deallocate()
        let histogram = UnsafeMutablePointer<vImagePixelCount>.allocate(capacity: max(Int(size), 1))
        histogram.initialize(repeating: 0, count: max(Int(size), 1))
        inputHistogram = histogram
        histogramSize = size
        var buffer = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: input), height: 1,
                                   width: vImagePixelCount(max(inputVolumeSize, 0)),
                                   rowBytes: max(inputVolumeSize, 0) * MemoryLayout<Float>.size)
        _ = vImageHistogramCalculation_PlanarF(&buffer, histogram, UInt32(size), inputMinValue, inputMaxValue,
                                               vImage_Flags(kvImageNoFlags))
    }

    /// The histogram convolved with 1 2 4 … 2^window … 4 2 1 over its sum.
    /// Each bin i from `window` on takes the kernel centered on the bin
    /// `window` before it, and the bins below `window` keep their counts, as
    /// the former loop did; the margins repeat the first bin, and the last
    /// bins but one at the far end.
    func smoothHistogram(window: Int) {
        guard let histogram = inputHistogram else { return }
        let limit = Int(histogramSize)
        let size = limit + 2 * window
        if window > limit { return }
        var original = [vImagePixelCount](repeating: 0, count: size)
        for i in 0..<limit {
            original[i + window] = histogram[i]
        }
        for i in 0..<window {
            original[i] = histogram[0]
            if size - i >= 0 && limit - i >= 0 && limit - i < limit && size - i < size {
                original[size - i] = histogram[limit - i]
            }
        }
        var i = window
        while i < limit {
            histogram[i] = original[i] &<< vImagePixelCount(window)
            var weight = 1 << window
            for j in 1...max(window, 1) where j <= window {
                histogram[i] = histogram[i] &+ ((original[j + i] &<< vImagePixelCount(j)) &+ (original[i - j] &<< vImagePixelCount(j)))
                weight += 1 << (j + 1)
            }
            histogram[i] /= vImagePixelCount(bitPattern: weight)
            i += 1
        }
    }

    /// The count of a bin, as the former code read it into an int; 0 outside
    /// the histogram, where it read past its end.
    func bin(_ index: Int) -> Int32 {
        Int32(truncatingIfNeeded: binCount(index))
    }

    func binCount(_ index: Int) -> vImagePixelCount {
        guard let histogram = inputHistogram, index >= 0, index < Int(histogramSize) else { return 0 }
        return histogram[index]
    }

    /// thresholdA and thresholdB: the local minima of the histogram on either
    /// side of the peak `pixValue` falls in, 10 bins a step. A value at the
    /// start or the end of the range starts 20 bins inside it. The search out
    /// of a peak stops at the end of the histogram, which the former loop read
    /// past.
    public func computeIntervalThresholds(from pixValue: Float) {
        if inputHistogram == nil {
            computeHistogram()
            smoothHistogram(window: 5)
        }

        let delta: Int32 = 10
        var value: Int32
        if pixValue == inputMinValue {
            value = delta << 1
        } else if pixValue == inputMaxValue {
            value = Int32(truncatingIfNeeded: histogramSize &- UInt32(delta << 1))
        } else {
            value = Int32(truncatingIfNeeded: cInt(pixValue - inputMinValue))
        }

        var x = bin(Int(value))
        var prev = bin(Int(value) - Int(delta))
        var next = bin(Int(value) + Int(delta))

        // get out of peak if local maxima
        while prev <= x && next <= x {
            value &+= delta
            if value < 0 || Int(value) >= Int(histogramSize) { break }
            prev = x
            x = next
            next = bin(Int(value))
        }

        let lower: Int32
        if prev <= x {
            lower = localMinimum(step: -delta, from: start(value &- delta))
        } else {
            lower = localMinimum(step: -delta, from: start(localMaximum(step: -delta, from: start(value &- delta))))
        }
        let upper: Int32
        if next <= x {
            upper = localMinimum(step: delta, from: start(value &+ delta))
        } else {
            upper = localMinimum(step: delta, from: start(localMaximum(step: delta, from: start(value &+ delta))))
        }
        thresholdA = Float(lower) + inputMinValue
        thresholdB = Float(upper) + inputMinValue
    }

    /// An int passed where the former methods took a vImagePixelCount.
    private func start(_ value: Int32) -> vImagePixelCount {
        vImagePixelCount(bitPattern: Int(value))
    }

    /// From `value`, `step` bins at a time while the count goes down by more
    /// than a sixteenth of the bins' number, in unsigned arithmetic: below 0
    /// the position wraps past the histogram's end and the search stops.
    func localMinimum(step: Int32, from start: vImagePixelCount) -> Int32 {
        let maxi = Int32(truncatingIfNeeded: histogramSize)
        let epsilon = maxi >> 4
        let limit = vImagePixelCount(bitPattern: Int(maxi))
        let increment = vImagePixelCount(bitPattern: Int(step))
        var value = start
        var xprev: Int32
        repeat {
            xprev = Int32(truncatingIfNeeded: value)
            value = value &+ increment
        } while value < limit && binCount(Int(xprev)) >= binCount(Int(value))
            && cAbs(Int32(truncatingIfNeeded: binCount(Int(xprev))) &- Int32(truncatingIfNeeded: binCount(Int(value)))) > epsilon
        return xprev
    }

    /// From `value`, `step` bins at a time while the count does not go down.
    func localMaximum(step: Int32, from start: vImagePixelCount) -> Int32 {
        let limit = vImagePixelCount(bitPattern: Int(Int32(truncatingIfNeeded: histogramSize)))
        let increment = vImagePixelCount(bitPattern: Int(step))
        var value = start
        var xprev: Int32
        repeat {
            xprev = Int32(truncatingIfNeeded: value)
            value = value &+ increment
        } while value < limit && binCount(Int(xprev)) <= binCount(Int(value))
        return xprev
    }
}

/// C's abs of an int: abs(INT_MIN) stays INT_MIN, where Swift's traps.
func cAbs(_ value: Int32) -> Int32 {
    value == Int32.min ? value : abs(value)
}
