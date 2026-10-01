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

//
//  AYDicomPrintPref.swift
//  AYDicomPrint
//
//  Created by Tobias Hoehmann on 12.06.06.
//  Copyright (c) 2006 aycan digitalsysteme gmbh. All rights reserved.
//

import Cocoa
import UniformTypeIdentifiers
import PreferencePanes

/// The former `[a isEqualToString: b]` on two values of a dictionary: NO when
/// either is nil or not a string.
private func isEqualString(_ a: Any?, _ b: Any?) -> Bool {
    guard let a = a as? NSString, let b = b as? NSString else { return false }
    return a.isEqual(to: b as String)
}

/// The DICOM Print preference pane.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors,
/// the xib outlets and <Horos/AYDicomPrintPref.h> are those of the former
/// class.
// Main actor: a preferences pane, which the preferences window creates, shows
// and hides on the main thread. Its NSPreferencePane overrides, nonisolated in
// the SDK, run their bodies on the main actor through assumeMainActor.
@MainActor
@objc(AYDicomPrintPref)
public final class AYDicomPrintPref: NSPreferencePane {
    private var m_PrinterDefaults: NSArray?
    @IBOutlet var m_PrinterController: NSArrayController?
    @IBOutlet var mainWindow: NSWindow?

    private var _tlos: NSArray?

    /// -init, which the former class inherited from NSObject: a pane without
    /// its nib, as before.
    public override init() {
        super.init()
    }

    @objc(initWithBundle:)
    public override init(bundle: Bundle) {
        // The former -initWithBundle: called -[super init]: the pane keeps no bundle.
        super.init()
        assumeMainActor(self) { $0.finishInitOnMainActor() }
    }

    private func finishInitOnMainActor() {
        let nib = NSNib(nibNamed: "AYDicomPrintPref", bundle: nil)
        nib?.instantiate(withOwner: self, topLevelObjects: &_tlos)

        if let contentView = mainWindow?.contentView {
            self.mainView = contentView
        }
        self.mainViewDidLoad()
    }

    isolated deinit {
        m_PrinterDefaults = nil
        _tlos = nil
    }

    public override func willUnselect() {
        assumeMainActor(self) { $0.willUnselectOnMainActor() }
    }

    private func willUnselectOnMainActor() {
        self.mainView.window?.makeFirstResponder(nil)
    }

    public override func awakeFromNib() {
        assumeMainActor(self) { $0.awakeFromNibOnMainActor() }
    }

    private func awakeFromNibOnMainActor() {
        AYDicomPrintWindowController.updateAllPreferencesFormat()

        // select default printer
        let printer = (m_PrinterController?.arrangedObjects as? NSArray) ?? NSArray()

        for i in 0..<printer.count {
            let printerDict = printer.object(at: i) as! NSObject

            if isEqualString(printerDict.value(forKey: "defaultPrinter"), "1") {
                m_PrinterController?.setSelectionIndex(i)
                break
            }
        }

        // set printer defaults for undo
        if let defaults = UserDefaults.standard.object(forKey: "AYDicomPrinter") as? [Any] {
            m_PrinterDefaults = NSArray(array: defaults)
        }
    }

    @objc(saveList:)
    @IBAction public func saveList(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "plist")!]
        panel.nameFieldStringValue = NSLocalizedString("DICOMPrinters.plist", comment: "")

        panel.begin { result in
            if result != .OK {
                return
            }

            (self.m_PrinterController?.arrangedObjects as? NSArray)?.write(to: panel.url!, atomically: true)
        }
    }

    @objc(loadList:)
    @IBAction public func loadList(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "plist")!]

        panel.begin { result in
            if result != .OK {
                return
            }

            guard let r = NSArray(contentsOf: panel.url!) else {
                return
            }

            if HorosAlertPanel.runInformational(title: NSLocalizedString("Load printers", comment: ""),
                                                message: NSLocalizedString("Should I add or replace the printer list? If you choose 'replace', the current list will be deleted.", comment: ""),
                                                defaultButton: NSLocalizedString("Add", comment: ""),
                                                alternateButton: NSLocalizedString("Replace", comment: ""),
                                                otherButton: nil) == HorosAlertPanel.defaultResponse {

            } else {
                self.m_PrinterController?.remove(contentsOf: (self.m_PrinterController?.arrangedObjects as? [Any]) ?? [])
            }

            self.m_PrinterController?.add(contentsOf: r as! [Any])

            @MainActor func arranged() -> NSArray {
                return (self.m_PrinterController?.arrangedObjects as? NSArray) ?? NSArray()
            }

            var i = 0
            while i < arranged().count {
                let server = arranged().object(at: i) as! NSObject

                var x = 0
                while x < arranged().count {
                    let c = arranged().object(at: x) as! NSObject

                    if c !== server {
                        if isEqualString(server.value(forKey: "host"), c.value(forKey: "host")) &&
                            isEqualString(server.value(forKey: "port"), c.value(forKey: "port")) {
                            self.m_PrinterController?.remove(atArrangedObjectIndex: i)
                            i -= 1
                            x = arranged().count
                        }
                    }
                    x += 1
                }
                i += 1
            }
        }
    }

    @objc(addPrinter:)
    @IBAction public func addPrinter(_ sender: Any?) {
        let printerCount = Int32(truncatingIfNeeded: ((m_PrinterController?.arrangedObjects as? NSArray)?.count ?? 0) + 1)
        let printer = NSMutableDictionary()

        // add default printer with default values
        printer.setValue(String(format: "Printer %d", printerCount), forKey: "printerName")
        printer.setValue("localhost", forKey: "host")
        printer.setValue("4080", forKey: "port")
        printer.setValue(String(format: "Printer_%d", printerCount), forKey: "aeTitle")

        printer.setValue("0", forKey: "imageDisplayFormatTag")
        printer.setValue("0", forKey: "borderDensityTag")
        printer.setValue("0", forKey: "emptyImageDensityTag")
        printer.setValue("0", forKey: "filmOrientationTag")
        printer.setValue("0", forKey: "filmDestinationTag")
        printer.setValue("0", forKey: "magnificationTypeTag")
        printer.setValue("0", forKey: "trimTag")
        printer.setValue("0", forKey: "filmSizeTag")
        printer.setValue("", forKey: "configurationInformation")
        printer.setValue("0", forKey: "priorityTag")
        printer.setValue("0", forKey: "mediumTag")
        printer.setValue("1", forKey: "copies")

        // add new printer & select it
        m_PrinterController?.addObject(printer)
        m_PrinterController?.setSelectedObjects([printer])

        // if it is the first printer added, set it as default
        if (m_PrinterController?.arrangedObjects as? NSArray)?.count == 1 {
            self.setDefaultPrinter(nil)
        }
    }

    @objc(setDefaultPrinter:)
    @IBAction public func setDefaultPrinter(_ sender: Any?) {
        // set new default printer
        let printer = (m_PrinterController?.arrangedObjects as? NSArray) ?? NSArray()

        for i in 0..<printer.count {
            // Sent as the former -removeObjectForKey: was, whatever the class of the entry.
            _ = (printer.object(at: i) as! NSObject).perform(#selector(NSMutableDictionary.removeObject(forKey:)), with: "defaultPrinter")
        }

        if let printerDict = m_PrinterController?.selection as? NSObject {
            printerDict.setValue("1", forKey: "defaultPrinter")
        }
    }
}
