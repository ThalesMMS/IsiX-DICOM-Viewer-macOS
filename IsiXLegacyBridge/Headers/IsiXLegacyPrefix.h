//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The porting kit's prefix header. A ported project's prefix header includes
// it before the plugin's own, so that every Objective-C file sees the
// replacements its converted source calls.

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "IsiXLegacyPortSupport.h"
#import "IsiXLegacyCalendarDate.h"
#import "IsiXLegacyDynamic.h"

// A class looked up by name reaches the kit's class, never the application's
// (IsiXLegacyDynamic.h). The headers that declare these functions are imported
// above, so the declarations keep their names; a call written
// (NSClassFromString)(name) is not diverted.
#define NSClassFromString(name) IsiXLegacyClassFromString(name)
#define objc_getClass(name) IsiXLegacyObjcGetClass(name)
#define objc_lookUpClass(name) IsiXLegacyObjcGetClass(name)
#endif
