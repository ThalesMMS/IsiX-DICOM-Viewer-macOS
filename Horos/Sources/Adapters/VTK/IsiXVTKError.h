//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The errors of the VTK adapters. This header, like every public header of
// Adapters/VTK, declares only Objective-C and C types: Swift reads it through
// the bridging header, and nothing of VTK reaches the files that import it.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// An error VTK reported for an object of the call (vtkErrorMacro, which VTK
/// sends as the object's ErrorEvent), or a C++ exception caught in an adapter.
FOUNDATION_EXPORT NSErrorDomain const IsiXVTKErrorDomain;
/// NSString: the adapter call that failed.
FOUNDATION_EXPORT NSString * const IsiXVTKOperationKey;
/// NSString: VTK's message, or the exception's what().
FOUNDATION_EXPORT NSString * const IsiXVTKMessageKey;
/// NSString: the class of the VTK object that reported the error.
FOUNDATION_EXPORT NSString * const IsiXVTKClassKey;

typedef NS_ERROR_ENUM(IsiXVTKErrorDomain, IsiXVTKErrorCode) {
    /// A C++ exception thrown inside the call.
    IsiXVTKErrorCodeException = -1,
    /// VTK reported an error for one of the call's objects.
    IsiXVTKErrorCodeLibrary = -2,
    /// The call needs a VTK object the pipeline does not have (yet).
    IsiXVTKErrorCodeUnavailable = -3,
    /// An argument outside what the call accepts.
    IsiXVTKErrorCodeInvalidArgument = -4,
    /// libtiff does not open the file as a TIFF; NSFilePathErrorKey holds its path.
    IsiXVTKErrorCodeCannotOpen = -5,
    /// The TIFF opens, but has no FluoView MM header; NSFilePathErrorKey holds its path.
    IsiXVTKErrorCodeNoFluoViewHeader = -6,
};

NS_ASSUME_NONNULL_END
