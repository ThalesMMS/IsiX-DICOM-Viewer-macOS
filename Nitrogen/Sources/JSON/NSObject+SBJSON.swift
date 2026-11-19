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

// NSObject (NSObject_SBJSON) is implemented in Swift; the selectors
// and <Horos/NSObject+SBJSON.h> are those of the category the vendored SBJson
// framework added.
//
// The web portal sends [x JSONRepresentation] to browsers, so the output keeps
// the bytes SBJsonWriter wrote with its defaults. SBJsonCompatibleWriter
// (SBJsonWriter.swift), which the SBJsonWriter class writes with too, follows
// SBJsonWriter.m rule by rule.

public extension NSObject {

    /// A string containing the receiver encoded as a JSON fragment: an
    /// NSDictionary, NSArray, NSString, NSNumber (also used for booleans) or
    /// NSNull. Nil, and a log line, when the receiver cannot be written.
    @objc(JSONFragment)
    func jsonFragment() -> NSString? {
        let writer = SBJsonCompatibleWriter()
        let json = writer.string(withFragment: self)
        if json == nil {
            NSLog("-JSONFragment failed. Error trace is: %@", writer.errorTraceDescription)
        }
        return json
    }

    /// A string containing the receiver encoded in JSON; only an NSDictionary
    /// or an NSArray is. Nil, and a log line, otherwise.
    @objc(JSONRepresentation)
    func jsonRepresentation() -> NSString? {
        let writer = SBJsonCompatibleWriter()
        let json = writer.string(withObject: self)
        if json == nil {
            NSLog("-JSONRepresentation failed. Error trace is: %@", writer.errorTraceDescription)
        }
        return json
    }
}
