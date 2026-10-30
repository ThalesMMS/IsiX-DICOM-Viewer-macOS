//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// IsiXLegacyBridge: the classes a Horos or OsiriX plugin was written against,
// rebuilt on the IsiX plugin API (IsiXPluginKit) and compiled into the plugin.
// The legacy source keeps its class names through @compatibility_alias; in the
// Objective-C runtime each class is named after the plugin, from the build
// setting ISIX_LEGACY_NAMESPACE (the plugin's module name), so neither the
// application's classes nor another ported plugin's copy of the kit share a
// name with them.

#ifndef ISIX_LEGACY_BRIDGE_DEFINES_H
#define ISIX_LEGACY_BRIDGE_DEFINES_H

#import <Cocoa/Cocoa.h>

#ifndef ISIX_LEGACY_NAMESPACE
#error "Define ISIX_LEGACY_NAMESPACE as the plugin's module name (GCC_PREPROCESSOR_DEFINITIONS = ISIX_LEGACY_NAMESPACE=$(PRODUCT_MODULE_NAME))."
#endif

#define ISIX_LEGACY_STRING_(x) #x
#define ISIX_LEGACY_STRING(x) ISIX_LEGACY_STRING_(x)
/// The runtime name of a kit class: IsiXLegacy<namespace>_<name>.
#define ISIX_LEGACY_CLASS(name) __attribute__((objc_runtime_name("IsiXLegacy" ISIX_LEGACY_STRING(ISIX_LEGACY_NAMESPACE) "_" #name)))

/// Returned without a reference the caller owns, as the legacy application
/// returned it, whatever the method's name says to ARC.
#ifndef NS_RETURNS_NOT_RETAINED
#define NS_RETURNS_NOT_RETAINED __attribute__((ns_returns_not_retained))
#endif

// NSNotificationCenter, in the files that import the kit, is the plugin's center.
#import "IsiXLegacyNotificationCenter.h"

#endif
