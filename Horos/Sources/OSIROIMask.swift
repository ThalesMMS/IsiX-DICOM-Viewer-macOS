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

/// The object a predicate of -filteredROIMaskUsingPredicate:floatVolumeData:
/// is evaluated against, read by key-value coding.
///
/// It was private to OSIROIMask.m; public, with the same Objective-C name, so
/// that the executable keeps exporting the class.
@objc(OSIMaskIndexPredicateStandIn)
public final class OSIMaskIndexPredicateStandIn: NSObject {
    @objc public var intensity: Float = 0
    @objc public var ROIMaskIntensity: Float = 0
    @objc public var ROIMaskIndexX: UInt = 0
    @objc public var ROIMaskIndexY: UInt = 0
    @objc public var ROIMaskIndexZ: UInt = 0
}

/// Converts a width range field to the NSUInteger of the former C arithmetic.
@inline(__always)
private func u(_ value: Int) -> UInt {
    return UInt(bitPattern: value)
}

/// The order of OSIROIMaskQSortCompareRun, in OSIROIMask+CAPI.m, for qsort.
private let osiROIMaskQSortCompareRun: @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?) -> Int32 = { voidMaskRun1, voidMaskRun2 in
    let maskRun1 = voidMaskRun1!.assumingMemoryBound(to: OSIROIMaskRun.self)
    let maskRun2 = voidMaskRun2!.assumingMemoryBound(to: OSIROIMaskRun.self)

    if maskRun1.pointee.depthIndex < maskRun2.pointee.depthIndex {
        return Int32(ComparisonResult.orderedAscending.rawValue)
    } else if maskRun1.pointee.depthIndex > maskRun2.pointee.depthIndex {
        return Int32(ComparisonResult.orderedDescending.rawValue)
    }

    if maskRun1.pointee.heightIndex < maskRun2.pointee.heightIndex {
        return Int32(ComparisonResult.orderedAscending.rawValue)
    } else if maskRun1.pointee.heightIndex > maskRun2.pointee.heightIndex {
        return Int32(ComparisonResult.orderedDescending.rawValue)
    }

    if u(maskRun1.pointee.widthRange.location) < u(maskRun2.pointee.widthRange.location) {
        return Int32(ComparisonResult.orderedAscending.rawValue)
    } else if u(maskRun1.pointee.widthRange.location) > u(maskRun2.pointee.widthRange.location) {
        return Int32(ComparisonResult.orderedDescending.rawValue)
    }

    return Int32(ComparisonResult.orderedSame.rawValue)
}

/// Sorts an array of OSIROIMaskRun values with -sortedArrayUsingFunction:context:
/// and the C function OSIROIMaskCompareRunValues, as the former code did.
private func sortedMaskRunValues(_ maskRuns: NSArray?) -> NSArray? {
    guard let maskRuns else {
        return nil
    }
    let compare: @convention(c) (NSValue?, NSValue?, UnsafeMutableRawPointer?) -> ComparisonResult = OSIROIMaskCompareRunValues
    // The same function pointer, typed as NSArray's Swift overlay expects it:
    // both take two object pointers and a context and return an NSInteger.
    let function = unsafeBitCast(compare, to: (@convention(c) (Any, Any, UnsafeMutableRawPointer?) -> Int).self)
    return maskRuns.sortedArray(function, context: nil) as NSArray
}

/// A mask that can be applied to a volume, stored as a set of width-direction
/// runs (OSIROIMaskRun).
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/OSIROIMask.h> are those of the former class. The C functions, the
/// OSIROIMaskRunZero constant and the NSValue category stay in Objective-C, in
/// OSIROIMask+CAPI.m.
@objc(OSIROIMask)
public final class OSIROIMask: NSObject, NSCopying {
    private var _maskRunsData: NSData?
    private var _maskRuns: NSArray?

    private init(maskRuns: NSArray?, maskRunsData: NSData?) {
        _maskRuns = maskRuns
        _maskRunsData = maskRunsData
        super.init()
    }

    @objc(ROIMask)
    public class func roiMask() -> OSIROIMask {
        return OSIROIMask()
    }

    @objc(ROIMaskFromVolumeData:)
    public class func roiMask(fromVolumeData floatVolumeData: OSIFloatVolumeData?) -> OSIROIMask {
        let maskRuns = NSMutableArray()
        var maskRun = OSIROIMaskRunZero
        maskRun.intensity = 0.0
        var inlineBuffer = CPRVolumeDataInlineBuffer()

        withUnsafeMutablePointer(to: &inlineBuffer) { inlineBufferPointer in
            if floatVolumeData?.aquireInlineBuffer(inlineBufferPointer) == true {
                let inlineBuffer = inlineBufferPointer.pointee
                let pixelsWide = Int(bitPattern: inlineBuffer.pixelsWide)
                let pixelsHigh = Int(bitPattern: inlineBuffer.pixelsHigh)
                let pixelsDeep = Int(bitPattern: inlineBuffer.pixelsDeep)
                let pixelsWideTimesPixelsHigh = Int(bitPattern: inlineBuffer.pixelsWideTimesPixelsHigh)
                // The volume is read through an unchecked pointer, as
                // CPRVolumeDataGetFloatAtPixelCoordinate did: i, j and k stay
                // inside the volume, so its bounds test never failed, and it
                // returned 0 when there were no float bytes.
                let floatBytes = inlineBuffer.floatBytes

                for k in 0..<pixelsDeep {
                    for j in 0..<pixelsHigh {
                        for i in 0..<pixelsWide {
                            var intensity: Float = 0
                            if let floatBytes {
                                intensity = floatBytes[i + j * pixelsWide + k * pixelsWideTimesPixelsHigh]
                            }
                            intensity = OSIROIMask.roundedIntensity(intensity)

                            if intensity != maskRun.intensity { // maybe start a run, maybe close a run
                                if maskRun.intensity != 0 { // we need to end the previous run
                                    maskRuns.add(NSValue(osiroiMaskRun: maskRun)!)
                                    maskRun = OSIROIMaskRunZero
                                    maskRun.intensity = 0.0
                                }

                                if intensity != 0 { // we need to start a new mask run
                                    maskRun.depthIndex = UInt(k)
                                    maskRun.heightIndex = UInt(j)
                                    maskRun.widthRange = NSMakeRange(i, 1)
                                    maskRun.intensity = intensity
                                }
                            } else { // maybe extend a run // maybe do nothing
                                if intensity != 0 { // we need to extend the run
                                    maskRun.widthRange.length += 1
                                }
                            }
                        }
                        // after each run scan line we need to close out any open mask run
                        if maskRun.intensity != 0 {
                            maskRuns.add(NSValue(osiroiMaskRun: maskRun)!)
                            maskRun = OSIROIMaskRunZero
                            maskRun.intensity = 0.0
                        }
                    }
                }
            }

            floatVolumeData?.releaseInlineBuffer(inlineBufferPointer)
        }

        return OSIROIMask(maskRuns: maskRuns)
    }

    /// roundf(intensity*255.0f)/255.0f. The Release build compiled the former
    /// code with -ffast-math, which turned the division by the constant into a
    /// multiplication by its float reciprocal; Debug divided.
    @inline(__always)
    private static func roundedIntensity(_ intensity: Float) -> Float {
        #if DEBUG
        return roundf(intensity * 255.0) / 255.0
        #else
        return roundf(intensity * 255.0) * (1.0 / 255.0 as Float)
        #endif
    }

    @objc public override convenience init() {
        self.init(maskRuns: NSArray(), maskRunsData: nil)
    }

    @objc(initWithMaskRuns:)
    public convenience init(maskRuns: NSArray?) {
        self.init(maskRuns: sortedMaskRunValues(maskRuns), maskRunsData: nil)
        self.checkdebug()
    }

    @objc(initWithMaskRunData:)
    public convenience init(maskRunData: NSData?) {
        let mutableMaskRunData = maskRunData?.mutableCopy() as? NSMutableData

        qsort(mutableMaskRunData?.mutableBytes, (mutableMaskRunData?.length ?? 0) / MemoryLayout<OSIROIMaskRun>.size, MemoryLayout<OSIROIMaskRun>.size, osiROIMaskQSortCompareRun)

        self.init(sortedMaskRunData: mutableMaskRunData)
    }

    @objc(initWithSortedMaskRunData:)
    public convenience init(sortedMaskRunData maskRunData: NSData?) {
        self.init(maskRuns: nil, maskRunsData: maskRunData)
        self.checkdebug()
    }

    @objc(initWithSortedMaskRuns:)
    public convenience init(sortedMaskRuns maskRuns: NSArray?) {
        self.init(maskRuns: maskRuns, maskRunsData: nil)
        self.checkdebug()
    }

    @objc(initWithIndexes:)
    public convenience init(indexes maskIndexes: NSArray?) {
        let count = maskIndexes?.count ?? 0
        let maskData = NSMutableData(length: count * MemoryLayout<OSIROIMaskIndex>.size)!
        let maskIndexArray = maskData.mutableBytes.assumingMemoryBound(to: OSIROIMaskIndex.self)
        for i in 0..<count {
            maskIndexArray[i] = (maskIndexes![i] as! NSValue).osiroiMaskIndexValue()
        }

        self.init(indexData: maskData)
    }

    @objc(initWithIndexData:)
    public convenience init(indexData: NSData?) {
        let indexes = indexData?.bytes.assumingMemoryBound(to: OSIROIMaskIndex.self)
        let indexCount = (indexData?.length ?? 0) / MemoryLayout<OSIROIMaskIndex>.size
        let maskRuns = NSMutableArray()
        var maskRun = OSIROIMaskRunZero

        if indexCount == 0 {
            self.init(maskRuns: NSArray(), maskRunsData: nil)
            return
        }

        for i in 0..<indexCount {
            maskRun.widthRange.location = Int(bitPattern: indexes![i].x)
            maskRun.widthRange.length = 1
            maskRun.heightIndex = indexes![i].y
            maskRun.depthIndex = indexes![i].z
            maskRuns.add(NSValue(osiroiMaskRun: maskRun)!)
        }

        let sortedMaskRuns = sortedMaskRunValues(maskRuns)!
        let newSortedRuns = NSMutableArray()

        maskRun = (sortedMaskRuns[0] as! NSValue).osiroiMaskRun()

        for i in 1..<max(indexCount, 1) {
            let sortedRun = (sortedMaskRuns[i] as! NSValue).osiroiMaskRun()

            if u(NSMaxRange(maskRun.widthRange)) == u(sortedRun.widthRange.location) &&
                maskRun.heightIndex == sortedRun.heightIndex &&
                maskRun.depthIndex == sortedRun.depthIndex {
                maskRun.widthRange.length += 1
            } else if OSIROIMaskRunsOverlap(maskRun, sortedRun) {
                NSLog("overlap?")
            } else {
                newSortedRuns.add(NSValue(osiroiMaskRun: maskRun)!)
                maskRun = sortedRun
            }
        }

        newSortedRuns.add(NSValue(osiroiMaskRun: maskRun)!)
        self.init(maskRuns: newSortedRuns, maskRunsData: nil)
        self.checkdebug()
    }

    @objc(initWithSortedIndexes:)
    public convenience init(sortedIndexes maskIndexes: NSArray?) {
        let count = maskIndexes?.count ?? 0
        let maskData = NSMutableData(length: count * MemoryLayout<OSIROIMaskIndex>.size)!
        let maskIndexArray = maskData.mutableBytes.assumingMemoryBound(to: OSIROIMaskIndex.self)
        for i in 0..<count {
            maskIndexArray[i] = (maskIndexes![i] as! NSValue).osiroiMaskIndexValue()
        }

        self.init(sortedIndexData: maskData)
    }

    @objc(initWithSortedIndexData:)
    public convenience init(sortedIndexData indexData: NSData?) {
        // The count is in indexes, and each index joins the run by its own y
        // and z. The former code counted bytes, read past the indexes, and
        // compared every index with indexes[1].
        let indexes = indexData?.bytes.assumingMemoryBound(to: OSIROIMaskIndex.self)
        let indexCount = (indexData?.length ?? 0) / MemoryLayout<OSIROIMaskIndex>.size
        let maskRuns = NSMutableArray()

        if indexCount == 0 {
            self.init(maskRuns: NSArray(), maskRunsData: nil)
            return
        }

        var maskRun = OSIROIMaskRunZero
        maskRun.widthRange.location = Int(bitPattern: indexes![0].x)
        maskRun.widthRange.length = 1
        maskRun.heightIndex = indexes![0].y
        maskRun.depthIndex = indexes![0].z

        for i in 1..<max(indexCount, 1) {
            if u(NSMaxRange(maskRun.widthRange)) == indexes![i].x &&
                maskRun.heightIndex == indexes![i].y &&
                maskRun.depthIndex == indexes![i].z {
                maskRun.widthRange.length += 1
            } else {
                maskRuns.add(NSValue(osiroiMaskRun: maskRun)!)
                maskRun.widthRange.location = Int(bitPattern: indexes![i].x)
                maskRun.widthRange.length = 1
                maskRun.heightIndex = indexes![i].y
                maskRun.depthIndex = indexes![i].z
            }
        }

        maskRuns.add(NSValue(osiroiMaskRun: maskRun)!)
        self.init(maskRuns: maskRuns, maskRunsData: nil)
        self.checkdebug()
    }

    @objc(copyWithZone:)
    public func copy(with zone: NSZone? = nil) -> Any {
        return OSIROIMask(sortedMaskRuns: self.maskRuns()?.copy() as? NSArray)
    }

    @objc(ROIMaskByTranslatingByX:Y:Z:)
    public func roiMaskByTranslatingBy(x: Int, y: Int, z: Int) -> OSIROIMask? {
        let newMaskRuns = NSMutableArray(capacity: self.maskRuns()?.count ?? 0)

        for case let maskRunValue as NSValue in self.maskRuns() ?? NSArray() {
            var maskRun = maskRunValue.osiroiMaskRun()

            cprVolumeDataAssert(maskRun.widthRange.location >= -x)
            maskRun.widthRange.location = maskRun.widthRange.location &+ x

            cprVolumeDataAssert(Int(bitPattern: maskRun.heightIndex) >= -y)
            maskRun.heightIndex = maskRun.heightIndex &+ UInt(bitPattern: y)

            cprVolumeDataAssert(Int(bitPattern: maskRun.depthIndex) >= -z)
            maskRun.depthIndex = maskRun.depthIndex &+ UInt(bitPattern: z)

            newMaskRuns.add(NSValue(osiroiMaskRun: maskRun)!)
        }

        return OSIROIMask(sortedMaskRuns: newMaskRuns)
    }

    @objc(ROIMaskByIntersectingWithMask:)
    public func roiMaskByIntersecting(withMask otherMask: OSIROIMask?) -> OSIROIMask? {
        return self.roiMaskBySubtractingMask(self.roiMaskBySubtractingMask(otherMask))
    }

    @objc(ROIMaskByUnioningWithMask:)
    public func roiMaskByUnioning(withMask otherMask: OSIROIMask?) -> OSIROIMask? {
        var index1: UInt = 0
        var index2: UInt = 0

        var runToAdd = OSIROIMaskRunZero
        var accumulatedRun = OSIROIMaskRunZero
        accumulatedRun.widthRange.length = 0

        let maskRun1Data = self.maskRunsData()
        let maskRun2Data = otherMask?.maskRunsData()
        // The runs are read through unchecked pointers: index1 and index2 stay
        // below the run counts of the two masks.
        let maskRunArray1 = maskRun1Data?.bytes.assumingMemoryBound(to: OSIROIMaskRun.self)
        let maskRunArray2 = maskRun2Data?.bytes.assumingMemoryBound(to: OSIROIMaskRun.self)

        let resultMaskRuns = NSMutableData()

        while index1 < self.maskRunCount() || index2 < (otherMask?.maskRunCount() ?? 0) {
            if index1 < self.maskRunCount() && index2 < (otherMask?.maskRunCount() ?? 0) {
                if OSIROIMaskCompareRun(maskRunArray1![Int(index1)], maskRunArray2![Int(index2)]) == .orderedAscending {
                    runToAdd = maskRunArray1![Int(index1)]
                    index1 += 1
                } else {
                    runToAdd = maskRunArray2![Int(index2)]
                    index2 += 1
                }
            } else if index1 < self.maskRunCount() {
                runToAdd = maskRunArray1![Int(index1)]
                index1 += 1
            } else {
                runToAdd = maskRunArray2![Int(index2)]
                index2 += 1
            }

            if accumulatedRun.widthRange.length == 0 {
                accumulatedRun = runToAdd
            } else if OSIROIMaskRunsOverlap(runToAdd, accumulatedRun) || OSIROIMaskRunsAbut(runToAdd, accumulatedRun) {
                if u(NSMaxRange(runToAdd.widthRange)) > u(NSMaxRange(accumulatedRun.widthRange)) {
                    accumulatedRun.widthRange.length = NSMaxRange(runToAdd.widthRange) &- accumulatedRun.widthRange.location
                }
            } else {
                resultMaskRuns.append(&accumulatedRun, length: MemoryLayout<OSIROIMaskRun>.size)
                accumulatedRun = runToAdd
            }
        }

        if accumulatedRun.widthRange.length != 0 {
            resultMaskRuns.append(&accumulatedRun, length: MemoryLayout<OSIROIMaskRun>.size)
        }

        return OSIROIMask(sortedMaskRunData: resultMaskRuns)
    }

    @objc(ROIMaskBySubtractingMask:)
    public func roiMaskBySubtractingMask(_ subtractMask: OSIROIMask?) -> OSIROIMask? {
        let templateRunStack = OSIROIMaskRunStack(maskRunData: self.maskRunsData())
        var newMaskRun: OSIROIMaskRun
        var length: Int

        var subtractIndex = 0
        let subtractData = subtractMask?.maskRunsData()
        let subtractDataCount = (subtractData?.length ?? 0) / MemoryLayout<OSIROIMaskRun>.size
        // Read through an unchecked pointer: subtractIndex stays below subtractDataCount.
        let subtractRunArray = subtractData?.bytes.assumingMemoryBound(to: OSIROIMaskRun.self)

        let resultMaskRuns = NSMutableData()
        var tempMaskRun: OSIROIMaskRun

        while subtractIndex < subtractDataCount && templateRunStack.count() != 0 {
            let subtractRun = subtractRunArray![subtractIndex]
            if OSIROIMaskRunsOverlap(templateRunStack.currentMaskRun(), subtractRun) == false {
                if OSIROIMaskCompareRun(templateRunStack.currentMaskRun(), subtractRun) == .orderedAscending {
                    tempMaskRun = templateRunStack.currentMaskRun()
                    resultMaskRuns.append(&tempMaskRun, length: MemoryLayout<OSIROIMaskRun>.size)
                    templateRunStack.popMaskRun()
                } else {
                    subtractIndex += 1
                }
            } else {
                // run the 4 cases
                if NSLocationInRange(templateRunStack.currentMaskRun().widthRange.location, subtractRun.widthRange) {
                    if NSLocationInRange(NSMaxRange(templateRunStack.currentMaskRun().widthRange) &- 1, subtractRun.widthRange) {
                        // 1.
                        templateRunStack.popMaskRun()
                    } else {
                        // 2.
                        newMaskRun = templateRunStack.currentMaskRun()
                        length = NSIntersectionRange(templateRunStack.currentMaskRun().widthRange, subtractRun.widthRange).length
                        newMaskRun.widthRange.location = newMaskRun.widthRange.location &+ length
                        newMaskRun.widthRange.length = newMaskRun.widthRange.length &- length
                        templateRunStack.popMaskRun()
                        templateRunStack.pushMaskRun(newMaskRun)
                        cprVolumeDataAssert(newMaskRun.widthRange.length > 0)
                    }
                } else {
                    if NSLocationInRange(NSMaxRange(templateRunStack.currentMaskRun().widthRange) &- 1, subtractRun.widthRange) {
                        // 4.
                        newMaskRun = templateRunStack.currentMaskRun()
                        length = NSIntersectionRange(templateRunStack.currentMaskRun().widthRange, subtractRun.widthRange).length
                        newMaskRun.widthRange.length = newMaskRun.widthRange.length &- length
                        templateRunStack.popMaskRun()
                        templateRunStack.pushMaskRun(newMaskRun)
                        cprVolumeDataAssert(newMaskRun.widthRange.length > 0)
                    } else {
                        // 3.
                        let originalMaskRun = templateRunStack.currentMaskRun()
                        templateRunStack.popMaskRun()

                        newMaskRun = originalMaskRun
                        length = NSMaxRange(subtractRun.widthRange) &- originalMaskRun.widthRange.location
                        newMaskRun.widthRange.location = newMaskRun.widthRange.location &+ length
                        newMaskRun.widthRange.length = newMaskRun.widthRange.length &- length
                        templateRunStack.pushMaskRun(newMaskRun)
                        cprVolumeDataAssert(newMaskRun.widthRange.length > 0)

                        newMaskRun = originalMaskRun
                        length = NSMaxRange(originalMaskRun.widthRange) &- subtractRun.widthRange.location
                        newMaskRun.widthRange.length = newMaskRun.widthRange.length &- length
                        templateRunStack.pushMaskRun(newMaskRun)
                        cprVolumeDataAssert(newMaskRun.widthRange.length > 0)
                    }
                }
            }
        }

        while templateRunStack.count() != 0 {
            tempMaskRun = templateRunStack.currentMaskRun()
            resultMaskRuns.append(&tempMaskRun, length: MemoryLayout<OSIROIMaskRun>.size)
            templateRunStack.popMaskRun()
        }

        return OSIROIMask(sortedMaskRunData: resultMaskRuns)
    }

    // probably could use a faster implementation...
    @objc(intersectsMask:)
    public func intersectsMask(_ otherMask: OSIROIMask?) -> Bool {
        let intersection = self.roiMaskByIntersecting(withMask: otherMask)
        return (intersection?.maskRunCount() ?? 0) > 0
    }

    // super lazy implementation FIXME!
    @objc(isEqualToMask:)
    public func isEqual(toMask otherMask: OSIROIMask?) -> Bool {
        let intersection = self.roiMaskByIntersecting(withMask: otherMask)
        let subMask1 = self.roiMaskBySubtractingMask(intersection)
        let subMask2 = otherMask?.roiMaskBySubtractingMask(intersection)

        return (subMask1?.maskRunCount() ?? 0) == 0 && (subMask2?.maskRunCount() ?? 0) == 0
    }

    @objc(filteredROIMaskUsingPredicate:floatVolumeData:)
    public func filteredROIMask(using predicate: NSPredicate?, floatVolumeData: OSIFloatVolumeData?) -> OSIROIMask? {
        let newMaskArray = NSMutableArray()
        var activeMaskRun = OSIROIMaskRunZero
        var isMaskRunActive = false
        var intensity: Float = 0
        let standIn = OSIMaskIndexPredicateStandIn()

        for case let maskRunValue as NSValue in self.maskRuns() ?? NSArray() {
            let maskRun = maskRunValue.osiroiMaskRun()

            var maskIndex = OSIROIMaskIndex()
            maskIndex.y = maskRun.heightIndex
            maskIndex.z = maskRun.depthIndex

            standIn.ROIMaskIntensity = maskRun.intensity
            standIn.ROIMaskIndexY = maskIndex.y
            standIn.ROIMaskIndexZ = maskIndex.z

            maskIndex.x = u(maskRun.widthRange.location)
            while maskIndex.x < u(NSMaxRange(maskRun.widthRange)) {
                _ = floatVolumeData?.getFloat(&intensity, atPixelCoordinateX: maskIndex.x, y: maskIndex.y, z: maskIndex.z)
                standIn.ROIMaskIndexX = maskIndex.x
                standIn.intensity = intensity

                if predicate?.evaluate(with: standIn) == true {
                    if isMaskRunActive {
                        activeMaskRun.widthRange.length += 1
                    } else {
                        activeMaskRun.widthRange.location = Int(bitPattern: maskIndex.x)
                        activeMaskRun.widthRange.length = 1
                        activeMaskRun.heightIndex = maskIndex.y
                        activeMaskRun.depthIndex = maskIndex.z
                        activeMaskRun.intensity = maskRun.intensity
                        isMaskRunActive = true
                    }
                } else {
                    if isMaskRunActive {
                        newMaskArray.add(NSValue(osiroiMaskRun: activeMaskRun)!)
                        isMaskRunActive = false
                    }
                }
                maskIndex.x = maskIndex.x &+ 1
            }
            if isMaskRunActive {
                newMaskArray.add(NSValue(osiroiMaskRun: activeMaskRun)!)
                isMaskRunActive = false
            }
        }

        let filteredMask = OSIROIMask(sortedMaskRuns: newMaskArray)
        filteredMask.checkdebug()
        return filteredMask
    }

    @objc public func maskRuns() -> NSArray? {
        if _maskRuns == nil {
            let maskRunCount = (_maskRunsData?.length ?? 0) / MemoryLayout<OSIROIMaskRun>.size
            let maskRunArray = _maskRunsData?.bytes.assumingMemoryBound(to: OSIROIMaskRun.self)
            let maskRuns = NSMutableArray(capacity: maskRunCount)
            for i in 0..<maskRunCount {
                maskRuns.add(NSValue(osiroiMaskRun: maskRunArray![i])!)
            }
            _maskRuns = maskRuns
        }

        return _maskRuns
    }

    @objc public func maskRunsData() -> NSData? {
        if _maskRunsData == nil {
            let count = _maskRuns?.count ?? 0
            let byteCount = count * MemoryLayout<OSIROIMaskRun>.size
            let maskRunArray = malloc(byteCount)!.assumingMemoryBound(to: OSIROIMaskRun.self)

            for i in 0..<count {
                maskRunArray[i] = (_maskRuns![i] as! NSValue).osiroiMaskRun()
            }

            _maskRunsData = NSData(bytesNoCopy: maskRunArray, length: byteCount, freeWhenDone: true)
        }

        return _maskRunsData
    }

    @objc public func maskRunCount() -> UInt {
        return UInt(self.maskRuns()?.count ?? 0)
    }

    @objc public func maskIndexCount() -> UInt {
        let maskRunData = self.maskRunsData()
        let maskRunArray = maskRunData?.bytes.assumingMemoryBound(to: OSIROIMaskRun.self)
        let maskRunCount = self.maskRunCount()
        var maskIndexCount: UInt = 0

        var i: UInt = 0
        while i < maskRunCount {
            maskIndexCount = maskIndexCount &+ u(maskRunArray![Int(i)].widthRange.length)
            i += 1
        }

        return maskIndexCount
    }

    @objc public func maskIndexes() -> NSArray? {
        let indexes = NSMutableArray()

        for case let maskRunValue as NSValue in self.maskRuns() ?? NSArray() {
            let maskRun = maskRunValue.osiroiMaskRun()
            if maskRun.intensity != 0 {
                indexes.addObjects(from: OSIROIMaskIndexesInRun(maskRun) ?? [])
            }
        }

        return indexes
    }

    @objc(indexInMask:)
    public func index(inMask index: OSIROIMaskIndex) -> Bool {
        // since the runs are sorted, we can binary search
        var runIndex: UInt = 0
        var runCount: UInt = 0

        let maskRunsData = self.maskRunsData()
        // Read through an unchecked pointer: the binary search stays within the runs.
        let maskRuns = maskRunsData?.bytes.assumingMemoryBound(to: OSIROIMaskRun.self)
        runCount = self.maskRunCount()

        while runCount != 0 {
            let middleIndex = runIndex &+ (runCount / 2)
            let middleRun = maskRuns![Int(middleIndex)]
            if OSIROIMaskIndexInRun(index, middleRun) {
                return true
            }

            var before = false
            if index.z < middleRun.depthIndex {
                before = true
            } else if index.z == middleRun.depthIndex && index.y < middleRun.heightIndex {
                before = true
            } else if index.z == middleRun.depthIndex && index.y == middleRun.heightIndex && index.x < u(middleRun.widthRange.location) {
                before = true
            }

            if before {
                runCount /= 2
            } else {
                runIndex = middleIndex &+ 1
                runCount = (runCount &- 1) / 2
            }
        }

        return false
    }

    // N3Vectors stored in NSValue objects. The mask is inside of these points
    @objc public func convexHull() -> NSArray? {
        var maxHeight = Int.min
        var minHeight = Int.max
        var maxDepth = Int.min
        var minDepth = Int.max
        var maxWidth = Int.min
        var minWidth = Int.max

        for case let maskRunValue as NSValue in self.maskRuns() ?? NSArray() {
            let maskRun = maskRunValue.osiroiMaskRun()

            maxHeight = macroMax(maxHeight, Int(bitPattern: maskRun.heightIndex) &+ 1)
            minHeight = macroMin(minHeight, Int(bitPattern: maskRun.heightIndex) &- 1)

            // The former MAX compared the NSInteger maxDepth with the
            // NSUInteger depthIndex + 1 as unsigned values, so NSIntegerMin
            // always won.
            maxDepth = macroMax(maxDepth, Int(bitPattern: maskRun.depthIndex) &+ 1)
            minDepth = macroMin(minDepth, Int(bitPattern: maskRun.depthIndex) &- 1)

            maxWidth = macroMax(maxWidth, NSMaxRange(maskRun.widthRange) &+ 1)
            minWidth = macroMin(minWidth, maskRun.widthRange.location &- 1)
        }

        let hull = NSMutableArray(capacity: 8)
        hull.add(NSValue(n3Vector: N3VectorMake(CGFloat(minWidth), CGFloat(minDepth), CGFloat(minHeight)))!)
        hull.add(NSValue(n3Vector: N3VectorMake(CGFloat(minWidth), CGFloat(maxDepth), CGFloat(minHeight)))!)
        hull.add(NSValue(n3Vector: N3VectorMake(CGFloat(maxWidth), CGFloat(maxDepth), CGFloat(minHeight)))!)
        hull.add(NSValue(n3Vector: N3VectorMake(CGFloat(maxWidth), CGFloat(minDepth), CGFloat(minHeight)))!)
        hull.add(NSValue(n3Vector: N3VectorMake(CGFloat(minWidth), CGFloat(minDepth), CGFloat(maxHeight)))!)
        hull.add(NSValue(n3Vector: N3VectorMake(CGFloat(minWidth), CGFloat(maxDepth), CGFloat(maxHeight)))!)
        hull.add(NSValue(n3Vector: N3VectorMake(CGFloat(maxWidth), CGFloat(maxDepth), CGFloat(maxHeight)))!)
        hull.add(NSValue(n3Vector: N3VectorMake(CGFloat(maxWidth), CGFloat(minDepth), CGFloat(maxHeight)))!)

        return hull
    }

    @objc public func centerOfMass() -> N3Vector {
        let maskData = self.maskRunsData()
        let runCount = (maskData?.length ?? 0) / MemoryLayout<OSIROIMaskRun>.size
        // Read through an unchecked pointer: i stays below runCount.
        let runArray = maskData?.bytes.assumingMemoryBound(to: OSIROIMaskRun.self)
        var floatCount: CGFloat = 0
        var centerOfMass = N3VectorZero

        for i in 0..<runCount {
            let run = runArray![i]
            let location = CGFloat(u(run.widthRange.location))
            let length = CGFloat(u(run.widthRange.length))
            // clang fused each `+= a * b` into a multiply-add; the products of the
            // integer-valued run coordinates are exact, so fusing does not change them.
            centerOfMass.x = fma(location + (length / 2.0), length, centerOfMass.x)
            centerOfMass.y = fma(CGFloat(run.heightIndex), length, centerOfMass.y)
            centerOfMass.z = fma(CGFloat(run.depthIndex), length, centerOfMass.z)
            floatCount += length
        }

        #if DEBUG
        centerOfMass.x /= floatCount
        centerOfMass.y /= floatCount
        centerOfMass.z /= floatCount
        #else
        // -ffast-math in the former Release build: one reciprocal, three products.
        let reciprocal = 1.0 / floatCount
        centerOfMass.x *= reciprocal
        centerOfMass.y *= reciprocal
        centerOfMass.z *= reciprocal
        #endif

        return centerOfMass
    }

    @objc func checkdebug() {
        #if DEBUG
        // make sure that all the runs are in order.
        precondition(_maskRuns != nil || _maskRunsData != nil)
        if let maskRunsData = _maskRunsData {
            let maskRunsDataCount = maskRunsData.length / MemoryLayout<OSIROIMaskRun>.size
            let maskRunArray = maskRunsData.bytes.assumingMemoryBound(to: OSIROIMaskRun.self)
            var i = 0
            while i < maskRunsDataCount - 1 {
                precondition(OSIROIMaskCompareRun(maskRunArray[i], maskRunArray[i + 1]) == .orderedAscending)
                precondition(OSIROIMaskRunsOverlap(maskRunArray[i], maskRunArray[i + 1]) == false)
                i += 1
            }
            for i in 0..<maskRunsDataCount {
                precondition(maskRunArray[i].widthRange.length > 0)
            }
        }

        if let maskRuns = _maskRuns {
            var i = 0
            while i < maskRuns.count - 1 {
                precondition(OSIROIMaskCompareRunValues(maskRuns[i] as? NSValue, maskRuns[i + 1] as? NSValue, nil) == .orderedAscending)
                precondition(OSIROIMaskRunsOverlap((maskRuns[i] as! NSValue).osiroiMaskRun(), (maskRuns[i + 1] as! NSValue).osiroiMaskRun()) == false)
                i += 1
            }
            for i in 0..<maskRuns.count {
                precondition((maskRuns[i] as! NSValue).osiroiMaskRun().widthRange.length > 0)
            }
        }
        #endif
    }
}

/// MAX of the former code for two NSIntegers.
@inline(__always)
private func macroMax(_ a: Int, _ b: Int) -> Int {
    return a < b ? b : a
}

/// MIN of the former code for two NSIntegers.
@inline(__always)
private func macroMin(_ a: Int, _ b: Int) -> Int {
    return a < b ? a : b
}
