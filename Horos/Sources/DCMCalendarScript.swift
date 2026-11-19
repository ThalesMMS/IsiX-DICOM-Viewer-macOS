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

/** \brief Runs applescript interaction with iCal

 The implementation of DCMCalendarScript, declared in DCMCalendarScript.h:
 the class of the Horos and OsiriX plugin SDK that asked a script of the
 Calendar application for routing destinations. It keeps the name of the
 calendar it was made with and answers no destination.
 */
@objc @implementation extension DCMCalendarScript {
    /// The calendar the script was to read, as -initWithCalendar: was given it.
    private final var calendar: String?

    /// The instance variable of the SDK: the script compiled for that
    /// calendar. No script is compiled, and it stays nil; a plugin built for
    /// the SDK binds its name when it loads.
    final var compiledScript: NSAppleScript?

    override init() {
        super.init()
    }

    init!(calendar: String!) {
        self.calendar = calendar
        super.init()
    }

    /// nil: the script that named the destinations is not among the
    /// application's resources, and was not among those of Horos.
    func routingDestination() -> NSMutableArray! {
        FormerSDKFacade.inert("DCMCalendarScript", "-routingDestination",
                              because: "the calendar script that named the routing destinations is not part of the application")
        return nil
    }
}
