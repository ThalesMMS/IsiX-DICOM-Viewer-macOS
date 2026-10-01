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
import Synchronization

private let FILL_HEIGHT = 40
private let fillOperationsContext = IdentityToken()

/// A double converted to NSUInteger as arm64 does it (fcvtzu): NaN and negative
/// values give 0, values past the top give the largest value.
private func unsignedTruncating(_ value: CGFloat) -> UInt {
    if value.isNaN || value < 1 {
        return 0
    }
    if value >= 18446744073709551616.0 {
        return UInt.max
    }
    return UInt(value)
}

/// assert() of the Objective-C: checked in Debug only.
@inline(__always)
private func debugAssert(_ condition: @autoclosure () -> Bool) {
    #if DEBUG
    precondition(condition())
    #endif
}

/// Generates the straightened CPR volume of a CPRStraightenedGeneratorRequest:
/// CPRHorizontalFillOperations sample the volume along the curve, then a
/// CPRProjectionOperation projects the slab.
///
/// Implemented in Swift since #719: the Objective-C name, the selectors and
/// <Horos/CPRStraightenedOperation.h> are those of the former class.
///
/// @unchecked Sendable, restated from Operation: the generator's queue runs it,
/// the fill operations report to it from their threads and `cancel()` may come
/// from any. The three state flags are atomics; the fill set and
/// `projectionOperation` are touched only under objc_sync on `fillOperations`;
/// `floatBytes` and `sampleSpacing` are written by `fill()` before any fill operation is queued
/// and read by the one that finishes last, which the sequentially consistent
/// countdown of `outstandingFillOperationCount` orders after them.
@objc(CPRStraightenedOperation)
public final class CPRStraightenedOperation: CPRGeneratorOperation, @unchecked Sendable {
    private let outstandingFillOperationCount = Atomic<Int32>(0)

    private var floatBytes: UnsafeMutablePointer<Float>?
    /// Also the lock of the former @synchronized (_fillOperations), which
    /// guards the projection operation too.
    private let fillOperations = NSMutableSet()
    private var projectionOperation: Operation?
    private let operationExecuting = Atomic<Bool>(false)
    private let operationFinished = Atomic<Bool>(false)
    private let operationFailed = Atomic<Bool>(false)

    private var sampleSpacing: CGFloat = 0 // generated and cached by the operation based on the width and the length of the bezier

    private static let fillQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = ProcessInfo.processInfo.processorCount
        return queue
    }()

    @objc(initWithRequest:volumeData:)
    public required init(request: CPRGeneratorRequest?, volumeData: CPRVolumeData?) {
        super.init(request: request, volumeData: volumeData)
    }

    @objc public override var request: CPRStraightenedGeneratorRequest? {
        return super.request as? CPRStraightenedGeneratorRequest
    }

    public override var isConcurrent: Bool {
        return true
    }

    public override var isExecuting: Bool {
        return operationExecuting.load(ordering: .acquiring)
    }

    public override var isFinished: Bool {
        return operationFinished.load(ordering: .acquiring)
    }

    @objc public override var didFail: Bool {
        return operationFailed.load(ordering: .acquiring)
    }

    public override func cancel() {
        let projectionOperation: Operation?
        objc_sync_enter(fillOperations)
        for case let operation as Operation in fillOperations {
            operation.cancel()
        }
        projectionOperation = self.projectionOperation
        objc_sync_exit(fillOperations)
        projectionOperation?.cancel()

        super.cancel()
    }

    public override func start() {
        if isCancelled {
            willChangeValue(forKey: CPROperationKeyPath.isFinished)
            operationFinished.store(true, ordering: .releasing)
            didChangeValue(forKey: CPROperationKeyPath.isFinished)
            return
        }

        willChangeValue(forKey: CPROperationKeyPath.isExecuting)
        operationExecuting.store(true, ordering: .releasing)
        didChangeValue(forKey: CPROperationKeyPath.isExecuting)
        main()
    }

    public override func main() {
        autoreleasepool {
            do {
                try HorosObjCException.perform { self.fill() }
            } catch {
                // The former @catch (...): the operation ends without a volume.
                self.finish()
            }
        }
    }

    private func finish() {
        willChangeValue(forKey: CPROperationKeyPath.isFinished)
        willChangeValue(forKey: CPROperationKeyPath.isExecuting)
        operationExecuting.store(false, ordering: .releasing)
        operationFinished.store(true, ordering: .releasing)
        didChangeValue(forKey: CPROperationKeyPath.isExecuting)
        didChangeValue(forKey: CPROperationKeyPath.isFinished)
    }

    private func fill() {
        // A request of another class is what the former unchecked @dynamic
        // property would have messaged into an exception: the operation ends.
        guard let request = self.request, isCancelled == false, request.pixelsHigh > 0 else {
            finish()
            return
        }

        let flattenedBezierCore = N3BezierCoreCreateMutableCopy(request.bezierPath?.n3BezierCore())
        N3BezierCoreSubdivide(flattenedBezierCore, 3.0)
        N3BezierCoreFlatten(flattenedBezierCore, 0.6)
        let bezierLength = N3BezierCoreLength(flattenedBezierCore)
        let pixelsWide = Int(bitPattern: request.pixelsWide)
        let pixelsHigh = Int(bitPattern: request.pixelsHigh)
        let pixelsDeep = Int(bitPattern: _pixelsDeep())

        var numVectors = pixelsWide
        sampleSpacing = bezierLength / CGFloat(pixelsWide)

        let vectorBytes = MemoryLayout<N3Vector>.size &* pixelsWide
        let newFloatBytes = malloc(Int(bitPattern: UInt(MemoryLayout<Float>.size) &* UInt(bitPattern: pixelsWide) &* UInt(bitPattern: pixelsHigh) &* UInt(bitPattern: pixelsDeep)))?
            .assumingMemoryBound(to: Float.self)
        floatBytes = newFloatBytes
        let vectors = malloc(vectorBytes)?.assumingMemoryBound(to: N3Vector.self)
        let fillVectors = malloc(vectorBytes)?.assumingMemoryBound(to: N3Vector.self)
        let fillNormals = malloc(vectorBytes)?.assumingMemoryBound(to: N3Vector.self)
        let tangents = malloc(vectorBytes)?.assumingMemoryBound(to: N3Vector.self)
        let normals = malloc(vectorBytes)?.assumingMemoryBound(to: N3Vector.self)
        let inSlabNormals = malloc(vectorBytes)?.assumingMemoryBound(to: N3Vector.self)

        guard let floatBytes = newFloatBytes, let vectors, let fillVectors, let fillNormals, let tangents, let normals, let inSlabNormals else {
            free(newFloatBytes)
            free(vectors)
            free(fillVectors)
            free(fillNormals)
            free(tangents)
            free(normals)
            free(inSlabNormals)

            self.floatBytes = nil

            willChangeValue(forKey: CPROperationKeyPath.didFail)
            willChangeValue(forKey: CPROperationKeyPath.isFinished)
            willChangeValue(forKey: CPROperationKeyPath.isExecuting)
            operationExecuting.store(false, ordering: .releasing)
            operationFinished.store(true, ordering: .releasing)
            operationFailed.store(true, ordering: .releasing)
            didChangeValue(forKey: CPROperationKeyPath.isExecuting)
            didChangeValue(forKey: CPROperationKeyPath.isFinished)
            didChangeValue(forKey: CPROperationKeyPath.didFail)

            N3BezierCoreRelease(flattenedBezierCore)
            return
        }

        numVectors = N3BezierCoreGetVectorInfo(flattenedBezierCore, sampleSpacing, 0, request.initialNormal, vectors, tangents, normals, pixelsWide)

        if numVectors > 0 {
            while numVectors < pixelsWide { // make sure that the full array is filled and that there is not a vector that did not get filled due to roundoff error
                vectors[numVectors] = vectors[numVectors - 1]
                tangents[numVectors] = tangents[numVectors - 1]
                normals[numVectors] = normals[numVectors - 1]
                numVectors += 1
            }
        } else { // there are no vectors at all to copy from, so just zero out everthing
            while numVectors < pixelsWide {
                vectors[numVectors] = N3VectorZero
                tangents[numVectors] = N3VectorZero
                normals[numVectors] = N3VectorZero
                numVectors += 1
            }
        }

        memcpy(fillNormals, normals, vectorBytes)
        N3VectorScalarMultiplyVectors(sampleSpacing, fillNormals, pixelsWide)

        memcpy(inSlabNormals, normals, vectorBytes)
        N3VectorCrossProductWithVectors(inSlabNormals, tangents, pixelsWide)
        N3VectorScalarMultiplyVectors(_slabSampleDistance(), inSlabNormals, pixelsWide)

        let fillOperations = NSMutableSet()

        var z = 0
        while z < pixelsDeep {
            var y = 0
            while y < pixelsHigh {
                let fillDistance = CGFloat(y) - CGFloat(pixelsHigh - 1) / 2.0 // the distance to go out from the centerline
                let slabDistance = CGFloat(z) - CGFloat(pixelsDeep - 1) / 2.0 // the distance to go out from the centerline
                // Unchecked pointer access: the arrays hold pixelsWide vectors.
                for i in 0..<pixelsWide {
                    fillVectors[i] = N3VectorAdd(N3VectorAdd(vectors[i], N3VectorScalarMultiply(fillNormals[i], fillDistance)), N3VectorScalarMultiply(inSlabNormals[i], slabDistance))
                }

                let horizontalFillOperation = CPRHorizontalFillOperation(volumeData: volumeData, interpolationMode: request.interpolationMode,
                                                                         floatBytes: floatBytes + (y &* pixelsWide) + (z &* pixelsWide &* pixelsHigh),
                                                                         width: UInt(bitPattern: pixelsWide), height: UInt(min(FILL_HEIGHT, pixelsHigh - y)),
                                                                         vectors: fillVectors, normals: fillNormals)
                horizontalFillOperation.queuePriority = queuePriority
                fillOperations.add(horizontalFillOperation)
                horizontalFillOperation.addObserver(self, forKeyPath: CPROperationKeyPath.isFinished, options: [], context: fillOperationsContext.pointer)
                _ = Unmanaged.passUnretained(self).retain() // so we don't get released while the operation is going
                y += FILL_HEIGHT
            }
            z += 1
        }

        objc_sync_enter(self.fillOperations)
        // -setSet: without bridging to a Swift Set and back, which hashed every
        // operation through AnyHashable twice (#776).
        self.fillOperations.removeAllObjects()
        for operation in fillOperations {
            self.fillOperations.add(operation)
        }
        objc_sync_exit(self.fillOperations)

        if isCancelled {
            for case let horizontalFillOperation as Operation in fillOperations {
                horizontalFillOperation.cancel()
            }
        }

        outstandingFillOperationCount.store(Int32(truncatingIfNeeded: fillOperations.count), ordering: .sequentiallyConsistent)

        let fillQueue = CPRStraightenedOperation.fillQueue
        for case let horizontalFillOperation as Operation in fillOperations {
            fillQueue.addOperation(horizontalFillOperation)
        }

        free(vectors)
        free(fillVectors)
        free(fillNormals)
        free(tangents)
        free(normals)
        free(inSlabNormals)
        N3BezierCoreRelease(flattenedBezierCore)
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard context == fillOperationsContext.pointer else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        debugAssert(object is Operation)
        let operation = object as! Operation

        guard keyPath == CPROperationKeyPath.isFinished, operation.isFinished else {
            return
        }
        operation.removeObserver(self, forKeyPath: CPROperationKeyPath.isFinished)
        _ = Unmanaged.passUnretained(self).autorelease() // to balance the retain when we observe operations
        let oustandingFillOperationCount = outstandingFillOperationCount.wrappingSubtract(1, ordering: .sequentiallyConsistent).newValue
        if oustandingFillOperationCount == 0 { // done with the fill operations, now do the projection
            let request = self.request
            let volumeTransform = N3AffineTransformMakeScale(1.0 / sampleSpacing, 1.0 / sampleSpacing, 1.0 / _slabSampleDistance())
            let generatedVolume = CPRVolumeData(floatBytesNoCopy: floatBytes, pixelsWide: numericCast(request?.pixelsWide ?? 0), pixelsHigh: numericCast(request?.pixelsHigh ?? 0),
                                                pixelsDeep: numericCast(_pixelsDeep()), volumeTransform: volumeTransform,
                                                outOfBoundsValue: volumeData?.outOfBoundsValue ?? 0, freeWhenDone: true)
            floatBytes = nil
            let projectionOperation = CPRProjectionOperation()
            projectionOperation.queuePriority = queuePriority

            projectionOperation.volumeData = generatedVolume
            projectionOperation.projectionMode = request?.projectionMode ?? 0
            if isCancelled {
                projectionOperation.cancel()
            }

            projectionOperation.addObserver(self, forKeyPath: CPROperationKeyPath.isFinished, options: [], context: fillOperationsContext.pointer)
            _ = Unmanaged.passUnretained(self).retain() // so we don't get released while the operation is going
            objc_sync_enter(fillOperations)
            self.projectionOperation = projectionOperation
            objc_sync_exit(fillOperations)
            CPRStraightenedOperation.fillQueue.addOperation(projectionOperation)
        } else if oustandingFillOperationCount == -1 {
            debugAssert(operation is CPRProjectionOperation)
            let projectionOperation = operation as? CPRProjectionOperation
            generatedVolume = projectionOperation?.generatedVolume

            willChangeValue(forKey: CPROperationKeyPath.isFinished)
            willChangeValue(forKey: CPROperationKeyPath.isExecuting)
            operationExecuting.store(false, ordering: .releasing)
            operationFinished.store(true, ordering: .releasing)

            didChangeValue(forKey: CPROperationKeyPath.isExecuting)
            didChangeValue(forKey: CPROperationKeyPath.isFinished)
        }
    }

    private func _slabSampleDistance() -> CGFloat {
        let request = self.request
        if (request?.slabSampleDistance ?? 0) != 0.0 {
            return request!.slabSampleDistance
        } else {
            return volumeData?.minPixelSpacing ?? 0 // this should be /2.0 to hit nyquist spacing, but it is too slow, and with this implementation to memory intensive
        }
    }

    private func _pixelsDeep() -> UInt {
        // MAX(slabWidth / slabSampleDistance, 0) + 1, converted to NSUInteger.
        let slabs = (request?.slabWidth ?? 0) / _slabSampleDistance()
        // A zero sample distance (none in the request and a volume whose
        // minPixelSpacing is 0) gave 0/0 = NaN, hence no plane and an operation
        // that never finished, or width/0 = inf and a wrapped allocation size.
        // A slab that cannot be sampled is the one plane of the curve (#773).
        guard slabs.isFinite else {
            return 1
        }
        return unsignedTruncating((slabs < 0 ? 0 : slabs) + 1)
    }
}
