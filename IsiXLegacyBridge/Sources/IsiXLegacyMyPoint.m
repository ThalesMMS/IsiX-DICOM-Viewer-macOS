//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Compiled with ARC (-fobjc-arc), whatever the plugin's own setting.

#import "IsiXLegacyBridgeInternal.h"

@implementation IsiXLegacyMyPoint

+ (IsiXLegacyMyPoint*) point: (NSPoint) a
{
    return [[self alloc] initWithPoint: a];
}

- (id) initWithPoint: (NSPoint) a
{
    if ((self = [super init])) pt = a;
    return self;
}

- (id) copyWithZone: (NSZone*) zone
{
    return [[[self class] allocWithZone: zone] initWithPoint: pt];
}

- (NSPoint) point { return pt; }
- (void) setPoint: (NSPoint) a { pt = a; }
- (float) x { return pt.x; }
- (float) y { return pt.y; }

- (void) move: (float) x :(float) y
{
    pt.x += x;
    pt.y += y;
}

- (BOOL) isEqualToPoint: (NSPoint) a
{
    return NSEqualPoints(pt, a);
}

- (BOOL) isNearToPoint: (NSPoint) a :(float) scale :(float) ratio
{
    return fabs(pt.x - a.x) < 5.0 / scale && fabs(pt.y - a.y) < 5.0 / (scale * ratio);
}

- (NSString*) description
{
    return [NSString stringWithFormat: @"%f %f", pt.x, pt.y];
}

@end
