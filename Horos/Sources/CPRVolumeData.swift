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
import Synchronization

/// `assert` of the former Objective-C: active in Debug (no NDEBUG), compiled out
/// in Release. Swift's own `assert` is compiled out by `-O`, which the Debug
/// configuration also uses, so the check is spelled with `precondition`.
@inline(__always)
func cprVolumeDataAssert(_ condition: @autoclosure () -> Bool, file: StaticString = #file, line: UInt = #line) {
    #if DEBUG
    precondition(condition(), file: file, line: line)
    #endif
}

/// Interface to a float volume: the pixel data, its size and the transform from
/// Dicom (patient) space to pixel coordinates.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/CPRVolumeData.h> are those of the former class. The C part of the
/// header (CPRInterpolationMode, CPRVolumeDataInlineBuffer and the inline
/// sampling functions) is unchanged, and the sampling methods below reach those
/// same inline functions. Open, because OSIFloatVolumeData subclasses it.
///
/// The interpolating getters sample through the ...ForSwift functions of
/// CPRVolumeData+CAPI.m, which call the inline samplers from Objective-C: the
/// target compiles Objective-C with -ffast-math in Release, and clang then
/// reassociates and vectorises the samplers. Swift calling the inline functions
/// would compile them without -ffast-math, and the Release linear interpolation
/// would round differently from the Objective-C callers of the same functions.
///
/// Readers and `-invalidateData` synchronise as before: a reader increments the
/// reader count with a full barrier and checks the valid flag again, and
/// `-invalidateData` clears the flag with a full barrier and spins until the
/// reader count drops to zero. The atomics are sequentially consistent, as the
/// OSAtomic*Barrier and OSMemoryBarrier calls were.
@objc(CPRVolumeData)
open class CPRVolumeData: NSObject {
    private let readerCount = Atomic<Int32>(0)
    private let valid: Atomic<Bool>

    private var _floatBytes: UnsafePointer<Float>?
    private let _outOfBoundsValue: Float

    private let _pixelsWide: UInt
    private let _pixelsHigh: UInt
    private let _pixelsDeep: UInt

    // volumeTransform is the transform from Dicom (patient) space to pixel data
    private let _volumeTransform: N3AffineTransform

    private let _freeWhenDone: Bool

    // volumeData objects that point to the same underlying data
    private let _childSubvolumes: NSMutableDictionary?

    // volumeTransform is the transform from Dicom (patient) space to pixel data
    @objc(initWithFloatBytesNoCopy:pixelsWide:pixelsHigh:pixelsDeep:volumeTransform:outOfBoundsValue:freeWhenDone:)
    public init(floatBytesNoCopy floatBytes: UnsafePointer<Float>?, pixelsWide: UInt, pixelsHigh: UInt, pixelsDeep: UInt,
                volumeTransform: N3AffineTransform, outOfBoundsValue: Float, freeWhenDone: Bool) {
        if let floatBytes {
            _floatBytes = floatBytes
        } else {
            let byteCount = UInt(MemoryLayout<Float>.size) &* pixelsWide &* pixelsHigh &* pixelsDeep
            _floatBytes = UnsafePointer(malloc(Int(bitPattern: byteCount))?.assumingMemoryBound(to: Float.self))
        }
        _outOfBoundsValue = outOfBoundsValue
        valid = Atomic(true)
        _pixelsWide = pixelsWide
        _pixelsHigh = pixelsHigh
        _pixelsDeep = pixelsDeep
        _volumeTransform = volumeTransform
        _freeWhenDone = freeWhenDone
        _childSubvolumes = NSMutableDictionary()
        super.init()
    }

    /// -init of NSObject left every instance variable zero: no data, not valid.
    @objc public override init() {
        _floatBytes = nil
        _outOfBoundsValue = 0
        valid = Atomic(false)
        _pixelsWide = 0
        _pixelsHigh = 0
        _pixelsDeep = 0
        _volumeTransform = N3AffineTransform()
        _freeWhenDone = false
        _childSubvolumes = nil
        super.init()
    }

    deinit {
        if _freeWhenDone {
            for childVolume in _childSubvolumes?.allValues ?? [] {
                (childVolume as? CPRVolumeData)?.invalidateData()
            }

            free(UnsafeMutableRawPointer(mutating: _floatBytes))
            _floatBytes = nil
        }
    }

    @objc public var pixelsWide: UInt { _pixelsWide }
    @objc public var pixelsHigh: UInt { _pixelsHigh }
    @objc public var pixelsDeep: UInt { _pixelsDeep }

    @objc public var rectilinear: Bool {
        @objc(isRectilinear) get {
            return N3AffineTransformIsRectilinear(_volumeTransform)
        }
    }

    // the smallest pixel spacing in any direction;
    @objc public var minPixelSpacing: CGFloat {
        // MIN(MIN(x, y), z), with the comparison of the MIN macro
        let spacingX = self.pixelSpacingX
        let spacingY = self.pixelSpacingY
        let minXY = spacingX < spacingY ? spacingX : spacingY
        let spacingZ = self.pixelSpacingZ
        return minXY < spacingZ ? minXY : spacingZ
    }

    // mm/pixel
    @objc public var pixelSpacingX: CGFloat {
        if self.rectilinear {
            return 1.0 / _volumeTransform.m11
        } else {
            let inverseTransform = N3AffineTransformInvert(_volumeTransform)
            let zero = N3VectorApplyTransform(N3VectorZero, inverseTransform)
            return N3VectorDistance(zero, N3VectorApplyTransform(N3VectorMake(1.0, 0.0, 0.0), inverseTransform))
        }
    }

    @objc public var pixelSpacingY: CGFloat {
        if self.rectilinear {
            return 1.0 / _volumeTransform.m22
        } else {
            let inverseTransform = N3AffineTransformInvert(_volumeTransform)
            let zero = N3VectorApplyTransform(N3VectorZero, inverseTransform)
            return N3VectorDistance(zero, N3VectorApplyTransform(N3VectorMake(0.0, 1.0, 0.0), inverseTransform))
        }
    }

    @objc public var pixelSpacingZ: CGFloat {
        if self.rectilinear {
            return 1.0 / _volumeTransform.m33
        } else {
            let inverseTransform = N3AffineTransformInvert(_volumeTransform)
            let zero = N3VectorApplyTransform(N3VectorZero, inverseTransform)
            return N3VectorDistance(zero, N3VectorApplyTransform(N3VectorMake(0.0, 0.0, 1.0), inverseTransform))
        }
    }

    @objc public var outOfBoundsValue: Float { _outOfBoundsValue }

    // volumeTransform is the transform from Dicom (patient) space to pixel data
    @objc public var volumeTransform: N3AffineTransform { _volumeTransform }

    @objc public func isDataValid() -> Bool {
        return valid.load(ordering: .sequentiallyConsistent)
    }

    // this is to be called right before freeing the data by objects who own the floatBytes that were given to the receiver
    // this may lock temporarily if other threads are accessing the data, after this returns, it is ok to free floatBytes and all calls to access data will fail gracefully
    @objc public func invalidateData() {
        var rqtp = timespec(tv_sec: 0, tv_nsec: 100)
        var rmtp = timespec(tv_sec: 0, tv_nsec: 0)

        cprVolumeDataAssert(_freeWhenDone == false) // you can't invalidate the data if it is owned by the CPRVolumeData

        valid.store(false, ordering: .sequentiallyConsistent) // make sure that the _isValid was set
        while readerCount.load(ordering: .sequentiallyConsistent) > 0 { // spin until we no know that any readers that were reading before the _isValid was set would have exited
            nanosleep(&rqtp, &rmtp)
        }

        if let childSubvolumes = _childSubvolumes {
            objc_sync_enter(childSubvolumes)
            defer { objc_sync_exit(childSubvolumes) }
            for childVolume in childSubvolumes.allValues {
                (childVolume as? CPRVolumeData)?.invalidateData()
            }
        }

        // now we know that everything is ok and it is safe to return and have the caller free the data;
        _floatBytes = nil
    }

    @inline(__always)
    private func beginReading() {
        readerCount.wrappingAdd(1, ordering: .sequentiallyConsistent)
    }

    @inline(__always)
    private func endReading() {
        readerCount.wrappingSubtract(1, ordering: .sequentiallyConsistent)
    }

    // will copy fill length*sizeof(float) bytes, the coordinates better be within the volume!!!
    // a run a is a series of pixels in the x direction
    @discardableResult
    @objc(getFloatRun:atPixelCoordinateX:y:z:length:)
    public func getFloatRun(_ buffer: UnsafeMutablePointer<Float>!, atPixelCoordinateX x: UInt, y: UInt, z: UInt, length: UInt) -> Bool {
        let byteCount = Int(bitPattern: UInt(MemoryLayout<Float>.size) &* length)
        if isDataValid() == false {
            memset(buffer, 0, byteCount)
            return false
        }

        // A run may end at the last column; one that leaves the volume is not
        // read. The former assertion refused the last column, and Release
        // copied past the volume.
        guard x < _pixelsWide, y < _pixelsHigh, z < _pixelsDeep, length <= _pixelsWide &- x else {
            memset(buffer, 0, byteCount)
            return false
        }

        beginReading()
        if isDataValid() {
            let offset = x &+ y &* _pixelsWide &+ z &* _pixelsWide &* _pixelsHigh
            memcpy(buffer, _floatBytes.map { $0 + Int(bitPattern: offset) }, byteCount)
            endReading()
            return true
        } else {
            endReading()
            memset(buffer, 0, byteCount)
            return false
        }
    }

    @objc(unsignedInt16ImageRepForSliceAtIndex:)
    public func unsignedInt16ImageRepForSlice(at z: UInt) -> CPRUnsignedInt16ImageRep? {
        if isDataValid() == false {
            return nil
        }

        beginReading()
        if isDataValid() {
            let imageRep = CPRUnsignedInt16ImageRep(data: nil, pixelsWide: _pixelsWide, pixelsHigh: _pixelsHigh)!
            imageRep.pixelSpacingX = self.pixelSpacingX
            imageRep.pixelSpacingY = self.pixelSpacingY
            imageRep.sliceThickness = self.pixelSpacingZ
            imageRep.imageToDicomTransform = N3AffineTransformConcat(N3AffineTransformMakeTranslation(0.0, 0.0, CGFloat(z)), N3AffineTransformInvert(_volumeTransform))

            let unsignedInt16Data = imageRep.unsignedInt16Data()

            let sliceByteOffset = _pixelsWide &* _pixelsHigh &* UInt(MemoryLayout<Float>.size) &* z
            var floatBuffer = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: _floatBytes).map { $0 + Int(bitPattern: sliceByteOffset) },
                                            height: vImagePixelCount(_pixelsHigh),
                                            width: vImagePixelCount(_pixelsWide),
                                            rowBytes: MemoryLayout<Float>.size * Int(bitPattern: _pixelsWide))

            var unsignedInt16Buffer = vImage_Buffer(data: UnsafeMutableRawPointer(unsignedInt16Data),
                                                    height: vImagePixelCount(_pixelsHigh),
                                                    width: vImagePixelCount(_pixelsWide),
                                                    rowBytes: MemoryLayout<UInt16>.size * Int(bitPattern: _pixelsWide))

            vImageConvert_FTo16U(&floatBuffer, &unsignedInt16Buffer, -1024, 1, 0)
            imageRep.slope = 1
            imageRep.offset = -1024

            endReading()
            return imageRep
        } else {
            endReading()
            return nil
        }
    }

    @objc(volumeDataForSliceAtIndex:)
    public func volumeDataForSlice(at z: UInt) -> CPRVolumeData? {
        // A slice the volume does not have has no data to point at.
        guard z < _pixelsDeep else { return nil }
        // The slice's pixels start at depth z of this volume. The former code
        // negated the unsigned index, which wrapped to about 1.8e19.
        let childVolumeTransform = N3AffineTransformConcat(_volumeTransform, N3AffineTransformMakeTranslation(0, 0, -CGFloat(z)))
        var childVolume = CPRVolumeData(floatBytesNoCopy: _floatBytes.map { $0 + Int(bitPattern: _pixelsWide &* _pixelsHigh &* z) },
                                        pixelsWide: _pixelsWide, pixelsHigh: _pixelsHigh, pixelsDeep: 1,
                                        volumeTransform: childVolumeTransform, outOfBoundsValue: _outOfBoundsValue, freeWhenDone: false)

        beginReading()
        if self.isDataValid() == false {
            childVolume.invalidateData()
        }
        if let childSubvolumes = _childSubvolumes {
            objc_sync_enter(childSubvolumes)
            let key = NSNumber(value: Int(bitPattern: z))
            if let existingVolume = childSubvolumes.object(forKey: key) as? CPRVolumeData {
                childVolume = existingVolume
            } else {
                childSubvolumes.setObject(childVolume, forKey: key)
            }
            objc_sync_exit(childSubvolumes)
        }
        endReading()

        return childVolume
    }

    // returns YES if the float was sucessfully gotten
    @discardableResult
    @objc(getFloat:atPixelCoordinateX:y:z:)
    public func getFloat(_ floatPtr: UnsafeMutablePointer<Float>!, atPixelCoordinateX x: UInt, y: UInt, z: UInt) -> Bool {
        if isDataValid() == false {
            return false
        }

        var inlineBuffer = CPRVolumeDataInlineBuffer()
        return withUnsafeMutablePointer(to: &inlineBuffer) { inlineBuffer in
            if self.aquireInlineBuffer(inlineBuffer) {
                floatPtr.pointee = CPRVolumeDataGetFloatAtPixelCoordinate(inlineBuffer, Int(bitPattern: x), Int(bitPattern: y), Int(bitPattern: z))
                self.releaseInlineBuffer(inlineBuffer)
                return true
            } else {
                self.releaseInlineBuffer(inlineBuffer)
                floatPtr.pointee = 0.0
                return false
            }
        }
    }

    // these are slower, use the inline buffer if you care about speed
    @discardableResult
    @objc(getLinearInterpolatedFloat:atDicomVector:)
    public func getLinearInterpolatedFloat(_ floatPtr: UnsafeMutablePointer<Float>!, atDicomVector vector: N3Vector) -> Bool {
        if isDataValid() == false {
            return false
        }

        var inlineBuffer = CPRVolumeDataInlineBuffer()
        return withUnsafeMutablePointer(to: &inlineBuffer) { inlineBuffer in
            if self.aquireInlineBuffer(inlineBuffer) {
                floatPtr.pointee = CPRVolumeDataLinearInterpolatedFloatAtDicomVectorForSwift(inlineBuffer, vector)
                self.releaseInlineBuffer(inlineBuffer)
                return true
            } else {
                self.releaseInlineBuffer(inlineBuffer)
                floatPtr.pointee = 0.0
                return false
            }
        }
    }

    // these are slower, use the inline buffer if you care about speed
    @discardableResult
    @objc(getNearestNeighborInterpolatedFloat:atDicomVector:)
    public func getNearestNeighborInterpolatedFloat(_ floatPtr: UnsafeMutablePointer<Float>!, atDicomVector vector: N3Vector) -> Bool {
        if isDataValid() == false {
            return false
        }

        var inlineBuffer = CPRVolumeDataInlineBuffer()
        return withUnsafeMutablePointer(to: &inlineBuffer) { inlineBuffer in
            if self.aquireInlineBuffer(inlineBuffer) {
                floatPtr.pointee = CPRVolumeDataNearestNeighborInterpolatedFloatAtDicomVectorForSwift(inlineBuffer, vector)
                self.releaseInlineBuffer(inlineBuffer)
                return true
            } else {
                self.releaseInlineBuffer(inlineBuffer)
                floatPtr.pointee = 0.0
                return false
            }
        }
    }

    // these are slower, use the inline buffer if you care about speed
    @discardableResult
    @objc(getCubicInterpolatedFloat:atDicomVector:)
    public func getCubicInterpolatedFloat(_ floatPtr: UnsafeMutablePointer<Float>!, atDicomVector vector: N3Vector) -> Bool {
        if isDataValid() == false {
            return false
        }

        // The cubic sampler points indexes that fall outside of the volume at
        // inlineBuffer->outOfBoundsValue, so the buffer has to stay at one
        // address for the whole call.
        var inlineBuffer = CPRVolumeDataInlineBuffer()
        return withUnsafeMutablePointer(to: &inlineBuffer) { inlineBuffer in
            if self.aquireInlineBuffer(inlineBuffer) {
                floatPtr.pointee = CPRVolumeDataCubicInterpolatedFloatAtDicomVectorForSwift(inlineBuffer, vector)
                self.releaseInlineBuffer(inlineBuffer)
                return true
            } else {
                self.releaseInlineBuffer(inlineBuffer)
                floatPtr.pointee = 0.0
                return false
            }
        }
    }

    // not done yet, will crash if given vectors that are outside of the volume
    @objc(tempBufferSizeForNumVectors:)
    public func tempBufferSize(forNumVectors numVectors: UInt) -> UInt {
        return numVectors &* UInt(MemoryLayout<Float>.size) &* 11
    }

    // Trilinear interpolation of each vector, in the volume's pixel space;
    // vectors outside the volume give the out-of-bounds value. The former code
    // read the N3Vectors' CGFloats as floats and indexed the volume with them,
    // without bounds. tempBuffer is no longer used.
    @objc(linearInterpolateVolumeVectors:outputValues:numVectors:tempBuffer:)
    public func linearInterpolateVolumeVectors(_ volumeVectors: N3VectorArray!, outputValues: UnsafeMutablePointer<Float>!, numVectors: UInt, tempBuffer: UnsafeMutableRawPointer!) {
        guard let volumeVectors = volumeVectors, let outputValues = outputValues else { return }
        var inlineBuffer = CPRVolumeDataInlineBuffer()
        withUnsafeMutablePointer(to: &inlineBuffer) { inlineBuffer in
            let valid = self.aquireInlineBuffer(inlineBuffer)
            for i in 0..<Int(bitPattern: numVectors) {
                let vector = volumeVectors[i]
                outputValues[i] = valid ? CPRVolumeDataLinearInterpolatedFloatAtVolumeCoordinateForSwift(inlineBuffer, vector.x, vector.y, vector.z) : 0
            }
            self.releaseInlineBuffer(inlineBuffer)
        }
    }

    // make sure to pair this with a releaseInlineBuffer (even if it returns NO!), returns YES if the data is valid. The data will be locked and remain valid until releaseInlineBuffer: is called
    @objc(aquireInlineBuffer:)
    public func aquireInlineBuffer(_ inlineBuffer: UnsafeMutablePointer<CPRVolumeDataInlineBuffer>!) -> Bool {
        memset(inlineBuffer, 0, MemoryLayout<CPRVolumeDataInlineBuffer>.size)

        if isDataValid() == false {
            return false
        }

        beginReading()
        if isDataValid() {
            inlineBuffer.pointee.floatBytes = _floatBytes
            inlineBuffer.pointee.outOfBoundsValue = _outOfBoundsValue
            inlineBuffer.pointee.pixelsWide = _pixelsWide
            inlineBuffer.pointee.pixelsHigh = _pixelsHigh
            inlineBuffer.pointee.pixelsDeep = _pixelsDeep
            inlineBuffer.pointee.pixelsWideTimesPixelsHigh = _pixelsWide &* _pixelsHigh
            inlineBuffer.pointee.volumeTransform = _volumeTransform
            return true
        } else {
            endReading()
            return false
        }
    }

    @objc(releaseInlineBuffer:)
    public func releaseInlineBuffer(_ inlineBuffer: UnsafeMutablePointer<CPRVolumeDataInlineBuffer>!) {
        if inlineBuffer.pointee.floatBytes != nil {
            endReading()
        }
        memset(inlineBuffer, 0, MemoryLayout<CPRVolumeDataInlineBuffer>.size)
    }

    // returns YES if the orientation matrix's determinant is non-zero
    fileprivate static func testOrientationMatrix(_ orientation: UnsafePointer<Double>) -> Bool {
        var transform = N3AffineTransformIdentity
        transform.m11 = orientation[0]
        transform.m12 = orientation[1]
        transform.m13 = orientation[2]
        transform.m21 = orientation[3]
        transform.m22 = orientation[4]
        transform.m23 = orientation[5]
        transform.m31 = orientation[6]
        transform.m32 = orientation[7]
        transform.m33 = orientation[8]

        return N3AffineTransformDeterminant(transform) != 0.0
    }

    // returns YES if the orientation matrix's determinant is non-zero
    @objc(_testOrientationMatrix:)
    func _testOrientationMatrix(_ orientation: UnsafeMutablePointer<Double>!) -> Bool {
        return CPRVolumeData.testOrientationMatrix(orientation)
    }
}

// DCMPixAndVolume: make a nice clean interface between the rest of of Horos that
// deals with pixlist and all their complications, and fill out our convenient data
// structure.
extension CPRVolumeData {
    @objc(initWithWithPixList:volume:)
    public convenience init(withPixList pixList: NSArray?, volume: NSData?) {
        var orientation = [Double](repeating: 0, count: 9)

        let firstPix = pixList?.object(at: 0) as? DCMPix

        var sliceThickness = Float(firstPix?.sliceInterval ?? 0)
        if sliceThickness == 0 {
            NSLog("slice interval = slice thickness!")
            sliceThickness = Float(firstPix?.sliceThickness ?? 0)
        }

        orientation.withUnsafeMutableBufferPointer { firstPix?.orientationDouble($0.baseAddress) }
        let spacingX = firstPix?.pixelSpacingX ?? 0
        let spacingY = firstPix?.pixelSpacingY ?? 0
        if sliceThickness == 0 { // if the slice thickness is still 0, make it the same as the average of the spacingX and spacingY
            sliceThickness = Float((spacingX + spacingY) / 2.0)
        }
        let spacingZ = Double(sliceThickness)

        // test to make sure that orientation is initialized, when the volume is curved or something, it doesn't make sense to talk about orientation, and
        // so the orientation is really bogus
        // the test we will do is to make sure that orientation is 3 non-degenerate vectors
        if orientation.withUnsafeBufferPointer({ CPRVolumeData.testOrientationMatrix($0.baseAddress!) }) == false {
            orientation = [Double](repeating: 0, count: 9)
            orientation[0] = 1
            orientation[4] = 1
            orientation[8] = 1
        }

        var pixToDicomTransform = N3AffineTransformIdentity
        pixToDicomTransform.m41 = firstPix?.originX ?? 0
        pixToDicomTransform.m42 = firstPix?.originY ?? 0
        pixToDicomTransform.m43 = firstPix?.originZ ?? 0
        pixToDicomTransform.m11 = orientation[0] * spacingX
        pixToDicomTransform.m12 = orientation[1] * spacingX
        pixToDicomTransform.m13 = orientation[2] * spacingX
        pixToDicomTransform.m21 = orientation[3] * spacingY
        pixToDicomTransform.m22 = orientation[4] * spacingY
        pixToDicomTransform.m23 = orientation[5] * spacingY
        pixToDicomTransform.m31 = orientation[6] * spacingZ
        pixToDicomTransform.m32 = orientation[7] * spacingZ
        pixToDicomTransform.m33 = orientation[8] * spacingZ

        self.init(floatBytesNoCopy: volume?.bytes.assumingMemoryBound(to: Float.self),
                  pixelsWide: UInt(bitPattern: firstPix?.pwidth ?? 0), pixelsHigh: UInt(bitPattern: firstPix?.pheight ?? 0),
                  pixelsDeep: UInt(bitPattern: pixList?.count ?? 0),
                  volumeTransform: N3AffineTransformInvert(pixToDicomTransform), outOfBoundsValue: -1000, freeWhenDone: false)
    }

    @objc(getOrientation:)
    public func getOrientation(_ orientation: UnsafeMutablePointer<Float>!) {
        var doubleOrientation = [Double](repeating: 0, count: 6)

        doubleOrientation.withUnsafeMutableBufferPointer { self.getOrientationDouble($0.baseAddress) }

        for i in 0..<6 {
            orientation[i] = Float(doubleOrientation[i])
        }
    }

    @objc(getOrientationDouble:)
    public func getOrientationDouble(_ orientation: UnsafeMutablePointer<Double>!) {
        let pixelToDicomTransform = N3AffineTransformInvert(_volumeTransform)

        let xBasis = N3VectorNormalize(N3VectorMake(pixelToDicomTransform.m11, pixelToDicomTransform.m12, pixelToDicomTransform.m13))
        let yBasis = N3VectorNormalize(N3VectorMake(pixelToDicomTransform.m21, pixelToDicomTransform.m22, pixelToDicomTransform.m23))

        orientation[0] = xBasis.x; orientation[1] = xBasis.y; orientation[2] = xBasis.z
        orientation[3] = yBasis.x; orientation[4] = yBasis.y; orientation[5] = yBasis.z
    }

    @objc public var originX: Float {
        let pixelToDicomTransform = N3AffineTransformInvert(_volumeTransform)

        return Float(pixelToDicomTransform.m41)
    }

    @objc public var originY: Float {
        let pixelToDicomTransform = N3AffineTransformInvert(_volumeTransform)

        return Float(pixelToDicomTransform.m42)
    }

    @objc public var originZ: Float {
        let pixelToDicomTransform = N3AffineTransformInvert(_volumeTransform)

        return Float(pixelToDicomTransform.m43)
    }
}
