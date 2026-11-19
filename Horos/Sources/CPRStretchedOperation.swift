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

/// Generates the stretched CPR volume of a CPRStretchedGeneratorRequest:
/// CPRHorizontalFillOperations sample the volume along the curve projected on
/// the plane normal to projectionNormal, and a CPRSlabProjector projects the
/// slab while its planes are sampled, so that only a few planes of a thick
/// slab are in memory at once.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/CPRStretchedOperation.h> are those of the former class.
///
/// @unchecked Sendable, restated from Operation: the generator's queue runs it,
/// the projector reports to it from the thread of the fill that finished last,
/// and `cancel()` may come from any thread. The three state flags are atomics
/// and the projector is kept under a mutex.
@objc(CPRStretchedOperation)
public final class CPRStretchedOperation: CPRGeneratorOperation, @unchecked Sendable {
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

    public override var request: CPRStretchedGeneratorRequest? {
        return super.request as? CPRStretchedGeneratorRequest
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

        let flattenedBezierCore = N3BezierCoreCreateMutableCopy(request.bezierPath?.n3BezierCore())
        N3BezierCoreSubdivide(flattenedBezierCore, 3.0)
        N3BezierCoreFlatten(flattenedBezierCore, 0.6)
        let bezierLength = N3BezierCoreLength(flattenedBezierCore)
        let pixelsWide = Int(bitPattern: request.pixelsWide)
        let pixelsHigh = Int(bitPattern: request.pixelsHigh)
        let pixelsDeep = Int(bitPattern: _pixelsDeep())
        let projectionNormal = request.projectionNormal
        let midHeightPoint = request.midHeightPoint
        let projectedBezierCore = N3BezierCoreCreateMutableCopyProjectedToPlane(flattenedBezierCore, N3PlaneMake(N3VectorZero, projectionNormal))
        let projectedBezierLength = N3BezierCoreLength(projectedBezierCore)
        var numVectors = pixelsWide
        _ = bezierLength
        let sampleSpacing = projectedBezierLength / CGFloat(pixelsWide)

        let vectorBytes = MemoryLayout<N3Vector>.size &* pixelsWide
        let projector = CPRSlabProjector(projectionMode: request.projectionMode, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, pixelsDeep: pixelsDeep,
                                         fillHeight: FILL_HEIGHT,
                                         volumeTransform: N3AffineTransformMakeScale(1.0 / sampleSpacing, 1.0 / sampleSpacing, 1.0 / _slabSampleDistance()),
                                         outOfBoundsValue: volumeData?.outOfBoundsValue ?? 0)
        let vectors = malloc(vectorBytes)?.assumingMemoryBound(to: N3Vector.self)
        let fillNormals = malloc(vectorBytes)?.assumingMemoryBound(to: N3Vector.self)
        let tangents = malloc(vectorBytes)?.assumingMemoryBound(to: N3Vector.self)
        let normals = malloc(vectorBytes)?.assumingMemoryBound(to: N3Vector.self)
        let inSlabNormals = malloc(vectorBytes)?.assumingMemoryBound(to: N3Vector.self)

        guard let projector, let vectors, let fillNormals, let tangents, let normals, let inSlabNormals else {
            free(vectors)
            free(fillNormals)
            free(tangents)
            free(normals)
            free(inSlabNormals)
            fail()
            N3BezierCoreRelease(flattenedBezierCore)
            N3BezierCoreRelease(projectedBezierCore)
            return
        }

        numVectors = N3BezierCoreGetProjectedVectorInfo(flattenedBezierCore, sampleSpacing, 0, request.projectionNormal, vectors, tangents, normals, nil, pixelsWide)

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

        // Unused, as in the former code, which kept it for the commented-out line below.
        _ = N3PlaneMake(N3VectorAdd(N3VectorScalarMultiply(N3VectorNormalize(projectionNormal), sampleSpacing * CGFloat(pixelsHigh) * 0.5), midHeightPoint), projectionNormal)
        for i in 0..<max(numVectors, 0) { // this implementation is a bit of a hack, just put the values that the straightened CPR would want, and use code copied from straightened CPR
            vectors[i] = N3LineIntersectionWithPlane(N3LineMake(vectors[i], projectionNormal), N3PlaneMake(midHeightPoint, projectionNormal))
            // vectors[i] = N3LineIntersectionWithPlane(N3LineMake(vectors[i], projectionNormal), topPlane)
            tangents[i] = N3VectorNormalize(N3VectorCrossProduct(normals[i], projectionNormal))
            normals[i] = N3VectorNormalize(projectionNormal)
        }

        memcpy(fillNormals, normals, vectorBytes)
        N3VectorScalarMultiplyVectors(sampleSpacing, fillNormals, pixelsWide)

        memcpy(inSlabNormals, normals, vectorBytes)
        N3VectorCrossProductWithVectors(inSlabNormals, tangents, pixelsWide)
        N3VectorScalarMultiplyVectors(_slabSampleDistance(), inSlabNormals, pixelsWide)

        // From here on the straightened CPR's sampling.
        let slab = CPRCurveSlab(vectors: vectors, fillNormals: fillNormals, inSlabNormals: inSlabNormals,
                                pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, pixelsDeep: pixelsDeep)

        free(vectors)
        free(fillNormals)
        free(tangents)
        free(normals)
        free(inSlabNormals)
        N3BezierCoreRelease(flattenedBezierCore)
        N3BezierCoreRelease(projectedBezierCore)

        project(slab, with: projector, interpolationMode: request.interpolationMode)
    }

    /// Samples and projects the slab; the operation finishes when the
    /// projector ends, with its volume, or with none when it was cancelled.
    private func project(_ slab: CPRCurveSlab, with projector: CPRSlabProjector, interpolationMode: CPRInterpolationMode) {
        slabProjector.withLock { $0 = projector }
        let queuePriority = self.queuePriority
        projector.start(on: CPRStretchedOperation.fillQueue, planeFills: { [self] plane, floatBytes in
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
    /// the volume's finest spacing or less. That spacing should be halved to
    /// hit the Nyquist spacing, but it is too slow.
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
}
