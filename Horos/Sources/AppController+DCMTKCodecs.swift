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

// AppController (DCMTK codecs): the codecs DCMTK decodes and encodes pixel
// data with, registered at launch through Adapters/DCMTK/IsiXDCMTKCodecs, and
// the UseJPEGColorSpace preference the JPEG decoder follows.

/// UseJPEGColorSpace: lossy JPEG whose JFIF or Adobe marker contradicts the
/// Photometric Interpretation decodes by the marker. Followed as it changes;
/// before the defaults are registered, its default (on) applies.
private enum JPEGColourPreference {
    nonisolated(unsafe) static let observation: NSObjectProtocol = {
        follow()
        return NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                      queue: nil) { _ in follow() }
    }()

    static func follow() {
        let value = UserDefaults.standard.object(forKey: "UseJPEGColorSpace")
        let on: Bool
        if value == nil { on = true }
        else if let number = value as? NSNumber { on = number.boolValue }
        else if let string = value as? NSString { on = string.boolValue }
        else { on = false }
        IsiXDCMTKCodecs.markersDecideColour = on
    }
}

extension AppController {

    /// Global registration of the DCMTK codecs, at launch.
    @objc func initDCMTK() {
        AppController.registerDCMTKCodecs()
    }

    /// The codecs alone; safe to call more than once. The dataset model
    /// (DCMObject) decodes and encodes through them, and a plugin may use it from -initPlugin,
    /// which runs while the plugins load, before -initDCMTK. Registering
    /// twice is a no-op.
    @objc nonisolated static func registerDCMTKCodecs() {
        do {
            try IsiXDCMTKCodecs.registerCodecs()
        } catch {
            NSLog("---- DCMTK codecs could not be registered: %@", error.localizedDescription)
        }
        _ = JPEGColourPreference.observation
    }

    /// Removes the codecs, when the application quits.
    @objc func destroyDCMTK() {
        do {
            try IsiXDCMTKCodecs.cleanupCodecs()
        } catch {
            NSLog("---- DCMTK codecs could not be removed: %@", error.localizedDescription)
        }
    }
}
