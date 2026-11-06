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

// The factory lists of the hanging protocols and hot keys.
extension ViewerPreferences {
    /// One protocol per modality, the localized modality name as its key; two
    /// by two for mammography, in the order of the usual views.
    static func factoryHangingProtocols() -> [String: Any] {
        let modalities = ["CR", "CT", "DX", "ES", "MG", "MR", "NM", "OT", "PT", "RF", "SC", "US", "XA"]
            .map { NSLocalizedString($0, comment: "") }
        var protocols: [String: Any] = [:]
        for modality in modalities {
            var hangingProtocol: [String: Any] = ["Study Description": NSLocalizedString("Default", comment: ""),
                                                  "WindowsTiling": 0, "ImageTiling": 0]
            if modality == "MG" {
                hangingProtocol["WindowsTiling"] = 5 // 2 x 2
                hangingProtocol["SeriesOrder"] = "R CC,L CC,R MLO,L MLO"
                hangingProtocol["NumberOfSeriesPerComparative"] = 4
            }
            protocols[modality] = [hangingProtocol]
        }
        return protocols
    }

    /// The key of each hot key action, in the order of the HotKeyActions enum
    /// (DefaultsOsiriX.h): a key maps to the index of its action. An empty key
    /// has no hot key.
    static func factoryHotKeys() -> [String: Int] {
        let keys = [
            "~",    //DefaultWWWLHotKeyAction
            "0",    //FullDynamicWWWLHotKeyAction
            "1",    //Preset1WWWLHotKeyAction
            "2",    //Preset2WWWLHotKeyAction
            "3",    //Preset3WWWLHotKeyAction
            "4",    //Preset4WWWLHotKeyAction
            "5",    //Preset5WWWLHotKeyAction
            "6",    //Preset6WWWLHotKeyAction
            "7",    //Preset7WWWLHotKeyAction
            "8",    //Preset8WWWLHotKeyAction
            "9",    //Preset9WWWLHotKeyAction
            "v",    //FlipVerticalHotKeyAction
            "h",    //FlipHorizontalHotKeyAction
            "w",    //WWWLToolHotKeyAction
            "m",    //MoveHotKeyAction
            "z",    //ZoomHotKeyAction
            "i",    //RotateHotKeyAction
            "",     //ScrollHotKeyAction
            "l",    //LengthHotKeyAction
            "a",    //AngleHotKeyAction
            "",     //RectangleHotKeyAction
            "e",    //OvalHotKeyAction
            "t",    //TextHotKeyAction
            "q",    //ArrowHotKeyAction
            "o",    //OpenPolygonHotKeyAction
            "c",    //ClosedPolygonHotKeyAction
            "d",    //PencilHotKeyAction
            "p",    //ThreeDPointHotKeyAction
            "b",    //PlainToolHotKeyAction
            "x",    //BoneRemovalHotKeyAction
            "[",    //Rotate3DHotKeyAction
            "]",    //Camera3DotKeyAction
            "\\",   //scissors3DHotKeyAction
            "r",    //RepulsorHotKeyAction
            "s",    //SelectorHotKeyAction
            ",",    //EmptyHotKeyAction
            ".",    //UnreadHotKeyAction
            "/",    //ReviewedHotKeyAction
            "\\",   //DictatedHotKeyAction
            "",     //ValidatedHotKeyAction
            "y",    //OrthoMPRCrossTool
            "",     //Preset1OpacityLHotKeyAction
            "",     //Preset2OpacityLHotKeyAction
            "",     //Preset3OpacityLHotKeyAction
            "",     //Preset4OpacityLHotKeyAction
            "",     //Preset5OpacityLHotKeyAction
            "",     //Preset6OpacityLHotKeyAction
            "",     //Preset7OpacityLHotKeyAction
            "",     //Preset8OpacityLHotKeyAction
            "",     //Preset9OpacityLHotKeyAction
            "dbl-click",        //FullScreenAction
            "dbl-click + alt",  //Sync3DAction
            "dbl-click + cmd",  //SetKeyImageAction
            "",     //ResliceAxialHotKeyAction
            "",     //ResliceCoronalHotKeyAction
            "",     //ResliceSagittalHotKeyAction
        ]
        var hotKeys: [String: Int] = [:]
        // A key listed twice keeps its last action (\ is the dictation's).
        for (action, key) in keys.enumerated() where !key.isEmpty {
            hotKeys[key] = action
        }
        return hotKeys
    }
}

// The compression of each modality, for the full and the low resolution lists.
extension DatabasePreferences {
    /// None, except the default (3); `quality` "1" for the full resolution
    /// list, "0" for the low resolution one.
    static func factoryCompression(quality: String) -> [[String: String]] {
        let modalities = ["CR", "CT", "DX", "ES", "MG", "MR", "NM", "OT", "PT", "RF", "SC", "US", "XA"]
        return [["modality": NSLocalizedString("default", comment: ""), "compression": "3", "quality": quality]]
            + modalities.map { ["modality": $0, "compression": "0", "quality": quality] }
    }
}
