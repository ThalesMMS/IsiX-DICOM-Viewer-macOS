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

import Cocoa
import Accelerate

/// Accesses the pixels of an OSIFloatVolumeData under an OSIROIMask.
///
/// Implemented in Swift since #719: the Objective-C name, the selectors and
/// <Horos/OSIROIFloatPixelData.h> are those of the former class. The
/// @synchronized(self) blocks take the same recursive lock (objc_sync_enter),
/// and the cached values use the same keys.
@objc(OSIROIFloatPixelData)
public final class OSIROIFloatPixelData: NSObject {
    private let _valueCache = NSMutableDictionary()
    private var _floatData: NSData?

    @objc public private(set) var ROIMask: OSIROIMask?
    @objc public private(set) var floatVolumeData: OSIFloatVolumeData?

    @objc(initWithROIMask:floatVolumeData:)
    public init(roiMask: OSIROIMask?, floatVolumeData volumeData: OSIFloatVolumeData?) {
        ROIMask = roiMask
        floatVolumeData = volumeData
        super.init()
    }

    /// -init of NSObject left the mask and the volume nil.
    @objc public override convenience init() {
        self.init(roiMask: nil, floatVolumeData: nil)
    }

    /// @synchronized(self)
    @inline(__always)
    private func synchronized<T>(_ body: () -> T) -> T {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        return body()
    }

    @objc public func intensityMean() -> Float {
        var floatCount = self.floatCount()

        return synchronized {
            if let meanNumber = _valueCache.object(forKey: "intensityMean") as? NSNumber {
                return meanNumber.floatValue
            }

            if floatCount == 0 {
                return Float.nan
            }

            var mean: Float = 0
            floatCount = self.floatCount()
            vDSP_meanv(self.floatData()!.bytes.assumingMemoryBound(to: Float.self), 1, &mean, vDSP_Length(floatCount))

            _valueCache.setObject(NSNumber(value: mean), forKey: "intensityMean" as NSString)
            return mean
        }
    }

    // legacy support
    @objc public func meanIntensity() -> Float {
        return self.intensityMean()
    }

    @objc public func intensityMax() -> Float {
        var max: Float = 0

        self.getIntensityMinimum(nil, firstQuartile: nil, secondQuartile: nil, thirdQuartile: nil, maximum: &max)
        return max
    }

    // legacy support
    @objc public func maxIntensity() -> Float {
        return self.intensityMax()
    }

    @objc public func intensityMin() -> Float {
        var min: Float = 0

        self.getIntensityMinimum(&min, firstQuartile: nil, secondQuartile: nil, thirdQuartile: nil, maximum: nil)
        return min
    }

    // legacy support
    @objc public func minIntensity() -> Float {
        return self.intensityMin()
    }

    @objc public func intensityMedian() -> Float {
        var median: Float = 0

        self.getIntensityMinimum(nil, firstQuartile: nil, secondQuartile: &median, thirdQuartile: nil, maximum: nil)
        return median
    }

    @objc(getIntensityMinimum:firstQuartile:secondQuartile:thirdQuartile:maximum:)
    public func getIntensityMinimum(_ minimum: UnsafeMutablePointer<Float>?, firstQuartile: UnsafeMutablePointer<Float>?, secondQuartile: UnsafeMutablePointer<Float>?,
                                    thirdQuartile: UnsafeMutablePointer<Float>?, maximum: UnsafeMutablePointer<Float>?) {
        let floatCount = Int(bitPattern: self.floatCount())

        synchronized {
            let minimumNumber = _valueCache.object(forKey: "intesityMinimum") as? NSNumber
            let Q1Number = _valueCache.object(forKey: "intesityFirstQuartile") as? NSNumber
            let Q2Number = _valueCache.object(forKey: "intesitySecondQuartile") as? NSNumber
            let Q3Number = _valueCache.object(forKey: "intesityThirdQuartile") as? NSNumber
            let maximumNumber = _valueCache.object(forKey: "intesityMaximum") as? NSNumber

            if let minimumNumber, let Q1Number, let Q2Number, let Q3Number, let maximumNumber {
                minimum?.pointee = minimumNumber.floatValue
                firstQuartile?.pointee = Q1Number.floatValue
                secondQuartile?.pointee = Q2Number.floatValue
                thirdQuartile?.pointee = Q3Number.floatValue
                maximum?.pointee = maximumNumber.floatValue
                return
            }

            if floatCount == 0 {
                minimum?.pointee = Float.nan
                firstQuartile?.pointee = Float.nan
                secondQuartile?.pointee = Float.nan
                thirdQuartile?.pointee = Float.nan
                maximum?.pointee = Float.nan
                return
            } else if floatCount == 1 {
                let intensity = self.floatData()!.bytes.assumingMemoryBound(to: Float.self)[0]
                minimum?.pointee = intensity
                firstQuartile?.pointee = intensity
                secondQuartile?.pointee = intensity
                thirdQuartile?.pointee = intensity
                maximum?.pointee = intensity
                return
            }

            let Q1Index: Int
            let Q2Index: Int
            let Q3Index: Int
            let Q3StartIndex: Int
            let QLength: Int

            let Q1: Float
            let Q2: Float
            let Q3: Float

            // Indexed without bounds checks: every index is below floatCount.
            let sorted = UnsafeMutablePointer<Float>.allocate(capacity: floatCount)
            memcpy(sorted, self.floatData()!.bytes, floatCount * MemoryLayout<Float>.size)
            vDSP_vsort(sorted, vDSP_Length(floatCount), 1)

            if floatCount % 2 != 0 { // floatCount is odd
                Q2Index = (floatCount - 1) / 2
                Q3StartIndex = Q2Index + 1
                Q2 = sorted[Q2Index]
            } else {
                Q2Index = floatCount / 2
                Q3StartIndex = Q2Index
                Q2 = (sorted[Q2Index] + sorted[Q2Index - 1]) / 2.0
            }
            QLength = Q2Index

            if QLength % 2 != 0 {
                Q1Index = (QLength - 1) / 2
                Q1 = sorted[Q1Index]

                Q3Index = Q1Index + Q3StartIndex
                Q3 = sorted[Q3Index]
            } else {
                Q1Index = QLength / 2
                Q1 = (sorted[Q1Index] + sorted[Q1Index - 1]) / 2.0

                Q3Index = Q1Index + Q3StartIndex
                Q3 = (sorted[Q3Index] + sorted[Q3Index - 1]) / 2.0
            }

            _valueCache.setObject(NSNumber(value: sorted[0]), forKey: "intesityMinimum" as NSString)
            _valueCache.setObject(NSNumber(value: Q1), forKey: "intesityFirstQuartile" as NSString)
            _valueCache.setObject(NSNumber(value: Q2), forKey: "intesitySecondQuartile" as NSString)
            _valueCache.setObject(NSNumber(value: Q3), forKey: "intesityThirdQuartile" as NSString)
            _valueCache.setObject(NSNumber(value: sorted[floatCount - 1]), forKey: "intesityMaximum" as NSString)

            minimum?.pointee = sorted[0]
            firstQuartile?.pointee = Q1
            secondQuartile?.pointee = Q2
            thirdQuartile?.pointee = Q3
            maximum?.pointee = sorted[floatCount - 1]

            sorted.deallocate()
        }
    }

    @objc public func intensityInterQuartileRange() -> Float {
        var Q1: Float = 0
        var Q3: Float = 0
        self.getIntensityMinimum(nil, firstQuartile: &Q1, secondQuartile: nil, thirdQuartile: &Q3, maximum: nil)
        return Q3 - Q1
    }

    @objc public func intensityStandardDeviation() -> Float {
        var negativeMean = -self.meanIntensity()
        let floatCount = self.floatCount()

        return synchronized {
            if let standardDeviationNumber = _valueCache.object(forKey: "intensityStandardDeviation") as? NSNumber {
                return standardDeviationNumber.floatValue
            }

            if floatCount == 0 {
                return Float.nan
            }

            var unscaledStdDev: Float = 0
            let scrap1 = UnsafeMutablePointer<Float>.allocate(capacity: Int(floatCount))
            let scrap2 = UnsafeMutablePointer<Float>.allocate(capacity: Int(floatCount))

            vDSP_vsadd(self.floatData()!.bytes.assumingMemoryBound(to: Float.self), 1, &negativeMean, scrap1, 1, vDSP_Length(floatCount))
            vDSP_vsq(scrap1, 1, scrap2, 1, vDSP_Length(floatCount))
            vDSP_sve(scrap2, 1, &unscaledStdDev, vDSP_Length(floatCount))

            scrap1.deallocate()
            scrap2.deallocate()

            let stdDev = sqrtf(unscaledStdDev / Float(floatCount))

            _valueCache.setObject(NSNumber(value: stdDev), forKey: "intensityStandardDeviation" as NSString)
            return stdDev
        }
    }

    @objc public func floatCount() -> UInt {
        return synchronized {
            if let floatData = _floatData {
                return UInt(floatData.length / MemoryLayout<Float>.size)
            }

            var floatCount: UInt = 0
            for case let runValue as NSValue in ROIMask?.maskRuns() ?? NSArray() {
                let maskRun = runValue.osiroiMaskRun()
                floatCount = floatCount &+ UInt(bitPattern: maskRun.widthRange.length)
            }
            return floatCount
        }
    }

    // Copies at most count floats, and returns how many. The former code
    // copied the whole data, whatever count was (#774).
    @objc(getFloatData:floatCount:)
    public func getFloatData(_ buffer: UnsafeMutablePointer<Float>!, floatCount count: UInt) -> UInt {
        return synchronized {
            let floatData = self.floatData()
            let floatDataCount = UInt((floatData?.length ?? 0) / MemoryLayout<Float>.size)
            let floatsCopied = count < floatDataCount ? count : floatDataCount
            floatData?.getBytes(buffer, length: Int(floatsCopied) * MemoryLayout<Float>.size)
            return floatsCopied
        }
    }

    @objc public func floatData() -> NSData? {
        return synchronized {
            if let floatData = _floatData {
                return floatData
            }

            let byteCount = Int(bitPattern: self.floatCount() &* UInt(MemoryLayout<Float>.size))
            let buffer = malloc(byteCount)!.assumingMemoryBound(to: Float.self)
            var floatBuffer = buffer
            memset(buffer, 0, byteCount)

            for case let runValue as NSValue in ROIMask?.maskRuns() ?? NSArray() {
                let maskRun = runValue.osiroiMaskRun()
                _ = floatVolumeData?.getFloatRun(floatBuffer, atPixelCoordinateX: UInt(bitPattern: maskRun.widthRange.location), y: maskRun.heightIndex, z: maskRun.depthIndex, length: UInt(bitPattern: maskRun.widthRange.length))
                floatBuffer += maskRun.widthRange.length
            }

            _floatData = NSData(bytesNoCopy: buffer, length: Int(bitPattern: self.floatCount() &* UInt(MemoryLayout<Float>.size)), freeWhenDone: true)
            return _floatData
        }
    }
}
