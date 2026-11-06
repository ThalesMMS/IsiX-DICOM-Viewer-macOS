//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import <Foundation/Foundation.h>
#include <stdexcept>
#include "ProbeThrowers.h"

void ProbeRaiseObjectiveC(void)
{
    [NSException raise:@"ProbeObjCException" format:@"the probe raised an Objective-C exception"];
}

void ProbeThrowCxx(void)
{
    throw std::runtime_error("the probe threw a C++ exception");
}

void ProbeThrowInt(void)
{
    throw 42;
}
