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

/// Fills one slice of the Y cache: the transposed copy of a source image, laid
/// out by HorosResliceCacheLayout.
///
/// Public with its former Objective-C name, so the executable still exports it.
@objc(ResliceOperation)
public final class ResliceOperation: Operation, @unchecked Sendable {
    private let dict: NSDictionary?

    @objc(initWithDict:)
    public init(dict d: NSDictionary!) {
        dict = d
        super.init()
    }

    public override func main() {
        autoreleasepool {
            NSLog("+")

            let originalDCMPixList = dict?.object(forKey: "DCMPixArray") as! NSArray
            let fPix = originalDCMPixList.object(at: 0) as! DCMPix
            let Ycache = (dict?.object(forKey: "Ycache") as! NSValue).pointerValue!.assumingMemoryBound(to: Float.self)

            let maxY = Int32(truncatingIfNeeded: fPix.pheight)
            let maxX = Int32(truncatingIfNeeded: fPix.pwidth)

            let z = (dict?.object(forKey: "zValue") as! NSNumber).int32Value

            // Unchecked pointers in the copy loop, as the Objective-C had.
            var basedstPtr = Ycache + ResliceCacheLayout.sliceBase(slice: Int(z), width: Int(maxX), height: Int(maxY))
            var basesrcPtr: UnsafeMutablePointer<Float> = (originalDCMPixList.object(at: Int(z)) as! DCMPix).fImage
            var x = maxX
            while x > 0 {
                x -= 1
                var dstPtr = basedstPtr
                var srcPtr = basesrcPtr

                basedstPtr += Int(maxY)
                basesrcPtr += 1

                var yy = maxY
                while yy > 0 {
                    yy -= 1
                    dstPtr.pointee = srcPtr.pointee
                    dstPtr += 1
                    srcPtr += Int(maxX)
                }
            }
        }
    }
}

/// Reslices a volume sagittally and coronally.
///
/// The Objective-C name and selectors are those of the former class.
@objc(OrthogonalReslice)
public final class OrthogonalReslice: NSObject {
    /// Assigned, not retained, as the Objective-C did: the caller owns the
    /// list for the reslicer's lifetime.
    private unowned(unsafe) var _originalDCMPixList: NSMutableArray?
    private let _xReslicedDCMPixList: NSMutableArray
    private let _yReslicedDCMPixList: NSMutableArray
    private let newPixListX: NSMutableArray
    private let newPixListY: NSMutableArray
    private var _thickSlab: Int16
    private var sign: Float = 0

    private var _useYcache: Bool
    private var Ycache: UnsafeMutablePointer<Float>?
    /// Whether this Y reslice reads the cache: decided once by -axeReslice::
    /// before it starts the threads, and only read by them.
    private var readsYcache = false

    private var minI = 0, maxI = 0, newX = 0, newY = 0, newTotal = 0, currentAxe = 0
    /// The first image of the list, not retained, as the Objective-C did.
    private unowned(unsafe) var firstPix: DCMPix?

    private var yCacheQueue: OperationQueue?
    private var processorsLock: NSLock?
    /// Only read and written under processorsLock.
    private var numberOfThreadsForCompute: Int32 = 0

    // init
    @objc public override init() {
        _xReslicedDCMPixList = NSMutableArray(capacity: 0)
        _yReslicedDCMPixList = NSMutableArray(capacity: 0)

        newPixListX = NSMutableArray(capacity: 0)
        newPixListY = NSMutableArray(capacity: 0)

        _thickSlab = 1
        Ycache = nil
        _useYcache = true
        super.init()
    }

    @objc(initWithOriginalDCMPixList:)
    public convenience init(originalDCMPixList pixList: NSMutableArray!) {
        self.init()

        self.setOriginalDCMPixList(pixList)

        let sliceInterval: Float

        if (pixList.object(at: 0) as! DCMPix).sliceInterval == 0 {
            sliceInterval = Float((pixList.object(at: 1) as! DCMPix).sliceLocation - (pixList.object(at: 0) as! DCMPix).sliceLocation)
        } else {
            sliceInterval = Float((pixList.object(at: 0) as! DCMPix).sliceInterval)
        }

        sign = (sliceInterval > 0) ? 1.0 : -1.0
    }

    @objc(setOriginalDCMPixList:)
    public func setOriginalDCMPixList(_ pixList: NSMutableArray!) {
        _originalDCMPixList = pixList
    }

    deinit {
        while (yCacheQueue?.operationCount ?? 0) > 0 {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if let Ycache = Ycache { free(Ycache) }
    }

    @objc(xReslice:)
    public func xReslice(_ x: Int) {
        self.axeReslice(0, x)
    }

    /// Reached by a thread selector in the former code; kept for callers
    /// that still name it.
    @objc(xResliceThread:)
    public func xResliceThread(_ xNum: NSNumber!) {
        autoreleasepool {
            do {
                try HorosObjCException.perform {
                    self.xReslice(Int(xNum.int32Value))
                }
            } catch {
                if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                    _N2LogExceptionImpl(e, true, "-[OrthogonalReslice xResliceThread:]")
                }
            }
        }
    }

    @objc(yReslice:)
    public func yReslice(_ y: Int) {
        self.axeReslice(1, y)
    }

    // processors
    @objc(reslice::)
    public func reslice(_ x: Int, _ y: Int) {
        self.yReslice(x)
        self.xReslice(y)
    }

    /// One band of rows, on one of the threads -axeReslice:: starts.
    @objc(subReslice:)
    public func subReslice(_ posNumber: NSNumber!) {
        let pos = Int(posNumber.int32Value)
        let threads = Int(Int32(truncatingIfNeeded: ProcessInfo.processInfo.processorCount))
        let originalDCMPixList = _originalDCMPixList!

        let from = (pos * newY) / threads
        let to = ((pos + 1) * newY) / threads

        var i = minI
        var stack = 0
        while i < maxI {
            if i < 0 { i = 0 }
            if i >= newTotal { i = newTotal - 1 }

            if currentAxe == 0 {     // X - RESLICE
                let curPix = newPixListX.object(at: stack) as! DCMPix

                if sign > 0 {
                    let curPixfImage: UnsafeMutablePointer<Float> = curPix.fImage

                    var y = from
                    while y < to {
                        let srcP = (originalDCMPixList.object(at: y) as! DCMPix).fImage! + i * newX

                        let dstP = curPixfImage + (newY - y - 1) * newX

                        memcpy(dstP, srcP, newX * MemoryLayout<Float>.size)
                        y += 1
                    }
                } else {
                    let curPixfImage: UnsafeMutablePointer<Float> = curPix.fImage

                    var y = from
                    while y < to {
                        let srcP = (originalDCMPixList.object(at: y) as! DCMPix).fImage! + i * firstPix!.pwidth

                        memcpy(curPixfImage + y * newX, srcP, newX * MemoryLayout<Float>.size)
                        y += 1
                    }
                }
            } else {                 // Y - RESLICE
                let rowBytes = firstPix!.pwidth

                let curPix = newPixListY.object(at: stack) as! DCMPix

                // Every thread takes the path -axeReslice:: chose. Asking the
                // queue here let a thread that came late read the cache while
                // the others read the images, and with a positive interval the
                // two paths fill mirrored bands: rows were written twice and
                // others not at all.
                if readsYcache, let Ycache = Ycache {
                    if sign > 0 {
                        let curPixfImage: UnsafeMutablePointer<Float> = curPix.fImage
                        let srcPix = originalDCMPixList.object(at: 0) as! DCMPix
                        let w = srcPix.pheight

                        var y = from
                        while y < to {
                            let srcP = Ycache + ResliceCacheLayout.sliceBase(slice: y, width: newTotal, height: newX)
                                              + ResliceCacheLayout.columnOffset(column: i, height: w)
                            let dstP = curPixfImage + (newY - y - 1) * newX

                            memcpy(dstP, srcP, newX * MemoryLayout<Float>.size)
                            y += 1
                        }
                    } else {
                        let curPixfImage: UnsafeMutablePointer<Float> = curPix.fImage

                        var y = from
                        while y < to {
                            // Columns are newX apart in the cache; a stride of
                            // newTotal, the width, hatched non-square images
                            // and read past the last slice (#374, A225).
                            let srcP = Ycache + ResliceCacheLayout.sliceBase(slice: y, width: newTotal, height: newX)
                                              + ResliceCacheLayout.columnOffset(column: i, height: newX)

                            memcpy(curPixfImage + y * newX, srcP, newX * MemoryLayout<Float>.size)
                            y += 1
                        }
                    }
                } else {
                    var x = from
                    while x < to {
                        var srcPtr: UnsafeMutablePointer<Float>
                        if sign > 0 {
                            srcPtr = (originalDCMPixList.object(at: newY - x - 1) as! DCMPix).fImage! + i
                        } else {
                            srcPtr = (originalDCMPixList.object(at: x) as! DCMPix).fImage! + i
                        }
                        var dstPtr: UnsafeMutablePointer<Float> = curPix.fImage! + x * newX

                        // Unchecked pointers in the copy loop, as the
                        // Objective-C had.
                        var yy = newX
                        while yy > 0 {
                            yy -= 1
                            dstPtr.pointee = srcPtr.pointee
                            dstPtr += 1
                            srcPtr += rowBytes
                        }
                        x += 1
                    }
                }
            }
            i += 1
            stack += 1
        }

        processorsLock!.lock()
        numberOfThreadsForCompute -= 1
        processorsLock!.unlock()
    }

    @objc(axeReslice::)
    public func axeReslice(_ axe: Int16, _ sliceNumber: Int) {
        let originalDCMPixList = _originalDCMPixList!
        let firstPix = originalDCMPixList.object(at: 0) as! DCMPix
        self.firstPix = firstPix

        let lastPix = originalDCMPixList.lastObject as! DCMPix
        var orientation = [Float](repeating: 0, count: 9)
        var origin = [Float](repeating: 0, count: 3)
        let newXSpace: Float, newYSpace: Float, sliceInterval: Float
        let isRGB = firstPix.isRGB

        currentAxe = Int(axe)

        if firstPix.sliceInterval == 0 {
            sliceInterval = Float((originalDCMPixList.object(at: 1) as! DCMPix).sliceLocation - firstPix.sliceLocation)
        } else {
            sliceInterval = Float(firstPix.sliceInterval)
        }

        // Get Values
        if axe == 0 {       // X - RESLICE
            newTotal = firstPix.pheight
            newX = firstPix.pwidth
            newXSpace = Float(firstPix.pixelSpacingX)
            newYSpace = Float(fabs(Double(sliceInterval)))
            newY = originalDCMPixList.count
        } else {            // Y - RESLICE
            newTotal = firstPix.pwidth
            newX = firstPix.pheight
            newY = originalDCMPixList.count
            newXSpace = Float(firstPix.pixelSpacingY)
            newYSpace = Float(fabs(Double(sliceInterval)))
        }

        // CREATE A NEW SERIES WITH *ONE* IMAGE !

        var curPix: DCMPix
        var stack = 0

        if _thickSlab <= 1 {
            _thickSlab = 1
            minI = max(0, min(sliceNumber, newTotal - 1))
            maxI = minI + 1
        } else {
            _thickSlab = (_thickSlab == 0) ? 1 : _thickSlab
            minI = Int(Double(sliceNumber) - floor(Double(Float(_thickSlab)) / 2.0))
            maxI = Int(Double(sliceNumber) + ceil(Double(Float(_thickSlab)) / 2.0))

            if maxI > newTotal - 1 {
                maxI = newTotal - 1
                if minI == maxI { minI = maxI - 1 }
            }
        }

        // Y - CACHE activated only if thick slab and if enough memory is available
        if axe != 0 {
            if _thickSlab > 1 && Ycache == nil {
                if _useYcache {
                    Ycache = malloc(ResliceCacheLayout.elementCount(width: newTotal, height: newX, slices: newY) * MemoryLayout<Float>.size)?
                        .assumingMemoryBound(to: Float.self)
                }

                if let Ycache = Ycache {
                    NSLog("start YCache")

                    let queue = OperationQueue()
                    yCacheQueue = queue

                    for x in 0..<max(newY, 0) {
                        let op = ResliceOperation(dict: NSDictionary(objects: [NSValue(pointer: UnsafeRawPointer(Ycache)), NSNumber(value: Int32(truncatingIfNeeded: x)), originalDCMPixList],
                                                                     forKeys: ["Ycache" as NSString, "zValue" as NSString, "DCMPixArray" as NSString]))

                        queue.addOperation(op)
                    }
                }
            }
        }

        if axe == 0 {       // X - RESLICE
            if sign > 0 {
                lastPix.orientation(&orientation)
            } else {
                firstPix.orientation(&orientation)
            }

            if sign > 0 {
                // Y Vector = Normal Vector
                orientation[3] = orientation[6] * -sign
                orientation[4] = orientation[7] * -sign
                orientation[5] = orientation[8] * -sign
            } else {
                // Y Vector = Normal Vector
                orientation[3] = orientation[6] * sign
                orientation[4] = orientation[7] * sign
                orientation[5] = orientation[8] * sign
            }
        } else {
            if sign > 0 {
                lastPix.orientation(&orientation)
            } else {
                firstPix.orientation(&orientation)
            }

            // Y Vector = Normal Vector
            orientation[0] = orientation[3]
            orientation[1] = orientation[4]
            orientation[2] = orientation[5]

            if sign > 0 {
                orientation[3] = orientation[6] * -sign
                orientation[4] = orientation[7] * -sign
                orientation[5] = orientation[8] * -sign
            } else {
                orientation[3] = orientation[6] * sign
                orientation[4] = orientation[7] * sign
                orientation[5] = orientation[8] * sign
            }
        }

        var bits: Int16 = 32
        if isRGB { bits = 8 }

        var i = minI
        stack = 0
        while i < maxI {
            if i < 0 { i = 0 }

            if axe == 0 {       // X - RESLICE
                if stack >= newPixListX.count {
                    curPix = DCMPix(data: nil, bits, newX, newY, 1, 1, 0, 0, 0, false)
                    curPix.copySUVfrom(firstPix)
                    curPix.frameofReferenceUID = firstPix.frameofReferenceUID
                    curPix.modalityString = firstPix.modalityString
                    newPixListX.add(curPix)
                } else {
                    curPix = newPixListX.object(at: stack) as! DCMPix
                }
            } else {
                if stack >= newPixListY.count {
                    curPix = DCMPix(data: nil, bits, newX, newY, 1, 1, 0, 0, 0, false)
                    curPix.copySUVfrom(firstPix)
                    curPix.frameofReferenceUID = firstPix.frameofReferenceUID
                    curPix.modalityString = firstPix.modalityString
                    newPixListY.add(curPix)
                } else {
                    curPix = newPixListY.object(at: stack) as! DCMPix
                }
            }

            _ = curPix.fImage   // <- Force CheckLoad
            curPix.displayInverted = firstPix.displayInverted

            curPix.tot = 0
            curPix.frameNo = 0
            curPix.id = 0

            // The origins are the Objective-C expression, whose last product
            // and sum clang fuses: originX + ((i * spacing) * cosine) * sign.
            if axe == 0 {       // X - RESLICE
                curPix.setOrientation(&orientation)   // Normal vector is recomputed in this procedure

                curPix.pixelSpacingX = Double(newXSpace)
                curPix.pixelSpacingY = Double(newYSpace)

                curPix.pixelRatio = Double(newYSpace / newXSpace)

                curPix.orientation(&orientation)

                let step = Double(i) * firstPix.pixelSpacingY
                if sign > 0 {
                    origin[0] = Float(lastPix.originX.addingProduct(step * Double(orientation[6]), Double(sign)))
                    origin[1] = Float(lastPix.originY.addingProduct(step * Double(orientation[7]), Double(sign)))
                    origin[2] = Float(lastPix.originZ.addingProduct(step * Double(orientation[8]), Double(sign)))
                } else {
                    origin[0] = Float(firstPix.originX.addingProduct(step * Double(orientation[6]), Double(-sign)))
                    origin[1] = Float(firstPix.originY.addingProduct(step * Double(orientation[7]), Double(-sign)))
                    origin[2] = Float(firstPix.originZ.addingProduct(step * Double(orientation[8]), Double(-sign)))
                }

                curPix.setOrigin(&origin)
                curPix.computeSliceLocation()

                curPix.sliceThickness = firstPix.pixelSpacingY
                curPix.sliceInterval = firstPix.pixelSpacingY
            } else {
                curPix.setOrientation(&orientation)   // Normal vector is recomputed in this procedure

                curPix.pixelSpacingX = Double(newXSpace)
                curPix.pixelSpacingY = Double(newYSpace)

                curPix.pixelRatio = Double(newYSpace / newXSpace)

                curPix.orientation(&orientation)

                let step = Double(i) * firstPix.pixelSpacingX
                if sign > 0 {
                    origin[0] = Float(lastPix.originX.addingProduct(step * Double(orientation[6]), Double(-sign)))
                    origin[1] = Float(lastPix.originY.addingProduct(step * Double(orientation[7]), Double(-sign)))
                    origin[2] = Float(lastPix.originZ.addingProduct(step * Double(orientation[8]), Double(-sign)))
                } else {
                    origin[0] = Float(firstPix.originX.addingProduct(step * Double(orientation[6]), Double(sign)))
                    origin[1] = Float(firstPix.originY.addingProduct(step * Double(orientation[7]), Double(sign)))
                    origin[2] = Float(firstPix.originZ.addingProduct(step * Double(orientation[8]), Double(sign)))
                }
                curPix.setOrigin(&origin)
                curPix.computeSliceLocation()

                curPix.sliceThickness = firstPix.pixelSpacingX
                curPix.sliceInterval = firstPix.pixelSpacingY
            }
            i += 1
            stack += 1
        }

        if axe == 0 {       // X - RESLICE
            if newPixListX.count > stack {
                newPixListX.removeObjects(in: NSMakeRange(stack, newPixListX.count - stack))
            }
        } else {
            if newPixListY.count > stack {
                newPixListY.removeObjects(in: NSMakeRange(stack, newPixListY.count - stack))
            }
        }

        if processorsLock == nil {
            processorsLock = NSLock()
        }

        // The cache is read only once every slice is in it, and then by all
        // the threads of this reslice.
        readsYcache = axe != 0 && Ycache != nil && (yCacheQueue?.operationCount ?? 0) == 0

        numberOfThreadsForCompute = Int32(truncatingIfNeeded: ProcessInfo.processInfo.processorCount)
        var thread = 0
        while thread < ProcessInfo.processInfo.processorCount - 1 {
            Thread.detachNewThreadSelector(#selector(subReslice(_:)), toTarget: self, with: NSNumber(value: Int32(truncatingIfNeeded: thread)))
            thread += 1
        }

        self.subReslice(NSNumber(value: Int32(truncatingIfNeeded: thread)))

        var done = false
        while !done {
            processorsLock!.lock()
            if numberOfThreadsForCompute <= 0 { done = true }
            processorsLock!.unlock()
        }

        if axe == 0 {
            _xReslicedDCMPixList.setArray(newPixListX as! [Any])
        } else {
            _yReslicedDCMPixList.setArray(newPixListY as! [Any])
        }
    }

    // accessors
    @objc public var originalDCMPixList: NSMutableArray! {
        return _originalDCMPixList
    }

    @objc public var xReslicedDCMPixList: NSMutableArray! {
        return _xReslicedDCMPixList
    }

    @objc public var yReslicedDCMPixList: NSMutableArray! {
        return _yReslicedDCMPixList
    }

    // thickSlab
    @objc public var thickSlab: Int16 {
        get { return _thickSlab }
        @objc(setThickSlab:) set { _thickSlab = newValue }
    }

    @objc public func flipVolume() {
        sign = -sign
    }

    /// The operations still filling the cache write into it: those not
    /// started are cancelled and the running ones waited for before it is
    /// freed. Freeing it under them wrote into freed memory.
    @objc(freeYCache)
    public func freeYCache() {
        if let queue = yCacheQueue {
            queue.cancelAllOperations()
            queue.waitUntilAllOperationsAreFinished()
        }
        yCacheQueue = nil
        if let Ycache = Ycache { free(Ycache) }
        Ycache = nil
    }

    @objc public var useYcache: Bool {
        get { return _useYcache }
        set {
            _useYcache = newValue
            if !newValue {
                self.freeYCache()
            }
        }
    }
}
