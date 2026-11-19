//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The selectors of the fly-through assistant in the former Horos/OsiriX
// plug-in SDK that take a std::vector<int> by reference: Swift cannot declare
// them. Each hands the vector's storage to the Swift method that does the work.

#import <vector>
#import "FlyAssistant.h"

@interface FlyAssistant (FormerSDKHistograms)
@end

@implementation FlyAssistant (FormerSDKHistograms)

- (void) computeSimpleHistogram:(std::vector<int> &)histo
{
    [self isixAddSimpleHistogramTo: histo.data() count: (NSInteger) histo.size()];
}

- (void) smooth:(std::vector<int> &)histo withWindow:(const unsigned int)w
{
    [self isixSmooth: histo.data() count: (NSInteger) histo.size() window: w];
}

- (void) determineThresholdIntervalFrom:(int)value On:(const std::vector<int> &)histo WithStep:(const int)delta
{
    [self isixDetermineThresholdIntervalFrom: value on: const_cast<int *>(histo.data()) count: (NSInteger) histo.size() step: delta];
}

- (int) getLocalMinimaFrom:(int)x OnHistogram:(const std::vector<int> &)h WithStep:(const int)delta
{
    return [self isixLocalMinimumFrom: x on: const_cast<int *>(h.data()) count: (NSInteger) h.size() step: delta];
}

- (int) getLocalMaximaFrom:(int)x OnHistogram:(const std::vector<int> &)h WithStep:(const int)delta
{
    return [self isixLocalMaximumFrom: x on: const_cast<int *>(h.data()) count: (NSInteger) h.size() step: delta];
}

@end
