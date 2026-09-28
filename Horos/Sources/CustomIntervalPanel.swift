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

/// The panel of the browser's custom date interval (timeIntervalType 100).
///
/// Implemented in Swift since #713: the Objective-C name, the selectors and
/// <Horos/CustomIntervalPanel.h> are those of the former class, the File's
/// Owner of CustomIntervalPanel.xib. The date pickers bind `self.fromDate` and
/// `self.toDate`, so both are `@objc dynamic`.
@objc(CustomIntervalPanel)
public final class CustomIntervalPanel: NSWindowController, NSWindowDelegate {
    // Outlets the xib sets: ivars of the former class.
    @IBOutlet @objc var matrix: NSMatrix!
    @IBOutlet @objc var fromPicker: NSDatePicker!
    @IBOutlet @objc var toPicker: NSDatePicker!
    @IBOutlet @objc var textualFromPicker: NSDatePicker!
    @IBOutlet @objc var textualToPicker: NSDatePicker!

    private var fromDateValue: Date?
    private var toDateValue: Date?
    /// Only -initWithWindow: registers the defaults observers; deinit removes
    /// what was registered.
    private var observesDefaults = false

    private static var shared: CustomIntervalPanel?

    @objc(sharedCustomIntervalPanel)
    public class func sharedCustomIntervalPanel() -> CustomIntervalPanel! {
        if shared == nil {
            let panel = CustomIntervalPanel(windowNibName: "CustomIntervalPanel")
            shared = panel

            panel.fromDate = Date()
            panel.toDate = Date()
            panel.sizeWindowAccordingToSettings()
            panel.setFormatAccordingToSettings()
        }

        return shared
    }

    public func windowWillClose(_ notification: Notification) {
        BrowserController.currentBrowser()?.timeIntervalType = 0
    }

    /// The designated initializer -initWithWindowNibName: goes through, as
    /// before. The outlets are not loaded yet here, so the locales set on the
    /// pickers reach nothing, as in the former class.
    public override init(window: NSWindow?) {
        super.init(window: window)

        fromPicker?.locale = Locale.current
        toPicker?.locale = Locale.current
        textualFromPicker?.locale = Locale.current
        textualToPicker?.locale = Locale.current

        NSUserDefaultsController.shared.addObserver(self,
                                                    forKeyPath: "values.customIntervalWithHoursAndMinutes",
                                                    options: .new,
                                                    context: nil)

        NSUserDefaultsController.shared.addObserver(self,
                                                    forKeyPath: "values.betweenDatesMode",
                                                    options: .new,
                                                    context: nil)
        observesDefaults = true
    }

    /// NSWindowController's other designated initializer; the former class did
    /// not override it and registered no observers there.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc(sizeWindowAccordingToSettings)
    public func sizeWindowAccordingToSettings() {
        guard let window = window else { return }
        var frame = window.frame

        if UserDefaults.standard.bool(forKey: "betweenDatesMode") {
            frame = NSMakeRect(frame.origin.x, frame.origin.y - (518 - frame.size.height), frame.size.width, 518)
        } else {
            frame = NSMakeRect(frame.origin.x, frame.origin.y - (297 - frame.size.height), frame.size.width, 297)
        }

        var minWidth: Float = 154
        if let matrix = matrix {
            minWidth = Float(matrix.frame.origin.x + matrix.frame.size.width + 10)
        }

        if UserDefaults.standard.bool(forKey: "betweenDatesMode") && UserDefaults.standard.bool(forKey: "customIntervalWithHoursAndMinutes") {
            frame = NSMakeRect(frame.origin.x, frame.origin.y, CGFloat(max(minWidth, 288)), frame.size.height)
        } else {
            frame = NSMakeRect(frame.origin.x, frame.origin.y, CGFloat(max(minWidth, 154)), frame.size.height)
        }

        window.setFrame(frame, display: true, animate: true)
    }

    @objc(setFormatAccordingToSettings)
    public func setFormatAccordingToSettings() {
        if UserDefaults.standard.bool(forKey: "betweenDatesMode") && UserDefaults.standard.bool(forKey: "customIntervalWithHoursAndMinutes") {
            toPicker?.datePickerElements = [.yearMonthDay, .hourMinute]
            fromPicker?.datePickerElements = [.yearMonthDay, .hourMinute]

            textualFromPicker?.datePickerElements = [.yearMonthDay, .hourMinute]
            textualToPicker?.datePickerElements = [.yearMonthDay, .hourMinute]
        } else {
            toPicker?.datePickerElements = .yearMonthDay
            fromPicker?.datePickerElements = .yearMonthDay

            textualFromPicker?.datePickerElements = .yearMonthDay
            textualToPicker?.datePickerElements = .yearMonthDay
        }
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                      change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "values.betweenDatesMode" || keyPath == "values.customIntervalWithHoursAndMinutes" {
            setFormatAccordingToSettings()

            sizeWindowAccordingToSettings()

            self.fromDate = fromPicker?.dateValue
            self.toDate = toPicker?.dateValue

            window?.display()
        }
    }

    /// Retained; the setters keep the former rules: without hours and minutes
    /// the start is the start of its day and the end the last second of its
    /// day, and outside the between-dates mode setting the start also sets the
    /// end. Either one, while the panel is visible, selects the custom interval
    /// in the browser.
    @objc public dynamic var fromDate: Date! {
        get { return fromDateValue }
        set(date) {
            // [fromDate isEqualToDate: date] == NO
            guard !(fromDateValue != nil && date != nil && fromDateValue == date) else { return }

            if UserDefaults.standard.bool(forKey: "customIntervalWithHoursAndMinutes") && UserDefaults.standard.bool(forKey: "betweenDatesMode") {
                fromDateValue = date
            } else {
                fromDateValue = date.flatMap { date -> Date? in
                    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
                    return Calendar.current.date(from: components)
                }

                if !UserDefaults.standard.bool(forKey: "betweenDatesMode") {
                    self.toDate = date
                }
            }

            if window?.isVisible == true {
                BrowserController.currentBrowser()?.timeIntervalType = 100
            }
        }
    }

    @objc public dynamic var toDate: Date! {
        get { return toDateValue }
        set(date) {
            // [toDate isEqualToDate: date] == NO
            guard !(toDateValue != nil && date != nil && toDateValue == date) else { return }

            if UserDefaults.standard.bool(forKey: "customIntervalWithHoursAndMinutes") && UserDefaults.standard.bool(forKey: "betweenDatesMode") {
                toDateValue = date
            } else {
                toDateValue = date.flatMap { date -> Date? in
                    var components = Calendar.current.dateComponents([.year, .month, .day], from: date)

                    components.hour = 23
                    components.minute = 59
                    components.second = 59

                    return Calendar.current.date(from: components)
                }
            }

            if window?.isVisible == true {
                BrowserController.currentBrowser()?.timeIntervalType = 100
            }
        }
    }

    @IBAction @objc(nowFrom:)
    public func nowFrom(_ sender: Any!) {
        self.fromDate = Date()
    }

    @IBAction @objc(nowTo:)
    public func nowTo(_ sender: Any!) {
        self.toDate = Date()
    }

    deinit {
        guard observesDefaults else { return }
        NSUserDefaultsController.shared.removeObserver(self, forKeyPath: "values.customIntervalWithHoursAndMinutes")
        NSUserDefaultsController.shared.removeObserver(self, forKeyPath: "values.betweenDatesMode")
    }
}
