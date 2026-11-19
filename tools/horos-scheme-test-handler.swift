//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Temporary LaunchServices setup for the native validation of the link schemes; not part of the application.
//   handler                         read the handler of horos://
//   handler BUNDLE-ID               set the handler of horos:// by identifier
//   handler SCHEME                  read the handler of isix://, horos:// or osirix://
//   handler SCHEME BUNDLE-ID        set it by identifier
//   handler SCHEME /PATH/TO/X.app   set it to that copy of an application
// Each run ends by printing the identifier and the path of the handler, or "none" twice.
// Save both output lines of every scheme before changing one; restore and compare after testing.
import AppKit
import CoreServices

let schemes = ["isix", "horos", "osirix"]
var arguments = Array(CommandLine.arguments.dropFirst())
var scheme = "horos"
if let first = arguments.first, schemes.contains(first.lowercased()) {
    scheme = first.lowercased()
    arguments.removeFirst()
}
precondition(arguments.count <= 1, "usage: handler [isix|horos|osirix] [bundle-identifier | /path/to/Application.app]")

if let target = arguments.first {
    if target.hasPrefix("/") {
        precondition(FileManager.default.fileExists(atPath: target), "no application at \(target)")
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: (any Error)?
        NSWorkspace.shared.setDefaultApplication(at: URL(fileURLWithPath: target), toOpenURLsWithScheme: scheme) { error in
            failure = error
            done.signal()
        }
        done.wait()
        if let failure { fatalError("setting the handler of \(scheme):// failed: \(failure)") }
    } else {
        let status = LSSetDefaultHandlerForURLScheme(scheme as CFString, target as CFString)
        precondition(status == noErr, "setting the handler of \(scheme):// failed: \(status)")
    }
}
if let application = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "\(scheme)://test")!) {
    print(Bundle(url: application)?.bundleIdentifier ?? "none")
    print(application.path)
} else {
    // A scheme with no handler is a state to record too: isix:// before the first build that declares it.
    print("none")
    print("none")
}
