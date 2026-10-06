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

import Cocoa

/// One step of an N2Steps assistant: a title and the view that asks for it.
///
/// Implemented in Swift: the Objective-C name, the selectors
/// and `<Horos/N2Step.h>` are those of the former class. The notification
/// names stay in N2Step+CAPI.m.
@available(*, deprecated)
@objc(N2Step)
public final class N2Step: NSObject {
    private var titleStorage: String?
    private var activeStorage = false
    private var enabledStorage = false
    private var necessaryStorage = false
    private var doneStorage = false

    @objc public private(set) var enclosedView: NSView?
    @objc public dynamic var defaultButton: NSButton?
    @objc public dynamic var shouldStayVisibleWhenInactive = false

    @objc(initWithTitle:enclosedView:)
    public init(title: String?, enclosedView view: NSView?) {
        enclosedView = view
        titleStorage = title

        necessaryStorage = true
        activeStorage = false
        enabledStorage = true
        doneStorage = false
        super.init()
    }

    /// -[NSObject init], inherited in Objective-C: every flag is NO.
    @objc public override init() {
        super.init()
    }

    @objc public dynamic var title: String? {
        get { titleStorage }
        set {
            titleStorage = newValue
            NotificationCenter.default.post(name: .N2StepTitleDidChange, object: self)
        }
    }

    @objc public dynamic var necessary: Bool {
        @objc(isNecessary) get { necessaryStorage }
        set { necessaryStorage = newValue }
    }

    @objc public dynamic var active: Bool {
        @objc(isActive) get { activeStorage }
        set {
            //if activeStorage != newValue {
            activeStorage = newValue
            NotificationCenter.default.post(name: newValue ? .N2StepDidBecomeActive : .N2StepDidBecomeInactive, object: self)
            //}
        }
    }

    @objc public dynamic var enabled: Bool {
        @objc(isEnabled) get { enabledStorage }
        set {
            //if enabledStorage != newValue {
            if !newValue && activeStorage {
                active = false
            }
            enabledStorage = newValue
            NotificationCenter.default.post(name: newValue ? .N2StepDidBecomeEnabled : .N2StepDidBecomeDisabled, object: self)
            //}
        }
    }

    @objc public dynamic var done: Bool {
        @objc(isDone) get { doneStorage }
        set { doneStorage = newValue }
    }
}
