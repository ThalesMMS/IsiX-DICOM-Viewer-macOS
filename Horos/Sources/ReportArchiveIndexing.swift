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
import Synchronization

/// The report SRs that a study is indexing right after archiving its own
/// attached report.
///
/// Such an SR is a copy of the file the study already points to. When the
/// importer finds that the two differ, the editor saved the report while the
/// copy was being taken - Pages does so whenever it loses focus, which is the
/// moment the app becomes active and archives. Moving the study to a new file
/// extracted from the SR would leave the document open in the editor detached
/// from the study, and the next report command would open the older copy in a
/// second window. The file on disk is kept, and the next synchronization
/// archives its newer contents.
///
/// A report SR received from elsewhere is never registered here, so it still
/// replaces the attached report as before.
@objc(HorosReportArchiveIndexing)
public final class ReportArchiveIndexing: NSObject {

    private static let paths = Mutex<[String: Int]>([:])

    /// Runs `body`, which indexes the SR at `path`, with that SR registered.
    static func indexing(_ path: String?, _ body: () -> Void) {
        guard let path, !path.isEmpty else { return body() }
        let key = canonical(path)
        paths.withLock { $0[key, default: 0] += 1 }
        defer {
            paths.withLock {
                let remaining = ($0[key] ?? 1) - 1
                $0[key] = remaining > 0 ? remaining : nil
            }
        }
        body()
    }

    /// Whether the SR at `path` is the study's own archive being indexed.
    @objc(isIndexingOwnArchiveAtPath:)
    public static func isIndexingOwnArchive(atPath path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        let key = canonical(path)
        return paths.withLock { $0[key] != nil }
    }

    /// The same file reached through /tmp or /private/tmp, or with `..`, is
    /// one key.
    private static func canonical(_ path: String) -> String {
        return ((path as NSString).standardizingPath as NSString).resolvingSymlinksInPath
    }
}
