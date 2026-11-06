/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

// N2Debug is implemented in Swift; <Horos/N2Debug.h> keeps the class, the
// logging macros and the C entry points. _N2LogExceptionImpl and
// N2LogStackTraceMessage are here; the variadic _N2LogErrorImpl and
// N2LogStackTrace stay in N2Debug+CAPI.m, since Swift cannot define a C
// function with a variable argument list.

// nonisolated(unsafe): a flag set at launch from the debug preference and read
// by the DLog macro on any thread, as the static BOOL of the Objective-C was.
nonisolated(unsafe) private var debugIsActive = false

@objc @implementation extension N2Debug {
    class func isActive() -> Bool {
        debugIsActive
    }

    class func setActive(_ active: Bool) {
        debugIsActive = active
    }
}

/// Serializes the exception lines so that a message and its stack trace are
/// not interleaved with another thread's. The Objective-C synchronized on
/// NSApp; a lock of its own does the same without sharing NSApp's lock with
/// the rest of the application.
private let exceptionLogLock = NSLock()

private func cString(_ pointer: UnsafePointer<CChar>?) -> String {
    pointer.map { String(cString: $0) } ?? "(null)"
}

/// The line the Objective-C logged: "<message> (in <function>): <exception>",
/// then the stack trace on the next line when there is one.
private func logException(message: String, function: String, exception: String, stackTrace: String?) {
    exceptionLogLock.lock()
    defer { exceptionLogLock.unlock() }
    NSLog("%@ (in %@): %@%@", message as NSString, function as NSString, exception as NSString,
          (stackTrace.map { "\n" + $0 } ?? "") as NSString)
}

/// The N2LogException and N2LogExceptionWithStackTrace macros: the exception's
/// name, the function and the exception, with its stack trace when logStack.
@_cdecl("_N2LogExceptionImpl") @implementation
func _N2LogExceptionImpl(_ e: NSException!, _ logStack: Bool, _ pf: UnsafePointer<CChar>!) {
    logException(message: e.map { $0.name.rawValue } ?? "(null)", function: cString(pf),
                 exception: e?.description ?? "(null)",
                 stackTrace: logStack ? (e?.stackTrace() ?? "(null)") : nil)
}

/// The message and the stack of the calling thread. The Objective-C raised and
/// caught an exception to take that stack; the frames are now the caller's
/// own, from this function up.
@_cdecl("N2LogStackTraceMessage") @implementation
func N2LogStackTraceMessage(_ message: String!) {
    logException(message: message ?? "(null)", function: "", exception: "",
                 stackTrace: NSException.stackTrace(ofReturnAddresses: Thread.callStackReturnAddresses))
}
