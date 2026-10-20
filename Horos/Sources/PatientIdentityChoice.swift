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

/// The identity a patient unification keeps, chosen in the alert that asks
/// for it.
///
/// Studies selected to be unified can carry names that differ only by a
/// character that is easy to miss ("Anon", "Anon.", "Anonˆ"). The alert
/// lists each identity once, in the order of the rows, with the name between
/// guillemets so the difference shows, and starts on the identity of the last
/// selected row. Under the menu it lists every study the chosen identity
/// changes, so this one alert answers for all of them.
@objc(HorosPatientIdentityChoice)
public final class PatientIdentityChoice: NSObject {

    /// What tells two studies' patients apart in the list: the name exactly as
    /// stored, the patient ID and the birth date.
    struct Identity: Hashable {
        let name: String
        let patientID: String
        let birthDate: Date?
    }

    /// One line of the list: an identity, the study whose fields it stands
    /// for, and how many of the studies carry it.
    struct Entry: Equatable {
        let identity: Identity
        let representative: Int
        let count: Int
    }

    /// One entry per distinct identity, in the order the studies come. The
    /// representative is the first study with that identity, except for the
    /// preferred study's identity, which keeps the preferred study: choosing
    /// it changes nothing from what the alert did before. Returns the index of
    /// the preferred study's entry too.
    static func entries(for identities: [Identity], preferred: Int) -> (entries: [Entry], selected: Int) {
        var order: [Identity] = []
        var first: [Identity: Int] = [:]
        var counts: [Identity: Int] = [:]
        for (index, identity) in identities.enumerated() {
            if first[identity] == nil {
                first[identity] = index
                order.append(identity)
            }
            counts[identity, default: 0] += 1
        }
        let preferredIdentity = identities.indices.contains(preferred) ? identities[preferred] : nil
        let entries = order.map { identity in
            Entry(identity: identity,
                  representative: identity == preferredIdentity ? preferred : first[identity]!,
                  count: counts[identity]!)
        }
        let selected = entries.firstIndex { $0.identity == preferredIdentity } ?? 0
        return (entries, selected)
    }

    /// «name» · ID · birth date · n studies. The guillemets show a leading or
    /// trailing space; a missing ID or birth date shows as a dash.
    static func label(for entry: Entry, birthDateText: (Date) -> String) -> String {
        let identity = entry.identity
        let studies = entry.count == 1
            ? NSLocalizedString("1 study", comment: "Number of studies with one patient identity, in the Unify Patient Identity alert")
            : String(format: NSLocalizedString("%d studies", comment: "Number of studies with one patient identity, in the Unify Patient Identity alert"), Int32(clamping: entry.count))
        return ["«\(identity.name)»",
                identity.patientID.isEmpty ? "—" : identity.patientID,
                identity.birthDate.map(birthDateText) ?? "—",
                studies].joined(separator: "  ·  ")
    }

    private static func identity(of study: NSObject) -> Identity {
        Identity(name: study.value(forKey: "name") as? String ?? "",
                 patientID: study.value(forKey: "patientID") as? String ?? "",
                 birthDate: study.value(forKey: "dateOfBirth") as? Date)
    }

    /// The studies a unification to `destination` changes, one line each:
    /// «name» · ID · study description. A study that already has the identity
    /// is not listed, as the unification leaves it alone.
    static func changes(of studies: [NSObject], to destination: NSObject) -> [String] {
        studies.filter { $0 !== destination && !study($0, hasIdentityOf: destination) }.map { study in
            let id = study.value(forKey: "patientID") as? String ?? ""
            let description = study.value(forKey: "studyName") as? String ?? ""
            return ["«\(study.value(forKey: "name") as? String ?? "")»", id.isEmpty ? "—" : id,
                    description.isEmpty ? "—" : description].joined(separator: "  ·  ")
        }
    }

    /// Whether a study already has the identity a unification gives it, in
    /// the database fields the unification writes: then there is nothing to
    /// confirm nor to change.
    @objc(study:hasIdentityOf:)
    public static func study(_ study: NSObject, hasIdentityOf destination: NSObject) -> Bool {
        for key in ["name", "patientID", "patientUID"] {
            let a = study.value(forKey: key) as? String ?? ""
            let b = destination.value(forKey: key) as? String ?? ""
            if a != b { return false }
        }
        return true
    }

    /// Runs the Unify Patient Identity alert for the selected studies, with a
    /// menu of their identities that starts on the preferred study's. Returns
    /// the historical response of the alert's buttons (Database & DICOM,
    /// Database only, Cancel) and, unless cancelled, the study whose identity
    /// was chosen.
    @MainActor @objc(runUnifyAlertForStudies:preferredStudy:chosenStudy:)
    public static func runUnifyAlert(for studies: [NSObject], preferred: NSObject,
                                     chosen: AutoreleasingUnsafeMutablePointer<NSObject?>) -> Int {
        let preferredIndex = studies.firstIndex { $0 === preferred } ?? 0
        let (entries, selected) = entries(for: studies.map(identity(of:)), preferred: preferredIndex)

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        // Through the menu: addItem(withTitle:) would drop an item whose title
        // an earlier one already has.
        for entry in entries {
            popUp.menu?.addItem(NSMenuItem(title: label(for: entry, birthDateText: formatter.string(from:)), action: nil, keyEquivalent: ""))
        }
        popUp.selectItem(at: selected)
        popUp.sizeToFit()

        let caption = NSTextField(labelWithString: NSLocalizedString("Identity to keep:", comment: "Label of the menu of identities in the Unify Patient Identity alert"))
        caption.sizeToFit()
        let width = min(max(popUp.frame.width, caption.frame.width, 360), 560)

        // Below the menu, every study the chosen identity changes, in one
        // list that follows the menu: no confirmation per study afterwards.
        let changesCaption = NSTextField(labelWithString: "")
        let changesText = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        changesText.isEditable = false
        changesText.drawsBackground = false
        changesText.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        changesText.textContainerInset = NSSize(width: 2, height: 4)
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: changesText.font!))
        let listHeight = lineHeight * CGFloat(min(max(studies.count - 1, 1), 8)) + 10
        let changesList = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: listHeight))
        changesList.borderType = .bezelBorder
        changesList.hasVerticalScroller = true
        changesList.autohidesScrollers = true
        changesList.documentView = changesText
        changesText.autoresizingMask = [.width]
        let update = ChangeListUpdate { index in
            guard entries.indices.contains(index) else { return }
            let lines = changes(of: studies, to: studies[entries[index].representative])
            changesCaption.stringValue = lines.isEmpty
                ? NSLocalizedString("No study changes: all of them have this identity already.", comment: "Unify Patient Identity alert, when the chosen identity is everyone's")
                : NSLocalizedString("Studies that will change:", comment: "Unify Patient Identity alert, above the list of the studies the chosen identity changes")
            changesText.string = lines.joined(separator: "\n")
        }
        popUp.target = update
        popUp.action = #selector(ChangeListUpdate.popUpChanged(_:))
        update.popUpChanged(popUp)
        changesCaption.sizeToFit()
        changesCaption.frame.size.width = width

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width,
                                             height: caption.frame.height + 6 + popUp.frame.height + 12 + changesCaption.frame.height + 4 + listHeight))
        changesList.frame.origin = .zero
        changesCaption.setFrameOrigin(NSPoint(x: 0, y: listHeight + 4))
        popUp.frame = NSRect(x: -3, y: changesCaption.frame.maxY + 12, width: width + 3, height: popUp.frame.height)
        caption.setFrameOrigin(NSPoint(x: 0, y: popUp.frame.maxY + 6))
        for view in [caption, popUp, changesCaption, changesList] as [NSView] {
            accessory.addSubview(view)
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("Unify Patient Identity", comment: "")
        alert.informativeText = NSLocalizedString("Are you sure you want to unify the patient identity of the selected studies? It cannot be cancelled. You can choose to modify the database fields only, or also change the DICOM files headers with the new values.\r\rThe Patient Name and ID of all these studies will become the identity chosen below.\r\rThe original Patient Name and Patient ID will be saved in the OtherPatientNames and OtherPatientIDs DICOM fields.", comment: "Unify Patient Identity alert, above the menu of identities")
        alert.addButton(withTitle: NSLocalizedString("Database & DICOM", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Database only", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = popUp

        // The menu's target is weak: the update lives until the alert closes.
        let response = withExtendedLifetime(update) { alert.runModal() }
        let index = popUp.indexOfSelectedItem
        if entries.indices.contains(index) {
            chosen.pointee = studies[entries[index].representative]
        }
        switch response {
        case .alertFirstButtonReturn: return HorosAlertPanel.defaultResponse
        case .alertSecondButtonReturn: return HorosAlertPanel.alternateResponse
        default: return HorosAlertPanel.otherResponse
        }
    }
}

/// The target of the identity menu: shows the studies the chosen identity
/// changes.
@MainActor private final class ChangeListUpdate: NSObject {
    private let update: @MainActor (Int) -> Void

    init(_ update: @escaping @MainActor (Int) -> Void) {
        self.update = update
    }

    @objc func popUpChanged(_ sender: NSPopUpButton) {
        update(sender.indexOfSelectedItem)
    }
}
