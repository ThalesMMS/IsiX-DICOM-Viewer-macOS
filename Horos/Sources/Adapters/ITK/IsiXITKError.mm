//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import "IsiXITKInternal.hpp"

NSErrorDomain const IsiXITKErrorDomain = @"IsiXITKErrorDomain";
NSString * const IsiXITKOperationKey = @"IsiXITKOperation";
NSString * const IsiXITKMessageKey = @"IsiXITKMessage";
NSString * const IsiXITKLocationKey = @"IsiXITKLocation";
NSString * const IsiXITKFileKey = @"IsiXITKFile";
NSString * const IsiXITKLineKey = @"IsiXITKLine";

static NSString *IsiXITKString(const char *text)
{
    return [NSString stringWithUTF8String:text ?: ""] ?: @"";
}

NSError *IsiXITKErrorFromLibrary(const itk::ExceptionObject &exception, const char *operation)
{
    NSString *call = IsiXITKString(operation);
    NSString *message = [IsiXITKString(exception.GetDescription())
                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *location = IsiXITKString(exception.GetLocation());
    NSString *file = IsiXITKString(exception.GetFile());
    NSLog(@"---- ITK adapter: %@ failed: %@ (%@)", call, message, location);
    return [NSError errorWithDomain:IsiXITKErrorDomain code:IsiXITKErrorCodeLibrary userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", call, message],
        IsiXITKOperationKey: call,
        IsiXITKMessageKey: message,
        IsiXITKLocationKey: location,
        IsiXITKFileKey: file,
        IsiXITKLineKey: @(exception.GetLine()),
    }];
}

NSError *IsiXITKErrorFromException(const char *what, const char *operation)
{
    NSString *reason = IsiXITKString(what), *call = IsiXITKString(operation);
    NSLog(@"---- ITK adapter: %@ threw a C++ exception: %@", call, reason);
    return [NSError errorWithDomain:IsiXITKErrorDomain code:IsiXITKErrorCodeException userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", call, reason],
        IsiXITKOperationKey: call,
        IsiXITKMessageKey: reason,
    }];
}

NSError *IsiXITKFailure(IsiXITKErrorCode code, NSString *description, const char *operation)
{
    NSString *call = IsiXITKString(operation);
    return [NSError errorWithDomain:IsiXITKErrorDomain code:code userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", call, description],
        IsiXITKOperationKey: call,
    }];
}
