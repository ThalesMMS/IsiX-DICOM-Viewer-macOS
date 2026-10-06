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

/// Opens a new outgoing message in Mail, with an image attached, through an
/// AppleScript. The 3D and MPR viewers use it for their Email export.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/Mailer.h> are those of the former class.
@objc(Mailer)
public final class Mailer: NSObject {

    /// The AppleScript that makes the message. Only the attachment is used:
    /// the other arguments were already ignored.
    @objc(mailScriptBody:to:subject:isMIME:name:sendNow:image:)
    public func mailScriptBody(_ body: String!, to: String!, subject: String!, isMIME: Bool, name clientName: String!, sendNow sendWithoutUserReview: Bool, image imagePath: String!) -> String! {
        let s = NSMutableString(capacity: 1000)

        s.append("tell application \"Mail\"\n")
        s.append("activate\n")

        s.append("set composeMessage to make new outgoing message with properties {visible:true}\n")

        s.append("tell composeMessage\n")

        if isMIME, let imagePath = imagePath, FileManager.default.fileExists(atPath: imagePath) {
            s.append(String(format: "set aFile to \"%@\"\n", imagePath))
            s.append("tell content\n")
            s.append("make new attachment with properties {file name:aFile}\n")
            s.append("end tell\n")
        }
        s.append("end tell\n")
        s.append("end tell\n")

        NSLog("%@", s)

        return s as String
    }

    @objc(sendMail:to:subject:isMIME:name:sendNow:image:)
    public func sendMail(_ richBody: String!, to: String!, subject: String!, isMIME: Bool, name client: String!, sendNow sendWithoutUserReview: Bool, image imagePath: String!) -> Bool {
        runScript(mailScriptBody(richBody, to: to, subject: subject, isMIME: isMIME, name: client, sendNow: sendWithoutUserReview, image: imagePath))
        return true
    }

    @objc(runScript:)
    public func runScript(_ txt: String!) {
        // A nil source made a nil script, and the messages to it did nothing.
        guard let txt = txt, let script = NSAppleScript(source: txt) else { return }
        var errs: NSDictionary? = nil
        script.run(withArguments: nil, error: &errs)
        if let errs = errs, errs.count > 0 {
            NSLog("Error: AppleScript execution failed: %@", errs)
        }
    }
}
