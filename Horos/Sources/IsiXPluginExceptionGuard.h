//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The domain of the errors IsiXPluginExceptionGuard returns for a C++ exception.
FOUNDATION_EXPORT NSErrorDomain const IsiXPluginCxxExceptionErrorDomain;

/// Where the application calls a plugin's code. A plugin is code of a third
/// party, often Objective-C or C++ around a library of its own: an exception
/// it lets escape would end the application, because Swift catches neither
/// kind. Only the call into the plugin goes through here.
@interface IsiXPluginExceptionGuard : NSObject

/// Runs `block`. An NSException it raises is returned as HorosObjCException
/// returns it (HorosObjCExceptionErrorDomain, the exception under
/// HorosObjCExceptionKey). A C++ exception, or another object thrown, is
/// returned in IsiXPluginCxxExceptionErrorDomain, with what() as the
/// description, when there is one, and the exception's type as the failure
/// reason. The frames between the throw and this method are unwound without
/// their Swift cleanups: what they held leaks, the block among them. So the
/// block is not declared NS_NOESCAPE: Swift checks, when such a call returns,
/// that nothing still holds the closure, and stops the application when an
/// unwound frame kept it.
+ (BOOL)performBlock:(void (^)(void))block error:(NSError **)error
    NS_SWIFT_NAME(perform(_:));

@end

NS_ASSUME_NONNULL_END
