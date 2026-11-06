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
import IOKit

// N2Shell is implemented in Swift, over Process; the selectors and
// <Horos/N2Shell.h> are those of the former class.

@objc @implementation extension N2Shell {
    class func execute(_ path: String!) -> String! {
        execute(path, arguments: nil)
    }

    class func execute(_ path: String!, arguments: [Any]!) -> String! {
        execute(path, arguments: arguments, expectedStatus: 0)
    }

    /// Runs the executable at `path` and returns its standard output as UTF-8
    /// without the surrounding white space and new lines, or nil when it is not
    /// UTF-8. The standard error is discarded. An executable that cannot be
    /// launched raises NSInvalidArgumentException, as NSTask's -launch did.
    ///
    /// The output is read to its end before the wait, so that a process
    /// writing more than a pipe holds is not left blocked; the wait polls
    /// rather than calling -waitUntilExit, which runs the current run loop.
    class func execute(_ path: String!, arguments: [Any]!, outStatus: UnsafeMutablePointer<Int32>!) -> String! {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path ?? "")
        process.arguments = (arguments ?? []).map { argument in
            guard let argument = argument as? String else {
                raise(.invalidArgumentException, "N2Shell arguments must be strings, not \(type(of: argument))")
            }
            return argument
        }
        let standardOutput = Pipe()
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            raise(.invalidArgumentException, "launch path not accessible: \(path ?? "(null)")")
        }
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.01)
        }
        outStatus?.pointee = process.terminationStatus
        return String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    class func execute(_ path: String!, arguments: [Any]!, expectedStatus: Int32) -> String! {
        var status: Int32 = 0
        let output = execute(path, arguments: arguments, outStatus: &status)
        if status != expectedStatus {
            raise(.genericException, "Task \(path ?? "(null)") exited with status \(status)")
        }
        return output
    }

    class func hostname() -> String! {
        var name = [CChar](repeating: 0, count: 128)
        gethostname(&name, 127)
        name[127] = 0
        // nil when the name is not UTF-8, as +stringWithCString:encoding: gave.
        return name.withUnsafeBufferPointer { String(validatingCString: $0.baseAddress!) }
    }

    class func serialNumber() -> String! {
        let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard platformExpert != 0 else { return nil }
        defer { IOObjectRelease(platformExpert) }
        return IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }
}

/// `[NSException raise:name format:…]`: the callers catch it, as before.
private func raise(_ name: NSExceptionName, _ reason: String) -> Never {
    NSException(name: name, reason: reason, userInfo: nil).raise()
    fatalError("NSException.raise() returned")
}
