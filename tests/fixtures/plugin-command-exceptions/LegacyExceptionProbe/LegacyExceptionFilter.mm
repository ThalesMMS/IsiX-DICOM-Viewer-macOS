//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// A legacy plugin, written the way Horos plugins were and ported with
// IsiXLegacyBridge, whose -filterImage: lets an Objective-C or a C++
// exception escape, as a plugin's own library does when it fails.

#import <Foundation/Foundation.h>
#import "PluginFilter.h"
#include <stdexcept>

@interface LegacyExceptionFilter : PluginFilter
@end

@implementation LegacyExceptionFilter

- (long) filterImage: (NSString*) menuName
{
    if ([menuName isEqualToString:@"Raise Objective-C"])
        [NSException raise:@"LegacyProbeException" format:@"the legacy probe raised an Objective-C exception"];
    if ([menuName isEqualToString:@"Throw C++"])
        throw std::logic_error("the legacy probe threw a C++ exception");
    return 0;
}

@end
