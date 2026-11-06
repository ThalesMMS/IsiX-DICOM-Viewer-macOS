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
import IsiXImaging
import IsiXPreferences

// The PET blending tables every 2D view shares: the colours a fused PET series
// is drawn with in the "B/W Inverse" PET CLUT mode (IsiXImaging's
// PETBlendingTable, made from the stored colour table "PET Blending CLUT"
// names). One set of three tables of 256 entries, which +PETredTable,
// +PETgreenTable and +PETblueTable of DCMView hand to plugins as they are.
// Only the main actor reads and replaces them: the views, their drawing and
// the preferences' change.

/// The guardian of the shared PET blending tables.
@MainActor
enum PETBlendingTables {
    private static var red: UnsafeMutablePointer<UInt8>?
    private static var green: UnsafeMutablePointer<UInt8>?
    private static var blue: UnsafeMutablePointer<UInt8>?

    /// The red table; nil before the first view made them.
    static var redTable: UnsafeMutablePointer<UInt8>? { red }
    /// The green table; nil before the first view made them.
    static var greenTable: UnsafeMutablePointer<UInt8>? { green }
    /// The blue table; nil before the first view made them.
    static var blueTable: UnsafeMutablePointer<UInt8>? { blue }

    /// Whether the tables were made.
    static var isComputed: Bool { red != nil }

    /// Frees the tables and makes them again from the preferences, as
    /// +computePETBlendingCLUT always did: the addresses handed out before
    /// are no longer valid.
    static func recompute() {
        let preferences = PreferencesSource.process.preferences
        let preset = ReconstructionPreferences.preset(preferences[ViewerPreferences.petBlendingCLUT], of: ImagePresetPreferences.colourTables,
                                                      in: preferences)
        replace(with: PETBlendingTable(preset: preset?.propertyList.object as? [String: Any]))
    }

    /// Frees the tables and makes them again from `table`.
    static func replace(with table: PETBlendingTable) {
        if let red { free(red) }
        if let green { free(green) }
        if let blue { free(blue) }
        let tables = ColourTableState.Tables(red: malloc(256)!.bindMemory(to: UInt8.self, capacity: 256),
                                             green: malloc(256)!.bindMemory(to: UInt8.self, capacity: 256),
                                             blue: malloc(256)!.bindMemory(to: UInt8.self, capacity: 256))
        table.colours.write(to: tables)
        red = tables.red
        green = tables.green
        blue = tables.blue
    }

    /// Whether a fused series is drawn with these tables rather than its
    /// own: the PET CLUT mode of the preferences is "B/W Inverse".
    static var drawFusedSeries: Bool {
        PETBlendingTable.drawsFusedSeries(inPETCLUTMode: PreferencesSource.process.preferences[ViewerPreferences.petCLUTMode])
    }
}
