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

/// The queue of Query & Retrieve downloads as Activity shows it: a waiting
/// retrieve's line gives its place, and its context menu moves it in the
/// queue or names it.
@objc(HorosRetrieveQueueActivity)
public final class RetrieveQueueActivity: NSObject {

    /// The status of a retrieve waiting in line: its place and what it
    /// retrieves.
    @objc(waitingStatus:position:)
    public static func waitingStatus(_ status: String, position: Int) -> String {
        String(format: NSLocalizedString("Waiting in queue (%ld) - %@", comment: "Activity status of a Query & Retrieve download waiting for its turn: its place in the queue, then what it retrieves"), position, status)
    }

    @MainActor private static let shared = RetrieveQueueActivity()

    /// The context menu of an Activity line: Move to Top, Up and Down while
    /// the retrieve waits, and Rename… until it ends. Nil for a line that is
    /// not a queued retrieve.
    @MainActor @objc(menuForThread:)
    public static func menu(for thread: Thread) -> NSMenu? {
        guard !thread.isFinished, let ticket = RetrieveQueue.ticket(of: thread) else { return nil }
        let queue = RetrieveQueue.shared
        let position = queue.position(of: ticket)
        let menu = NSMenu()
        menu.autoenablesItems = false
        if position > 0 {
            let moves: [(String, RetrieveQueue.Move, Bool)] = [
                (NSLocalizedString("Move to Top", comment: "Activity menu: a waiting download goes first in the queue"), .top, position > 1),
                (NSLocalizedString("Move Up", comment: "Activity menu: a waiting download goes one place ahead in the queue"), .up, position > 1),
                (NSLocalizedString("Move Down", comment: "Activity menu: a waiting download goes one place back in the queue"), .down, position < queue.waitingCount),
            ]
            for (title, move, enabled) in moves {
                let item = NSMenuItem(title: title, action: #selector(moveTicket(_:)), keyEquivalent: "")
                item.target = shared
                item.tag = move.rawValue
                item.representedObject = ticket
                item.isEnabled = enabled
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let rename = NSMenuItem(title: NSLocalizedString("Rename…", comment: "Activity menu: names a queued download"), action: #selector(renameThread(_:)), keyEquivalent: "")
        rename.target = shared
        rename.representedObject = thread
        menu.addItem(rename)
        return menu
    }

    @MainActor @objc private func moveTicket(_ sender: NSMenuItem) {
        guard let ticket = sender.representedObject as? RetrieveQueue.Ticket,
              let move = RetrieveQueue.Move(rawValue: sender.tag) else { return }
        RetrieveQueue.shared.move(move, ticket)
    }

    /// Asks for the name the line shows until the retrieve ends; an empty name
    /// gives back the usual one.
    @MainActor @objc private func renameThread(_ sender: NSMenuItem) {
        guard let thread = sender.representedObject as? Thread, let ticket = RetrieveQueue.ticket(of: thread) else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Rename Download", comment: "Title of the dialog that names a queued download in Activity")
        alert.informativeText = NSLocalizedString("The name Activity shows for this download until it ends. Leave it empty for the usual name.", comment: "Text of the dialog that names a queued download in Activity")
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = RetrieveQueue.shared.label(of: ticket) ?? ""
        field.placeholderString = NSLocalizedString("Retrieving images...", comment: "")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, !thread.isFinished else { return }
        RetrieveQueue.shared.setLabel(field.stringValue, of: ticket)
        thread.name = RetrieveQueue.shared.label(of: ticket) ?? NSLocalizedString("Retrieving images...", comment: "")
    }
}
