/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

// NSMutableArray (MutableArrayCategory) is implemented in Swift; the
// selectors and <Horos/MutableArrayCategory.h> are those of the former
// category. -shuffle and NSArray (ArrayCategory) -shuffledArray draw from
// rand(), which Swift cannot call: they stay in MutableArrayCategory+CAPI.m,
// with the exported sortByAddress function.

public extension NSMutableArray {

    // appends array to self except when the object is already in the array as determined by isEqual:
    @objc(mergeWithArray:)
    func merge(with array: NSArray?) {
        guard let array else { return }
        // The whole array, including what this merge has added: an object
        // that `array` holds twice is added once.
        for object in array where !contains(object) {
            add(object)
        }
    }

    // Removes the later occurrences of the same object (identity), keeping
    // the first one where it is. The duplicate itself is removed; formerly,
    // -indexOfObject: removed the first object equal to it, which could be
    // another object, and left the duplicate in place.
    @objc func removeDuplicatedObjects() {
        var seen = Set<ObjectIdentifier>()
        var duplicates = IndexSet()
        for (index, object) in enumerated() where !seen.insert(ObjectIdentifier(object as AnyObject)).inserted {
            duplicates.insert(index)
        }
        removeObjects(at: duplicates)
    }

    @objc func removeDuplicatedStrings() {
        removeObjects(at: duplicatedStringIndexes())
    }

    // Removes the same indexes from otherArray, so that the pairs stay
    // together: the first path of each group keeps its own object.
    @objc(removeDuplicatedStringsInSyncWithThisArray:)
    func removeDuplicatedStrings(inSyncWithThisArray otherArray: NSMutableArray?) {
        let duplicates = duplicatedStringIndexes()
        removeObjects(at: duplicates)
        otherArray?.removeObjects(at: duplicates)
    }

    // The indexes of the strings equal (-isEqual:, as -isEqualToString:) to
    // an earlier one; other objects are never duplicates. The array used to
    // be sorted with -compare:, which left a literal duplicate apart when a
    // canonically equivalent string sorted between them, and raised when
    // the array held NSNull, which -valueForKey: puts for a missing path.
    private func duplicatedStringIndexes() -> IndexSet {
        let seen = NSMutableSet()
        var duplicates = IndexSet()
        for (index, object) in enumerated() {
            guard let string = object as? NSString else { continue }
            if seen.contains(string) { duplicates.insert(index) } else { seen.add(string) }
        }
        return duplicates
    }

    // Deprecated: why use this instead of containsObject: ?
    @available(*, deprecated)
    @objc(containsString:)
    func containsString(_ string: String?) -> Bool {
        for object in self {
            if let candidate = object as? NSString, let string, candidate.isEqual(to: string) {
                return true
            }
        }

        return false
    }
}
