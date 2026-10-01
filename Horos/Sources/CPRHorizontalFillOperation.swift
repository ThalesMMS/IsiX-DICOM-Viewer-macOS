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

/// Fills floatBytes from the given data. floatBytes is a tightly packed float
/// image of width "width" and height "height": it is filled with the values at
/// vectors, and each successive scan line with the values at
/// vector+normal*scanlineNumber.
///
/// Implemented in Swift since #719: the Objective-C name, the selectors and
/// <Horos/CPRHorizontalFillOperation.h> are those of the former class.
///
/// @unchecked Sendable, restated from Operation: every property is constant
/// after `init`. The operation writes only its own rows of `floatBytes`, and
/// the generator reads them after the operation has finished.
@objc(CPRHorizontalFillOperation)
public final class CPRHorizontalFillOperation: Operation, @unchecked Sendable {
    @objc public let volumeData: CPRVolumeData?

    @objc public let floatBytes: UnsafeMutablePointer<Float>?
    @objc public let width: UInt
    @objc public let height: UInt

    @objc public let vectors: UnsafeMutablePointer<N3Vector>?
    @objc public let normals: UnsafeMutablePointer<N3Vector>?

    @objc public let interpolationMode: CPRInterpolationMode // YES by default

    /// vectors and normals need to be arrays of length width; they are copied.
    @objc(initWithVolumeData:interpolationMode:floatBytes:width:height:vectors:normals:)
    public init(volumeData: CPRVolumeData?, interpolationMode: CPRInterpolationMode, floatBytes: UnsafeMutablePointer<Float>?,
                width: UInt, height: UInt, vectors: UnsafeMutablePointer<N3Vector>?, normals: UnsafeMutablePointer<N3Vector>?) {
        let vectorBytes = Int(bitPattern: width &* UInt(MemoryLayout<N3Vector>.size))
        self.volumeData = volumeData
        self.floatBytes = floatBytes
        self.width = width
        self.height = height
        self.vectors = malloc(vectorBytes)?.assumingMemoryBound(to: N3Vector.self)
        memcpy(self.vectors, vectors, vectorBytes)
        self.normals = malloc(vectorBytes)?.assumingMemoryBound(to: N3Vector.self)
        memcpy(self.normals, normals, vectorBytes)
        self.interpolationMode = interpolationMode
        super.init()
    }

    /// -init of NSOperation left everything zero, as this does.
    @objc public override convenience init() {
        self.init(volumeData: nil, interpolationMode: 0, floatBytes: nil, width: 0, height: 0, vectors: nil, normals: nil)
    }

    deinit {
        free(vectors)
        free(normals)
    }

    public override func main() {
        autoreleasepool {
            // The former @try/@catch (...) ended the operation quietly.
            try? HorosObjCException.perform { self.fill() }
        }
    }

    private func fill() {
        if isCancelled {
            return
        }

        let threadPriority = Thread.threadPriority()
        Thread.setThreadPriority(threadPriority * 0.5)

        if interpolationMode == CPRInterpolationMode(CPRInterpolationModeLinear.rawValue) {
            _linearInterpolatingFill()
        } else if interpolationMode == CPRInterpolationMode(CPRInterpolationModeNearestNeighbor.rawValue) {
            _nearestNeighborFill()
        } else if interpolationMode == CPRInterpolationMode(CPRInterpolationModeCubic.rawValue) {
            _cubicInterpolatingFill()
        } else {
            _unknownInterpolatingFill()
        }

        Thread.setThreadPriority(threadPriority)
    }

    /// The vectors and normals in the volume's pixel space, in malloc'd arrays
    /// the caller frees.
    private func volumeVectorsAndNormals() -> (UnsafeMutablePointer<N3Vector>, UnsafeMutablePointer<N3Vector>) {
        let count = Int(bitPattern: width)
        let vectorBytes = Int(bitPattern: width &* UInt(MemoryLayout<N3Vector>.size))
        // A nil volume gives the zero transform, as a message to nil did.
        let volumeTransform = volumeData?.volumeTransform ?? N3AffineTransform()

        let volumeVectors = malloc(vectorBytes)!.assumingMemoryBound(to: N3Vector.self)
        memcpy(volumeVectors, vectors, vectorBytes)
        N3VectorApplyTransformToVectors(volumeTransform, volumeVectors, count)

        let volumeNormals = malloc(vectorBytes)!.assumingMemoryBound(to: N3Vector.self)
        memcpy(volumeNormals, normals, vectorBytes)
        var vectorTransform = volumeTransform
        vectorTransform.m41 = 0.0
        vectorTransform.m42 = 0.0
        vectorTransform.m43 = 0.0
        N3VectorApplyTransformToVectors(vectorTransform, volumeNormals, count)

        return (volumeVectors, volumeNormals)
    }

    // The three fills below are the former three copies of one loop, each
    // calling its own inline sampling function of CPRVolumeData.h. Their inner
    // loops, one line of samples, are C functions of CPRVolumeData+CAPI.m, so
    // that the samplers are compiled as the Objective-C compiled them
    // (-ffast-math in Release), which Swift does not do. They index floatBytes
    // and the vector arrays with no bounds checks, as the Objective-C did:
    // floatBytes holds width*height floats and the arrays width vectors.

    private func _linearInterpolatingFill() {
        let width = Int(bitPattern: self.width)
        let height = Int(bitPattern: self.height)
        let (volumeVectors, volumeNormals) = volumeVectorsAndNormals()
        var inlineBuffer = CPRVolumeDataInlineBuffer()

        if volumeData?.aquireInlineBuffer(&inlineBuffer) ?? false {
            let floatBytes = self.floatBytes!
            for y in 0..<max(height, 0) {
                if isCancelled {
                    break
                }

                CPRVolumeDataLinearInterpolatedFloatsAtVolumeVectorsForSwift(&inlineBuffer, volumeVectors, floatBytes + y &* width, width)

                N3VectorAddVectors(volumeVectors, volumeNormals, width)
            }
        } else {
            memset(floatBytes, 0, Int(bitPattern: self.height &* self.width &* UInt(MemoryLayout<Float>.size)))
        }

        volumeData?.releaseInlineBuffer(&inlineBuffer)

        free(volumeVectors)
        free(volumeNormals)
    }

    private func _nearestNeighborFill() {
        let width = Int(bitPattern: self.width)
        let height = Int(bitPattern: self.height)
        let (volumeVectors, volumeNormals) = volumeVectorsAndNormals()
        var inlineBuffer = CPRVolumeDataInlineBuffer()

        if volumeData?.aquireInlineBuffer(&inlineBuffer) ?? false {
            let floatBytes = self.floatBytes!
            for y in 0..<max(height, 0) {
                if isCancelled {
                    break
                }

                CPRVolumeDataNearestNeighborInterpolatedFloatsAtVolumeVectorsForSwift(&inlineBuffer, volumeVectors, floatBytes + y &* width, width)

                N3VectorAddVectors(volumeVectors, volumeNormals, width)
            }
        } else {
            memset(floatBytes, 0, Int(bitPattern: self.height &* self.width &* UInt(MemoryLayout<Float>.size)))
        }

        volumeData?.releaseInlineBuffer(&inlineBuffer)

        free(volumeVectors)
        free(volumeNormals)
    }

    private func _cubicInterpolatingFill() {
        let width = Int(bitPattern: self.width)
        let height = Int(bitPattern: self.height)
        let (volumeVectors, volumeNormals) = volumeVectorsAndNormals()
        var inlineBuffer = CPRVolumeDataInlineBuffer()

        if volumeData?.aquireInlineBuffer(&inlineBuffer) ?? false {
            let floatBytes = self.floatBytes!
            for y in 0..<max(height, 0) {
                if isCancelled {
                    break
                }

                CPRVolumeDataCubicInterpolatedFloatsAtVolumeVectorsForSwift(&inlineBuffer, volumeVectors, floatBytes + y &* width, width)

                N3VectorAddVectors(volumeVectors, volumeNormals, width)
            }
        } else {
            memset(floatBytes, 0, Int(bitPattern: self.height &* self.width &* UInt(MemoryLayout<Float>.size)))
        }

        volumeData?.releaseInlineBuffer(&inlineBuffer)

        free(volumeVectors)
        free(volumeNormals)
    }

    private func _unknownInterpolatingFill() {
        NSLog("unknown interpolation mode")
        // Every float: the former byte count lacked sizeof(float) and cleared
        // only the first quarter of the buffer (#773).
        memset(floatBytes, 0, Int(bitPattern: height &* width &* UInt(MemoryLayout<Float>.size)))
    }
}
