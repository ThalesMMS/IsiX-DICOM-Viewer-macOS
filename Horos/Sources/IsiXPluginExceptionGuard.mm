//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import "IsiXPluginExceptionGuard.h"
#import "HorosObjCException.h"

#include <cxxabi.h>
#include <cstdlib>
#include <exception>
#include <typeinfo>

NSErrorDomain const IsiXPluginCxxExceptionErrorDomain = @"IsiXPluginCxxExceptionErrorDomain";

/// The readable name of the type of the exception being handled.
static NSString *IsiXCurrentExceptionTypeName(void)
{
    const std::type_info *type = abi::__cxa_current_exception_type();
    if (!type) return @"(unknown type)";
    int status = 0;
    char *demangled = abi::__cxa_demangle(type->name(), nullptr, nullptr, &status);
    NSString *name = [NSString stringWithUTF8String:(status == 0 && demangled) ? demangled : type->name()];
    std::free(demangled);
    return name ?: @"(unknown type)";
}

static NSError *IsiXCxxExceptionError(NSString *description)
{
    NSString *type = IsiXCurrentExceptionTypeName();
    return [NSError errorWithDomain:IsiXPluginCxxExceptionErrorDomain code:1
                           userInfo:@{NSLocalizedDescriptionKey: description.length ? description : type,
                                      NSLocalizedFailureReasonErrorKey: type}];
}

@implementation IsiXPluginExceptionGuard

+ (BOOL)performBlock:(void (^)(void))block error:(NSError **)error
{
    // HorosObjCException catches the NSExceptions; whatever it lets through is
    // caught here, in C++.
    try {
        return [HorosObjCException performBlock:block error:error];
    }
    catch (const std::exception &exception) {
        NSString *what = [NSString stringWithUTF8String:exception.what() ?: ""];
        if (error) *error = IsiXCxxExceptionError(what ?: @"");
        return NO;
    }
    catch (...) {
        if (error) *error = IsiXCxxExceptionError(@"");
        return NO;
    }
}

@end
