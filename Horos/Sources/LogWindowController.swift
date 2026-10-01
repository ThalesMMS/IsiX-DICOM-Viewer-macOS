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
import UniformTypeIdentifiers

/// The window of the network logs (LogWindow.xib): receive, send, move and web
/// tables, each exported as CSV.
///
/// Implemented in Swift since #713: the Objective-C name, the selectors and
/// <Horos/LogWindowController.h> are those of the former class, the File's
/// Owner of LogWindow.xib.
@objc(LogWindowController)
public final class LogWindowController: NSWindowController {
    // Outlets the xib sets: ivars of the former class.
    @IBOutlet @objc var receive: NSArrayController!
    @IBOutlet @objc var move: NSArrayController!
    @IBOutlet @objc var send: NSArrayController!
    @IBOutlet @objc var web: NSArrayController!

    @IBAction @objc(export:)
    public func export(_ sender: Any!) {
        var a: [Any]? = nil
        var filename: String? = nil

        switch (sender as? NSObject)?.value(forKey: "tag") as? Int ?? 0 {
        case 1: a = receive?.arrangedObjects as? [Any]; filename = "ReceiveLog.csv"
        case 2: a = send?.arrangedObjects as? [Any]; filename = "SendLog.csv"
        case 3: a = move?.arrangedObjects as? [Any]; filename = "MoveLog.csv"
        case 4: a = web?.arrangedObjects as? [Any]; filename = "WebLog.csv"
        default: break
        }

        let csv = NSMutableString()

        // The attribute names in the order of the model's own dictionary, as
        // before: read through KVC so no bridged copy reorders them.
        let entity = BrowserController.currentBrowser()?.database?.managedObjectModel?.entitiesByName["LogEntry"]
        let logEntries = ((entity?.value(forKey: "attributesByName") as? NSDictionary)?.allKeys as? [String]) ?? []

        // HEADER
        var line = NSMutableString()
        for name in logEntries {
            line.append(name)
            line.append(",")
        }
        line.deleteCharacters(in: NSMakeRange(line.length - 1, 1))
        csv.append(line as String)
        csv.append("\n")

        for case let o as NSManagedObject in a ?? [] {
            line = NSMutableString()
            for name in logEntries {
                if let value = o.value(forKey: name) {
                    if let date = value as? Date {
                        line.append((UserDefaults.dateTimeFormatter().string(from: date) as NSString)
                            .replacingOccurrences(of: ",", with: " "))
                    } else {
                        line.append((String(describing: value as AnyObject) as NSString)
                            .replacingOccurrences(of: ",", with: " "))
                    }
                } else {
                    line.append("void")
                }

                line.append(",")
            }
            line.deleteCharacters(in: NSMakeRange(line.length - 1, 1))

            csv.append(line as String)
            csv.append("\n")
        }

        let savePanel = NSSavePanel()

        savePanel.allowedContentTypes = [UTType(filenameExtension: "csv")!]

        // The xib's four buttons have tags 1 to 4; another tag named no file.
        if let filename = filename {
            savePanel.nameFieldStringValue = filename
        }

        savePanel.begin { result in
            if result != .OK {
                return
            }

            if let url = savePanel.url {
                try? csv.write(to: url, atomically: true, encoding: String.Encoding.utf8.rawValue)
            }
        }
    }

    /// [super initWithWindowNibName:@"LogWindow"], which goes through
    /// -initWithWindow: as before.
    @objc public convenience init() {
        self.init(windowNibName: "LogWindow")
    }

    /// Overridden so that -initWithWindowNibName: is inherited, unchanged.
    public override init(window: NSWindow?) {
        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Does not call super, as the former class did not.
    public override func awakeFromNib() {
        _ = MainActor.assumeIsolated {
            window?.setFrameAutosaveName("LogWindow")
        }
    }

    deinit {
        NSLog("LogWindowController dealloc")
    }

    @IBAction public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)

        if (BrowserController.currentBrowser()?.isNetworkLogsActive() ?? false) == false {
            if HorosAlertPanel.runInformational(title: NSLocalizedString("Network Logs", comment: ""),
                                                message: NSLocalizedString("Network Logs are currently off. Do you want to activate them?\r\rYou can activate or de-activate them in the Preferences - Listener window.", comment: ""),
                                                defaultButton: NSLocalizedString("Activate", comment: ""),
                                                alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                otherButton: nil) == 1 {
                UserDefaults.standard.set(true, forKey: "NETWORKLOGS")
                BrowserController.currentBrowser()?.setNetworkLogs()
            }
        }
    }
}
