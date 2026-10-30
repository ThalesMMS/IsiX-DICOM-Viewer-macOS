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

/// The rules of a saved layout of the 2D viewers ("windows state"), stored in
/// each study as an XML property list of one dictionary per viewer.
public enum ViewerWindowsState {

    /// The keys that describe the whole layout rather than one viewer: a part
    /// of a layout keeps none of them, and its viewers are tiled when it is
    /// restored.
    public static let layoutKeys = ["window position", "screen", "screenIndex", "LastWindowsTilingRowsColumns"]

    /// The value of "seriesInstanceUID" for a viewer whose movie frames show
    /// the series `uids`: the one series, or all of them joined by `\**\`
    /// when the frames come from different series; nil without any.
    public static func seriesInstanceUID(of uids: [String]) -> String? {
        guard let last = uids.last else { return nil }
        if uids.allSatisfy({ $0 == last }) { return last }
        return uids.joined(separator: "\\**\\")
    }

    /// "x y width height" of a window frame, as "%f %f %f %f".
    public static func windowPosition(_ frame: CGRect) -> String {
        String(format: "%f %f %f %f", Double(frame.origin.x), Double(frame.origin.y), Double(frame.size.width), Double(frame.size.height))
    }

    /// The viewers of a saved layout that a study of `patientUID` keeps.
    ///
    /// `patients[i]` is the patient of `state[i]`, compared as
    /// -databaseOpenStudy: compares them (case, diacritics and width
    /// ignored): the whole layout would put another patient's series, window
    /// and zoom into the study's state. When the patient keeps only part of
    /// the layout, each of its entries loses the `layoutKeys`.
    public static func entries(of state: [NSDictionary], patients: [String], patientUID: String?) -> [NSDictionary] {
        var own: [NSDictionary] = []
        for i in 0..<min(state.count, patients.count)
        where (patients[i] as NSString).compare(patientUID ?? "", options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame {
            own.append(state[i])
        }
        if own.count == state.count { return own }

        return own.map { entry in
            let part = entry.mutableCopy() as! NSMutableDictionary
            part.removeObjects(forKeys: layoutKeys)
            return part
        }
    }
}
