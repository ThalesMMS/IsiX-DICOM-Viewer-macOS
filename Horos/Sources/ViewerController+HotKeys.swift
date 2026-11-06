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

import AppKit

// The tools that a hot key selects. The table lists, for each ToolMode in
// order, the hot key action of the HotKeyActions enum (DefaultsOsiriX.h) that
// selects it, or -1. If either list changes, this one, DCMView.h's ToolMode
// and the hot key preference pane must change with it.

/// The hot key action of each tool, by ToolMode.
private let hotKeyToolCrossTable: [Int32] = [
    Int32(WWWLToolHotKeyAction.rawValue),      // tWL            0
    Int32(MoveHotKeyAction.rawValue),          // tTranslate     1
    Int32(ZoomHotKeyAction.rawValue),          // tZoom          2
    Int32(RotateHotKeyAction.rawValue),        // tRotate        3
    Int32(ScrollHotKeyAction.rawValue),        // tNext          4
    Int32(LengthHotKeyAction.rawValue),        // tMesure        5
    Int32(RectangleHotKeyAction.rawValue),     // tROI           6
    Int32(Rotate3DHotKeyAction.rawValue),      // t3DRotate      7
    Int32(OrthoMPRCrossHotKeyAction.rawValue), // tCross         8
    Int32(OvalHotKeyAction.rawValue),          // tOval          9
    Int32(OpenPolygonHotKeyAction.rawValue),   // tOPolygon      10
    Int32(ClosedPolygonHotKeyAction.rawValue), // tCPolygon      11
    Int32(AngleHotKeyAction.rawValue),         // tAngle         12
    Int32(TextHotKeyAction.rawValue),          // tText          13
    Int32(ArrowHotKeyAction.rawValue),         // tArrow         14
    Int32(PencilHotKeyAction.rawValue),        // tPencil        15
    -1,                                        // t3Dpoint       16
    Int32(scissors3DHotKeyAction.rawValue),    // t3DCut         17
    Int32(Camera3DotKeyAction.rawValue),       // tCamera3D      18
    Int32(ThreeDPointHotKeyAction.rawValue),   // t2DPoint       19
    Int32(PlainToolHotKeyAction.rawValue),     // tPlain         20
    Int32(BoneRemovalHotKeyAction.rawValue),   // tBonesRemoval  21
    -1,                                        // tWLBlended     22
    Int32(RepulsorHotKeyAction.rawValue),      // tRepulsor      23
    -1,                                        // tLayerROI      24
    Int32(SelectorHotKeyAction.rawValue),      // tROISelector   25
    -1,                                        // tAxis          26
    -1,                                        // tDynAngle      27
    -1,                                        // tCurvedROI     28
    -1,                                        // tTAGT          29
]

extension ViewerController {

    /// The first tool whose hot key action is `h` (the first tool without one
    /// for -1), or -1.
    @objc(getToolEquivalentToHotKey:)
    class func getToolEquivalent(toHotKey h: Int32) -> ToolMode {
        let index = hotKeyToolCrossTable.firstIndex(of: h) ?? -1
        return ToolMode(rawValue: Int16(index))!
    }

    /// The hot key action of the tool `h`, or -1. The former code also read
    /// the element after the table for the tool right after the last one,
    /// out of its bounds; -1 is answered for it.
    @objc(getHotKeyEquivalentToTool:)
    class func getHotKeyEquivalent(toTool h: ToolMode) -> Int32 {
        let tool = Int(h.rawValue)
        guard tool >= 0, tool < hotKeyToolCrossTable.count else { return -1 }
        return hotKeyToolCrossTable[tool]
    }
}
