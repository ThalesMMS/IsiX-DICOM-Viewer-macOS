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

import CoreGraphics

// N2MinMax is the C struct of N2MinMax.h, the width constraint
// N2CellDescriptor gives Objective-C; its arithmetic, C++ in the former
// N2MinMax.mm, is here, for N2ColumnLayout. A minimum and a maximum are those
// of std::min and std::max: with equal values, a signed zero or a NaN, the
// first operand is kept, as the C++ kept it.

extension N2MinMax {
    /// N2MakeMinMax(): no constraint, from N2NoMin to N2NoMax.
    static var unconstrained: N2MinMax {
        N2MinMax(min: N2NoMin, max: N2NoMax)
    }

    /// N2ComposeMinMax: the larger minimum and the smaller maximum.
    func composed(with other: N2MinMax) -> N2MinMax {
        N2MinMax(min: maximum(min, other.min), max: minimum(max, other.max))
    }

    /// N2MinMaxConstrainedValue: the value raised to the minimum, then lowered
    /// to the maximum.
    func constrained(_ value: CGFloat) -> CGFloat {
        var value = value
        if value < min { value = min }
        if value > max { value = max }
        return value
    }

    /// operator+(const N2MinMax&, const N2MinMax&)
    static func + (lhs: N2MinMax, rhs: N2MinMax) -> N2MinMax {
        N2MinMax(min: infinityAwareSum(lhs.min, rhs.min), max: infinityAwareSum(lhs.max, rhs.max))
    }

    /// operator+(const N2MinMax&, const CGFloat&)
    static func + (lhs: N2MinMax, rhs: CGFloat) -> N2MinMax {
        N2MinMax(min: infinityAwareSum(lhs.min, rhs), max: infinityAwareSum(lhs.max, rhs))
    }
}

/// std::min: the second only when it is smaller.
private func minimum(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
    b < a ? b : a
}

/// std::max: the second only when the first is smaller.
private func maximum(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
    a < b ? b : a
}

/// N2InfinityAwareSum: N2NoMax (CGFLOAT_MAX), then N2NoMin (CGFLOAT_MIN),
/// absorbs the other term.
private func infinityAwareSum(_ f1: CGFloat, _ f2: CGFloat) -> CGFloat {
    if f1 == N2NoMax || f2 == N2NoMax { return N2NoMax }
    if f1 == N2NoMin || f2 == N2NoMin { return N2NoMin }
    return f1 + f2
}
