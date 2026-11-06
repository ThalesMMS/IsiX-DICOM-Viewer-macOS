//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import "DicomFileDCMTKCategory.h"
#import "IsiXDCMTKFile.h"

// +newSeriesUID is of the new family by its name, and its declaration says the
// string it returns is autoreleased (+0), which callers - plugins included -
// rely on. A Swift implementation returns +1 whatever the declaration says, so
// every caller would leak the string; this file is compiled under manual
// retain and release and returns the autoreleased string the adapter makes.
@implementation DicomFile (Identifiers)

+ (NSString *)newSeriesUID
{
    return [IsiXDCMTKFile generateUIDWithRoot:IsiXDCMTKUIDRootSeries];
}

@end
