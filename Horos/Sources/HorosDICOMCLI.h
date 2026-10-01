// Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
// This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
// Licensed under the GNU Lesser General Public License, version 3.
#pragma once
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// params includes the executable name at index zero. Returns the number of
// failed operations/files; invalid arguments return one without touching files.
int HorosModifyDICOMCLI(NSArray *params, NSStringEncoding encoding);

#ifdef __cplusplus
}
#endif
