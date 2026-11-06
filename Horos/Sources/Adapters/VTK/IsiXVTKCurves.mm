//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import "IsiXVTKCurves.h"
#import "IsiXVTKInternal.hpp"

#include <vtkCardinalSpline.h>
#include <vtkPiecewiseFunction.h>
#include <vtkSmartPointer.h>
#include <vector>

#if !__has_feature(objc_arc)
#error "IsiXVTKCurves.mm is compiled with ARC"
#endif

@implementation IsiXVTKCurve3D
{
    vtkSmartPointer<vtkCardinalSpline> _splines[3];
    vtkSmartPointer<vtkPiecewiseFunction> _functions[3];
}

- (instancetype)initWithKind:(IsiXVTKCurveKind)kind
{
    if (!(self = [super init])) return nil;
    _kind = kind;
    // The objects are made here, outside any guard: a failed allocation ends
    // the process, as everywhere in VTK.
    for (int axis = 0; axis < 3; axis++) {
        if (kind == IsiXVTKCurveKindCardinalSpline) _splines[axis] = vtkSmartPointer<vtkCardinalSpline>::New();
        else _functions[axis] = vtkSmartPointer<vtkPiecewiseFunction>::New();
    }
    return self;
}

- (BOOL)addPointAt:(double)t x:(double)x y:(double)y z:(double)z error:(NSError **)error
{
    const double values[3] = {x, y, z};
    if (_kind == IsiXVTKCurveKindCardinalSpline) {
        return IsiXVTKGuard(error, "IsiXVTKCurve3D addPoint", {_splines[0], _splines[1], _splines[2]}, [&]() -> NSError * {
            for (int axis = 0; axis < 3; axis++) _splines[axis]->AddPoint(t, values[axis]);
            return nil;
        });
    }
    return IsiXVTKGuard(error, "IsiXVTKCurve3D addPoint", {_functions[0], _functions[1], _functions[2]}, [&]() -> NSError * {
        for (int axis = 0; axis < 3; axis++) _functions[axis]->AddPoint(t, values[axis]);
        return nil;
    });
}

- (BOOL)computeWithError:(NSError **)error
{
    if (_kind != IsiXVTKCurveKindCardinalSpline) return YES;
    return IsiXVTKGuard(error, "IsiXVTKCurve3D compute", {_splines[0], _splines[1], _splines[2]}, [&]() -> NSError * {
        for (int axis = 0; axis < 3; axis++) _splines[axis]->Compute();
        return nil;
    });
}

- (BOOL)evaluateAt:(double)t point:(double *)point error:(NSError **)error
{
    if (_kind == IsiXVTKCurveKindCardinalSpline) {
        return IsiXVTKGuard(error, "IsiXVTKCurve3D evaluate", {_splines[0], _splines[1], _splines[2]}, [&]() -> NSError * {
            for (int axis = 0; axis < 3; axis++) point[axis] = _splines[axis]->Evaluate(t);
            return nil;
        });
    }
    return IsiXVTKGuard(error, "IsiXVTKCurve3D evaluate", {_functions[0], _functions[1], _functions[2]}, [&]() -> NSError * {
        for (int axis = 0; axis < 3; axis++) point[axis] = _functions[axis]->GetValue(t);
        return nil;
    });
}

@end

@implementation IsiXVTKPiecewiseFunction
{
    vtkSmartPointer<vtkPiecewiseFunction> _function;
}

- (instancetype)init
{
    if (!(self = [super init])) return nil;
    _function = vtkSmartPointer<vtkPiecewiseFunction>::New();
    return self;
}

- (BOOL)addPointAt:(double)x value:(double)y error:(NSError **)error
{
    return IsiXVTKGuard(error, "IsiXVTKPiecewiseFunction addPoint", {_function}, [&]() -> NSError * {
        _function->AddPoint(x, y);
        return nil;
    });
}

- (BOOL)removeAllPointsWithError:(NSError **)error
{
    return IsiXVTKGuard(error, "IsiXVTKPiecewiseFunction removeAllPoints", {_function}, [&]() -> NSError * {
        _function->RemoveAllPoints();
        return nil;
    });
}

- (double)valueAt:(double)x error:(NSError **)error
{
    double value = 0;
    IsiXVTKGuard(error, "IsiXVTKPiecewiseFunction value", {_function}, [&]() -> NSError * {
        value = _function->GetValue(x);
        return nil;
    });
    return value;
}

- (BOOL)getValues:(float *)values count:(NSInteger)count error:(NSError **)error
{
    if (count < 0) {
        if (error) *error = IsiXVTKFailure(IsiXVTKErrorCodeInvalidArgument, @"A table of a negative number of values",
                                           "IsiXVTKPiecewiseFunction values");
        return NO;
    }
    return IsiXVTKGuard(error, "IsiXVTKPiecewiseFunction values", {_function}, [&]() -> NSError * {
        // Gathered first and copied after: a table too large to allocate
        // throws before anything is written into the caller's buffer.
        std::vector<double> table((size_t)count);
        for (size_t i = 0; i < table.size(); i++) table[i] = _function->GetValue((double)i);
        for (size_t i = 0; i < table.size(); i++) values[i] = (float)table[i];
        return nil;
    });
}

@end
