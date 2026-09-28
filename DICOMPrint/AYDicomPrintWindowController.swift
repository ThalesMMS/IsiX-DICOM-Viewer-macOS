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

// Template for DCMTK presentation state command-line applications (sample .cfg files in DCMTK source under dcmpstat/etc)
//
private let DCMTK_PRINTER_CONFIG_TEMPLATE = """

[[GENERAL]]

[DATABASE]
Directory = database

[NETWORK]
aetitle = {{HOROS_AETITLE}}

[[COMMUNICATION]]

[PRINTSCP]
Aetitle = {{PRINTER_AETITLE}}
Description = DICOM Printer
Hostname = {{HOST}}
Port = {{PORT}}
Type = LOCALPRINTER
DisableNewVRs = true
DisplayFormat={{COLUMNS}},{{ROWS}}
FilmDestination = {{FILM_DESTINATION}}
FilmSizeID = {{FILM_SIZE}}
ImplicitOnly = true
MagnificationType = {{MAGNIFICATION_TYPE}}
MaxDensity = 320
MaxPDU = 16384
MediumType = {{MEDIUM_TYPE}}
OmitSOPClassUIDFromCreateResponse = true
PresentationLUTMatchRequired = true
PresentationLUTinFilmSession = false
Supports12Bit = false
SupportsPresentationLUT = false
"""

private let DCMTK_LOGGER_CONFIG_TEMPLATE = """
log4cplus.rootLogger = INFO, logfile
log4cplus.appender.logfile = log4cplus::FileAppender
log4cplus.appender.logfile.File = {{LOG_DIRECTORY}}/print.log
log4cplus.appender.logfile.Append = true
log4cplus.appender.logfile.ImmediateFlush = true
"""

private let VERSIONNUMBERSTRING = "v1.00.000"

// MARK: Tables
// The tables of the former file. They were C arrays with external linkage that
// no header declared; the indexes are the tags the xib and the preferences store.
private let filmOrientationTag = ["Portrait", "Landscape"]
private let filmDestinationTag = ["Processor", "Magazine"]
private let filmSizeTag = ["8 IN x 10 IN", "8.5 IN x 11 IN", "10 IN x 12 IN", "10 IN x 14 IN", "11 IN x 14 IN", "11 IN x 17 IN", "14 IN x 14 IN", "14 IN x 17 IN", "24 CM x  24 CM", "24 CM x  30 CM", "A4", "A3"]
private let magnificationTypeTag = ["NONE", "BILINEAR", "CUBIC", "REPLICATE"]
private let trimTag = ["NO", "YES"]
private let imageDisplayFormatTag = ["Standard 1,1", "Standard 1,2", "Standard 2,1", "Standard 2,2", "Standard 2,3", "Standard 2,4", "Standard 3,3", "Standard 3,4", "Standard 3,5", "Standard 4,4", "Standard 4,5", "Standard 4,6", "Standard 5,6", "Standard 5,7"]
private let imageDisplayFormatNumbers: [Int32] = [1,2,2,4,6,8,9,12,15,16,20,24,30,35]
private let imageDisplayFormatRows: [Int32] =    [1,1,2,2,2,2,3, 3, 3, 4, 4, 4, 5, 5]
private let imageDisplayFormatColumns: [Int32] = [1,2,1,2,3,4,3, 4, 5, 4, 5, 6, 6, 7]
private let borderDensityTag = ["BLACK", "WHITE"]
private let emptyImageDensityTag = ["BLACK", "WHITE"]
private let priorityTag = ["HIGH", "MED", "LOW"]
private let mediumTag = ["Blue Film", "Clear Film", "Paper"]

/// `[[dict valueForKey: key] intValue]`
private func ayIntValue(_ dict: AnyObject?, _ key: String) -> Int32 {
    return (dict?.value(forKey: key) as AnyObject?)?.intValue ?? 0
}

/// `table[[[dict valueForKey: key] intValue]]`
private func ayTag<T>(_ table: [T], _ dict: AnyObject?, _ key: String) -> T {
    return table[Int(ayIntValue(dict, key))]
}

/// An argument of `%@`: nil is printed "(null)", as by -stringWithFormat:.
private func ayArg(_ value: Any?) -> CVarArg {
    if let value = value as AnyObject? as? NSObject { return value }
    if let value = value { return String(describing: value) as NSString }
    return "(null)" as NSString
}
// MARK: End of tables

/// -replaceOccurrencesOfString:withString:options:range: over the whole string,
/// with NSCaseInsensitiveSearch. A replacement that is not a string raises, as
/// Foundation did for the former nil or non-string value.
private func ayReplace(_ string: NSMutableString, _ target: String, _ replacement: Any?) {
    guard let replacement = replacement as? String else {
        NSException(name: .invalidArgumentException, reason: "*** -[__NSCFString replaceOccurrencesOfString:withString:options:range:]: nil argument", userInfo: nil).raise()
        return
    }
    string.replaceOccurrences(of: target, with: replacement, options: .caseInsensitive, range: NSMakeRange(0, string.length))
}

/// `-[NSMutableDictionary setObject:forKey:]` sent to an object typed `id`.
private func aySetObject(_ dictionary: Any?, _ object: Any, _ key: String) {
    guard let dictionary = dictionary as AnyObject? else { return }
    _ = dictionary.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: object, with: key)
}

/// C's int division and remainder, without Swift's trap: arm64 gives 0 for a
/// division by zero, and the dividend for its remainder.
private func ayDivide(_ a: Int32, _ b: Int32) -> Int32 {
    if b == 0 { return 0 }
    if b == -1 { return 0 &- a }
    return a / b
}

private func ayRemainder(_ a: Int32, _ b: Int32) -> Int32 {
    return a &- ayDivide(a, b) &* b
}

/// Window Controller for DICOM printing.
///
/// Implemented in Swift since #717: the Objective-C name, the selectors and
/// AYDicomPrintWindowController.h are those of the former class. It is the
/// File's Owner of AYDicomPrint.xib.
@objc(AYDicomPrintWindowController)
public final class AYDicomPrintWindowController: NSWindowController, NSWindowDelegate {
    private var m_PrinterOnImage: NSImage?
    private var m_PrinterOffImage: NSImage?
    /// Not retained by the former class (an ivar under manual retain/release):
    /// weak, so that a viewer closed meanwhile reads as nil.
    private weak var m_CurrentViewer: ViewerController?

    @IBOutlet var m_ImageSelection: NSMatrix?
    @IBOutlet var m_PrinterController: NSArrayController?

    @IBOutlet var m_ProgressSheet: NSPanel?
    @IBOutlet var m_ProgressMessage: NSTextField?
    @IBOutlet var m_ProgressTabView: NSTabView?
    @IBOutlet var m_ProgressOKButton: NSButton?
    @IBOutlet var m_ProgressIndicator: NSProgressIndicator?

    @IBOutlet var m_PrintButton: NSButton?
    @IBOutlet var m_ToggleDrawerButton: NSButton?
    @IBOutlet var m_VerifyConnectionButton: NSButton?

    @IBOutlet var entireSeriesBox: NSBox?
    @IBOutlet var entireSeriesInterval: NSSlider?, entireSeriesFrom: NSSlider?, entireSeriesTo: NSSlider?
    @IBOutlet var entireSeriesIntervalText: NSTextField?, entireSeriesFromText: NSTextField?, entireSeriesToText: NSTextField?
    @IBOutlet var m_pages: NSTextField?

    @IBOutlet var formatPopUp: NSPopUpButton?
    @IBOutlet var m_VersionNumberTextField: NSTextField?

    private var printing: NSLock?

    private var windowFrameToRestore = NSRect.zero
    private var scaleFitToRestore = false

    /// `+tagForKey:array:size:` of the former class, which took a C array.
    private static func tag(forKey v: Any?, array: [String]) -> String {
        for i in 0..<array.count {
            if (array[i] as NSString).isEqual(to: v as? String) {
                return String(format: "%d", Int32(i))
            }
        }

        NSLog("*** not found updateAllPreferencesFormat : %@", ayArg(v))

        return "0"
    }

    @objc public class func updateAllPreferencesFormat() {
        var updated = false
        let printers = (UserDefaults.standard.array(forKey: "AYDicomPrinter") as NSArray?)?.mutableCopy() as? NSMutableArray

        var i = 0
        while i < (printers?.count ?? 0) {
            let dict = printers!.object(at: i) as AnyObject

            if dict.value(forKey: "imageDisplayFormatTag") == nil {
                let mDict = NSMutableDictionary(dictionary: dict as! [AnyHashable: Any])

                mDict.setObject(AYDicomPrintWindowController.tag(forKey: dict.value(forKey: "filmOrientation"), array: filmOrientationTag), forKey: "filmOrientationTag" as NSString)

                mDict.setObject(AYDicomPrintWindowController.tag(forKey: dict.value(forKey: "filmDestination"), array: filmDestinationTag), forKey: "filmDestinationTag" as NSString)
                mDict.setObject(AYDicomPrintWindowController.tag(forKey: dict.value(forKey: "filmSize"), array: filmSizeTag), forKey: "filmSizeTag" as NSString)
                mDict.setObject(AYDicomPrintWindowController.tag(forKey: dict.value(forKey: "magnificationType"), array: magnificationTypeTag), forKey: "magnificationTypeTag" as NSString)
                mDict.setObject(AYDicomPrintWindowController.tag(forKey: dict.value(forKey: "trim"), array: trimTag), forKey: "trimTag" as NSString)
                mDict.setObject(AYDicomPrintWindowController.tag(forKey: dict.value(forKey: "imageDisplayFormat"), array: imageDisplayFormatTag), forKey: "imageDisplayFormatTag" as NSString)
                mDict.setObject(AYDicomPrintWindowController.tag(forKey: dict.value(forKey: "borderDensity"), array: borderDensityTag), forKey: "borderDensityTag" as NSString)
                mDict.setObject(AYDicomPrintWindowController.tag(forKey: dict.value(forKey: "emptyImageDensity"), array: emptyImageDensityTag), forKey: "emptyImageDensityTag" as NSString)
                mDict.setObject(AYDicomPrintWindowController.tag(forKey: dict.value(forKey: "priority"), array: priorityTag), forKey: "priorityTag" as NSString)
                mDict.setObject(AYDicomPrintWindowController.tag(forKey: dict.value(forKey: "medium"), array: mediumTag), forKey: "mediumTag" as NSString)

                printers!.replaceObject(at: i, with: mDict)

                updated = true
            }
            i += 1
        }

        if updated {
            UserDefaults.standard.set(printers, forKey: "AYDicomPrinter")
        }
    }

    public override init(window: NSWindow?) {
        super.init(window: window)
    }

    /// -init: -[NSWindowController init] is -initWithWindow: nil.
    @objc public convenience init() {
        self.init(window: nil)
        self.setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// The body of the former -init, after [super init].
    private func setUp() {
        AYDicomPrintWindowController.updateAllPreferencesFormat()

        // fetch current viewer
        m_CurrentViewer = self._currentViewer()

        // initialize printer state images
        m_PrinterOnImage = NSImage(named: "available")
        m_PrinterOffImage = NSImage(named: "away")

        printing = NSLock()

        windowFrameToRestore = NSMakeRect(0, 0, 0, 0)
        scaleFitToRestore = m_CurrentViewer?.imageView()?.isScaledFit() ?? false

        if UserDefaults.standard.bool(forKey: "SquareWindowForPrinting") {
            let AlwaysScaleToFit = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "AlwaysScaleToFit"))
            UserDefaults.standard.set(0, forKey: "AlwaysScaleToFit")

            windowFrameToRestore = m_CurrentViewer?.window?.frame ?? .zero
            var newFrame = AppController.usefullRect(for: m_CurrentViewer?.window?.screen)

            if newFrame.size.width < newFrame.size.height { newFrame.size.height = newFrame.size.width }
            else { newFrame.size.width = newFrame.size.height }

            AppController.resizeWindow(withAnimation: m_CurrentViewer?.window, newSize: newFrame)
            if scaleFitToRestore { m_CurrentViewer?.imageView()?.scaleToFit() }

            UserDefaults.standard.set(Int(AlwaysScaleToFit), forKey: "AlwaysScaleToFit")
        }

        for case let v as ViewerController in ViewerController.getDisplayed2DViewers() ?? NSMutableArray() {
            if v !== m_CurrentViewer {
                v.window?.orderOut(self)
            }
        }

        self.window?.center()
    }
    //
    //- (void) windowWillClose: (NSNotification*) n
    //{
    //    if( NSIsEmptyRect( windowFrameToRestore) == NO)
    //        [AppController resizeWindowWithAnimation: m_CurrentViewer.window newSize: windowFrameToRestore];
    //}

    public override var windowNibName: NSNib.Name? {
        return "AYDicomPrint"
    }

    /// Does not call super, as the former method did not.
    public override func awakeFromNib() {
        let printers = m_PrinterController?.arrangedObjects as? NSArray

        // show dialog if no printers are configured OR open modal print dialog
        if (printers?.count ?? 0) == 0 {
            _ = HorosAlertPanel.run(title: NSLocalizedString("DICOM Print", comment: ""), message: NSLocalizedString("No DICOM printers were found, please add a dicom printer in the preferences.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            self.close()
            return
        }

        // set default printer & printer state to off
        var i = 0
        while i < printers!.count {
            let printerDict = printers!.object(at: i) as AnyObject
            printerDict.setValue(m_PrinterOffImage, forKey: "state")

            if (printerDict.value(forKey: "defaultPrinter") as AnyObject?)?.isEqual(to: "1") ?? false {
                _ = m_PrinterController?.setSelectionIndex(i)
            }
            i += 1
        }

        m_ProgressIndicator?.usesThreadedAnimation = true
        m_ProgressIndicator?.startAnimation(self)
        m_VersionNumberTextField?.stringValue = VERSIONNUMBERSTRING

        Thread.detachNewThreadSelector(#selector(_verifyConnections(_:)), toTarget: self, with: m_PrinterController?.arrangedObjects)

        let pixCount = m_CurrentViewer?.pixList()?.count ?? 0

        entireSeriesFrom?.maxValue = Double(pixCount)
        entireSeriesTo?.maxValue = Double(pixCount)

        entireSeriesFrom?.numberOfTickMarks = pixCount
        entireSeriesTo?.numberOfTickMarks = pixCount

        if pixCount < 20 {
            entireSeriesFrom?.intValue = 1
            entireSeriesTo?.intValue = Int32(truncatingIfNeeded: pixCount)
            entireSeriesInterval?.intValue = 1
        } else {
            let curImage = Int(m_CurrentViewer?.imageView()?.curImage ?? 0)
            if m_CurrentViewer?.imageView()?.flippedData ?? false { entireSeriesFrom?.intValue = Int32(truncatingIfNeeded: pixCount &- curImage) }
            else { entireSeriesFrom?.intValue = Int32(truncatingIfNeeded: 1 + curImage) }
            entireSeriesTo?.intValue = Int32(truncatingIfNeeded: pixCount)
        }

        entireSeriesToText?.intValue = entireSeriesTo?.intValue ?? 0
        entireSeriesFromText?.intValue = entireSeriesFrom?.intValue ?? 0
        entireSeriesIntervalText?.intValue = entireSeriesInterval?.intValue ?? 0

        self.setPages(self)

        if let window = self.window {
            NSApp.runModal(for: window)
        }
    }

    @IBAction public func cancel(_ sender: Any?) {
        NSApp.stopModal()


        if UserDefaults.standard.bool(forKey: "SquareWindowForPrinting") && NSIsEmptyRect(windowFrameToRestore) == false {
            let AlwaysScaleToFit = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "AlwaysScaleToFit"))
            UserDefaults.standard.set(0, forKey: "AlwaysScaleToFit")

            AppController.resizeWindow(withAnimation: m_CurrentViewer?.window, newSize: windowFrameToRestore)

            if scaleFitToRestore { m_CurrentViewer?.imageView()?.scaleToFit() }

            UserDefaults.standard.set(Int(AlwaysScaleToFit), forKey: "AlwaysScaleToFit")
        }

        for case let v as ViewerController in ViewerController.get2DViewers() ?? NSMutableArray() {
            v.window?.orderFront(self)
        }

        m_CurrentViewer?.window?.makeKeyAndOrderFront(self)

        self.close()
    }

    @IBAction public func printImages(_ sender: Any?) {
        if (m_pages?.intValue ?? 0) > 10 && (m_ImageSelection?.selectedCell()?.tag ?? 0) == eAllImages {
            if HorosAlertPanel.runInformational(title: NSLocalizedString("DICOM Print", comment: ""), message: String(format: NSLocalizedString("Are you really sure you want to print %d pages?", comment: ""), m_pages?.intValue ?? 0), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil) != NSAlertDefaultReturn { return }
        }

        (sender as? NSControl)?.isEnabled = false

        self._createPrintjobDCMTK()

        self.cancel(self)
    }

    @IBAction public func verifyConnection(_ sender: Any?) {
        Thread.detachNewThreadSelector(#selector(_verifyConnections(_:)), toTarget: self, with: m_PrinterController?.selectedObjects)
    }

    @IBAction public func closeSheet(_ sender: Any?) {
        if let sheet = m_ProgressSheet {
            NSApp.endSheet(sheet)
        }
        m_ProgressSheet?.orderOut(self)
        m_PrintButton?.isEnabled = true
        m_PrintButton?.needsDisplay = true
    }

    @objc(checkView::)
    func checkView(_ aView: NSView!, _ OnOff: Bool) {
        if let control = aView as? NSControl {
            control.isEnabled = OnOff
            return
        }

        // Recursively check all the subviews in the view
        for view in aView?.subviews ?? [] {
            self.checkView(view, OnOff)
        }
    }

    @IBAction public func exportDICOMSlider(_ sender: Any?) {
        if (m_ImageSelection?.selectedCell()?.tag ?? 0) == eAllImages {
            entireSeriesFromText?.takeIntValueFrom(entireSeriesFrom)
            entireSeriesToText?.takeIntValueFrom(entireSeriesTo)

            let senderIntValue: Int32 = (sender as AnyObject?)?.intValue ?? 0
            let senderValue = Int(senderIntValue)
            if m_CurrentViewer?.imageView()?.flippedData ?? false { m_CurrentViewer?.imageView()?.setIndex(Int16(truncatingIfNeeded: (m_CurrentViewer?.pixList()?.count ?? 0) &- senderValue)) }
            else { m_CurrentViewer?.imageView()?.setIndex(Int16(truncatingIfNeeded: senderValue &- 1)) }

            m_CurrentViewer?.imageView()?.sendSyncMessage(0)

            m_CurrentViewer?.adjustSlider()

            self.setPages(self)
        }
    }

    @IBAction public func setPages(_ sender: Any?) {
        var no_of_images: Int32 = 0

        let dict = (m_PrinterController?.selectedObjects as NSArray?)?.object(at: 0) as AnyObject?

        if formatPopUp?.menu?.item(withTag: Int(ayIntValue(dict, "imageDisplayFormatTag"))) == nil {
            aySetObject((m_PrinterController?.selectedObjects as NSArray?)?.object(at: 0), "0", "imageDisplayFormat")
        }

        var ipp = ayTag(imageDisplayFormatNumbers, dict, "imageDisplayFormatTag")

        let mode = m_ImageSelection?.selectedCell()?.tag ?? 0
        if mode == eAllImages {
            let source = sender as AnyObject?
            if source === entireSeriesTo { entireSeriesToText?.intValue = entireSeriesTo?.intValue ?? 0 }
            if source === entireSeriesFrom { entireSeriesFromText?.intValue = entireSeriesFrom?.intValue ?? 0 }

            if source === entireSeriesToText { entireSeriesTo?.intValue = entireSeriesToText?.intValue ?? 0 }
            if source === entireSeriesFromText { entireSeriesFrom?.intValue = entireSeriesFromText?.intValue ?? 0 }

            var from = (entireSeriesFrom?.intValue ?? 0) &- 1
            var to = entireSeriesTo?.intValue ?? 0

            if from >= to {
                to = entireSeriesFrom?.intValue ?? 0
                from = (entireSeriesTo?.intValue ?? 0) &- 1
            }

            var i = from
            while i < to {
                no_of_images += 1
                i &+= entireSeriesInterval?.intValue ?? 0
            }

    //		no_of_images = (to - from) / [entireSeriesInterval intValue];
        } else if mode == eCurrentImage { no_of_images = 1 }
        else if mode == eKeyImages {
            let fileList = m_CurrentViewer?.fileList() as NSArray?
            let roiList = m_CurrentViewer?.roiList() as NSArray?

            no_of_images = 0
            var i = 0
            while i < (fileList?.count ?? 0) {
                let isKeyImage = ((fileList!.object(at: i) as AnyObject).value(forKey: "isKeyImage") as AnyObject?)?.boolValue ?? false
                if isKeyImage || ((roiList?.object(at: i) as? NSArray)?.count ?? 0) != 0 { no_of_images += 1 }
                i += 1
            }
        }

        if UserDefaults.standard.bool(forKey: "autoAdjustPrintingFormat") {
            var index = 0, no: Int32
            repeat {
                no = imageDisplayFormatNumbers[formatPopUp?.menu?.item(at: index)?.tag ?? 0]
                index += 1
            } while no_of_images > no && index < (formatPopUp?.menu?.numberOfItems ?? 0)

            let currentPrinter = (m_PrinterController?.selectedObjects as NSArray?)?.object(at: 0)

            if no == 2 {
                if ayTag(filmOrientationTag, dict, "filmOrientationTag").uppercased() == "PORTRAIT" {
                    aySetObject(currentPrinter, "1", "imageDisplayFormatTag")
                } else {
                    aySetObject(currentPrinter, "2", "imageDisplayFormatTag")
                }
            } else {
                aySetObject(currentPrinter, String(format: "%d", Int32(truncatingIfNeeded: index) &- 1), "imageDisplayFormatTag")
                ipp = ayTag(imageDisplayFormatNumbers, dict, "imageDisplayFormatTag")
            }
        }

        if no_of_images == 0 { m_pages?.intValue = 1 }
        else if ayRemainder(no_of_images, ipp) == 0 { m_pages?.intValue = ayDivide(no_of_images, ipp) }
        else { m_pages?.intValue = 1 &+ ayDivide(no_of_images, ipp) }
    }

    @IBAction public func setExportMode(_ sender: Any?) {
        if ((sender as? NSControl)?.selectedCell()?.tag ?? 0) == eAllImages { self.checkView(entireSeriesBox, true) }
        else { self.checkView(entireSeriesBox, false) }

        self.setPages(self)
    }

    @objc(_currentViewer)
    func _currentViewer() -> ViewerController? {
        let windows = NSApp.windows

        for window in windows {
            if window.windowController is ViewerController && window.isMainWindow {
                return window.windowController as? ViewerController
            }
        }

        return nil
    }

    // HOROS-532: using DCMTK commands to create print objects and sent to printer to replace legacy 32-bit aycan binaries.
    //
    @objc(_createPrintjobDCMTK)
    func _createPrintjobDCMTK() {
        // show progress sheet
        self._setProgressMessage(nil)
        if let sheet = m_ProgressSheet, let window = self.window {
            NSApp.beginSheet(sheet, modalFor: window, modalDelegate: self, didEnd: nil, contextInfo: nil)
        }

        // dictionary for selected printer
        let dict = (m_PrinterController?.selectedObjects as NSArray?)?.object(at: 0) as AnyObject?

        // show alert, if displayFormat is invalid
        if formatPopUp?.menu?.item(withTag: Int(ayIntValue(dict, "imageDisplayFormatTag"))) == nil {
            NSLog("_createPrintjobDCMTK invalid format")
            self._setProgressMessage(NSLocalizedString("The Format you selected is not valid.", comment: ""))
            self.performSelector(onMainThread: #selector(errorMessage(_:)), with: [NSLocalizedString("Print failed", comment: ""), NSLocalizedString("The Format you selected is not valid.", comment: ""), NSLocalizedString("OK", comment: "")] as NSArray, waitUntilDone: false)
        } else {
            // Create directory for print log, if it doesn't already exist.
            //
            let fileManager = FileManager.default
            var logPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/HorosDicomPrint")
            if !fileManager.fileExists(atPath: logPath) {
                if (try? fileManager.createDirectory(atPath: logPath, withIntermediateDirectories: true, attributes: nil)) == nil {
                    NSLog("_createPrintjobDCMTK failed to create log directory for print job.")
                    logPath = "log" // default to subdirectory in temp area
                }
            }

            // Create temporary directory for print job files
            //
            let printJobID = NSMutableString(string: NSDate().description)
            printJobID.replaceOccurrences(of: " ", with: "-", options: .caseInsensitive, range: NSMakeRange(0, printJobID.length))
            let printJobDir = (FileManager.default.tmpDirPath() as NSString).appendingPathComponent(String(format: "dicomPrint-%@", printJobID))

            // remove destination directory
            if fileManager.fileExists(atPath: printJobDir) {
                try? fileManager.removeItem(atPath: printJobDir)
            }

            // create destination directory
            //
            if fileManager.fileExists(atPath: printJobDir) || (try? fileManager.createDirectory(atPath: printJobDir, withIntermediateDirectories: true, attributes: nil)) == nil {
                NSLog("_createPrintjobDCMTK create directory error")
                self._setProgressMessage(NSLocalizedString("Can't write to temporary directory.", comment: ""))
                self.performSelector(onMainThread: #selector(errorMessage(_:)), with: [NSLocalizedString("Print failed", comment: ""), NSLocalizedString("Can't write to temporary directory.", comment: ""), NSLocalizedString("OK", comment: "")] as NSArray, waitUntilDone: false)
            } else {
                // HOROS-532: replacing aycan 32-bit print binaries with calls to DCMTK command-line applications.
                //
                // Create a printer configuration file with the neccessary values.
                //
                let loggerConfigPath = String(format: "%@/logger.cfg", printJobDir)
                let printConfigPath = String(format: "%@/print.cfg", printJobDir)
                let printScriptPath = String(format: "%@/print.sh", printJobDir)
                let copies = ayIntValue(dict, "copies")
                let rows = ayTag(imageDisplayFormatRows, dict, "imageDisplayFormatTag")
                let columns = ayTag(imageDisplayFormatColumns, dict, "imageDisplayFormatTag")
                let filmSize = NSMutableString(string: ayTag(filmSizeTag, dict, "filmSizeTag"))
                filmSize.replaceOccurrences(of: " ", with: "", options: .caseInsensitive, range: NSMakeRange(0, filmSize.length))
                filmSize.replaceOccurrences(of: ".", with: "_", options: .caseInsensitive, range: NSMakeRange(0, filmSize.length))
                var aeTitle = UserDefaults.defaultAETitle()
                if aeTitle == nil {
                    aeTitle = "HOROS_DICOM_PRINT"
                }

                let printConfig = NSMutableString(string: DCMTK_PRINTER_CONFIG_TEMPLATE)
                ayReplace(printConfig, "{{PRINTER_AETITLE}}", dict?.value(forKey: "aeTitle"))
                ayReplace(printConfig, "{{HOST}}", dict?.value(forKey: "host"))
                ayReplace(printConfig, "{{PORT}}", dict?.value(forKey: "port"))
                ayReplace(printConfig, "{{HOROS_AETITLE}}", aeTitle)
                ayReplace(printConfig, "{{COLUMNS}}", String(format: "%d", columns))
                ayReplace(printConfig, "{{ROWS}}", String(format: "%d", rows))
                ayReplace(printConfig, "{{FILM_DESTINATION}}", ayTag(filmDestinationTag, dict, "filmDestinationTag").uppercased())
                ayReplace(printConfig, "{{FILM_SIZE}}", filmSize.uppercased)
                ayReplace(printConfig, "{{MEDIUM_TYPE}}", ayTag(mediumTag, dict, "mediumTag").uppercased())
                ayReplace(printConfig, "{{MAGNIFICATION_TYPE}}", ayTag(magnificationTypeTag, dict, "magnificationTypeTag"))

                let loggerConfig = NSMutableString(string: DCMTK_LOGGER_CONFIG_TEMPLATE)
                ayReplace(loggerConfig, "{{LOG_DIRECTORY}}", logPath)

                // Create script for this print job.
                //
                let printScript = NSMutableString()
                // Stop before sending an incomplete job and preserve command failures.
                printScript.append("set -e\n")
                printScript.appendFormat("export DCMDICTPATH=\"%@/dicom.dic\"\n", ayArg(Bundle.main.resourcePath))
                printScript.appendFormat("cd \"%@\"\n", printJobDir)
                printScript.appendFormat("mkdir \"%@/log\"\n", printJobDir) // backup dir for log
                printScript.appendFormat("mkdir \"%@/database\" 2>&1 >> \"%@/print.log\"\n", printJobDir, logPath)
                printScript.appendFormat("echo \"`date`: Starting print job %@\" >> \"%@/print.log\"\n", printJobID, logPath)

                let ipp = ayTag(imageDisplayFormatNumbers, dict, "imageDisplayFormatTag")

                var from = (entireSeriesFrom?.intValue ?? 0) &- 1
                var to = entireSeriesTo?.intValue ?? 0

                if to < from {
                    to = entireSeriesFrom?.intValue ?? 0
                    from = (entireSeriesTo?.intValue ?? 0) &- 1
                }

                if from < 0 { from = 0 }
                if to == from { to = from &+ 1 }

                let options: NSDictionary = [
                    "columns": NSNumber(value: columns),
                    "rows": NSNumber(value: rows),
                    "mode": NSNumber(value: Int32(truncatingIfNeeded: m_ImageSelection?.selectedCell()?.tag ?? 0)),
                    "from": NSNumber(value: from),
                    "to": NSNumber(value: to),
                    "interval": NSNumber(value: entireSeriesInterval?.intValue ?? 0),
                ]

                // DCMTK command-line apps only support grayscale. +TODO+ add support for color, requires extending DCMTK commands.
                //
                var colorPrint = ayIntValue(dict, "colorPrint") != 0
                if colorPrint {
                    colorPrint = false
                }

                // Collect images for printing
                //
                let dicomConverter = AYNSImageToDicom()
                dicomConverter.prepareForDCMTK = true
                var images = dicomConverter.dicomFileList(forViewer: m_CurrentViewer, destinationPath: printJobDir, options: options, asColorPrint: colorPrint, withAnnotations: false)

                if (images?.count ?? 0) > 0 {
                    self.closeSheet(self)
                    let preview = DICOMPrintPreview(images: (dicomConverter.previewImages as? [NSImage]) ?? [], annotatedImages: (dicomConverter.annotatedPreviewImages as? [NSImage]) ?? [], columns: Int(columns), rows: Int(rows), filmSize: filmSize as String, landscape: ayIntValue(dict, "filmOrientationTag") != 0)
                    let edited = preview.runModal()
                    if edited == nil {
                        try? fileManager.removeItem(atPath: printJobDir)
                        return
                    }
                    if let sheet = m_ProgressSheet, let window = self.window {
                        NSApp.beginSheet(sheet, modalFor: window, modalDelegate: self, didEnd: nil, contextInfo: nil)
                    }
                    let sourceFiles = images
                    var written: NSArray? = nil
                    do {
                        try HorosObjCException.perform {
                            written = dicomConverter.writePreviewImages(edited as NSArray?, sourceFiles: sourceFiles, destinationPath: printJobDir)
                        }
                    } catch {
                        written = nil
                    }
                    images = written
                }

                // check, if images were collected
                if (images?.count ?? 0) == 0 {
                    try? fileManager.removeItem(atPath: printJobDir)
                    self._setProgressMessage(NSLocalizedString("No printable images were prepared. Check the selection and available disk space.", comment: ""))
                    self.performSelector(onMainThread: #selector(errorMessage(_:)), with: [NSLocalizedString("Print failed", comment: ""), NSLocalizedString("No printable images were prepared. Check the selection and available disk space.", comment: ""), NSLocalizedString("OK", comment: "")] as NSArray, waitUntilDone: false)
                } else {
                    let images = images!
                    // i <= ([images count] - 1) / ipp: unsigned long arithmetic, where a
                    // division by zero gives zero on arm64.
                    let divisor = UInt(bitPattern: Int(ipp))
                    let lastPage = divisor == 0 ? 0 : (UInt(images.count) &- 1) / divisor
                    var i: Int32 = 0
                    while UInt(bitPattern: Int(i)) <= lastPage {
                        // Format command to create the presentation state for the page ("filmbox").
                        // DCMTK command-line seems to only handle setting up one page printing, so creating one for each "filmbox".
                        //
                        printScript.appendFormat("\"%@/dcmpsprt\" -c \"%@\" -lc \"%@\" --printer PRINTSCP --layout %d %d --filmsize %@ --magnification %@ --configinfo \"%@\" --border %@ --empty-image %@ ",
                                                 ayArg(Bundle.main.resourcePath),
                                                 printConfigPath,
                                                 loggerConfigPath,
                                                 columns,
                                                 rows,
                                                 filmSize.uppercased,
                                                 ayTag(magnificationTypeTag, dict, "magnificationTypeTag"),
                                                 ayArg(dict?.value(forKey: "configurationInformation")),
                                                 ayTag(borderDensityTag, dict, "borderDensityTag"),
                                                 ayTag(emptyImageDensityTag, dict, "emptyImageDensityTag"))
                        if ayIntValue(dict, "trimTag") == 0 {
                            printScript.append("--no-trim ")
                        } else {
                            printScript.append("--trim ")
                        }
                        if ayIntValue(dict, "filmOrientationTag") == 0 {
                            printScript.append("--portrait ")
                        } else {
                            printScript.append("--landscape ")
                        }
                        printScript.append("\\\n")

                        // Add DICOM file to command ("imagebox")
                        //
                        let upper = min(UInt(bitPattern: Int(i &* ipp &+ ipp)), UInt(images.count))
                        var j = i &* ipp
                        while UInt(bitPattern: Int(j)) < upper {
                            if ((images.object(at: Int(j)) as AnyObject) as? NSString)?.length ?? 0 > 0 {
                                printScript.appendFormat(" \"%@\"\\\n", ayArg(images.object(at: Int(j))))
                            }
                            j += 1
                        }
                        printScript.append("\n")
                        i += 1
                    }

                    // Format command to send the presentation states to the printer.
                    //
                    printScript.appendFormat("\"%@/dcmprscu\" -c \"%@\" -lc \"%@\" --printer PRINTSCP --copies %d --priority %@ --destination %@ --medium-type \"%@\" \"%@/database/\"SP_*\n",
                                             ayArg(Bundle.main.resourcePath),
                                             printConfigPath,
                                             loggerConfigPath,
                                             copies,
                                             ayTag(priorityTag, dict, "priorityTag"),
                                             ayTag(filmDestinationTag, dict, "filmDestinationTag").uppercased(),
                                             ayTag(mediumTag, dict, "mediumTag").uppercased(),
                                             printJobDir)

                    printScript.appendFormat("echo \"`date`: End print job %@ [status=$?]\" >> \"%@/print.log\"\n", printJobID, logPath)

                    if (try? loggerConfig.write(toFile: loggerConfigPath, atomically: true, encoding: String.Encoding.windowsCP1250.rawValue)) == nil ||
                        (try? printConfig.write(toFile: printConfigPath, atomically: true, encoding: String.Encoding.windowsCP1250.rawValue)) == nil ||
                        (try? printScript.write(toFile: printScriptPath, atomically: true, encoding: String.Encoding.windowsCP1250.rawValue)) == nil {
                        NSLog("_createPrintjobDCMTK unable to create files in temp dir")
                        self._setProgressMessage(NSLocalizedString("Can't write to temporary directory.", comment: ""))
                        self.performSelector(onMainThread: #selector(errorMessage(_:)), with: [NSLocalizedString("Print failed", comment: ""), NSLocalizedString("Can't write to temporary directory.", comment: ""), NSLocalizedString("OK", comment: "")] as NSArray, waitUntilDone: false)
                        try? FileManager.default.removeItem(atPath: printJobDir)
                    } else {
                        // Send printjob to printer
                        //
                        let t = Thread(target: self, selector: #selector(_sendPrintjobDCMTK(_:)), object: printJobDir)
                        t.name = NSLocalizedString("DICOM Printing...", comment: "")
                        ThreadsManager.default().addThreadAndStart(t)
                    }
                }
            }
        }

        self.closeSheet(self)
    }

    @objc(_sendPrintjobDCMTK:)
    func _sendPrintjobDCMTK(_ printJobDir: String!) {
        autoreleasepool {
            printing?.lock()

            var theTask: Process? = nil

            do {
                try HorosObjCException.perform {
                    let task = Process()
                    theTask = task

                    let printScriptPath = String(format: "%@/print.sh", ayArg(printJobDir))
                    task.arguments = [printScriptPath]
                    task.launchPath = "/bin/bash"
                    task.launch()
                    while task.isRunning { Thread.sleep(forTimeInterval: 0.01) }

                    let status = task.terminationStatus

                    if status != 0 {
                        self.performSelector(onMainThread: #selector(self.errorMessage(_:)), with: [NSLocalizedString("Print failed", comment: ""), NSLocalizedString("Couldn't print images.", comment: ""), NSLocalizedString("OK", comment: "")] as NSArray, waitUntilDone: false)
                    }
                }
            } catch {
                if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                    _N2LogExceptionImpl(e, true, "-[AYDicomPrintWindowController _sendPrintjobDCMTK:]")
                }
            }
            // @finally
            // remove temporary files
            if let printJobDir = printJobDir {
                try? FileManager.default.removeItem(atPath: printJobDir)
            }
            theTask = nil
            _ = theTask

            printing?.unlock()
        }
    }

    @objc(errorMessage:)
    func errorMessage(_ msg: NSArray!) {
        _ = HorosAlertPanel.runCritical(title: msg.object(at: 0) as? String, message: String(format: "%@", ayArg(msg.object(at: 1))), defaultButton: msg.object(at: 2) as? String, alternateButton: nil, otherButton: nil)
    }

    @objc(_setProgressMessage:)
    func _setProgressMessage(_ message: String!) {
        m_ProgressMessage?.stringValue = ""
        m_ProgressMessage?.needsDisplay = true

        if message == nil {
            m_ProgressTabView?.selectFirstTabViewItem(self)
            m_ProgressMessage?.stringValue = NSLocalizedString("Printing images...", comment: "")
        } else {
            m_ProgressTabView?.selectLastTabViewItem(self)
            m_ProgressMessage?.stringValue = message
        }

        m_ProgressMessage?.needsDisplay = true
    }

    @objc(setVerifyButton:)
    func setVerifyButton(_ enabled: NSNumber!) {
        m_VerifyConnectionButton?.isEnabled = enabled?.boolValue ?? false
    }

    @objc(setPrinterStateOn:)
    func setPrinterStateOn(_ printer: NSMutableDictionary!) {
        printer?.setValue(m_PrinterOnImage, forKey: "state")
    }

    @objc(setPrinterStateOff:)
    func setPrinterStateOff(_ printer: NSMutableDictionary!) {
        printer?.setValue(m_PrinterOffImage, forKey: "state")
    }

    @objc(_verifyConnections:)
    func _verifyConnections(_ printers: NSArray!) {
        autoreleasepool {
            // The former method retained self until it returned; the thread
            // that runs it retains its target as long.
            withExtendedLifetime(self) {
                do {
                    try HorosObjCException.perform {
                        self.performSelector(onMainThread: #selector(self.setVerifyButton(_:)), with: NSNumber(value: false), waitUntilDone: true)

                        for printer in printers ?? NSArray() {
                            if self._verifyConnection(printer as? NSDictionary) {
                                self.performSelector(onMainThread: #selector(self.setPrinterStateOn(_:)), with: printer, waitUntilDone: false)
                            } else {
                                self.performSelector(onMainThread: #selector(self.setPrinterStateOff(_:)), with: printer, waitUntilDone: false)
                            }
                        }
                    }
                } catch {
                    if let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                        _N2LogExceptionImpl(e, false, "-[AYDicomPrintWindowController _verifyConnections:]")
                    }
                }
                self.performSelector(onMainThread: #selector(self.setVerifyButton(_:)), with: NSNumber(value: true), waitUntilDone: true)

                Thread.sleep(forTimeInterval: 5)
            }
        }
    }

    @objc(_verifyConnection:)
    func _verifyConnection(_ dict: NSDictionary!) -> Bool {
        return QueryController.echo(dict?.value(forKey: "host") as? String, port: ayIntValue(dict, "port"), aet: dict?.value(forKey: "aeTitle") as? String)
    }

    @objc(drawerDidOpen:)
    func drawerDidOpen(_ notification: Notification!) {
        m_ToggleDrawerButton?.title = NSLocalizedString("Hide Printers...", comment: "")
    }

    @objc(drawerDidClose:)
    func drawerDidClose(_ notification: Notification!) {
        m_ToggleDrawerButton?.title = NSLocalizedString("Show Printers...", comment: "")
    }
}
