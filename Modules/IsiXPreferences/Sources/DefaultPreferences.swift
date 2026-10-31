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

/// The factory settings: what the application registers beneath the user's own
/// preferences, and what the Decompress helper starts from before it reads the
/// application's. Both are built from the catalog, where each key is declared
/// with its value or the rule that makes it, except where the helper has no
/// use for a value (`viewer` false): it gets no colour tables (they are
/// resources of the application), no AE title made from the host name, and
/// does not copy files into the database.
@objc(IsiXDefaultPreferences)
public final class DefaultPreferences: NSObject {
    /// Every key of the catalog, area by area; each name once.
    public static let catalog: [any CataloguedPreference] = ImagePresetPreferences.catalog + ApplicationPreferences.catalog
        + DatabasePreferences.catalog + NetworkPreferences.catalog + ReconstructionPreferences.catalog
        + ViewerPreferences.catalog + VolumeRenderingPreferences.catalog + WebPortalPreferences.catalog

    /// A new dictionary at each call, which the caller may change. `viewer` is
    /// the application, false for the Decompress helper; `appStore` the build for
    /// the Mac App Store. A super-sampling the user stored below the default is
    /// raised to it in the standard preferences.
    @objc(defaultsForViewer:appStore:)
    public static func defaults(forViewer viewer: Bool, appStore: Bool) -> NSMutableDictionary {
        defaults(in: .current(viewer: viewer, appStore: appStore), store: UserDefaults.standard)
    }

    /// The registered values of the catalog in `environment`, raising in `store`
    /// a super-sampling stored below the default.
    public static func defaults(in environment: PreferenceEnvironment, store: any PreferenceStore) -> NSMutableDictionary {
        let values = NSMutableDictionary()
        for key in catalog {
            if let value = key.registration?.value(in: environment) {
                values[key.name] = value
            }
        }
        let superSampling = VolumeRenderingPreferences.superSampling
        let minimum = Float.reading(values[superSampling.name])
        if store[superSampling] < minimum {
            store.set(minimum, for: superSampling)
        }
        return values
    }

    /// This computer's host name; nil when it cannot be read as UTF-8.
    static func hostName() -> String? {
        var name = [CChar](repeating: 0, count: Int(_POSIX_HOST_NAME_MAX) + 1)
        gethostname(&name, Int(_POSIX_HOST_NAME_MAX))
        return String(validating: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
