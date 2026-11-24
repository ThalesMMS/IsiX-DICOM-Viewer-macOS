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

/// Whether a volume takes a file, asked before a medium is written to it. The
/// volume is emptied before the files are copied, so one that refuses the write
/// has to be found out while everything is still on it, and the reason is what
/// tells the user how to let the application write.
public enum VolumeWriteProbe {
    /// Why a volume did not take a file.
    public enum Refusal: Equatable, Sendable {
        /// The system did not permit the write (EPERM): the privacy setting of
        /// removable volumes, or the App Sandbox for a folder the user did not
        /// point at in a panel.
        case notPermitted
        /// The permissions of the volume do not let this account write (EACCES).
        case accessDenied
        /// The volume is read-only (EROFS).
        case readOnly
        /// Anything else, by its error number.
        case other(Int32)
    }

    /// The refusal an error number of the write stands for.
    public static func refusal(errorNumber: Int32) -> Refusal {
        switch errorNumber {
        case EPERM: return .notPermitted
        case EACCES: return .accessDenied
        case EROFS: return .readOnly
        default: return .other(errorNumber)
        }
    }

    /// Creates a file at the root of `volumePath` and removes it. Nil when the
    /// volume took it; a path that is not absolute names no volume.
    public static func refusal(writingTo volumePath: String) -> Refusal? {
        guard volumePath.hasPrefix("/") else { return .other(ENOENT) }
        let path = (volumePath as NSString).appendingPathComponent(".write-test-" + UUID().uuidString)
        let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else { return refusal(errorNumber: errno) }
        close(descriptor)
        unlink(path)
        return nil
    }

    /// Empties `volumePath` when it takes a file, and removes nothing from it
    /// when it does not: the answer is the refusal, nil once it was emptied.
    public static func empty(_ volumePath: String) -> Refusal? {
        if let refusal = refusal(writingTo: volumePath) { return refusal }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: volumePath)) ?? [] {
            try? FileManager.default.removeItem(atPath: (volumePath as NSString).appendingPathComponent(name))
        }
        return nil
    }
}
