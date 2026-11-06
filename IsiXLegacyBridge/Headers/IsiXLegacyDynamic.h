//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The paths by which a legacy plugin reached the application's classes by
// name: NSClassFromString(), objc_getClass() and objc_lookUpClass(). The
// kit's prefix header (IsiXLegacyPrefix.h) turns these calls in the plugin's
// own Objective-C into the functions below, which answer with the kit's class
// for a legacy name the kit has (ViewerController, DCMPix, ROI...), with the
// plugin's own classes and the system's as before, and with nil, and a
// message in the log, for a class of the application: a ported plugin talks
// to the application through the plugin API only.
//
// The kit's own objects also answer what the legacy application's answered
// dynamically: performSelector:, objc_msgSend() and key-value coding reach
// the methods and properties the kit declares; a selector or a key the kit
// has no equivalent for gives nil (zero), and a message in the log, instead
// of an exception.

#ifndef ISIX_LEGACY_DYNAMIC_H
#define ISIX_LEGACY_DYNAMIC_H

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "IsiXLegacyPortSupport.h"

/// NSClassFromString() for the plugin: the plugin's own class of that name,
/// else the kit's class of that legacy name, else the class of the system (or
/// of IsiXPluginKit); nil for a class of the application, with a message.
ISIX_LEGACY_PORT_EXTERN Class IsiXLegacyClassFromString(NSString *name);

/// objc_getClass() and objc_lookUpClass() for the plugin, by the same rules.
ISIX_LEGACY_PORT_EXTERN Class IsiXLegacyObjcGetClass(const char *name);

#endif
