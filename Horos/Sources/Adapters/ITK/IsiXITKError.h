//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The errors of the ITK adapters. This header, like every public header of
// Adapters/ITK, declares only Objective-C and C types: Swift reads it through
// the bridging header, and nothing of ITK reaches the files that import it.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// An exception ITK threw (itk::ExceptionObject), another C++ exception caught
/// in an adapter, or an argument an adapter refused before calling ITK.
FOUNDATION_EXPORT NSErrorDomain const IsiXITKErrorDomain;
/// NSString: the adapter call that failed.
FOUNDATION_EXPORT NSString * const IsiXITKOperationKey;
/// NSString: ITK's description of the exception, or the exception's what().
FOUNDATION_EXPORT NSString * const IsiXITKMessageKey;
/// NSString: where ITK threw it (the method ITK names as the location).
FOUNDATION_EXPORT NSString * const IsiXITKLocationKey;
/// NSString: the ITK source file that threw it.
FOUNDATION_EXPORT NSString * const IsiXITKFileKey;
/// NSNumber: the line of that file.
FOUNDATION_EXPORT NSString * const IsiXITKLineKey;

typedef NS_ERROR_ENUM(IsiXITKErrorDomain, IsiXITKErrorCode) {
    /// A C++ exception that is not ITK's, thrown inside the call.
    IsiXITKErrorCodeException = -1,
    /// ITK threw an itk::ExceptionObject.
    IsiXITKErrorCodeLibrary = -2,
    /// An argument outside what the call accepts; ITK was not called.
    IsiXITKErrorCodeInvalidArgument = -4,
    /// ITK finished without an image to hand back.
    IsiXITKErrorCodeEmptyResult = -5,
};

NS_ASSUME_NONNULL_END
