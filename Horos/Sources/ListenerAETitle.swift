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

import Foundation

/// The AE titles the DICOM listeners answer to, as they are stored.
///
/// The listener threads used to work these out and write them to the defaults
/// themselves. The Listener preferences bind those keys, and a default written
/// on another thread notifies their bindings on that thread: with the pane
/// open, taking the host's name stopped the application, and a title longer
/// than 16 characters left the listener stopped on an AppKit exception. The
/// main thread now stores them before it starts the listeners, which only read.
enum ListenerAETitle {
    /// An AE title holds at most 16 characters.
    static let maximumLength = 16
    /// The title taken when the host has no name to give.
    static let fallback = "ISIX"

    /// The host's name up to its first dot, cut to 16 characters.
    static func fromHostName(_ hostName: String?) -> String {
        let name = hostName.map { String($0.prefix { $0 != "." }) } ?? ""
        let title = limited(name) ?? ""
        return title.isEmpty ? fallback : title
    }

    /// `title` cut to 16 UTF-16 units, as the listener has always counted
    /// them, without splitting a character.
    static func limited(_ title: String?) -> String? {
        guard let title, title.utf16.count > maximumLength else { return title }
        var result = ""
        var used = 0
        for character in title {
            used += character.utf16.count
            if used > maximumLength { break }
            result.append(character)
        }
        return result
    }
}
