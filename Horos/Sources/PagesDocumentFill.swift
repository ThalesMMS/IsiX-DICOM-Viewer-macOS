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
import Foundation

/// Filling in a Pages document that has no `index.xml`.
///
/// A template saved by Pages 5 or later is IWA - compressed protocol buffers -
/// so the text substitution that works on a Pages '09 package has nothing to
/// edit, and a modern template could only be refused. Pages itself can be asked,
/// which is what the Word report already does with its mail merge.
///
/// What Pages lets a script reach is filled in: the body text, the text of every
/// text box and shape - including the ones on a section layout, which repeat on
/// every page and are how a letterhead in the top margin is usually made - and
/// the cells of every table, whether it floats or sits in the body - and the
/// same inside groups, nested or not, which is how a letterhead with a logo is
/// often put together. The header and footer fields themselves are not in
/// Pages' scripting dictionary: PagesHeaderFooterFill fills those in the file,
/// before Pages opens it.
///
/// A paragraph at a time, and not a range of characters: `set characters i thru
/// j of body text to "x"` assigns the *whole* string to *each* character of the
/// range - measured, it turned one placeholder into twenty copies of the value -
/// because that is what assigning to a plural element means in AppleScript.
@objc(HorosPagesDocumentFill)
public final class PagesDocumentFill: NSObject {

    /// The text of a text box or shape, or the cells of a table. `location`
    /// is the path of `iWork item` indices from the document, dot-separated:
    /// `3` is the document's third item, `3.2` the second item of the group
    /// that is the third.
    enum Item: Equatable {
        case text(location: String, text: String)
        case table(location: String, cells: [String])
    }

    /// Opens the document, replaces what `substitute` changes, saves and closes
    /// it. false when Pages could not be driven, and then nothing was written.
    ///
    /// Pages saves documents by itself, so the file handed here has to be a copy
    /// that may be thrown away: measured, an edit made through AppleScript was on
    /// disk before anything asked for it to be saved.
    @objc(fillDocumentAtPath:substitute:)
    public static func fill(documentAt path: String,
                            substitute: (String) -> String) -> Bool {
        guard let (identifier, body, items) = open(path) else {
            NSLog("---- Pages did not open the report at %@", path)
            return false
        }
        let changes = edits(body: body, items: items, substitute: substitute)
        if changes.isEmpty {
            // Nothing to fill in, and the copy stands as the template does.
            return run(Self.closeScript, [identifier]) != nil
        }
        return run(Self.writeScript, [identifier] + changes) != nil
    }

    /// What the write script is told to change, four arguments an edit: a kind,
    /// where, which paragraph or cell, and the new text. `p` is a paragraph of
    /// the body, `o` a paragraph of an item's text, `c` a cell of a table.
    ///
    /// The items come first and the body last, each last paragraph first: a
    /// replacement that is not one line changes the numbering of everything after
    /// it, and nothing written into an item renumbers the items.
    static func edits(body: String, items: [Item], substitute: (String) -> String) -> [String] {
        var edits: [String] = []
        for item in items {
            switch item {
            case let .text(location, text):
                for (paragraph, filled) in paragraphEdits(text, substitute) {
                    edits += ["o", location, String(paragraph), filled]
                }
            case let .table(location, cells):
                for (cell, text) in cells.enumerated() {
                    let filled = substitute(text)
                    if filled != text {
                        edits += ["c", location, String(cell + 1), filled]
                    }
                }
            }
        }
        for (paragraph, filled) in paragraphEdits(body, substitute) {
            edits += ["p", "0", String(paragraph), filled]
        }
        return edits
    }

    /// The paragraphs `substitute` changes, numbered from 1, last first.
    ///
    /// A paragraph is replaced without a line break of its own: measured,
    /// `set paragraph i` keeps the paragraph's break, and one more in the new text
    /// left an empty paragraph after it. And a paragraph holding an object
    /// anchored in the text - an inline table, a text box that moves with it,
    /// U+FFFC in what Pages reads back - is left alone: rewriting it as a string
    /// deletes the object, which is a worse report than a placeholder left as is.
    private static func paragraphEdits(_ text: String, _ substitute: (String) -> String) -> [(Int, String)] {
        var edits: [(Int, String)] = []
        let paragraphs = text.components(separatedBy: "\n")
        for (index, paragraph) in paragraphs.enumerated().reversed() {
            if paragraph.contains("\u{FFFC}") { continue }
            let filled = substitute(paragraph)
            if filled != paragraph {
                edits.append((index + 1, filled))
            }
        }
        return edits
    }

    // MARK: talking to Pages

    /// Pages is sandboxed, and asking it over AppleScript to open a path of our
    /// choosing did nothing at all - measured: the event was answered, and no
    /// document appeared. The file is opened the way a person opens one, through
    /// LaunchServices, which is what grants Pages the file; the script then only
    /// has to find the document that appeared, by the name of the file, and
    /// `open` does not answer with it.
    ///
    /// The values of a table come back in one event for all its cells; what is
    /// not text there - a number, a date, an empty cell - cannot hold a
    /// placeholder and comes back empty.
    private static let openScript = """
    on run argv
      set nm to item 1 of argv
      with timeout of 600 seconds
      tell application id "com.apple.Pages"
        set d to missing value
        repeat with attempt from 1 to 60
          repeat with candidate in documents
            if (name of candidate) is nm then
              set d to contents of candidate
              exit repeat
            end if
          end repeat
          if d is not missing value then exit repeat
          delay 0.5
        end repeat
        if d is missing value then error "Pages did not open " & nm
        set bodyText to ""
        try
          set bodyText to (body text of d) as string
        end try
        set found to my collectItems(d, "", {})
        return {(id of d) as string, bodyText, found}
      end tell
      end timeout
    end run

    on collectItems(container, prefix, found)
      tell application id "com.apple.Pages"
        repeat with i from 1 to (count of iWork items of container)
          set x to iWork item i of container
          set here to prefix & (i as string)
          if (class of x) is group then
            set found to my collectItems(x, here & ".", found)
          else if (class of x) is table then
            set cellValues to value of every cell of x
            set texts to {}
            repeat with v in cellValues
              set v to contents of v
              if class of v is text then
                set end of texts to v
              else
                set end of texts to ""
              end if
            end repeat
            set end of found to {"table", here, texts}
          else
            try
              set end of found to {"text", here, (object text of x) as string}
            end try
          end if
        end repeat
      end tell
      return found
    end collectItems
    """

    /// A cell is made a text cell before it is written: Pages reads what is typed
    /// into an automatic cell, and measured, a patient ID of 00123 became the
    /// number 123. No variable is called `kind`: that is a word of Pages'
    /// dictionary inside the tell block, and assigning to it is refused.
    private static let writeScript = """
    on run argv
      set docId to item 1 of argv
      with timeout of 600 seconds
      tell application id "com.apple.Pages"
        set d to document id docId
        repeat with k from 2 to (count of argv) by 4
          set editKind to item k of argv
          set i to (item (k + 2) of argv) as integer
          set newText to item (k + 3) of argv
          if editKind is "p" then
            set paragraph i of body text of d to newText
          else if editKind is "o" then
            set x to my itemAt(d, item (k + 1) of argv)
            set paragraph i of object text of x to newText
          else
            set x to my itemAt(d, item (k + 1) of argv)
            tell x
              set format of cell i to text
              set value of cell i to newText
            end tell
          end if
        end repeat
        save d
        close d saving no
      end tell
      end timeout
      return "done"
    end run

    on itemAt(d, location)
      set savedDelimiters to AppleScript's text item delimiters
      set AppleScript's text item delimiters to "."
      set steps to text items of location
      set AppleScript's text item delimiters to savedDelimiters
      tell application id "com.apple.Pages"
        set x to d
        repeat with stepText in steps
          set x to iWork item ((contents of stepText) as integer) of x
        end repeat
      end tell
      return x
    end itemAt
    """

    private static let closeScript = """
    on run argv
      with timeout of 600 seconds
      tell application id "com.apple.Pages"
        close (document id (item 1 of argv)) saving no
      end tell
      end timeout
      return "done"
    end run
    """

    private static func open(_ path: String) -> (String, String, [Item])? {
        let name = (path as NSString).lastPathComponent
        guard let application = PagesApplication.url() else { return nil }
        // No waiting on the completion handler: it is delivered on the main
        // queue, and this runs on the main thread, so waiting for it here is a
        // deadlock - measured, the report generation stopped dead at this line.
        // The script below waits for the document to appear instead, which is
        // the thing actually being waited for.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: application,
                                configuration: configuration, completionHandler: nil)
        guard let answer = execute(openScript, [name]) else { return nil }
        return document(from: answer)
    }

    /// The document id, its body text and its items out of what the open script
    /// answers; nil when the answer is not that.
    static func document(from answer: NSAppleEventDescriptor) -> (String, String, [Item])? {
        guard answer.numberOfItems == 3,
              let identifier = answer.atIndex(1)?.stringValue, !identifier.isEmpty,
              let body = answer.atIndex(2)?.stringValue,
              let found = answer.atIndex(3) else { return nil }
        var items: [Item] = []
        if found.numberOfItems > 0 {
            for position in 1...found.numberOfItems {
                guard let entry = found.atIndex(position), entry.numberOfItems == 3,
                      let kind = entry.atIndex(1)?.stringValue,
                      let location = entry.atIndex(2)?.stringValue, isLocation(location),
                      let payload = entry.atIndex(3) else { return nil }
                switch kind {
                case "text":
                    guard let text = payload.stringValue else { return nil }
                    items.append(.text(location: location, text: text))
                case "table":
                    var cells: [String] = []
                    if payload.numberOfItems > 0 {
                        for cell in 1...payload.numberOfItems {
                            cells.append(payload.atIndex(cell)?.stringValue ?? "")
                        }
                    }
                    items.append(.table(location: location, cells: cells))
                default:
                    return nil
                }
            }
        }
        return (identifier, body, items)
    }

    /// One or more positive indices joined by dots, as the open script writes
    /// them; anything else would send the write script to the wrong item.
    static func isLocation(_ location: String) -> Bool {
        let steps = location.split(separator: ".", omittingEmptySubsequences: false)
        return !steps.isEmpty && steps.allSatisfy { step in
            !step.isEmpty && step.allSatisfy(\.isASCII) && step.allSatisfy(\.isNumber) && (Int(step) ?? 0) > 0
        }
    }

    /// `on run argv` is reached by sending the script an open-application event
    /// whose direct object is the argument list; that is how AppleScript passes
    /// argv, and it is the only way to hand a script a value from here.
    private static func execute(_ source: String, _ arguments: [String]) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else {
            NSLog("---- the script that fills in a Pages document would not compile")
            return nil
        }
        let list = NSAppleEventDescriptor.list()
        for (index, value) in arguments.enumerated() {
            list.insert(NSAppleEventDescriptor(string: value), at: index + 1)
        }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                           eventID: AEEventID(kAEOpenApplication),
                                           targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            NSLog("---- the Pages document could not be filled in: %@", error)
            return nil
        }
        return result
    }

    private static func run(_ source: String, _ arguments: [String]) -> String? {
        guard let result = execute(source, arguments) else { return nil }
        return result.stringValue ?? "done"
    }
}
