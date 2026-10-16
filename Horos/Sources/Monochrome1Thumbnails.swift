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

import CoreData
import Foundation

/// Series thumbnails stored with MONOCHROME1 shown in reverse.
///
/// MONOCHROME1 polarity was moved out of the pixel data into the display, and
/// for a while the thumbnail generator did not follow it: the icons it stored
/// for MONOCHROME1 radiographs came out in reverse video. Once per
/// database, the stored thumbnails of the projection modalities that carry
/// MONOCHROME1 are dropped, and each is made again the next time it is shown.
/// They are single images, so this is cheap; other modalities keep theirs.
@objc(HorosMonochrome1Thumbnails)
public final class Monochrome1Thumbnails: NSObject {
    /// The databases already done, by their base directory.
    @objc public static let doneKey = "MONOCHROME1ThumbnailsRebuiltDatabases"

    @objc public static let modalities = ["CR", "DX", "DR", "MG", "RG", "RF", "XA", "PX", "IO", "OT"]

    @objc public static var predicate: NSPredicate {
        NSPredicate(format: "modality IN %@ AND thumbnail != nil", modalities)
    }

    /// Whether the database at `path` still has to be done, recording it as done.
    @objc(claimDatabaseAtPath:)
    public static func claimDatabase(atPath path: String?) -> Bool {
        guard let path = path, !path.isEmpty else { return false }
        var done = UserDefaults.standard.stringArray(forKey: doneKey) ?? []
        if done.contains(path) { return false }
        done.append(path)
        UserDefaults.standard.set(done, forKey: doneKey)
        return true
    }

    @objc(rebuildOnceInDatabase:)
    public static func rebuildOnce(in database: DicomDatabase?) {
        guard let database = database, database.isLocal(), !database.isReadOnly,
              claimDatabase(atPath: database.baseDirPath) else { return }

        guard let context = database.managedObjectContext else { return }
        context.performAndWait {
            let series = database.objects(forEntity: "Series", predicate: predicate) ?? []
            if series.isEmpty { return }
            for item in series {
                (item as? NSManagedObject)?.setValue(nil, forKey: "thumbnail")
            }
            _ = database.save(nil)
            NSLog("Rebuilding %d stored thumbnails of radiography series (MONOCHROME1 polarity)", series.count)
        }
    }
}
