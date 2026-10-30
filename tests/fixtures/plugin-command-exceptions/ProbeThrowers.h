//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The plugin's own Objective-C++ code that lets an exception escape, as a
// library inside a plugin does: one function per kind of exception.

#ifdef __cplusplus
extern "C" {
#endif

/// Raises an NSException named ProbeObjCException.
void ProbeRaiseObjectiveC(void);
/// Throws std::runtime_error.
void ProbeThrowCxx(void);
/// Throws an int, an exception of no std::exception type.
void ProbeThrowInt(void);

#ifdef __cplusplus
}
#endif
