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

/// When the application looks for a new release by itself, and which release
/// it offers then.
///
/// With the automatic checks on (CheckHorosUpdates) and the listener errors
/// shown, it checks once, at launch. With the checks off, or in the server
/// mode that hides the listener errors, where nobody would be told of a
/// release, it does not read the feed at all. Nothing follows the launch: no
/// check is repeated while the application runs, and a preference changed
/// meanwhile counts from the next launch, which is what the option's label
/// says ("at startup time"). A check asked from the menu is outside these
/// rules: it always reads the feed and always tells its result.
public enum UpdateCheckSchedule {

    /// Whether this launch reads the feed.
    public static func checksAtLaunch(automaticChecks: Bool, listenerErrorsHidden: Bool) -> Bool {
        automaticChecks && !listenerErrorsHidden
    }

    /// Whether an automatic check offers a release the feed reports: not the
    /// one the user chose to skip, nor an earlier one.
    ///
    /// - Parameters:
    ///   - build: the build number of the release, digits only.
    ///   - skippedBuild: the build the user skipped (SkippedUpdateBuild), nil
    ///     when none was. Build numbers are compared as integers; a stored
    ///     value that is not a number skips nothing.
    public static func offersAutomatically(build: String, skippedBuild: String?) -> Bool {
        guard let skipped = skippedBuild.flatMap({ Int64($0) }), let available = Int64(build) else { return true }
        return available > skipped
    }

    /// Whether a launch asks the user to choose the automatic checks: only the
    /// first launch of an installation whose preferences are new, of a copy
    /// that can be told of a release, and only when nobody chose yet.
    ///
    /// - Parameters:
    ///   - launchCount: the launch counter as this launch read it. It is 1 until
    ///     a launch has stored it, and preferences brought from an earlier
    ///     installation bring their own count.
    ///   - choiceAlreadyMade: the preference was given to this launch, is stored
    ///     for the application, or is imposed by a managed profile.
    ///   - releaseCopy: a development copy is never told of a release by itself.
    ///   - appStore: the App Store updates its own copies.
    ///   - protectedMode: that launch runs no automatic check.
    ///   - serverMode: the mode that hides the listener errors shows no alert.
    public static func asksAtFirstLaunch(launchCount: Int, choiceAlreadyMade: Bool, releaseCopy: Bool,
                                         appStore: Bool, protectedMode: Bool, serverMode: Bool) -> Bool {
        launchCount == 1 && !choiceAlreadyMade && releaseCopy && !appStore && !protectedMode && !serverMode
    }
}
