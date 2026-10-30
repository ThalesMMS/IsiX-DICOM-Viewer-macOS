//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The curves the 3D viewers take from VTK: the fly-through's path between its
// steps and the endoscopy's smoothed centerline (vtkCardinalSpline, or
// vtkPiecewiseFunction for a linear path), and the thick slab's opacity table
// (vtkPiecewiseFunction). Objective-C and C types only; every call into VTK
// goes through the adapter's guard, and an error VTK reports or a C++
// exception comes back as an NSError of IsiXVTKErrorDomain.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, IsiXVTKCurveKind) {
    /// vtkCardinalSpline on each axis.
    IsiXVTKCurveKindCardinalSpline = 1,
    /// vtkPiecewiseFunction on each axis: straight between the points.
    IsiXVTKCurveKindPiecewiseLinear = 2,
};

/// A curve of three coordinates over a parameter t, each axis a VTK function
/// of t.
@interface IsiXVTKCurve3D : NSObject

- (instancetype)initWithKind:(IsiXVTKCurveKind)kind NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) IsiXVTKCurveKind kind;

/// The point (x, y, z) at t.
- (BOOL)addPointAt:(double)t x:(double)x y:(double)y z:(double)z error:(NSError **)error;

/// The spline's coefficients from its points (vtkSpline::Compute); nothing to
/// do for a piecewise curve. A spline needs two points.
- (BOOL)computeWithError:(NSError **)error;

/// The curve at t, in `point` (three doubles). The point VTK evaluated is
/// given even when VTK reported an error.
- (BOOL)evaluateAt:(double)t point:(double *)point error:(NSError **)error;

@end

/// A function of one variable, straight between its points (vtkPiecewiseFunction,
/// clamped to its first and last values outside them).
@interface IsiXVTKPiecewiseFunction : NSObject

- (BOOL)addPointAt:(double)x value:(double)y error:(NSError **)error;
- (BOOL)removeAllPointsWithError:(NSError **)error;
/// The value at x.
- (double)valueAt:(double)x error:(NSError **)error;
/// The values at 0, 1, … count - 1, rounded to float, in `values`.
- (BOOL)getValues:(float *)values count:(NSInteger)count error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
