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

// The sampling of CPRVolumeData, which is implemented in Swift since #719
// (Horos/Sources/CPRVolumeData.swift). The interpolating getters of the class
// sample through these functions, so that the inline samplers of CPRVolumeData.h
// are compiled by clang with the flags of the target, as for every Objective-C
// caller: the Release build uses -ffast-math, which changes how the linear and
// cubic samplers round. Swift compiling the inline functions itself would not
// use it.

#import "CPRVolumeData.h"

float CPRVolumeDataLinearInterpolatedFloatAtDicomVectorForSwift(CPRVolumeDataInlineBuffer *inlineBuffer, N3Vector vector)
{
    return CPRVolumeDataLinearInterpolatedFloatAtDicomVector(inlineBuffer, vector);
}

float CPRVolumeDataNearestNeighborInterpolatedFloatAtDicomVectorForSwift(CPRVolumeDataInlineBuffer *inlineBuffer, N3Vector vector)
{
    return CPRVolumeDataNearestNeighborInterpolatedFloatAtDicomVector(inlineBuffer, vector);
}

float CPRVolumeDataCubicInterpolatedFloatAtDicomVectorForSwift(CPRVolumeDataInlineBuffer *inlineBuffer, N3Vector vector)
{
    return CPRVolumeDataCubicInterpolatedFloatAtDicomVector(inlineBuffer, vector);
}

float CPRVolumeDataLinearInterpolatedFloatAtVolumeCoordinateForSwift(CPRVolumeDataInlineBuffer *inlineBuffer, CGFloat x, CGFloat y, CGFloat z)
{
    return CPRVolumeDataLinearInterpolatedFloatAtVolumeCoordinate(inlineBuffer, x, y, z);
}

// The inner loops of the three fills of CPRHorizontalFillOperation, as the
// Objective-C wrote them, so that the samplers are inlined with the flags of the
// Objective-C: -ffast-math in Release, which Swift must not get (#998). The
// target compiles this file with -O3 in Debug too, as Swift -O inlined the
// samplers before; the samples are the same bits as at -O0.
void CPRVolumeDataLinearInterpolatedFloatsAtVolumeVectorsForSwift(CPRVolumeDataInlineBuffer *inlineBuffer, const N3Vector *vectors, float *floats, NSInteger count)
{
    for (NSInteger i = 0; i < count; i++) {
        floats[i] = CPRVolumeDataLinearInterpolatedFloatAtVolumeVector(inlineBuffer, vectors[i]);
    }
}

void CPRVolumeDataNearestNeighborInterpolatedFloatsAtVolumeVectorsForSwift(CPRVolumeDataInlineBuffer *inlineBuffer, const N3Vector *vectors, float *floats, NSInteger count)
{
    for (NSInteger i = 0; i < count; i++) {
        floats[i] = CPRVolumeDataNearestNeighborInterpolatedFloatAtVolumeVector(inlineBuffer, vectors[i]);
    }
}

void CPRVolumeDataCubicInterpolatedFloatsAtVolumeVectorsForSwift(CPRVolumeDataInlineBuffer *inlineBuffer, const N3Vector *vectors, float *floats, NSInteger count)
{
    for (NSInteger i = 0; i < count; i++) {
        floats[i] = CPRVolumeDataCubicInterpolatedFloatAtVolumeVector(inlineBuffer, vectors[i]);
    }
}
