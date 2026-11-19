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

import IsiXImaging
import Cocoa
import Synchronization

private let FILL_HEIGHT = 40

/// One plane at a time of the slab of an oblique slice: a plane is `z` sample
/// distances from the slice, and its rows are sampled FILL_HEIGHT at a time,
/// each row a down step from the one above it.
private struct ObliqueSlab: Sendable {
    /// The top row of the slice, one point per column.
    let vectors: [N3Vector]
    /// The down step of every column.
    let downVectors: [N3Vector]
    let downDirection: N3Vector
    /// From one plane to the next, the slab sample distance long.
    let inSlabNormal: N3Vector
    let pixelsHigh: Int
    let pixelsDeep: Int

    /// The fill operations that sample plane `z` into `floatBytes`.
    func fills(ofPlane z: Int, into floatBytes: UnsafeMutablePointer<Float>, volumeData: CPRVolumeData?,
               interpolationMode: CPRInterpolationMode, queuePriority: Operation.QueuePriority) -> [Operation] {
        let pixelsWide = vectors.count
        var fillVectors = [N3Vector](repeating: N3VectorZero, count: pixelsWide)
        var fills: [Operation] = []
        downVectors.withUnsafeBufferPointer { downVectors in
            let slabOffset = N3VectorScalarMultiply(inSlabNormal, CGFloat(z) - CGFloat(pixelsDeep - 1) / 2.0)
            var y = 0
            while y < pixelsHigh {
                let heightOffset = N3VectorScalarMultiply(downDirection, CGFloat(y))
                for i in 0..<pixelsWide {
                    fillVectors[i] = N3VectorAdd(N3VectorAdd(vectors[i], heightOffset), slabOffset)
                }

                let horizontalFillOperation = CPRHorizontalFillOperation(volumeData: volumeData, interpolationMode: interpolationMode,
                                                                         floatBytes: floatBytes + (y &* pixelsWide),
                                                                         width: UInt(bitPattern: pixelsWide), height: UInt(min(FILL_HEIGHT, pixelsHigh - y)),
                                                                         vectors: &fillVectors, normals: UnsafeMutablePointer(mutating: downVectors.baseAddress))
                horizontalFillOperation.queuePriority = queuePriority
                fills.append(horizontalFillOperation)
                y += FILL_HEIGHT
            }
        }
        return fills
    }
}

/// Generates the oblique slice of a CPRObliqueSliceGeneratorRequest (the
/// transverse sections of the CPR): CPRHorizontalFillOperations sample the
/// volume on the plane, and a CPRSlabProjector projects the slab while its
/// planes are sampled, so that only a few planes of a thick slab are in memory
/// at once.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/CPRObliqueSliceOperation.h> are those of the former class.
///
/// @unchecked Sendable, restated from Operation: the generator's queue runs it,
/// the projector reports to it from the thread of the fill that finished last,
/// and `cancel()` may come from any thread. The three state flags are atomics
/// and the projector is kept under a mutex.
@objc(CPRObliqueSliceOperation)
public final class CPRObliqueSliceOperation: CPRGeneratorOperation, @unchecked Sendable {
    /// The projector of the slab, once `fill()` has made it, for `cancel()`.
    private let slabProjector = Mutex<CPRSlabProjector?>(nil)
    private let operationExecuting = Atomic<Bool>(false)
    private let operationFinished = Atomic<Bool>(false)
    private let operationFailed = Atomic<Bool>(false)

    private static let fillQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = ProcessInfo.processInfo.processorCount
        return queue
    }()

    @objc(initWithRequest:volumeData:)
    public required init(request: CPRGeneratorRequest?, volumeData: CPRVolumeData?) {
        super.init(request: request, volumeData: volumeData)
    }

    public override var request: CPRObliqueSliceGeneratorRequest? {
        return super.request as? CPRObliqueSliceGeneratorRequest
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

    public override var didFail: Bool {
        return operationFailed.load(ordering: .acquiring)
    }

    public override func cancel() {
        // The flag before the projector: `fill()` publishes the projector
        // before it reads the flag, so one of the two cancels it.
        super.cancel()
        slabProjector.withLock { $0 }?.cancel()
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
            self.fill()
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

    private func fail() {
        willChangeValue(forKey: CPROperationKeyPath.didFail)
        willChangeValue(forKey: CPROperationKeyPath.isFinished)
        willChangeValue(forKey: CPROperationKeyPath.isExecuting)
        operationExecuting.store(false, ordering: .releasing)
        operationFinished.store(true, ordering: .releasing)
        operationFailed.store(true, ordering: .releasing)
        didChangeValue(forKey: CPROperationKeyPath.isExecuting)
        didChangeValue(forKey: CPROperationKeyPath.isFinished)
        didChangeValue(forKey: CPROperationKeyPath.didFail)
    }

    private func fill() {
        // A request of another class is what the former unchecked @dynamic
        // property would have messaged into an exception: the operation ends.
        guard let request = self.request, isCancelled == false, request.pixelsHigh > 0 else {
            finish()
            return
        }

        let pixelsWide = Int(bitPattern: request.pixelsWide)
        let pixelsHigh = Int(bitPattern: request.pixelsHigh)
        let pixelsDeep = Int(bitPattern: _pixelsDeep())
        let origin = request.origin
        let leftDirection = N3VectorScalarMultiply(N3VectorNormalize(request.directionX), request.pixelSpacingX)
        let downDirection = N3VectorScalarMultiply(N3VectorNormalize(request.directionY), request.pixelSpacingY)
        let inSlabNormal = N3VectorScalarMultiply(N3VectorNormalize(N3VectorCrossProduct(leftDirection, downDirection)), _slabSampleDistance())

        guard let projector = CPRSlabProjector(projectionMode: request.projectionMode, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                               pixelsDeep: pixelsDeep, fillHeight: FILL_HEIGHT, volumeTransform: _generatedVolumeTransform(),
                                               outOfBoundsValue: volumeData?.outOfBoundsValue ?? 0) else {
            fail()
            return
        }

        let slab = ObliqueSlab(vectors: (0..<max(pixelsWide, 0)).map { N3VectorAdd(origin, N3VectorScalarMultiply(leftDirection, CGFloat($0))) },
                               downVectors: [N3Vector](repeating: downDirection, count: max(pixelsWide, 0)),
                               downDirection: downDirection, inSlabNormal: inSlabNormal, pixelsHigh: pixelsHigh, pixelsDeep: pixelsDeep)

        slabProjector.withLock { $0 = projector }
        let interpolationMode = request.interpolationMode
        let queuePriority = self.queuePriority
        projector.start(on: CPRObliqueSliceOperation.fillQueue, planeFills: { [self] plane, floatBytes in
            slab.fills(ofPlane: plane, into: floatBytes, volumeData: volumeData, interpolationMode: interpolationMode, queuePriority: queuePriority)
        }, completion: { [self] volume in
            generatedVolume = volume
            finish()
        })
        if isCancelled {
            projector.cancel()
        }
    }

    /// The planes of the slab and the distance between them (CurvedSlabSampling):
    /// the request's own distance, or what divides the slab's width evenly at
    /// the volume's finest spacing or less.
    private func slabPlanes() -> (count: Int, distance: Double) {
        CurvedSlabSampling.planes(width: Double(request?.slabWidth ?? 0), spacing: Double(volumeData?.minPixelSpacing ?? 0),
                                  fixedDistance: Double(request?.slabSampleDistance ?? 0))
    }

    private func _slabSampleDistance() -> CGFloat {
        CGFloat(slabPlanes().distance)
    }

    private func _pixelsDeep() -> UInt {
        UInt(slabPlanes().count)
    }

    private func _generatedVolumeTransform() -> N3AffineTransform {
        let request = self.request
        let leftDirection = N3VectorScalarMultiply(N3VectorNormalize(request?.directionX ?? N3Vector()), request?.pixelSpacingX ?? 0)
        let downDirection = N3VectorScalarMultiply(N3VectorNormalize(request?.directionY ?? N3Vector()), request?.pixelSpacingY ?? 0)
        let inSlabNormal = N3VectorScalarMultiply(N3VectorNormalize(N3VectorCrossProduct(leftDirection, downDirection)), _slabSampleDistance())

        let volumeOrigin = N3VectorAdd(request?.origin ?? N3Vector(), N3VectorScalarMultiply(inSlabNormal, CGFloat(_pixelsDeep() &- 1) / -2.0))

        var volumeTransform = N3AffineTransformIdentity
        volumeTransform.m41 = volumeOrigin.x
        volumeTransform.m42 = volumeOrigin.y
        volumeTransform.m43 = volumeOrigin.z
        volumeTransform.m11 = leftDirection.x
        volumeTransform.m12 = leftDirection.y
        volumeTransform.m13 = leftDirection.z
        volumeTransform.m21 = downDirection.x
        volumeTransform.m22 = downDirection.y
        volumeTransform.m23 = downDirection.z
        volumeTransform.m31 = inSlabNormal.x
        volumeTransform.m32 = inSlabNormal.y
        volumeTransform.m33 = inSlabNormal.z

        volumeTransform = N3AffineTransformInvert(volumeTransform)
        return volumeTransform
    }
}
