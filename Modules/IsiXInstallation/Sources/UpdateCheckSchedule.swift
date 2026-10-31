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

/// When the application looks for a new release by itself.
///
/// With the automatic checks on (CheckHorosUpdates), it checks at launch and
/// then every hour. With them off it asks the preference again every minute,
/// and checks as soon as they are turned on. After a crash with the automatic
/// checks off it checks once, so that a user running an outdated version hears
/// of the release that may fix it; with them on, that launch checks nothing.
public enum UpdateCheckSchedule {

    /// The time between two automatic checks.
    public static let interval: TimeInterval = 3600
    /// The time between two reads of the preference while the checks are off.
    public static let retry: TimeInterval = 60

    /// What the launch does.
    public enum LaunchCheck: Sendable, Equatable {
        /// Start the automatic checks with one now.
        case automatic
        /// Check once, as after a crash: a newer release is offered, nothing
        /// is said when there is none, and no automatic check follows.
        case afterCrash
        /// Nothing.
        case none
    }

    /// The next step of the automatic checks.
    public enum Step: Sendable, Equatable {
        /// Check after this many seconds.
        case check(after: TimeInterval)
        /// Read the preference again after this many seconds.
        case wait(after: TimeInterval)
    }

    /// What a launch does after a crash marker was found (`crashed`) or not.
    public static func atLaunch(crashed: Bool, automaticChecks: Bool, listenerErrorsHidden: Bool) -> LaunchCheck {
        guard crashed else { return .automatic }
        return !automaticChecks && !listenerErrorsHidden ? .afterCrash : .none
    }

    /// The step after an automatic check.
    public static func afterCheck(automaticChecks: Bool) -> Step {
        automaticChecks ? .check(after: interval) : .wait(after: retry)
    }

    /// The step after a read of the preference while the checks were off.
    public static func afterWait(automaticChecks: Bool) -> Step {
        automaticChecks ? .check(after: 0) : .wait(after: retry)
    }
}
