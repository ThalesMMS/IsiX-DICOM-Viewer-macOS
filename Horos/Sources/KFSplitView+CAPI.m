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
// KFSplitView.m
// KFSplitView v. 1.3, 11/27/2004
// 
// Copyright (c) 2003-2004 Ken Ferry. Some rights reserved.
// http://homepage.mac.com/kenferry/software.html
//
// Other contributors: Kirk Baker, John Pannell
// 
// This work is licensed under a Creative Commons license:
// http://creativecommons.org/licenses/by-nc/1.0/
//
// Send me an email if you have any problems (after you've read what there is to read).
//
// You can reach me at kenferry at the domain mac.com.
// 
// On this whole major axis, minor axis thing:
// 
//     The 'major' axis refers to the direction in which dividers can move.
//     It's the y-axis when [self isVertical] returns NO, and the x-axis otherwise.
//     Pretty much everything that uses coordinates or dimensions in this file works
//     more comfortably in that coordinate system.
// 
// Other
// 
//     This class is a basically a complete reimplementation of NSSplitView.  The
//     underlying NSSplitView is mostly used for drawing dividers.

// The part of KFSplitView that stays in Objective-C. The class is implemented
// in Swift since #714 (KFSplitView.swift). The former KFSplitView.m defined:
// - KFOffScreenPoint, a global the executable exports as _KFOffScreenPoint.
//   The header never declared it; the Swift class uses the same value.
// - kfScaleUInts, unchanged here as KFSplitViewScaleUInts: it draws from rand(),
//   which Swift cannot call, and keeps its float and unsigned arithmetic.
//   KFSplitView.h declares it only to Swift, and the symbol is not exported.

#import <AppKit/AppKit.h>

__attribute__((used)) const NSPoint KFOffScreenPoint = {1000000.0,1000000.0};

// Declared to Swift by KFSplitView.h, under HOROS_BRIDGING_HEADER.
BOOL KFSplitViewScaleUInts(unsigned *integers, int numInts, unsigned targetTotal);

// proportionally scale a list of integers so that the sum of the resulting list is targetTotal
// Will fail (return NO) if all integers are zero 
// Favors not completely zeroing out a nonzero int
__attribute__((visibility("hidden"))) BOOL KFSplitViewScaleUInts(unsigned *integers, int numInts, unsigned targetTotal)
{
    unsigned total;
    float scalingFactor;
    int i, numNonZeroInts;
    
    // compute total
    total = 0;
    numNonZeroInts = 0;
    for (i = 0; i < numInts; i++)
    {
        if (integers[i] != 0)
        {
            total += integers[i];
            numNonZeroInts++;
        }
    }
    
    if (numNonZeroInts == 0) // fail
    {
        return NO;
    }
    
    // compute scalingFactor
    scalingFactor = (float)targetTotal / total;
    
    // scale all ints and recompute total (which may not equal targetTotal due to roundoff error)
    total = 0;
    for (i = 0; i < numInts; i++)
    {
        if (integers[i] != 0)
        {
            // this is preferable to rounding when used for subviews - helps
            // prevent a subview getting stuck at thickness 1 during a drag resize
            integers[i] = MAX(floor(scalingFactor*integers[i]), 1); 
            total += integers[i];
        }
    }
    
    // Each non-zero integer may be as much as 1 off of its "proper" floating point value due to roundoff,
    // so abs(targetTotal - total) might be as much as numNonZero.  We randomly choose integers to increment (or decrement)
    // to make up the gap, and we choose only from the non-zero values.
    int gap = abs((int)targetTotal - (int)total);
    int closeGapIncrement =  (targetTotal > total) ? 1 : -1;
    int numRemainingNonZeroInts = numNonZeroInts;
    for (i = 0; i < numInts && gap > 0; i++)
    {
        if (integers[i] > 0)
        {
            BOOL shouldIncrementInt =  (gap == numRemainingNonZeroInts) || (rand() < (float) gap / numRemainingNonZeroInts * RAND_MAX);
            if (shouldIncrementInt)
            {
                integers[i] += closeGapIncrement;
                gap--;
            }
            numRemainingNonZeroInts--;
        }
    }
    
    return YES;
}
