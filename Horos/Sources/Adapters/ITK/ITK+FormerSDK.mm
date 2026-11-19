//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The selectors of ITK, the class of the plug-in SDK of Horos and OsiriX that
// handed a volume to ITK, that carry C++ types of ITK the class's header and
// Swift cannot name: the import filter it made, and the setup of that filter.
// A plug-in built with ITK's headers sends them without being rebuilt.
//
// The filter was an object of the ITK the plug-in was built with, whose
// classes are templates compiled into the plug-in itself: the application
// cannot make one of them. Each selector keeps the calling convention it had
// and makes nothing:
// - ImportFilterType::Pointer is itk::SmartPointer, one pointer with a copy
//   constructor and a destructor of its own, so that it is returned in memory
//   the caller gives. The pointer answered is null, which its destructor
//   leaves alone;
// - ImportFilterType::SizeType is itk::Size<3>, an aggregate of three
//   itk::SizeValueType (unsigned long), passed as any such structure is.
// No header of ITK is read here.

#import <Foundation/Foundation.h>

#import "ITK.h"

// The application's notice of a selector answered only for plug-ins of that
// SDK, a Swift class: named here by the one message sent to it, so that the
// adapter does not read the application's generated header.
@interface IsiXFormerSDKFacade : NSObject
+ (void)inert:(NSString *)type selector:(NSString *)selector because:(NSString *)reason;
@end

namespace {

/// itk::SmartPointer<T> as a caller built with ITK's headers receives it.
struct FormerSDKSmartPointer
{
    void *object;
    FormerSDKSmartPointer() noexcept : object(nullptr) {}
    FormerSDKSmartPointer(const FormerSDKSmartPointer &other) noexcept : object(other.object) {}
    ~FormerSDKSmartPointer() {}
};

/// itk::Size<3> as a caller built with ITK's headers passes it.
struct FormerSDKSize3
{
    unsigned long size[3];
};

void Inert(SEL selector)
{
    [IsiXFormerSDKFacade inert:@"ITK" selector:[@"-" stringByAppendingString:NSStringFromSelector(selector)]
                       because:@"an import filter is an object of the plugin's own ITK, which the application cannot make"];
}

} // namespace

@interface ITK (FormerSDKImportFilter)
- (FormerSDKSmartPointer)itkImporter;
- (void)setupImportFilterWithSize:(FormerSDKSize3)size origin:(double *)origin spacing:(double *)spacing data:(float *)data
              filterWillOwnBuffer:(BOOL)filterWillOwnBuffer;
@end

@implementation ITK (FormerSDKImportFilter)

// A null pointer: there is no filter.
- (FormerSDKSmartPointer)itkImporter
{
    Inert(_cmd);
    return FormerSDKSmartPointer();
}

// Makes no filter. The buffer stays its caller's, whatever filterWillOwnBuffer
// says: nothing here takes it.
- (void)setupImportFilterWithSize:(FormerSDKSize3)size origin:(double *)origin spacing:(double *)spacing data:(float *)data
              filterWillOwnBuffer:(BOOL)filterWillOwnBuffer
{
    Inert(_cmd);
}

@end
