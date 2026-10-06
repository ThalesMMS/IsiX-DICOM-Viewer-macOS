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

/// Window Controller for creating smart albums: the File's Owner of
/// SmartAlbum.xib.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/SmartWindowController.h> are those of the former class. The xib binds
/// name, predicate, predicateFormat, mode, nameIsValid, predicateFormatIsValid,
/// modeIsPredicate, modeIsSQL and okButtonTitle; they stay KVO compliant, with
/// the same dependent keys.
@objc(SmartWindowController)
public final class SmartWindowController: NSWindowController, NSTextFieldDelegate {
    private var _predicateFormat: String?
    private var _contentCriterionCheckbox: NSButton?

    @objc public dynamic var database: DicomDatabase!
    @objc public dynamic var album: DicomAlbum!
    @objc public dynamic var name: String!
    @objc public dynamic var mode: Int = 0

    /// assign in the former header: the xib's window owns the field.
    @IBOutlet @objc public weak var nameField: NSTextField!
    /// assign in the former header: the xib's window owns the editor.
    @IBOutlet @objc public weak var editor: O2DicomPredicateEditor!

    /// Failable as Swift saw the former -(id)initWithDatabase:; it never fails.
    @objc(initWithDatabase:)
    public convenience init!(database: DicomDatabase!) {
        self.init(windowNibName: "SmartAlbum")
        // Outside the designated initializer: through the setter, as before.
        self.database = database
    }

    /// Overridden so that -initWithWindowNibName: is inherited, unchanged.
    public override init(window: NSWindow?) {
        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func awakeFromNib() {
        MainActor.assumeIsolated {
            self.editor?.dbMode = true
            installContentCriterionCheckbox()
            (self.nameField?.cell as? NSTextFieldCell)?.placeholderString = NSLocalizedString("Smart Album", comment: "")
            self.nameField?.delegate = self

            if let predicate = self.predicate, !(self.editor?.reallyMatch(for: predicate) ?? false) {
                self.mode = 1
            }
        }
    }

    // The former -dealloc released the checkbox and set name, predicate, album
    // and database to nil; the stored properties are released here as well.

    @objc class func keyPathsForValuesAffectingPredicate() -> Set<String> {
        return ["predicateFormat"]
    }

    /// (assign) NSPredicate: the predicate of predicateFormat, or nil when it
    /// is empty or does not parse.
    @objc public dynamic var predicate: NSPredicate! {
        get {
            var predicate: NSPredicate?
            _ = try? HorosObjCException.perform {
                if let format = self.predicateFormat, !format.isEmpty {
                    predicate = NSPredicate(format: format, argumentArray: nil)
                }
            }
            return predicate
        }
        set {
            self.predicateFormat = newValue?.predicateFormat
        }
    }

    /// (retain, nonatomic): an empty string reads as nil.
    @objc public dynamic var predicateFormat: String! {
        get {
            if let format = _predicateFormat, !format.isEmpty {
                return format
            }
            return nil
        }
        set {
            _predicateFormat = newValue
        }
    }

    // MARK: Actions

    @IBAction @objc(cancelAction:)
    public func cancelAction(_ sender: Any!) {
        if let window = self.window {
            window.sheetParent?.endSheet(window, returnCode: .abort)
        }

        BrowserController.currentBrowser()?.testPredicate = nil
        _ = BrowserController.currentBrowser()?.outlineViewRefresh()
    }

    // Esc cancels the sheet. From a control it comes up the responder
    // chain here; from the name field, whose editor would turn it into word
    // completion, it comes through the field's delegate below.
    public override func cancelOperation(_ sender: Any?) {
        cancelAction(sender)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.cancelOperation(_:)) {
            cancelAction(control)
            return true
        }
        return false
    }

    @IBAction @objc(okAction:)
    public func okAction(_ sender: Any!) {
        if let window = self.window {
            window.sheetParent?.endSheet(window)
        }

        BrowserController.currentBrowser()?.testPredicate = nil
        _ = BrowserController.currentBrowser()?.outlineViewRefresh()
    }

    @IBAction @objc(helpAction:)
    public func helpAction(_ sender: Any!) {
        // [sender selectedSegment]: the xib's sender is a segmented control;
        // a nil sender answered 0.
        let selectedSegment = (sender as? NSSegmentedControl)?.selectedSegment ?? 0

        if selectedSegment == 0 {
            try? FileManager.default.removeItem(atPath: (NSTemporaryDirectory() as NSString).appendingPathComponent("OsiriXTables.pdf"))
            // A missing resource raised in -copyItemAtPath:toPath:error:,
            // which ended the action there.
            guard let tables = Bundle.main.path(forResource: "OsiriXTables", ofType: "pdf") else {
                return
            }
            try? FileManager.default.copyItem(atPath: tables, toPath: (NSTemporaryDirectory() as NSString).appendingPathComponent("OsiriXTables.pdf"))
            NSWorkspace.shared.open(URL(fileURLWithPath: (NSTemporaryDirectory() as NSString).appendingPathComponent("OsiriXTables.pdf")))

            Thread.sleep(forTimeInterval: 1)
        }

        if selectedSegment == 1 {
            if let url = URL(string: "http://developer.apple.com/documentation/Cocoa/Conceptual/Predicates/Articles/pSyntax.html#//apple_ref/doc/uid/TP40001795") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @IBAction @objc(testAction:)
    public func testAction(_ sender: Any!) {
        // The former @try: an exception raised by the predicate, the browser
        // or the database, or one of the two the method raised itself, ends
        // up in the critical panel with the exception's description.
        var failure: String?
        do {
            try HorosObjCException.perform {
                var p: NSPredicate? = self.predicateFormat.flatMap { NSPredicate(format: $0, argumentArray: nil) }

                let bc = BrowserController.currentBrowser()
                p = bc?.smartAlbumPredicateString(self.predicateFormat)
                guard let p else {
                    failure = NSLocalizedString("Invalid NSPredicate SQL syntax", comment: "")
                    return
                }

                // -objectsForEntity:predicate:error: answers nil exactly when it
                // sets the error, which Swift turns into a throw.
                if let database = self.database {
                    do {
                        _ = try database.objects(forEntity: database.studyEntity(), predicate: p, error: ())
                    } catch {
                        failure = error.localizedDescription
                        return
                    }
                }

                bc?.testPredicate = p
                _ = bc?.outlineViewRefresh()

                let message = NSLocalizedString("This filter works: the result is now displayed in the Database Window.", comment: "")

                HorosAlertPanel.runInformational(title: NSLocalizedString("It works!", comment: ""), message: message,
                                                 defaultButton: nil, alternateButton: nil, otherButton: nil)
            }
        } catch {
            let exception = (error as NSError).userInfo[HorosObjCExceptionKey]
            failure = exception.map { String(describing: $0 as AnyObject) } ?? (error as NSError).localizedDescription
        }

        if let failure {
//            N2LogExceptionWithStackTrace(e);
            HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""),
                                        message: String(format: NSLocalizedString("This filter is NOT working: %@", comment: ""), failure),
                                        defaultButton: nil, alternateButton: nil, otherButton: nil)
        }
    }

    // MARK: -

    @objc class func keyPathsForValuesAffectingPredicateFormatIsValid() -> Set<String> {
        return ["predicateFormat"]
    }

    @objc public var predicateFormatIsValid: Bool {
        var valid = false
        _ = try? HorosObjCException.perform {
            if let format = self.predicateFormat, NSPredicate(format: format, argumentArray: nil) as NSPredicate? != nil {
                valid = true
            }
        }
        return valid
    }

    @objc class func keyPathsForValuesAffectingNameIsValid() -> Set<String> {
        return ["name"]
    }

    @objc public var nameIsValid: Bool {
        let albums = NSMutableArray(array: self.database?.objects(forEntity: self.database?.albumEntity()) ?? [])
        if let album = self.album {
            albums.remove(album)
        }
        guard let name = self.name, !name.isEmpty else {
            return false
        }
        return !((albums.value(forKey: "name") as? NSArray)?.contains(name) ?? false)
    }

    @objc class func keyPathsForValuesAffectingModeIsPredicate() -> Set<String> {
        return ["mode"]
    }

    @objc public var modeIsPredicate: Bool {
        return self.mode == 0
    }

    @objc class func keyPathsForValuesAffectingModeIsSQL() -> Set<String> {
        return ["mode"]
    }

    @objc public var modeIsSQL: Bool {
        return self.mode == 1
    }

    @objc class func keyPathsForValuesAffectingOkButtonTitle() -> Set<String> {
        return ["album"]
    }

    // MARK: Content criterion

    @objc func installContentCriterionCheckbox() {
        guard let content = self.window?.contentView, _contentCriterionCheckbox == nil else { return }

        let box = NSButton(checkboxWithTitle: NSLocalizedString("Only studies with ROIs or segmentations", comment: ""),
                           target: self, action: #selector(toggleContentCriterion(_:)))
        box.controlSize = .small
        box.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        box.state = self.wantsROIOrSegmentation ? .on : .off
        box.translatesAutoresizingMaskIntoConstraints = false
        box.setAccessibilityLabel(box.title)

        // Under the editor, above the Predicate/SQL/Test/Cancel/Create row: the row's
        // control that hangs from the editors now hangs from the box. The window is
        // laid out by these constraints, so moving frames by hand did not last.
        var row: NSView? = nil
        var editors: [NSLayoutConstraint] = []
        for c in content.constraints {
            if c.firstAttribute == .top && c.secondAttribute == .bottom &&
                c.firstItem is NSSegmentedControl && c.secondItem is NSScrollView {
                row = c.firstItem as? NSView
                editors.append(c)
            }
        }
        content.addSubview(box)
        if let row {
            var added: [NSLayoutConstraint] = []
            for c in editors {
                if let editorView = c.secondItem as? NSView {
                    added.append(box.topAnchor.constraint(equalTo: editorView.bottomAnchor, constant: 8))
                }
            }
            NSLayoutConstraint.deactivate(editors)
            added.append(box.leadingAnchor.constraint(equalTo: row.leadingAnchor))
            added.append(row.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 8))
            NSLayoutConstraint.activate(added)
            // Grow the sheet by the box's line, so the editor keeps its height.
            if let window = self.window {
                var frame = window.frame
                let grow = box.fittingSize.height + 8
                frame.size.height += grow
                frame.origin.y -= grow
                window.setFrame(frame, display: false)
            }
        } else {
            // No row to hang from: keep the box at the bottom left rather than lose it.
            NSLayoutConstraint.activate([box.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                                         box.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4)])
        }
        _contentCriterionCheckbox = box
    }

    /// Whether the predicate being edited carries the "studies with ROIs or
    /// segmentations" clause.
    @objc public var wantsROIOrSegmentation: Bool {
        return StudyContentPredicates.contains(StudyContentPredicates.roiOrSegmentationFormat, in: self.predicateFormat)
    }

    /// Toggles the "studies with ROIs or segmentations" clause on the predicate
    /// being edited, without touching the rest of it.
    @IBAction @objc(toggleContentCriterion:)
    public func toggleContentCriterion(_ sender: Any!) {
        let clause = StudyContentPredicates.roiOrSegmentationFormat
        // The sender is the checkbox; a nil sender answered NSControlStateValueOff.
        let wanted = (sender as? NSButton)?.state == .on
        let updated = wanted ? StudyContentPredicates.adding(clause, to: self.predicateFormat)
                             : StudyContentPredicates.removing(clause, from: self.predicateFormat)
        self.predicateFormat = updated.isEmpty ? nil : updated
        // The row editor cannot show a SUBQUERY; the raw predicate mode can.
        if self.predicate == nil || !(self.editor?.reallyMatch(for: self.predicate) ?? false) {
            self.mode = 1
        }
    }

    @objc public var okButtonTitle: String {
        if self.album != nil {
            return NSLocalizedString("Save", comment: "")
        }
        return NSLocalizedString("Create", comment: "")
    }
}
