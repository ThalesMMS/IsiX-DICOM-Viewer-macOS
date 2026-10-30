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

/// What DCMPix decides about a NIfTI-1 image once nifti1_io has read it.
public enum NIfTIImage {
    /// The orientation codes nifti_mat44_to_orientation answers.
    public static let leftToRight: Int32 = 1, rightToLeft: Int32 = 2, posteriorToAnterior: Int32 = 3,
        anteriorToPosterior: Int32 = 4, inferiorToSuperior: Int32 = 5, superiorToInferior: Int32 = 6

    /// Whether `magic` is that of NIfTI-1 ("n+1" or "ni1"): otherwise the header is Analyze.
    public static func isNIfTI(magic: (UInt8, UInt8, UInt8, UInt8)) -> Bool {
        magic.0 == UInt8(ascii: "n") && (magic.1 == UInt8(ascii: "i") || magic.1 == UInt8(ascii: "+"))
            && magic.2 == UInt8(ascii: "1") && magic.3 == 0
    }

    /// Whether a data file of `fileSize` bytes (nil when it cannot be read) holds
    /// every voxel from where they start: nifti_image_read takes a short read for
    /// a full one and leaves the missing voxels zero.
    public static func dataFileHoldsVoxels(fileSize: UInt64?, offset: UInt64, voxels: UInt64, bytesPerVoxel: Int) -> Bool {
        guard let fileSize else { return false }
        return fileSize >= offset &+ voxels &* UInt64(truncatingIfNeeded: bytesPerVoxel)
    }

    /// The datatypes turned into floats: (u)int 8, 16, 32 and 64, float32 and float64.
    public static func convertsToFloats(_ datatype: Int16) -> Bool {
        [2, 256, 4, 512, 8, 768, 1024, 1280, 16, 64].contains(datatype)
    }

    /// `count` voxels of `datatype` as floats; false (nothing written) for a datatype that is not shown.
    /// vDSP converts as the C casts did (round to nearest); it keeps a frame as fast
    /// as the C loop in a build without optimization, where a loop in Swift is not.
    @discardableResult
    public static func floats(_ voxels: UnsafeRawPointer, datatype: Int16, count: Int, into values: UnsafeMutablePointer<Float>) -> Bool {
        guard convertsToFloats(datatype) else { return false }
        guard count > 0 else { return true }
        let n = vDSP_Length(count)
        switch datatype {
        case 2: vDSP_vfltu8(voxels.assumingMemoryBound(to: UInt8.self), 1, values, 1, n)
        case 256: vDSP_vflt8(voxels.assumingMemoryBound(to: Int8.self), 1, values, 1, n)
        case 4: vDSP_vflt16(voxels.assumingMemoryBound(to: Int16.self), 1, values, 1, n)
        case 512: vDSP_vfltu16(voxels.assumingMemoryBound(to: UInt16.self), 1, values, 1, n)
        case 8: vDSP_vflt32(voxels.assumingMemoryBound(to: Int32.self), 1, values, 1, n)
        case 768: vDSP_vfltu32(voxels.assumingMemoryBound(to: UInt32.self), 1, values, 1, n)
        case 1024:
            let source = voxels.assumingMemoryBound(to: Int64.self)
            for i in 0..<count { values[i] = Float(source[i]) }
        case 1280:
            let source = voxels.assumingMemoryBound(to: UInt64.self)
            for i in 0..<count { values[i] = Float(source[i]) }
        case 16: values.update(from: voxels.assumingMemoryBound(to: Float.self), count: count)
        case 64: vDSP_vdpsp(voxels.assumingMemoryBound(to: Double.self), 1, values, 1, n)
        default: return false
        }
        return true
    }

    /// RGB24 voxels as four bytes a pixel, alpha (zero) first.
    public static func argb(_ rgb: UnsafePointer<UInt8>, count: Int, into argb: UnsafeMutablePointer<UInt8>) {
        for i in 0..<Swift.max(count, 0) {
            argb[4 * i] = 0
            argb[4 * i + 1] = rgb[3 * i]
            argb[4 * i + 2] = rgb[3 * i + 1]
            argb[4 * i + 3] = rgb[3 * i + 2]
        }
    }

    /// How a NIfTI frame is placed, from the codes of its i and j axes.
    public struct Placement: Equatable {
        /// The axis the frame number advances along (0 x: sagittal, 1 y: coronal,
        /// 2 z: axial), nil when the codes say none.
        public var stackAxis: Int?
        /// How many times the rows of the orientation turn: the second takes the
        /// first, the first takes the third (whole numbers of it).
        public var turns: Int
        /// Whether the second row takes the third (j is superior/inferior).
        public var secondRowFromThird: Bool
        public var flipsColumns: Bool
        public var flipsRows: Bool
    }

    /// The placement the codes `i` and `j` give.
    public static func placement(i: Int32, j: Int32) -> Placement {
        var stackAxis: Int?
        if j == anteriorToPosterior || j == posteriorToAnterior {
            stackAxis = 2
        } else if j == superiorToInferior || j == inferiorToSuperior {
            if i == anteriorToPosterior || i == posteriorToAnterior {
                stackAxis = 0
            } else if i == rightToLeft || i == leftToRight {
                stackAxis = 1
            }
        }
        var turns = 0
        var secondRowFromThird = false
        if i != leftToRight && i != rightToLeft {
            if i == anteriorToPosterior || i == posteriorToAnterior {
                turns = 2
            } else if i == superiorToInferior || i == inferiorToSuperior {
                turns = 1
            }
        } else if j != anteriorToPosterior && j != posteriorToAnterior {
            secondRowFromThird = true
        }
        let flipsColumns = i == leftToRight || i == posteriorToAnterior || i == superiorToInferior
        let flipsRows = j == posteriorToAnterior || j == leftToRight || j == superiorToInferior
        return Placement(stackAxis: stackAxis, turns: turns, secondRowFromThird: secondRowFromThird,
                         flipsColumns: flipsColumns, flipsRows: flipsRows)
    }
}
