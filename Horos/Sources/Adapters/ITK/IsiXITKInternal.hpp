//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// What the ITK adapters share in C++: the image types, the volume's import
// filter, and the guard every call into ITK goes through, which turns an
// itk::ExceptionObject and any other C++ exception into an NSError. Only the
// adapters' Objective-C++ files include this header; their public headers
// declare Objective-C and C types alone.

#pragma once

#ifndef __cplusplus
#error "IsiXITKInternal.hpp is for the Objective-C++ files of the ITK adapters"
#endif

#import <Foundation/Foundation.h>
#import "IsiXITKError.h"
#import "IsiXITKVolume.h"

#include <itkMacro.h>
#include <itkImage.h>
#include <itkImportImageFilter.h>
#include <exception>
#include <utility>

/// The volumes the app hands to ITK: 32-bit floats, three dimensions.
using IsiXITKFloatImage = itk::Image<float, 3>;
using IsiXITKFloatImporter = itk::ImportImageFilter<float, 3>;
/// The masks ITK hands back: one byte per voxel.
using IsiXITKByteImage = itk::Image<unsigned char, 3>;

/// The error for an exception ITK threw.
NSError *IsiXITKErrorFromLibrary(const itk::ExceptionObject &exception, const char *operation);

/// The error for another C++ exception caught in an adapter.
NSError *IsiXITKErrorFromException(const char *what, const char *operation);

/// An error the adapter makes itself, with `code` and `description`.
NSError *IsiXITKFailure(IsiXITKErrorCode code, NSString *description, const char *operation);

@interface IsiXITKVolume ()
/// ITK's import filter over the volume's voxels.
- (IsiXITKFloatImporter *)importer;
@end

/// Runs `body`, which returns the call's error (nil when it succeeded), and
/// turns an exception ITK throws, or any other C++ exception, into an error.
/// Returns whether the call succeeded, and gives its error through `error`.
template <typename Body>
static inline BOOL IsiXITKGuard(NSError * __autoreleasing *error, const char *operation, Body &&body)
{
    NSError *failure = nil;
    try {
        failure = std::forward<Body>(body)();
    } catch (const itk::ExceptionObject &exception) {
        failure = IsiXITKErrorFromLibrary(exception, operation);
    } catch (const std::exception &exception) {
        failure = IsiXITKErrorFromException(exception.what(), operation);
    } catch (...) {
        failure = IsiXITKErrorFromException("unknown exception", operation);
    }
    if (failure && error) *error = failure;
    return failure == nil;
}
