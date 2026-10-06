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

/// Import into Photos.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/Photos.h> are those of the former class.
@objc(Photos)
public final class Photos: NSObject {

    /// "%@" of an object, "(null)" for nil, as the former format strings wrote them.
    private func formatted(_ object: Any?) -> NSString {
        guard let object else { return "(null)" }
        return NSString(format: "%@", object as AnyObject as! CVarArg)
    }

    @objc(scriptBody:)
    func scriptBody(_ files: [Any]!) -> String! {
        let albumNameStr = UserDefaults.standard.string(forKey: "ALBUMNAME")
        let albumName = formatted(albumNameStr)

        let s = NSMutableString(capacity: 1000)

        s.append("tell application \"Photos\"\n")

        s.append(NSString(format: "if not (exists album \"%@\") then \n", albumName) as String)
        s.append(NSString(format: "make new album named \"%@\" \n", albumName) as String)
        s.append("end if \n")
        s.append(NSString(format: "set this_album to album \"%@\" \n", albumName) as String)

        for loopItem in files ?? [] {
            s.append(NSString(format: "import (POSIX file \"%@\" as alias) into this_album skip check duplicates yes \n", formatted(loopItem)) as String)
        }

        s.append("end tell \n")

        return s as String
    }

    @objc(importInPhotos:) @discardableResult
    public func importInPhotos(_ files: [Any]!) -> Bool {
        runScript(scriptBody(files))
        return true
    }

    public override init() {
        super.init()
    }

    // do the grunge work -
    // the sweetly wrapped method is all we need to know:

    @objc(runScript:)
    public func runScript(_ txt: String!) {
        // -initWithSource: with a nil source gave a nil script, which ran nothing.
        let script = txt.flatMap { NSAppleScript(source: $0) }
        var errs: NSDictionary? = nil
        script?.run(withArguments: nil, error: &errs)
        if let errs, errs.count > 0 {
            NSLog("Error: AppleScript execution failed: %@", errs)
        }
    }
}
