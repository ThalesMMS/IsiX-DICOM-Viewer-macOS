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

import Foundation

/// The Dock's tiles for applications, as com.apple.dock keeps them in
/// persistent-apps. Reading and writing the Dock's preferences is the app's.
public enum DockTile {
    /// A tile for the application at `path`, as a property list object, so
    /// that no path is interpolated into XML.
    public static func tile(forApplicationAt path: String) -> [String: Any] {
        ["tile-data": ["file-data": ["_CFURLString": URL(fileURLWithPath: path).absoluteString,
                                     "_CFURLStringType": 15]],
         "tile-type": "file-tile"]
    }

    /// Whether one of the tiles is the application at `path`: its file URL,
    /// standardized, is the same. Anything that is not a well-formed tile is
    /// skipped.
    public static func contains(_ tiles: [Any], applicationAt path: String) -> Bool {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        for tile in tiles {
            guard let tile = tile as? [String: Any],
                  let data = tile["tile-data"] as? [String: Any],
                  let file = data["file-data"] as? [String: Any],
                  let value = file["_CFURLString"] as? String else { continue }
            let url = value.hasPrefix("file:") ? URL(string: value) : URL(fileURLWithPath: value)
            if url?.standardizedFileURL == target { return true }
        }
        return false
    }
}
