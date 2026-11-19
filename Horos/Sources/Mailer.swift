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

/// Why Mail did not make the message: the number of the error the script
/// ended with.
public struct MailerFailure: Error, Equatable, Sendable {
    public let number: Int

    public init(number: Int) {
        self.number = number
    }

    /// What the user is told: the text the drafts of the other exports have
    /// for the same error of Mail.
    public var message: String {
        MailDraftComposer.message(errorInfo: [NSAppleScript.errorNumber: number], result: nil) ?? ""
    }
}

/// Opens a new outgoing message in Mail, with an image attached, through an
/// AppleScript. The 3D and MPR viewers use it for their Email export.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/Mailer.h> are those of the former class.
@objc(Mailer)
public final class Mailer: NSObject {
    /// myComponent of an older header of the former Horos and OsiriX plugin
    /// SDK, exported at this field's offset for the plugins built with it: the
    /// scripting component of the Component Manager the script once ran in.
    /// The script runs in NSAppleScript: nothing here reads or writes it.
    final var myComponent: UnsafeMutableRawPointer?

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
            // A quote or a backslash in the path would end the script's
            // string or escape what follows it.
            let quoted = imagePath.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            s.append(String(format: "set aFile to \"%@\"\n", quoted))
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

    /// Makes the message with the image attached and answers why Mail did not
    /// make it, nil when it did. Mail is looked for first: a script that names
    /// an application that is not installed may ask the user where it is.
    public func mailFailure(image imagePath: String?, mailInstalled: Bool = Mailer.isMailInstalled) -> MailerFailure? {
        guard mailInstalled else { return MailerFailure(number: Int(procNotFound)) }
        return failure(running: mailScriptBody("--", to: "--", subject: "", isMIME: true, name: "--", sendNow: false, image: imagePath))
    }

    /// Makes the message with the image attached and tells the user when Mail
    /// did not make it: every window that e-mails its image ends here, so
    /// none fails in silence.
    @MainActor public func mailShowingFailure(image imagePath: String?) {
        guard let failure = mailFailure(image: imagePath) else { return }
        HorosAlertPanel.run(title: NSLocalizedString("Email Export Failed", comment: ""), message: failure.message, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    public static var isMailInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: MailDraftComposer.mailBundleIdentifier) != nil
    }

    @objc(runScript:)
    public func runScript(_ txt: String!) {
        _ = failure(running: txt)
    }

    /// Runs the script and answers the error it ended with, nil when it ended well.
    func failure(running txt: String?) -> MailerFailure? {
        // A nil source made a nil script, and the messages to it did nothing.
        let script = txt.flatMap { NSAppleScript(source: $0) }
        var errs: NSDictionary? = nil
        script?.run(withArguments: nil, error: &errs)
        guard let errs, errs.count > 0 else { return nil }
        NSLog("Error: AppleScript execution failed: %@", errs)
        return MailerFailure(number: (errs[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0)
    }
}
