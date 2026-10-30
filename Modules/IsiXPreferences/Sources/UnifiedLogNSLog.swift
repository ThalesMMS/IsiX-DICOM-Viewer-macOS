//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import IsiXLogging

/// NSLog for the Swift sources of this module, written to the unified log as
/// the Objective-C one is, through IsiXLogging's `unifiedLogv`: the format's
/// text and the numbers readable, string and object arguments `<private>`.
/// Declared in this module, it shadows Foundation's, whose line reaches only
/// standard error, or the unified log as one private string.
func NSLog(_ format: StaticString, _ args: CVarArg...) {
    unifiedLogv(format, args)
}

/// Foundation's `NSLog` with a format built at run time, which would log the
/// whole line, patient data included, as one private string. Declared here so
/// that it shadows Foundation's and does not compile: pass the text as an
/// argument, `NSLog("%@", text)`.
@available(*, unavailable, message: "the format must be a literal: pass text built at run time as an argument, NSLog(\"%@\", text)")
func NSLog(_ format: String, _ args: CVarArg...) {
    withVaList(args) { NSLogv(format, $0) }
}
