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

// NSException (N2) is implemented in Swift; the selectors and
// <Horos/NSException+N2.h> are those of the former category. N2ErrorDomain is
// a constant of the header.

@objc(N2) @implementation extension NSException {
    /// The symbols of the frames the exception was raised from, one per line,
    /// separated by carriage returns.
    func stackTrace() -> String! {
        NSException.stackTrace(ofReturnAddresses: callStackReturnAddresses)
    }

    func printStackTrace() -> String! {
        let stackTrace = stackTrace() ?? ""
        NSLog("%@", stackTrace as NSString)
        return stackTrace
    }
}

extension NSException {
    /// backtrace_symbols of the addresses, joined with carriage returns; empty
    /// without addresses.
    @nonobjc static func stackTrace(ofReturnAddresses addresses: [NSNumber]) -> String {
        guard !addresses.isEmpty else { return "" }
        var frames = addresses.map { UnsafeMutableRawPointer(bitPattern: $0.uintValue) }
        guard let symbols = backtrace_symbols(&frames, Int32(frames.count)) else { return "" }
        defer { free(symbols) }
        return (0..<frames.count).map { symbols[$0].map { String(cString: $0) } ?? "" }.joined(separator: "\r")
    }
}
