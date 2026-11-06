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
//
//  PFMoveApplication.m, version 1.7.2
//  LetsMove
//
//  Created by Andy Kim at Potion Factory LLC on 9/17/09
//
//  The contents of this file are dedicated to the public domain.

import AppKit
import Darwin

// What the C entry point PFAddInstalledApplicationToDock did, and where a
// translocated copy really is. AppController calls
// moveToApplicationsFolderIfNecessary(), as PFMoveToApplicationsFolderIfNecessary
// did, on the main thread.
extension HorosApplicationInstaller {
    /// Adds the installed application to the Dock, after the user agreed to
    /// the move and the new copy was launched.
    static func addInstalledApplicationToDock(_ path: String) -> Bool {
        if NSApp.applicationExistsInDock(path) { return true }
        let added = NSApp.addApplicationToDock(path)
        if !added { NSLog("The installed application could not be added to the Dock.") }
        return added
    }

    /// Where a copy Gatekeeper runs translocated really is, from Security's
    /// SecTranslocateCreateOriginalPathForURL. The function is not in the
    /// SDK's headers, so it is looked up at run time; nil without it.
    static func originalURL(ofTranslocated url: URL) -> URL? {
        typealias CreateOriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return nil }
        defer { dlclose(security) }
        guard let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateOriginalPath.self)
        return create(url as CFURL, nil)?.takeRetainedValue() as URL?
    }
}
