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

// Temporary LaunchServices setup for the URL scheme's native validation; not part of Horos.
// No argument: read the handler. One bundle identifier: explicitly set it.
// Save both output lines before changing it; restore and compare after testing.
import AppKit
import CoreServices

precondition(CommandLine.arguments.count <= 2, "usage: handler [bundle-identifier]")
if CommandLine.arguments.count == 2 {
    let status = LSSetDefaultHandlerForURLScheme("horos" as CFString,
                                                CommandLine.arguments[1] as CFString)
    precondition(status == noErr, "setting handler failed: \(status)")
}
guard let application = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "horos://test")!),
      let identifier = Bundle(url: application)?.bundleIdentifier else {
    fatalError("No registered horos:// handler; do not change it without a restoration plan")
}
print(identifier)
print(application.path)
