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
////////////////////////////////////////////
//
//	Matt Brewer
//	December 1, 2009
//
//	matt@matt-brewer.com
//	http://www.matt-brewer.com
//
//
//	This code is released as is
//	with NO warranty, implied or otherwise.
//
////////////////////////////////////////////

import AppKit
import IsiXInstallation

/// The application's tile in the user's Dock, after a move to Applications.
/// The tiles themselves are IsiXInstallation's DockTile.
extension NSApplication {
    private static let dockDomain = "com.apple.dock" as CFString
    private static let persistentApps = "persistent-apps" as CFString

    /// Adds the application at `path` to the Dock, unless a tile already
    /// names it, and has the Dock reload. NO for a path that is not an
    /// existing .app, Dock preferences that cannot be read or written, or a
    /// Dock that does not reload within 5 seconds.
    @objc(addApplicationToDock:)
    func addApplicationToDock(_ path: String) -> Bool {
        guard (path as NSString).pathExtension == "app", FileManager.default.fileExists(atPath: path) else { return false }
        let stored = CFPreferencesCopyAppValue(NSApplication.persistentApps, NSApplication.dockDomain)
        if stored != nil && !(stored is [Any]) { return false }
        let tiles = stored as? [Any] ?? []
        if DockTile.contains(tiles, applicationAt: path) { return true }
        let updated = tiles + [DockTile.tile(forApplicationAt: path)]
        CFPreferencesSetAppValue(NSApplication.persistentApps, updated as CFArray, NSApplication.dockDomain)
        guard CFPreferencesAppSynchronize(NSApplication.dockDomain) else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["-HUP", "Dock"]
        var error: NSError?
        let started = HorosRunTaskUntilExit(task, 5, &error)
        return started && task.terminationStatus == 0
    }

    /// Whether a tile of the Dock names the application at `path`.
    @objc(applicationExistsInDock:)
    func applicationExistsInDock(_ path: String) -> Bool {
        guard let tiles = CFPreferencesCopyAppValue(NSApplication.persistentApps, NSApplication.dockDomain) as? [Any] else {
            return false
        }
        return DockTile.contains(tiles, applicationAt: path)
    }
}
