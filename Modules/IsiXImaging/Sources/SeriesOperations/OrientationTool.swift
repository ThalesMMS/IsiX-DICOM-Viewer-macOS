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

// The orientation tool of a 2D viewer (the tags of its orientation matrix and
// of its MPR menu) and what changing it does to the series: a reslice along the
// rows or the columns of the slices, then the flips and the quarter turn that
// bring the new slices upright. The viewer applies the steps to its DCMPix;
// nothing here knows DCMPix or the viewer.

/// The orientation a 2D viewer shows its series in.
public enum OrientationTool: Int16, Sendable, CaseIterable {
    case axial = 0, coronal = 1, sagittal = 2
}

extension SliceStackOrientation {
    /// The orientation tool of a stack whose slices are stacked in this
    /// orientation.
    public var tool: OrientationTool {
        switch self {
        case .axialPositive, .axialNegative: return .axial
        case .coronalPositive, .coronalNegative: return .coronal
        case .sagittalPositive, .sagittalNegative: return .sagittal
        }
    }
}
