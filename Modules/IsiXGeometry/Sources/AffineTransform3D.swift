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

import QuartzCore

/// The geometry's transforms are Core Animation's: a point is a row vector
/// (x y z 1) times the matrix, so the translation is m41, m42, m43.
public extension CATransform3D {

    @inlinable
    var isAffine: Bool {
        m14 == 0.0 && m24 == 0.0 && m34 == 0.0 && m44 == 1.0
    }

    /// Only scales and translates.
    var isRectilinear: Bool {
        m12 == 0.0 && m13 == 0.0 && m14 == 0.0 &&
            m21 == 0.0 && m23 == 0.0 && m24 == 0.0 &&
            m31 == 0.0 && m32 == 0.0 && m34 == 0.0 &&
            m44 == 1.0
    }

    var transposed: CATransform3D {
        CATransform3D(m11: m11, m12: m21, m13: m31, m14: m41,
                      m21: m12, m22: m22, m23: m32, m24: m42,
                      m31: m13, m32: m23, m33: m33, m34: m43,
                      m41: m14, m42: m24, m43: m34, m44: m44)
    }

    /// The determinant of the 3×3 part of an affine transform.
    var determinant: Double {
        assert(isAffine)
        return ((m21 * m32) * m13)
            .addingProduct(m11 * m22, m33)
            .addingProduct(m31 * m12, m23)
            .addingProduct(-(m11 * m32), m23)
            .addingProduct(-(m21 * m12), m33)
            .addingProduct(-(m31 * m22), m13)
    }

    /// The inverse; an affine transform keeps an exact last column, which
    /// CATransform3DInvert does not always give.
    var inverted: CATransform3D {
        var inverse = CATransform3DInvert(self)
        if isAffine {
            inverse.m14 = 0.0
            inverse.m24 = 0.0
            inverse.m34 = 0.0
            inverse.m44 = 1.0
        }
        return inverse
    }

    /// self, then transform; two affine transforms keep an exact last column.
    func concatenating(_ transform: CATransform3D) -> CATransform3D {
        var concatenation = CATransform3DConcat(self, transform)
        if isAffine && transform.isAffine {
            concatenation.m14 = 0.0
            concatenation.m24 = 0.0
            concatenation.m34 = 0.0
            concatenation.m44 = 1.0
        }
        return concatenation
    }
}
