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

import CryptoKit
import Foundation

/// A NIfTI or Analyze file carries no study, series or instance identifiers: the database names them
/// after the file. Named after the file alone, `subject1/brain.nii` and `subject2/brain.nii` were one
/// study, one series and one image, and imported in place they became a single series showing one of
/// the two volumes. The key tells such files apart by where they are, and a file that stays where
/// it is keeps it: imported again, or read again after a relaunch.
@objc(HorosFileIdentity)
public final class FileIdentity: NSObject {
    /// Sixteen hexadecimal digits of the SHA-256 of the file's standardized path.
    @objc(keyForPath:)
    public static func key(forPath path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        return SHA256.hash(data: Data(standardized.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
