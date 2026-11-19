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

// The C++ functions and operators of N2Operators.h and N2MinMax.h, and N2Yes
// and N2No. The application's own arithmetic on sizes, points and N2MinMax is
// Swift; these stay for the plugins built for Horos or OsiriX in
// Objective-C++, which call them by their mangled names without being rebuilt.
// Swift cannot define a function with a C++ name, and every one here is marked
// used so that the linker keeps it although the application calls none.

#import "N2Operators.h"
#import "N2MinMax.h"
#import "N2Alignment.h"
#include <cmath>
#include <algorithm>

// A const of namespace scope is internal in C++ unless a declaration says
// extern: N2Operators.h does, for these two.
__attribute__((used)) const NSNumber* const N2Yes = [[NSNumber alloc] initWithBool:YES];
__attribute__((used)) const NSNumber* const N2No = [[NSNumber alloc] initWithBool:NO];

// NSRectCenteredInRect is a C function (N2Operators.swift). Horos compiled it as
// Objective-C++ without C linkage, so a plugin built against it looks up the
// C++ name: the same function, under that name too.
__attribute__((used)) NSRect IsiXNSRectCenteredInRectCXX(NSRect smallRect, NSRect bigRect) __asm__("__Z20NSRectCenteredInRect6CGRectS_");
NSRect IsiXNSRectCenteredInRectCXX(NSRect smallRect, NSRect bigRect) {
	return NSRectCenteredInRect(smallRect, bigRect);
}

/// NSSize

namespace n2 {
	
	__attribute__((used)) NSSize floor(const NSSize& s) {
		return NSMakeSize(std::floor(s.width), std::floor(s.height));
	}
	
	__attribute__((used)) NSSize ceil(const NSSize& s) {
		return NSMakeSize(std::ceil(s.width), std::ceil(s.height));
	}
	
	__attribute__((used)) NSSize round(const NSSize& s) {
		return floor(s+0.5);
	}
	
}

__attribute__((used)) NSSize NSMakeSize(CGFloat wh) {
	return NSMakeSize(wh, wh);
}

__attribute__((used)) NSSize operator-(const NSSize& s) {
	return NSMakeSize(-s.width, -s.height);
}

__attribute__((used)) NSSize operator+(const NSSize& s1, const NSSize& s2) {
	return NSMakeSize(s2.width+s1.width, s2.height+s1.height);
}

__attribute__((used)) NSSize operator+=(NSSize& s1, const NSSize& s2) {
	return s1 = s1+s2;
}

__attribute__((used)) NSSize operator-(const NSSize& s1, const NSSize& s2) {
	return s1+(-s2);
}

__attribute__((used)) NSSize operator-=(NSSize& s1, const NSSize& s2) {
	return s1 = s1-s2;
}

__attribute__((used)) NSSize operator*(const NSSize& s1, const NSSize& s2) {
	return NSMakeSize(s1.width*s2.width, s1.height*s2.height);
}

__attribute__((used)) NSSize operator*=(NSSize& s1, const NSSize& s2) {
	return s1 = s1*s2;
}

__attribute__((used)) NSSize operator/(const NSSize& s1, const NSSize& s2) {
	return s1*(1/s2);
}

__attribute__((used)) NSSize operator/=(NSSize& s1, const NSSize& s2) {
	return s1 = s1/s2;
}

__attribute__((used)) BOOL operator==(const NSSize& s1, const NSSize& s2) {
	return (s1.width==s2.width) && (s1.height==s2.height);
}

__attribute__((used)) BOOL operator!=(const NSSize& s1, const NSSize& s2) {
	return !(s1==s2);
}

// NSSize & CGFloat

__attribute__((used)) NSSize operator+(const NSSize& s, const CGFloat f) {
	return NSMakeSize(s.width+f, s.height+f);
}

__attribute__((used)) NSSize operator+=(NSSize& s, const CGFloat f) {
	return s = s+f;
}

__attribute__((used)) NSSize operator-(const NSSize& s, const CGFloat f) {
	return s+(-f);
}

__attribute__((used)) NSSize operator-=(NSSize& s, const CGFloat f) {
	return s = s-f;
}

__attribute__((used)) NSSize operator*(const CGFloat f, const NSSize& s) {
	return NSMakeSize(f*s.width, f*s.height);
}

__attribute__((used)) NSSize operator/(const CGFloat f, const NSSize& s) {
	return NSMakeSize(f/s.width, f/s.height);
}

__attribute__((used)) NSSize operator*(const NSSize& s, const CGFloat f) {
	return f*s;
}

__attribute__((used)) NSSize operator*=(NSSize& s, const CGFloat f) {
	return s = s*f;
}

__attribute__((used)) NSSize operator/(const NSSize& s, const CGFloat f) {
	return s*(1/f);
}

__attribute__((used)) NSSize operator/=(NSSize& s, const CGFloat f) {
	return s = s/f;
}


/// NSPoint

__attribute__((used)) NSPoint operator-(const NSPoint& p) {
	return NSMakePoint(-p.x, -p.y);
}

__attribute__((used)) NSPoint operator+(const NSPoint& p1, const NSPoint& p2) {
	return NSMakePoint(p2.x+p1.x, p2.y+p1.y);
}

__attribute__((used)) NSPoint operator+=(NSPoint& p1, const NSPoint& p2) {
	return p1 = p1+p2;
}

__attribute__((used)) NSPoint operator-(const NSPoint& p1, const NSPoint& p2) {
	return p1+(-p2);
}

__attribute__((used)) NSPoint operator-=(NSPoint& p1, const NSPoint& p2) {
	return p1 = p1-p2;
}

__attribute__((used)) NSPoint operator*(const NSPoint& p1, const NSPoint& p2) {
	return NSMakePoint(p1.x*p2.x, p1.y*p2.y);
}

__attribute__((used)) NSPoint operator*=(NSPoint& p1, const NSPoint& p2) {
	return p1 = p1*p2;
}

__attribute__((used)) NSPoint operator/(const NSPoint& p1, const NSPoint& p2) {
	return p1*(1/p2);
}

__attribute__((used)) NSPoint operator/=(NSPoint& p1, const NSPoint& p2) {
	return p1 = p1/p2;
}

__attribute__((used)) BOOL operator==(const NSPoint& p1, const NSPoint& p2) {
	return (p1.x==p2.x) && (p1.y==p2.y);
}

__attribute__((used)) BOOL operator!=(const NSPoint& p1, const NSPoint& p2) {
	return !(p1==p2);
}

// NSPoint & CGFloat

__attribute__((used)) NSPoint operator+(const NSPoint& p, const CGFloat f) {
	return NSMakePoint(p.x+f, p.y+f);
}

__attribute__((used)) NSPoint operator+=(NSPoint& p, const CGFloat f) {
	return p = p+f;
}

__attribute__((used)) NSPoint operator-(const NSPoint& p, const CGFloat f) {
	return p+(-f);
}

__attribute__((used)) NSPoint operator-=(NSPoint& p, const CGFloat f) {
	return p = p-f;
}

__attribute__((used)) NSPoint operator*(const CGFloat f, const NSPoint& p) {
	return NSMakePoint(f*p.x, f*p.y);
}

__attribute__((used)) NSPoint operator/(const CGFloat f, const NSPoint& p) {
	return NSMakePoint(f/p.x, f/p.y);
}

__attribute__((used)) NSPoint operator*(const NSPoint& p, const CGFloat f) {
	return f*p;
}

__attribute__((used)) NSPoint operator*=(NSPoint& p, const CGFloat f) {
	return p = p*f;
}

__attribute__((used)) NSPoint operator/(const NSPoint& p, const CGFloat f) {
	return p*(1/f);
}

__attribute__((used)) NSPoint operator/=(NSPoint& p, const CGFloat f) {
	return p = p/f;
}

// NSPoint & NSSize

__attribute__((used)) NSPoint NSMakePoint(const NSSize& s) {
	return NSMakePoint(s.width, s.height);
}

__attribute__((used)) NSSize operator+(const NSSize& s, const NSPoint& p) {
	return NSMakeSize(p.x+s.width, p.y+s.height);
}

__attribute__((used)) NSSize operator+=(NSSize& s, const NSPoint& p) {
	return s = s+p;
}

__attribute__((used)) NSPoint operator+(const NSPoint& p, const NSSize& s) {
	return NSMakePoint(p.x+s.width, p.y+s.height);
}

__attribute__((used)) NSPoint operator+=(NSPoint& p, const NSSize& s) {
	return p = p+s;
}

__attribute__((used)) NSSize operator-(const NSSize& s, const NSPoint& p) {
	return s+(-p);
}

__attribute__((used)) NSPoint operator-(const NSPoint& p, const NSSize& s) {
	return p+(-s);
}

__attribute__((used)) NSSize operator*(const NSSize& s, const NSPoint& p) {
	return NSMakeSize(p.x*s.width, p.y*s.height);
}

__attribute__((used)) NSPoint operator*(const NSPoint& p, const NSSize& s) {
	return NSMakePoint(p.x*s.width, p.y*s.height);
}

__attribute__((used)) NSSize operator/(const NSSize& s, const NSPoint& p) {
	return s*(1/p);
}

__attribute__((used)) NSPoint operator/(const NSPoint& p, const NSSize& s) {
	return p*(1/s);
}


/// NSVector

__attribute__((used)) NSVector NSMakeVector(CGFloat x, CGFloat y) {
	NSVector vector;
	vector.x = x;
	vector.y = y;
	return vector;
}

__attribute__((used)) NSVector NSMakeVector(const NSPoint& p1, const NSPoint& p2) {
	return NSMakeVector(p2.x-p1.x, p2.y-p1.y);
}

__attribute__((used)) NSVector NSMakeVector(const NSPoint& p) {
	return NSMakeVector(p.x, p.y);
}

__attribute__((used)) NSPoint NSMakePoint(const NSVector& v) {
	return NSMakePoint(v.x, v.y);
}

__attribute__((used)) NSVector operator!(const NSVector& v) {
	return NSMakeVector(-v.y, v.x);
}

__attribute__((used)) CGFloat NSAngle(const NSVector& v) {
//	if (v.x == 0)
//		return -pi/2*NSSign(v.y);
	return atan2f(v.y, v.x);
}

__attribute__((used)) CGFloat NSLength(const NSVector& v) {
	return std::sqrt(std::pow(v.x, 2)+std::pow(v.y, 2));
}

// other

__attribute__((used)) CGFloat NSDistance(const NSPoint& p1, const NSPoint& p2) {
	return NSLength(NSMakeVector(p1, p2));
}

__attribute__((used)) CGFloat NSAngle(const NSPoint& p1, const NSPoint& p2) {
	return NSAngle(NSMakeVector(p1, p2));
}

__attribute__((used)) NSPoint NSMiddle(const NSPoint& p1, const NSPoint& p2) {
	return (p1+p2)/2;
}

// NSLine

__attribute__((used)) NSLine NSMakeLine(const NSPoint& origin, const NSVector& direction) {
	NSLine line;
	line.origin = origin;
	line.direction = direction;
	return line;
}

__attribute__((used)) NSLine NSMakeLine(const NSPoint& p1, const NSPoint& p2) {
	return NSMakeLine(p1, NSMakeVector(p1, p2));
}

__attribute__((used)) CGFloat NSAngle(const NSLine& l) {
	return NSAngle(l.direction);
}

__attribute__((used)) BOOL NSParallel(const NSLine& l1, const NSLine& l2) {
	return NSAngle(l1) == NSAngle(l2);
}

__attribute__((used)) CGFloat NSLineInterceptionValue(const NSLine& l1, const NSLine& l2) {
	if (NSParallel(l1, l2))
		[NSException raise:N2LinesDontInterceptException format:@"The two lines are parallel and therefore have no interception."];
	return (l2.direction.x*(l1.origin.y-l2.origin.y)-l2.direction.y*(l1.origin.x-l2.origin.x))/(l2.direction.y*l1.direction.x-l2.direction.x*l1.direction.y);
}

__attribute__((used)) NSPoint NSLineAtValue(const NSLine& l, CGFloat u) {
	return NSMakePoint(l.origin.x+u*l.direction.x, l.origin.y+u*l.direction.y);
}

__attribute__((used)) NSPoint operator*(const NSLine& l1, const NSLine& l2) {
	return NSLineAtValue(l1, NSLineInterceptionValue(l1, l2));
}

__attribute__((used)) CGFloat NSLineYAtX(const NSLine& l, CGFloat x) {
	if (l.direction.x)
		return l.origin.y+l.direction.y/l.direction.x*x;
	else return l.origin.y; // TODO: return NAN or exception
}

// NSRect

__attribute__((used)) NSRect NSMakeRect(const NSPoint& o, const NSSize& s) {
	return NSMakeRect(o.x, o.y, s.width, s.height);
}

__attribute__((used)) NSRect NSInsetRect(const NSRect& r, const NSSize& s) {
	return NSInsetRect(r, s.width, s.height);
}

__attribute__((used)) NSRect operator+(const NSRect& r, const NSSize& s) {
	return NSMakeRect(r.origin, r.size+s);
}

__attribute__((used)) NSRect operator-(const NSRect& r, const NSSize& s) {
	return NSMakeRect(r.origin, r.size-s);
}

__attribute__((used)) BOOL operator==(const NSRect& r1, const NSRect& r2) {
	return (r1.origin==r2.origin) && (r1.size==r2.size);
}

__attribute__((used)) BOOL operator!=(const NSRect& r1, const NSRect& r2) {
	return !(r1==r2);
}

__attribute__((used)) NSPoint RectBR(const NSRect& r) {
	return r.origin+r.size;
}

/// N2MinMax

__attribute__((used)) N2MinMax N2MakeMinMax(CGFloat min, CGFloat max) {
	N2MinMax mm = {min, max};
	return mm;
}

__attribute__((used)) N2MinMax N2MakeMinMax(CGFloat val) {
	return N2MakeMinMax(val, val);
}

__attribute__((used)) N2MinMax N2MakeMinMax() {
	return N2MakeMinMax(N2NoMin, N2NoMax);
}

__attribute__((used)) N2MinMax N2MakeMin(CGFloat min) {
	return N2MakeMinMax(min, N2NoMax);
}

__attribute__((used)) N2MinMax N2MakeMax(CGFloat max) {
	return N2MakeMinMax(N2NoMin, max);
}

__attribute__((used)) CGFloat N2MinMaxConstrainedValue(const N2MinMax& mm, CGFloat val) {
	if (val < mm.min) val = mm.min;
	if (val > mm.max) val = mm.max;
	return val;
}

__attribute__((used)) void N2ExtendMinMax(N2MinMax& n2minmax, CGFloat value) {
	n2minmax.min = std::min(n2minmax.min, value);
	n2minmax.max = std::max(n2minmax.max, value);
}

__attribute__((used)) N2MinMax N2ComposeMinMax(const N2MinMax& mm1, const N2MinMax& mm2) {
	return N2MakeMinMax(std::max(mm1.min, mm2.min), std::min(mm1.max, mm2.max));
}

static CGFloat N2InfinityAwareSum(CGFloat f1, CGFloat f2) {
	if (f1 == CGFLOAT_MAX || f2 == CGFLOAT_MAX) return CGFLOAT_MAX;
	if (f1 == CGFLOAT_MIN || f2 == CGFLOAT_MIN) return CGFLOAT_MIN;
	return f1+f2;
}

__attribute__((used)) N2MinMax operator+(const N2MinMax& mm1, const N2MinMax& mm2) {
	return N2MakeMinMax(N2InfinityAwareSum(mm1.min, mm2.min), N2InfinityAwareSum(mm1.max, mm2.max));
}

__attribute__((used)) N2MinMax operator+(const N2MinMax& mm, const CGFloat& f) {
	return N2MakeMinMax(N2InfinityAwareSum(mm.min, f), N2InfinityAwareSum(mm.max, f));
}

