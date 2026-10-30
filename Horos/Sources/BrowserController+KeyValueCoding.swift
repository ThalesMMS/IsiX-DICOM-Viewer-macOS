/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit

// Key-value coding of the former instance variables. MainMenu.xib connects
// the browser's outlets by their names (databaseOutline, _sourcesTableView...),
// and plugins and scripts read the state by the names of the instance
// variables. The class answers the keys of its properties itself; a key it
// does not know, with or without its leading underscore, is the holder's
// that keeps it now (BrowserState.swift, BrowserOutlets.swift). "_database"
// is the database shown. Swift's stored properties are not instance
// variables to look up by key.

extension BrowserController {

    /// The holders, in the order the keys are looked for.
    nonisolated private var stateHolders: [NSObject] {
        return [windowOutlets, sheetOutlets, previewState, studyListState, comparativeState, albumState,
                selectionCache, transferState, sheetValues, viewerOpeningState, windowState]
    }

    /// The position of the holder of each key in stateHolders.
    nonisolated private static let holderIndexForKey: [String: Int] = {
        let classes: [AnyClass] = [BrowserWindowOutlets.self, BrowserSheetOutlets.self, BrowserPreviewState.self,
                                   BrowserStudyListState.self, BrowserComparativeState.self, BrowserAlbumState.self,
                                   BrowserSelectionCache.self, BrowserTransferState.self, BrowserSheetValues.self,
                                   BrowserViewerOpeningState.self, BrowserWindowState.self]
        var index: [String: Int] = [:]
        for position in classes.indices {
            let holderClass: AnyClass = classes[position]
            var count: UInt32 = 0
            guard let properties = class_copyPropertyList(holderClass, &count) else { continue }
            for property in UnsafeBufferPointer(start: properties, count: Int(count)) {
                let name = String(cString: property_getName(property))
                if index[name] == nil { index[name] = position }
            }
            free(properties)
        }
        return index
    }()

    /// The holder of a former instance variable's key, and the key there.
    nonisolated private func holder(forKey key: String) -> (holder: NSObject, key: String)? {
        let name = key.hasPrefix("_") ? String(key.dropFirst()) : key
        guard let position = BrowserController.holderIndexForKey[name] else { return nil }
        return (stateHolders[position], name)
    }

    public override nonisolated func value(forUndefinedKey key: String) -> Any? {
        if key == "_database" { return horos_databaseIvar }
        if let found = holder(forKey: key) { return found.holder.value(forKey: found.key) }
        return super.value(forUndefinedKey: key)
    }

    public override nonisolated func setValue(_ value: Any?, forUndefinedKey key: String) {
        if key == "_database" {
            willChangeValue(forKey: key)
            horos_databaseIvar = value as? DicomDatabase
            didChangeValue(forKey: key)
            return
        }
        guard let found = holder(forKey: key) else {
            super.setValue(value, forUndefinedKey: key)
            return
        }
        willChangeValue(forKey: key)
        found.holder.setValue(value, forKey: found.key)
        didChangeValue(forKey: key)
    }
}
