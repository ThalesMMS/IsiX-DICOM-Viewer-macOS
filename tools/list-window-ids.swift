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

// The CGWindowIDs of an application's on-screen windows, so a capture can name
// one window instead of the display.
//
//   swift tools/list-window-ids.swift Horos
//
// `tools/check-viewer-pixels.py --window <id>` and `screencapture -l <id>` both
// take the number this prints. Reading the window list needs no permission;
// capturing one does. A window id goes stale as soon as the window closes.
import CoreGraphics
import Foundation

let wanted = CommandLine.arguments.dropFirst().first
guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("the window list is not available\n".utf8))
    exit(2)
}
var found = 0
for window in windows {
    let owner = window[kCGWindowOwnerName as String] as? String ?? ""
    if let wanted = wanted, !owner.localizedCaseInsensitiveContains(wanted) { continue }
    let number = window[kCGWindowNumber as String] as? Int ?? -1
    let name = window[kCGWindowName as String] as? String ?? ""
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = bounds["Width"] as? Double ?? 0, height = bounds["Height"] as? Double ?? 0
    let x = bounds["X"] as? Double ?? 0, y = bounds["Y"] as? Double ?? 0
    // Screen coordinates with the origin at the top left, which is what
    // screencapture and the window server use.
    print(String(format: "%-8d %-20s %5.0f %5.0f %5.0f %5.0f  %@", number,
                 (owner as NSString).utf8String!, x, y, width, height, name))
    found += 1
}
if found == 0 { exit(1) }
