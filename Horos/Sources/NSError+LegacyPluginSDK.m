/*
 Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)

 This file is free software: you can redistribute it and/or modify it under the
 terms of the GNU Lesser General Public License as published by the Free
 Software Foundation, version 3 of the License.

 It is distributed in the hope that it will be useful, but WITHOUT ANY
 WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
 A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.
 */

#import "NSError+OsiriX.h"

// The two constructors of the plugin SDK of Horos and OsiriX that take a
// format and its arguments. A plugin built for that SDK still sends them, and
// Swift cannot declare a method with variable arguments for Objective-C: they
// make the description and hand it to the constructors NSError (OsiriX) has.
@implementation NSError (OsiriXFormattedDescription)

+ (NSError *)osirixErrorWithCode:(NSInteger)code localizedDescriptionFormat:(NSString *)format, ...
{
    va_list arguments;
    va_start(arguments, format);
    NSString *description = format ? [[[NSString alloc] initWithFormat:format arguments:arguments] autorelease] : nil;
    va_end(arguments);
    return [self osirixErrorWithCode:code localizedDescription:description];
}

+ (NSError *)osirixErrorWithCode:(NSInteger)code underlyingError:(NSError *)underlyingError localizedDescriptionFormat:(NSString *)format, ...
{
    va_list arguments;
    va_start(arguments, format);
    NSString *description = format ? [[[NSString alloc] initWithFormat:format arguments:arguments] autorelease] : nil;
    va_end(arguments);
    return [self osirixErrorWithCode:code underlyingError:underlyingError localizedDescription:description];
}

@end
