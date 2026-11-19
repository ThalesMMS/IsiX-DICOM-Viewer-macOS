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
import IsiXPreferences

/// Why an import into Photos did not happen: the number and the message of
/// the error the script ended with.
public struct PhotosImportFailure: Error, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// macOS does not let the application send Apple Events to Photos:
        /// the user refused it, or the application has no right to ask.
        case automationNotPermitted
        /// Photos is not installed, or could not be opened.
        case photosUnavailable
        /// Anything else: the answer is the system's own message.
        case other
    }

    public let number: Int
    public let systemMessage: String?

    public init(number: Int, systemMessage: String? = nil) {
        self.number = number
        self.systemMessage = systemMessage
    }

    public var reason: Reason {
        switch number {
        // errAEEventNotPermitted, errAEEventWouldRequireUserConsent and
        // errAEPrivilegeError, which a sandbox answers with.
        case -1743, -1744, -10004: return .automationNotPermitted
        // procNotFound, kLSUnknownErr and kLSApplicationNotFoundErr.
        case -600, -10810, -10814: return .photosUnavailable
        default: return .other
        }
    }

    /// What the user is told.
    public var message: String {
        switch reason {
        case .automationNotPermitted:
            return NSLocalizedString("Photos access was denied. Allow IsiX DICOM Viewer to control Photos in System Settings > Privacy & Security > Automation, then retry the export.", comment: "")
        case .photosUnavailable:
            return NSLocalizedString("Photos is not available. Check that Photos is installed and can be opened, then retry the export.", comment: "")
        case .other:
            guard let systemMessage, !systemMessage.isEmpty else {
                return String(format: NSLocalizedString("Photos could not import the images (error %ld).", comment: ""), number)
            }
            return String(format: NSLocalizedString("Photos could not import the images (error %ld).\n\n%@", comment: ""), number, systemMessage)
        }
    }
}

/// Import into Photos.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/Photos.h> are those of the former class.
@objc(Photos)
public final class Photos: NSObject {

    /// Where the album's name is read: the preferences of the process.
    private let preferences: any PreferenceStore = PreferencesSource.process.preferences

    /// "%@" of an object, "(null)" for nil, as the former format strings wrote them.
    private func formatted(_ object: Any?) -> NSString {
        guard let object else { return "(null)" }
        return NSString(format: "%@", object as AnyObject as! CVarArg)
    }

    /// A text as it goes between the quotes of a string of the script: a
    /// quote or a backslash in the album's name or in a path would end the
    /// string or escape what follows it.
    private static func scriptText(_ text: NSString) -> String {
        (text as String).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    @objc(scriptBody:)
    func scriptBody(_ files: [Any]!) -> String! {
        let albumNameStr = preferences[DatabasePreferences.albumName]
        let albumName = Self.scriptText(formatted(albumNameStr))

        let s = NSMutableString(capacity: 1000)

        s.append("tell application \"Photos\"\n")

        s.append(NSString(format: "if not (exists album \"%@\") then \n", albumName) as String)
        s.append(NSString(format: "make new album named \"%@\" \n", albumName) as String)
        s.append("end if \n")
        s.append(NSString(format: "set this_album to album \"%@\" \n", albumName) as String)

        for loopItem in files ?? [] {
            s.append(NSString(format: "import (POSIX file \"%@\" as alias) into this_album skip check duplicates yes \n", Self.scriptText(formatted(loopItem))) as String)
        }

        s.append("end tell \n")

        return s as String
    }

    @objc(importInPhotos:) @discardableResult
    public func importInPhotos(_ files: [Any]!) -> Bool {
        runScript(scriptBody(files))
        return true
    }

    /// Imports the files and answers why Photos did not take them, nil when
    /// it did. Photos is looked for first: a script that names an application
    /// that is not installed may ask the user where it is.
    public func importFailure(_ files: [Any], photosInstalled: Bool = Photos.isInstalled) -> PhotosImportFailure? {
        guard photosInstalled else { return PhotosImportFailure(number: Int(procNotFound)) }
        return failure(running: scriptBody(files))
    }

    /// Imports the files and tells the user when Photos did not take them:
    /// every window that exports to Photos ends here, so none fails in silence.
    @MainActor public func importShowingFailure(_ files: [Any]) {
        guard let failure = importFailure(files) else { return }
        HorosAlertPanel.run(title: NSLocalizedString("Photos Export Failed", comment: ""), message: failure.message, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    public static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") != nil
    }

    public override init() {
        super.init()
    }

    // do the grunge work -
    // the sweetly wrapped method is all we need to know:

    @objc(runScript:)
    public func runScript(_ txt: String!) {
        _ = failure(running: txt)
    }

    /// Runs the script and answers the error it ended with, nil when it ended well.
    func failure(running txt: String?) -> PhotosImportFailure? {
        // -initWithSource: with a nil source gave a nil script, which ran nothing.
        let script = txt.flatMap { NSAppleScript(source: $0) }
        var errs: NSDictionary? = nil
        script?.run(withArguments: nil, error: &errs)
        guard let errs, errs.count > 0 else { return nil }
        NSLog("Error: AppleScript execution failed: %@", errs)
        return PhotosImportFailure(number: (errs[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0,
                                   systemMessage: errs[NSAppleScript.errorMessage] as? String)
    }
}
