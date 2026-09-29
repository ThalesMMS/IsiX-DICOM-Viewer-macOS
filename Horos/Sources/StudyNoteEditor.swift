//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import CoreData

// The note of a study: free text kept in the `note` attribute of the Study
// entity (model 2.6), edited in a window of its own. The «Note» item of the 2D
// viewer's toolbar and Note… in the 2D Viewer menu open it for the viewer's
// study. One editor per study: asking again brings the open one forward.

/// Reads and writes the note of a study, by key, so that it works on any
/// managed object of the Study entity.
@objc(HorosStudyNote)
public final class StudyNote: NSObject {

    @objc public static let key = "note"

    /// What is stored for `text`: nil for a note with nothing but white space
    /// in it, the text as typed otherwise.
    @objc(storedValueForText:)
    public class func storedValue(for text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// The note of `study`, or "" when it has none.
    @objc(textOfStudy:)
    public class func text(of study: NSManagedObject) -> String {
        return study.value(forKey: key) as? String ?? ""
    }

    /// Sets the note of `study` to what is stored for `text`; answers whether
    /// that changed it.
    @objc(setText:ofStudy:)
    @discardableResult
    public class func setText(_ text: String?, of study: NSManagedObject) -> Bool {
        let value = storedValue(for: text)
        if value == (study.value(forKey: key) as? String) { return false }
        study.setValue(value, forKey: key)
        return true
    }

    /// The note on one line, for a column of the database browser.
    @objc(singleLineTextOfNote:)
    public class func singleLineText(of note: String?) -> String? {
        guard let note = storedValue(for: note) else { return nil }
        return note.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

@objc(HorosStudyNoteEditor)
public final class StudyNoteEditor: NSWindowController, NSWindowDelegate {

    /// The open editors, by the object identifier of their study.
    private static var editors: [NSManagedObjectID: StudyNoteEditor] = [:]

    /// Quitting from the application menu closes every window, which saves the
    /// notes; a quit that does not (from the Dock, at log out) saves them here.
    private static let terminationObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            for editor in Array(editors.values) { editor.window?.close() }
        }

    private let study: DicomStudy
    private let studyID: NSManagedObjectID
    private let readOnly: Bool
    private let textView: NSTextView
    private var discard = false

    /// Opens the editor of `study`, or brings forward the one already open.
    @objc(showEditorForStudy:)
    @discardableResult
    public class func showEditor(for study: DicomStudy) -> StudyNoteEditor {
        if let open = editors[study.objectID] {
            open.showWindow(nil)
            return open
        }
        _ = terminationObserver
        let editor = StudyNoteEditor(study: study)
        editors[editor.studyID] = editor
        editor.showWindow(nil)
        return editor
    }

    private init(study: DicomStudy) {
        self.study = study
        self.studyID = study.objectID
        let database = study.managedObjectContext.flatMap { DicomDatabase(for: $0) }
        self.readOnly = database?.isReadOnly ?? true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 300, height: 200)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 280))
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.string = StudyNote.text(of: study)
        textView.isEditable = !readOnly
        textView.setAccessibilityLabel(NSLocalizedString("Study note", comment: "the text of the note editor of a study"))
        scrollView.documentView = textView
        self.textView = textView

        let cancel = NSButton(title: NSLocalizedString("Cancel", comment: ""), target: nil, action: #selector(StudyNoteEditor.cancelNote(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: NSLocalizedString("Save", comment: ""), target: nil, action: #selector(StudyNoteEditor.saveNote(_:)))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        save.isEnabled = !readOnly
        for button in [cancel, save] { button.translatesAutoresizingMaskIntoConstraints = false }

        let content = NSView()
        content.addSubview(scrollView)
        content.addSubview(cancel)
        content.addSubview(save)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            save.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 12),
            save.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            save.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            cancel.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -8),
        ])
        window.contentView = content

        super.init(window: window)

        cancel.target = self
        save.target = self
        window.delegate = self
        window.title = StudyNoteEditor.title(for: study, readOnly: readOnly)
        window.setFrameAutosaveName("HorosStudyNoteEditor")
        window.initialFirstResponder = textView
        if !window.setFrameUsingName("HorosStudyNoteEditor") { window.center() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private static func title(for study: DicomStudy, readOnly: Bool) -> String {
        let name = UserDefaults.standard.bool(forKey: "HIDEPATIENTNAME") ? nil : study.name
        let parts = [name, study.studyName].compactMap { $0 }.filter { !$0.isEmpty }
        var title = parts.isEmpty ? NSLocalizedString("Note", comment: "the note of a study") :
            String(format: NSLocalizedString("Note: %@", comment: "title of the note editor of a study"), parts.joined(separator: " - "))
        if readOnly { title += " " + NSLocalizedString("(read-only)", comment: "") }
        return title
    }

    // MARK: - Actions

    @objc(saveNote:)
    func saveNote(_ sender: Any?) {
        window?.close() // the note is saved as the window closes
    }

    @objc(cancelNote:)
    func cancelNote(_ sender: Any?) {
        discard = true
        window?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        if !discard { commit() }
        StudyNoteEditor.editors[studyID] = nil
    }

    /// Stores the text in the study and saves its database, on the main thread,
    /// in the study's own context. When that fails the text is logged and the
    /// user is told, rather than the note being lost without a word.
    private func commit() {
        guard !readOnly else { return }
        textView.window?.makeFirstResponder(nil) // ends an input still being composed
        let text = textView.string
        guard let context = study.managedObjectContext, !study.isDeleted else {
            failed(NSLocalizedString("The study is no longer in the database.", comment: ""), text)
            return
        }
        let database = DicomDatabase(for: context)
        var saveError: NSError? = nil
        var saved = true
        do {
            try HorosObjCException.perform {
                guard StudyNote.setText(text, of: self.study) else { return }
                if let remote = database as? RemoteDicomDatabase {
                    remote.object(self.study, setValue: StudyNote.storedValue(for: text), forKey: StudyNote.key)
                } else if let database {
                    saved = database.save(&saveError) && saveError == nil
                }
                BrowserController.currentBrowser()?.databaseOutline?.reloadData()
            }
        } catch {
            failed((error as NSError).localizedDescription, text)
            return
        }
        if !saved {
            failed(saveError?.localizedDescription ?? NSLocalizedString("unknown error", comment: ""), text)
        }
    }

    private func failed(_ reason: String, _ text: String) {
        NSLog("Study note: the note could not be saved (%@): %@", reason, text)
        HorosAlertPanel.run(title: NSLocalizedString("Note", comment: "the note of a study"),
                            message: String(format: NSLocalizedString("The note could not be saved: %@", comment: ""), reason),
                            defaultButton: nil, alternateButton: nil, otherButton: nil)
    }
}

public extension ViewerController {

    /// Opens the note editor of the study shown in this viewer.
    @objc(showStudyNoteEditor:)
    func showStudyNoteEditor(_ sender: Any?) {
        guard let study = self.currentStudy() else { return }
        StudyNoteEditor.showEditor(for: study)
    }
}
