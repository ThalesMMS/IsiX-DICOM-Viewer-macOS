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
/*

NSAppleScript+HandlerCalls.m
ASHandlerTest
by Buzz Andersen

More information at: http://www.scifihifi.com/weblog/mac/Cocoa-AppleEvent-Handlers.html

This work is licensed under the Creative Commons Attribution License. To view a copy of this license, visit

http://creativecommons.org/licenses/by/1.0/

or send a letter to Creative Commons, 559 Nathan Abbott Way, Stanford,
California 94305, USA.

*/

import Foundation
import Carbon

// NSAppleScript (HandlerCalls) is implemented in Swift since #716; the
// selectors and <Horos/NSAppleScript+HandlerCalls.h> are those of the former
// category.

public extension NSAppleScript {

    @objc(callHandler:withArguments:errorInfo:)
    func callHandler(_ handler: String!, withArguments arguments: NSAppleEventDescriptor!,
                     errorInfo: AutoreleasingUnsafeMutablePointer<NSDictionary?>?) -> NSAppleEventDescriptor? {
        /* This will be a self-targeted AppleEvent, so we need to identify ourselves using our process id */
        var pid = ProcessInfo.processInfo.processIdentifier
        let targetAddress = NSAppleEventDescriptor(descriptorType: DescType(typeKernelProcessID), bytes: &pid, length: MemoryLayout.size(ofValue: pid))

        /* Set up our root AppleEvent descriptor: a subroutine call (psbr) */
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: targetAddress, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))

        /* Set up an AppleEvent descriptor containing the subroutine (handler) name */
        // +descriptorWithString:nil is an empty string.
        let subroutineDescriptor = NSAppleEventDescriptor(string: handler ?? "")
        event.setParam(subroutineDescriptor, forKeyword: AEKeyword(keyASSubroutineName))

        /* Add the provided arguments to the handler call */
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))

        /* Execute the handler */
        return executeAppleEvent(event, error: errorInfo)
    }

    @objc(mailExportErrorMessage:result:)
    class func mailExportErrorMessage(_ errorInfo: NSDictionary?, result: NSAppleEventDescriptor?) -> String? {
        if errorInfo == nil && result == nil {
            return NSLocalizedString("IsiX DICOM Viewer could not prepare the Mail draft. Check that Mail is available and retry the export. If the problem persists, reinstall IsiX DICOM Viewer to restore its Mail export script.", comment: "")
        }
        let code: Int
        if let errorInfo {
            // -integerValue of whatever the dictionary holds: 0 when it holds nothing.
            code = (errorInfo.object(forKey: NSAppleScript.errorNumber) as AnyObject?)?.integerValue ?? 0
        } else {
            code = Int(result!.int32Value)
        }
        if errorInfo == nil && result != nil && code == 0 { return nil }
        if code == -1743 || code == -1744 {
            return NSLocalizedString("Mail access was denied. Allow IsiX DICOM Viewer to control Mail in System Settings > Privacy & Security > Automation, then retry the export.", comment: "")
        }
        if code == -1712 {
            return NSLocalizedString("IsiX DICOM Viewer did not receive a reply from Mail in time (error -1712). If macOS asked for Automation permission, allow IsiX DICOM Viewer to control Mail in System Settings > Privacy & Security > Automation, then retry. Check Mail and any draft already opened; attachments may be incomplete.", comment: "")
        }
        return String(format: NSLocalizedString("IsiX DICOM Viewer could not finish creating the Mail draft (error %ld). Check Mail and any draft already opened before retrying; attachments may be incomplete.", comment: ""), code)
    }
}
