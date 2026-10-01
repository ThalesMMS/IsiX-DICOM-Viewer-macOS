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
import Carbon

// OsiriXScripts is implemented in Swift since #716. Horos.sdef names the class
// for its commands; the class name and <Horos/Scripting_Additions.h> are those
// of the former Objective-C class.

/** \brief  AppleScript functions */
// Main actor: AppleScript sends its commands on the main thread;
// -performDefaultImplementation, nonisolated in the SDK, runs its body there.
@MainActor
@objc(OsiriXScripts)
public final class OsiriXScripts: NSScriptCommand {

    @objc(posixStylePathFromHfsPath:isDirectory:)
    func posixStylePath(fromHfsPath s: String!, isDirectory: DarwinBoolean) -> String? {
        // kCFURLHFSPathStyle, which Swift marks unavailable; the value is the same.
        let hfsPathStyle = CFURLPathStyle(rawValue: 1)!
        guard let url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, s as CFString, hfsPathStyle, isDirectory.boolValue) else {
            fputs("Can't get URL.\n", stdout)
            return nil
        }

        if let hfsStyle = CFURLCopyFileSystemPath(url, .cfurlposixPathStyle) {
            return hfsStyle as String
        }

        return nil
    }

    public override func performDefaultImplementation() -> Any? {
        return assumeMainActor(self) { $0.performDefaultImplementationOnMainActor() }
    }

    private func performDefaultImplementationOnMainActor() -> Any? {
        var ASReply: Any? = nil
        let command = commandDescription.commandName

        NSLog("%@", command)

        if command == "SelectImageFile" {
            if let convertedPath = posixStylePath(fromHfsPath: arguments?["FileName"] as? String, isDirectory: false) {
                NSLog("%@", convertedPath)

                BrowserController.currentBrowser()?.addFilesAndFolder(toDatabase: [convertedPath])

                if BrowserController.currentBrowser()?.findAndSelectFile(convertedPath, image: nil, shouldExpand: true) == true {
                    NSLog("done!")
                }
            }
        }

        if command == "DownloadURLFile" {
            // +[NSURL URLWithString:], which parses as it did before.
            guard let url = (arguments?["URL"] as? String).flatMap({ NSURL(string: $0) }) else {
                scriptErrorNumber = Int(errOSAGeneralError)
                scriptErrorString = "Invalid URL."
                return nil
            }
            suspendExecution()
            BrowserController.currentBrowser()?.importURLs([url], completion: { files, report, succeeded in
                if (files?.count ?? 0) == 0 || !succeeded {
                    self.scriptErrorNumber = Int(errOSAGeneralError)
                    self.scriptErrorString = report ?? NSLocalizedString("Nothing could be downloaded from that URL.", comment: "")
                } else {
                    _ = BrowserController.currentBrowser()?.findAndSelectFile(files?[0] as? String, image: nil, shouldExpand: false)
                }
                self.resumeExecution(withResult: files)
            })
            return nil
        }

        if command == "OpenViewerForSelected" { BrowserController.currentBrowser()?.viewerDICOM(self) }
        if command == "DeleteSelected" { BrowserController.currentBrowser()?.delItem(self) }

        /*
         * Code added by Kanteron Systems
         */
        if command == "invoke XMLRPC method" {
            NSLog("invoke XMLRPC method")
            // The parameters are the first record of the list the sdef declares;
            // a lone record arrives wrapped in one, and an empty list is no
            // parameters. Cocoa converts only the records: any other item
            // arrives as it is, and the script gets an error for it.
            var parameters: [AnyHashable: Any]? = nil
            if let params = arguments?["XMLRPCParams"] {
                let first: Any?
                if let list = params as? NSArray { first = list.firstObject } else { first = params }
                if let first {
                    guard let record = first as? NSDictionary else {
                        scriptErrorNumber = Int(errAECoercionFail)
                        scriptErrorString = "The XMLRPC method parameters must be a record."
                        return nil
                    }
                    parameters = record as? [AnyHashable: Any]
                }
            }

            // The XMLRPC method is the direct parameter in AppleScript
            let xmlrpcMethodName = directParameter as? String

            ASReply = try? AppController.shared()?.xmlrpcServer?.methodCall(xmlrpcMethodName, parameters: parameters)
        }
        return ASReply
    }
}
