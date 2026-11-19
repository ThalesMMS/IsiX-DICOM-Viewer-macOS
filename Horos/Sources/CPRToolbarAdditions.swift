//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXPreferences

/// The items the curved MPR toolbar gained after users had saved theirs.
///
/// A toolbar the user arranged is kept as arranged, and an item that did not
/// exist then is not in it: the tool would be there for a new user and
/// nowhere for the others. Each addition is put into a saved toolbar once,
/// beside the item it goes with; removed afterwards, it stays removed.
@MainActor
enum CPRToolbarAdditions {
    static func insertOnce(into toolbar: NSToolbar?, store: any PreferenceStore) {
        guard let toolbar else { return }
        let additions: [(key: PreferenceKey<Bool>, items: [String], after: String)] = [
            (ReconstructionPreferences.cprToolbarStenosisInserted, ["tbStenosis"], "tbPathAssistant"),
            (ReconstructionPreferences.cprToolbarPathsInserted, [CurvedPathLibrary.pathsItem, CurvedPathLibrary.coronaryMIPItem], "tbStenosis"),
        ]
        for addition in additions where !store[addition.key] {
            store.set(true, for: addition.key)
            var index = toolbar.items.firstIndex { $0.itemIdentifier.rawValue == addition.after }.map { $0 + 1 } ?? toolbar.items.count
            for item in addition.items where !toolbar.items.contains(where: { $0.itemIdentifier.rawValue == item }) {
                toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier(item), at: index)
                index += 1
            }
        }
    }
}
