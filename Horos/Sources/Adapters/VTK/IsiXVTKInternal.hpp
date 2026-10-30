//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// What the VTK adapters share in C++: the guard every call into VTK goes
// through, which turns a C++ exception and an error VTK reports for one of the
// call's objects into an NSError. Only the adapters' Objective-C++ files
// include this header; their public headers declare Objective-C and C types
// alone.

#pragma once

#ifndef __cplusplus
#error "IsiXVTKInternal.hpp is for the Objective-C++ files of the VTK adapters"
#endif

#import <Foundation/Foundation.h>
#import "IsiXVTKError.h"

#include <exception>
#include <initializer_list>
#include <utility>
#include <vector>

class vtkObject;

/// The error for a C++ exception caught in an adapter.
NSError *IsiXVTKErrorFromException(const char *what, const char *operation);

/// The error for a message VTK reported for an object of `className`.
NSError *IsiXVTKErrorFromLibrary(const char *message, const char *className, const char *operation);

/// An error the adapter makes itself, with `code` and `description`.
NSError *IsiXVTKFailure(IsiXVTKErrorCode code, NSString *description, const char *operation);

/// While it lives, takes the errors VTK reports for `objects` (their
/// ErrorEvent) instead of VTK's output window, and logs them as VTK did. The
/// first one becomes the call's error.
class IsiXVTKErrorCapture
{
public:
    IsiXVTKErrorCapture(std::initializer_list<vtkObject *> objects, const char *operation);
    ~IsiXVTKErrorCapture();
    IsiXVTKErrorCapture(const IsiXVTKErrorCapture &) = delete;
    IsiXVTKErrorCapture &operator=(const IsiXVTKErrorCapture &) = delete;

    /// The first error reported since the capture began, or nil.
    NSError *Error() const { return this->First; }

    // Called by the observer.
    void Report(vtkObject *object, const char *message);

private:
    std::vector<std::pair<vtkObject *, unsigned long>> Observers;
    const char *Operation;
    NSError *First = nil;
};

/// Runs `body`, which returns the call's error (nil when it succeeded), with
/// VTK's errors for `objects` captured, and turns any C++ exception it throws
/// into an error. Returns whether the call succeeded, and gives its error
/// through `error`.
template <typename Body>
static inline BOOL IsiXVTKGuard(NSError * __autoreleasing *error, const char *operation,
                                std::initializer_list<vtkObject *> objects, Body &&body)
{
    NSError *failure = nil;
    try {
        IsiXVTKErrorCapture capture(objects, operation);
        failure = std::forward<Body>(body)();
        if (!failure) failure = capture.Error();
    } catch (const std::exception &exception) {
        failure = IsiXVTKErrorFromException(exception.what(), operation);
    } catch (...) {
        failure = IsiXVTKErrorFromException("unknown exception", operation);
    }
    if (failure && error) *error = failure;
    return failure == nil;
}
