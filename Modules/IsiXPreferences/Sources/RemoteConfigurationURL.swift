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

/// Where the lists that replace preferences, DICOM nodes or database servers may
/// come from. What they hold overwrites the application's settings, so a plain
/// `http:` address, which anyone on the way can rewrite, is not read.
public enum RemoteConfigurationURL {

    /// An `https:` address, or a file the person chose or that is local.
    public static func isAcceptable(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "file"
    }
}
