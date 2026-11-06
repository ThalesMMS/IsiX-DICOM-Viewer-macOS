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

// The synchronization of 2D viewers: what the "Sync" button of the toolbar
// does (between viewers of one study it switches the view's own syncro mode;
// across studies it locks the series at their current offset). The settings
// one viewer hands on to another (window level, zoom, pan, rotation) are
// SettingsPropagation's. The viewers apply them; these are the rules.

public enum ViewerSynchronization {

    /// Whether the "Sync" button works between studies: when the other
    /// displayed viewers are not all of `study`. A viewer without a study is of
    /// none (NSString equality, false with nil on either side).
    public static func syncsBetweenStudies(study: String?, otherStudies: [String?]) -> Bool {
        otherStudies.contains { !same(study, $0) }
    }

    /// What a viewer shows, as synchronization places it: its study and the
    /// frame of reference of its series.
    public struct World: Sendable, Equatable {
        public var study: String?
        public var frameOfReference: String?

        public init(study: String?, frameOfReference: String?) {
            self.study = study
            self.frameOfReference = frameOfReference
        }
    }

    /// Whether the "Sync" button locks the series at their current offset
    /// instead of switching the syncro mode: when the other displayed viewers
    /// are not all of this one's study, and, where the frame of reference
    /// counts, of its frame. Two series of one study in different frames (a
    /// colonography supine and prone) do not follow each other by location,
    /// and with the button of a single study nothing else linked them.
    /// Frames are compared when both are known.
    public static func syncsBetweenWorlds(_ world: World, others: [World], usesFrameOfReference: Bool) -> Bool {
        others.contains { other in
            if !same(world.study, other.study) { return true }
            guard usesFrameOfReference else { return false }
            let frame = (world.frameOfReference ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let otherFrame = (other.frameOfReference ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !frame.isEmpty && !otherFrame.isEmpty && frame != otherFrame
        }
    }

    /// Whether the series lock is reset after the button's behaviour is worked
    /// out again: always when it works within a study, and when it has just
    /// started working between studies.
    public static func resetsSeriesLock(betweenStudies: Bool, wasBetweenStudies: Bool) -> Bool {
        (betweenStudies && !wasBetweenStudies) || !betweenStudies
    }

    /// NSString equality, as -isEqualToString: answers it (false with nil).
    public static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return (a as NSString).isEqual(to: b)
    }
}
