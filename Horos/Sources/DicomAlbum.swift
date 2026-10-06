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

import Cocoa
import CoreData

/// Core Data entity for an album.
///
/// Implemented in Swift: the Objective-C name (which the
/// OsiriXDB_DataModel model names as the Album entity's class), the selectors,
/// the KVC keys and <Horos/DicomAlbum.h> are those of the former class. Core
/// Data provides the accessors of the modelled properties (@NSManaged, the
/// former @dynamic) and of the studies relationship.
@objc(DicomAlbum)
public final class DicomAlbum: NSManagedObject {
    @NSManaged public var index: NSNumber!
    @NSManaged public var name: String!
    @NSManaged public var predicateString: String!
    @NSManaged public var smartAlbum: NSNumber!
    @NSManaged public var studies: Set<AnyHashable>!

    /// Not modelled: the count the album list shows, kept in the object as
    /// the former synthesized int was. Atomic in the former header; a single
    /// aligned word, read and written whole.
    @objc public dynamic var numberOfStudies: Int32 = 0

    // MARK: CoreDataGeneratedAccessors

    @objc(addStudiesObject:)
    @NSManaged public func addStudiesObject(_ value: DicomStudy!)

    @objc(removeStudiesObject:)
    @NSManaged public func removeStudiesObject(_ value: DicomStudy!)

    @objc(addStudies:)
    @NSManaged public func addStudies(_ value: Set<AnyHashable>!)

    @objc(removeStudies:)
    @NSManaged public func removeStudies(_ value: Set<AnyHashable>!)
}
