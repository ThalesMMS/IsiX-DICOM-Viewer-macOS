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

/// The first entry of each list of compression settings (the full and the low
/// resolution one) is the default, the one a modality without an entry of its
/// own takes: it is named "default", in the language of the application, and
/// it never says "same as default" (compression 0), which would refer to
/// itself. The Database pane can leave it otherwise; each check of the
/// preferences puts it back.
public enum CompressionSettingsNormalization {
    /// Both lists, as the check after a change of the preferences leaves them.
    public static func normalize(in store: any PreferenceStore,
                                 defaultModality: String = NSLocalizedString("default", comment: "")) {
        for key in [DatabasePreferences.compressionSettings, DatabasePreferences.compressionSettingsLowRes] {
            normalize(key, in: store, defaultModality: defaultModality)
        }
    }

    /// One list: its first entry gets compression "1" in place of 0 and the
    /// default's name, the others are left as they are. Nothing is written
    /// when the entry already is the default, nor for an empty list. A list
    /// that is not there is written as not there, as it always was.
    static func normalize(_ key: PreferenceKey<[PropertyListValue]?>, in store: any PreferenceStore, defaultModality: String) {
        let list = store.object(forKey: key.name) as? [Any]
        if list?.isEmpty == true { return }
        let first = list?.first as? [String: Any]
        let refersToItself = compression(first?["compression"]) == 0
        let named = ((first?["modality"] as? String).map { ($0 as NSString).isEqual(to: defaultModality) }) ?? false
        guard refersToItself || !named else { return }
        var entry = first
        if refersToItself { entry?["compression"] = "1" }
        if !named { entry?["modality"] = defaultModality }
        var updated = list
        if let entry { updated?[0] = entry }
        store.set(updated, forKey: key.name)
    }

    /// The compression of an entry, a number or its text, as `intValue` reads it.
    private static func compression(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        if let text = value as? String { return (text as NSString).intValue }
        return 0
    }
}
