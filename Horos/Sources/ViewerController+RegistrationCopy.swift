//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit
import IsiXImaging

extension NSMenu {
    /// The item that sends `action`, in this menu or one of its submenus,
    /// with the menu that holds it.
    func horosItem(sending action: Selector) -> (item: NSMenuItem, menu: NSMenu)? {
        for item in items {
            if item.action == action { return (item, self) }
            if let found = item.submenu?.horosItem(sending: action) { return found }
        }
        return nil
    }
}

/// "Copy ROIs from Fused Series...": the ROI menu item and its dialog, which
/// confirms a comparison of two patients, previews the plan (quality,
/// algorithm, placements, refusals), takes a manual offset in millimetres,
/// and copies under one undo entry (ViewerController+RegistrationHost.swift).
extension ViewerController {

    /// Adds "Copy ROIs from Fused Series..." to the ROI menu after the JSON
    /// export item.
    @objc class func installRegistrationMenuItems() {
        guard let menu = NSApp.mainMenu, menu.horosItem(sending: #selector(copyROIsFromFusedSeries(_:))) == nil else { return }
        guard let anchor = menu.horosItem(sending: #selector(roiExportInterchange(_:))) else {
            NSLog("Registration: ROI export menu item not found; guided copy item not installed")
            return
        }
        let item = NSMenuItem(title: NSLocalizedString("Copy ROIs from Fused Series...", comment: ""),
                              action: #selector(copyROIsFromFusedSeries(_:)), keyEquivalent: "")
        item.target = nil // first responder: the front 2D viewer
        anchor.menu.insertItem(item, at: anchor.menu.index(of: anchor.item) + 1)
    }

    /// An alert with this title and text, run modally.
    private func runRegistrationAlert(_ informativeText: String) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Copy ROIs from Fused Series", comment: "")
        alert.informativeText = informativeText
        alert.runModal()
    }

    /// The offset typed in the three fields.
    private func registrationOffset(_ fields: [NSTextField]) -> [Double] {
        return FusionComparison.offset(fields.map(\.doubleValue))
    }

    /// Menu action: preview, manual offset, confirmation, then one undoable copy.
    @IBAction @objc(copyROIsFromFusedSeries:)
    func copyROIsFromFusedSeries(_ sender: Any?) {
        guard let source = blending() else {
            runRegistrationAlert(NSLocalizedString("No fused series. Fuse a series onto this viewer first (Fusion dialog).", comment: ""))
            return
        }
        if let pending = horosPatientComparisonPending(with: source) {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Compare two different patients?", comment: "")
            alert.informativeText = String(format: NSLocalizedString("The fused series belongs to another patient. Confirm the comparison of these two studies explicitly; they are never matched by name:\n%@", comment: ""), pending)
            alert.addButton(withTitle: NSLocalizedString("Compare", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            if alert.runModal() != .alertFirstButtonReturn { return }
            horosConfirmPatientComparison(with: source)
        }
        var offset: [Double] = [0, 0, 0]
        while true {
            let outcome = guidedCopyPlan(from: source, offsetMM: offset)
            guard var plan = outcome.plan else {
                runRegistrationAlert(outcome.refusal ?? "")
                return
            }
            let overlay = horosRegistrationSession().companion(source.horosSeriesDICOMUID())
            let quality = overlay?.quality?.summary
                ?? NSLocalizedString("Shared frame of reference: identity transform, no registration estimated.", comment: "")
            let alert = NSAlert()
            alert.messageText = String(format: NSLocalizedString("Copy %lu ROI(s) by patient position?", comment: ""), plan.placed.count)
            alert.informativeText = "\(quality)\n\(plan.transform.algorithm) \(plan.transform.version)\n\n\(plan.summary)"
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 48))
            let label = NSTextField(frame: NSRect(x: 0, y: 26, width: 320, height: 18))
            label.stringValue = NSLocalizedString("Manual offset in target millimetres (x, y, z):", comment: "")
            label.isEditable = false
            label.isBordered = false
            label.drawsBackground = false
            accessory.addSubview(label)
            let fields = (0..<3).map { i -> NSTextField in
                let field = NSTextField(frame: NSRect(x: CGFloat(i * 108), y: 0, width: 100, height: 22))
                field.doubleValue = offset[i]
                accessory.addSubview(field)
                return field
            }
            alert.accessoryView = accessory
            alert.addButton(withTitle: NSLocalizedString("Copy", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Preview with Offset", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                offset = registrationOffset(fields)
                continue
            }
            if response != .alertFirstButtonReturn { return }
            let finalOffset = registrationOffset(fields)
            if finalOffset != offset {
                guard let replanned = guidedCopyPlan(from: source, offsetMM: finalOffset).plan else { return }
                plan = replanned
            }
            let added = horosApplyGuidedCopyPlan(plan, from: source)
            NSLog("Guided ROI copy: %ld ROI(s) added, %lu refused", added, plan.refused.count)
            return
        }
    }
}
