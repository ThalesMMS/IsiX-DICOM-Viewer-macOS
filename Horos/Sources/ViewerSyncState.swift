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
import IsiXImaging

// The synchronization the 2D viewers share, which the former viewer kept in
// globals: the series lock across studies (SYNCSERIES), what the toolbar's
// "Sync" button does (SyncButtonBehaviorIsBetweenStudies) and the viewer an
// image is dragged from for a fusion; and, kept here, where each view was
// panned when the series were locked and the pan its own zooms moved, which
// the pan going between viewers leaves out. The process graph makes one; the
// viewers read and write it on the main actor, through
// ViewerSettingsPropagator and ViewerFusion, and the other windows through
// ViewerController's class methods.

/// The synchronization state of the process's 2D viewers.
@MainActor final class ViewerSyncState {

    /// Whether the series of viewers of different studies are locked at their
    /// offsets (SYNCSERIES).
    var seriesLocked = false

    /// Whether the "Sync" button works between studies: the other displayed
    /// viewers were not all of the key viewer's study when it was worked out.
    /// It is the C global the former plugin SDK published, which a plugin may set.
    var betweenStudies: Bool {
        get { SyncButtonBehaviorIsBetweenStudies.boolValue }
        set { SyncButtonBehaviorIsBetweenStudies = ObjCBool(newValue) }
    }

    /// Where each view was panned when the series were locked, in pixels of
    /// its image; a view that is gone leaves no entry behind.
    private let lockPans = NSMapTable<NSView, NSValue>.weakToStrongObjects()

    func lockPan(of view: NSView) -> CGPoint {
        lockPans.object(forKey: view)?.pointValue ?? .zero
    }

    func setLockPan(_ pan: CGPoint, of view: NSView) {
        lockPans.setObject(NSValue(point: pan), forKey: view)
    }

    /// What the settings last saw of each view's zoom and pan, and how far the
    /// zooms kept to it have moved its pan; a view that is gone leaves no
    /// entry behind.
    private let zoomPans = NSMapTable<NSView, ZoomPanEntry>.weakToStrongObjects()

    private final class ZoomPanEntry {
        let zoomPan: SettingsPropagation.ZoomPan
        init(_ zoomPan: SettingsPropagation.ZoomPan) { self.zoomPan = zoomPan }
    }

    /// Nil for a view the settings have not seen yet.
    func zoomPan(of view: NSView) -> SettingsPropagation.ZoomPan? {
        zoomPans.object(forKey: view)?.zoomPan
    }

    func setZoomPan(_ zoomPan: SettingsPropagation.ZoomPan, of view: NSView) {
        zoomPans.setObject(ZoomPanEntry(zoomPan), forKey: view)
    }

    /// The viewer an image is dragged from, to fuse it with the viewer it is
    /// dropped on; not retained, and nil once that viewer is gone.
    weak var draggedViewer: ViewerController?

    /// Made with the process graph, from any thread.
    nonisolated init() {}
}
