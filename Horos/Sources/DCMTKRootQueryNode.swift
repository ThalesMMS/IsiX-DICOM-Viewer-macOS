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
import IsiXDICOMNetwork

/// The root of a search of a node: its children are the studies found.
@objc(DCMTKRootQueryNode)
final class DCMTKRootQueryNode: DCMTKQueryNode, @unchecked Sendable {

    override func queryPrototype() -> DICOMQueryIdentifier? {
        let defaults = UserDefaults.standard
        return QueryIdentifiers.studies(options: QueryReturnKeyOptions(
            bodyPartExamined: defaults.bool(forKey: "CFINDBodyPartExaminedSupport"),
            commentsAndStatus: defaults.bool(forKey: "CFINDCommentsAndStatusSupport"),
            modalitiesInStudy: defaults.bool(forKey: "SupportQRModalitiesinStudy")))
    }

    override func addChild(_ response: IsiXDCMTKDataset?) {
        childrenLock.lock(); defer { childrenLock.unlock() }
        if childrenStorage == nil { childrenStorage = NSMutableArray() }
        guard let response, let children = childrenStorage else { return }
        let limit = UserDefaults.standard.integer(forKey: "maximumNumberOfCFindObjects")
        if limit > 0 && children.count > limit {
            NSLog("----- C-Find maximumNumberOfCFindObjects reached: %d, %d", Int32(truncatingIfNeeded: children.count),
                  Int32(truncatingIfNeeded: limit))
            return
        }
        let study = child(DCMTKStudyQueryNode.self, from: response)
        var alreadyHere = false
        if UserDefaults.standard.bool(forKey: "QRRemoveDuplicateEntries") {
            for case let existing as DCMTKStudyQueryNode in children
            where Self.same(existing.studyInstanceUID(), study.studyInstanceUID()) && Self.same(existing.name(), study.name())
                && Self.same(existing.accessionNumber(), study.accessionNumber())
                && (existing.numberImages()?.int32Value ?? 0) == (study.numberImages()?.int32Value ?? 0)
                && Self.same(existing.date(), study.date()) {
                alreadyHere = true
            }
        }
        if !alreadyHere { children.add(study) }
        NotificationCenter.default.post(name: NSNotification.Name("realtimeCFindResults"), object: self)
    }
}

extension DCMTKQueryNode {
    /// -isEqualToString: sent to a value that may be nil: false then.
    static func same(_ first: String?, _ second: String?) -> Bool {
        guard let first, let second else { return false }
        return (first as NSString).isEqual(to: second)
    }

    /// -isEqualToDate: sent to a date that may be nil: false then.
    static func same(_ first: NSDate?, _ second: NSDate?) -> Bool {
        guard let first, let second else { return false }
        return first.isEqual(to: second as Date)
    }
}
