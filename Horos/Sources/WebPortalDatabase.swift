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

/// The database of the web portal's users and of the studies they are given.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/WebPortalDatabase.h> are those of the former class. Its superclass,
/// N2ManagedDatabase, stays in Objective-C; the constants
/// WebPortalDatabaseUserEntityName and WebPortalDatabaseStudyEntityName stay in
/// WebPortalDatabase+CAPI.m.
@objc(WebPortalDatabase)
public final class WebPortalDatabase: N2ManagedDatabase {
    /// Portal databases are opened on the connection threads too, so the
    /// shared model is made and read under `modelLock`; Core Data shares a
    /// model between threads once a coordinator uses it.
    private static let modelLock = NSLock()
    // nonisolated(unsafe): read and written only inside `modelLock.withLock`.
    nonisolated(unsafe) private static var model: NSManagedObjectModel? = nil

    public override class func modelName() -> String! {
        return "WebPortalDB.momd"
    }

    public override var managedObjectModel: NSManagedObjectModel! {
        return WebPortalDatabase.modelLock.withLock {
            if WebPortalDatabase.model == nil {
                WebPortalDatabase.model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent(WebPortalDatabase.modelName())))
            }
            return WebPortalDatabase.model
        }
    }

    @objc(userEntity)
    public func userEntity() -> NSEntityDescription! {
        return self.entity(forName: WebPortalDatabaseUserEntityName)
    }

    @objc(studyEntity)
    public func studyEntity() -> NSEntityDescription! {
        return self.entity(forName: WebPortalDatabaseStudyEntityName)
    }

    @objc(usersWithPredicate:)
    public func users(with p: NSPredicate!) -> [Any]! {
        return self.objects(forEntity: self.userEntity(), predicate: p)
    }

    @objc(userWithName:)
    public func user(withName name: String!) -> WebPortalUser! {
        let res = self.users(with: WebPortalUserLookup.predicate(forName: name ?? ""))
        return WebPortalUserLookup.user(among: (res as? [NSManagedObject]) ?? [], forName: name ?? "") as? WebPortalUser
    }

    /// -newUser. Swift returns it retained (+1), as the "new" family says; the
    /// former implementation returned it autoreleased.
    @objc(newUser)
    public func newUser() -> WebPortalUser! {
        let newUser = NSEntityDescription.insertNewObject(forEntityName: WebPortalDatabaseUserEntityName, into: self.managedObjectContext)

        newUser.setValue(Date(timeIntervalSinceReferenceDate: Date.timeIntervalSinceReferenceDate + Double(UserDefaults.standard.integer(forKey: "temporaryUserDuration") * 60 * 60 * 24)), forKey: "deletionDate")

        return newUser as? WebPortalUser
    }
}
