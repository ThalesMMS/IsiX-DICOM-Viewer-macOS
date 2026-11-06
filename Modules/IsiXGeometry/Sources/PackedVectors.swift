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
import QuartzCore

/// Arrays of vectors stored as consecutive x, y, z doubles (the layout of a C
/// array of three-double structs), changed in place with vDSP.
public enum PackedVectors {

    /// Every vector times scalar.
    public static func scale(_ vectors: UnsafeMutablePointer<Double>, count: Int, by scalar: Double) {
        var scalar = scalar
        vDSP_vsmulD(vectors, 1, &scalar, vectors, 1, vDSP_Length(count * 3))
    }

    /// vectors[i] += others[i].
    public static func add(_ others: UnsafePointer<Double>, to vectors: UnsafeMutablePointer<Double>, count: Int) {
        vDSP_vaddD(vectors, 1, others, 1, vectors, 1, vDSP_Length(count * 3))
    }

    /// Every point transformed by an affine transform.
    public static func apply(_ transform: CATransform3D, to vectors: UnsafeMutablePointer<Double>, count: Int) {
        assert(transform.isAffine)
        let linear: [Double] = [transform.m11, transform.m12, transform.m13,
                      transform.m21, transform.m22, transform.m23,
                      transform.m31, transform.m32, transform.m33]
        var translation: [Double] = [transform.m41, transform.m42, transform.m43]
        let transformed = UnsafeMutablePointer<Double>.allocate(capacity: max(count * 3, 1))
        defer { transformed.deallocate() }
        vDSP_mmulD(vectors, 1, linear, 1, transformed, 1, vDSP_Length(count), 3, 3)
        for axis in 0..<3 {
            vDSP_vsaddD(transformed + axis, 3, &translation[axis], vectors + axis, 3, vDSP_Length(count))
        }
    }
}
