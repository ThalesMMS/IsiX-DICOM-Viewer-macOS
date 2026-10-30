/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit
import IsiXDatabase

// The browser's menus: the list's and the albums' contextual menus, the Help
// menu, and the validation of the browser's commands, which also titles Delete
// and Merge after the selection. What decides without the app's classes is
// IsiXDatabase's BrowserMenuValidation. The selectors are those of the former
// Objective-C methods.

/// [value boolValue]: NO for nil and for what is neither a number nor a string.
private func boolValue(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? NSString { return string.boolValue }
    return false
}

/// The rows of a selection in order: the position in the selection, the row.
private func rows(_ selection: IndexSet) -> [Int] {
    Array(selection)
}

/// What the browser's menu validation asks, read from the window when asked.
@MainActor private struct BrowserMenuState {
    let browser: BrowserController
    let item: NSMenuItem
    let selection: [Int]

    init(browser: BrowserController, item: NSMenuItem) {
        self.browser = browser
        self.item = item
        self.selection = rows(browser.horos_databaseOutline?.selectedRowIndexes ?? IndexSet())
    }

    func object(at position: Int) -> NSObject? {
        browser.horos_databaseOutline?.item(atRow: selection[position]) as? NSObject
    }
}

extension BrowserMenuState: @MainActor BrowserMenuFacts {
    func selectedCount() -> Int { selection.count }
    func selectedType(at position: Int) -> Any? { object(at: position)?.value(forKey: "type") }
    func selectedLocked(at position: Int) -> Any? { object(at: position)?.value(forKey: "lockedStudy") }
    func databaseIsLocal() -> Bool { browser.horos_databaseIvar?.isLocal() ?? false }
    func databaseIsReadOnly() -> Bool { browser.horos_databaseIvar?.isReadOnly ?? false }

    /// [databaseOutline itemAtRow: [[databaseOutline selectedRowIndexes] firstIndex]].
    private func firstSelected() -> NSObject? {
        guard let first = selection.first else { return nil }
        return browser.horos_databaseOutline?.item(atRow: first) as? NSObject
    }

    func firstSelectedHasItem() -> Bool { firstSelected() != nil }

    func firstSelectedStudyHasReport() -> Bool {
        guard let item = firstSelected() else { return false }
        let isStudy = (item.value(forKey: "type") as? NSString)?.isEqual(to: "Study") ?? false
        let study = isStudy ? item : item.value(forKey: "study") as? NSObject
        return study?.value(forKey: "reportURL") != nil
    }

    func isImageTileMenu() -> Bool { item.menu === browser.horos_imageTileMenu }
    func mainWindowIsViewer() -> Bool { NSApp.mainWindow?.windowController is ViewerController }
    func commentsAutoFill() -> Bool { UserDefaults.standard.bool(forKey: "COMMENTSAUTOFILL") }
    func roiImageCount() -> Int { browser.roiImages(item)?.count ?? 0 }
    func roisAndKeyImageCount() -> Int { browser.roisAndKeyImages(item)?.count ?? 0 }
    func keyImageCount() -> Int { browser.keyImages(item)?.count ?? 0 }
    func isThumbnailMenuItem() -> Bool { browser.isThumbnailMenuItem(item) }

    func selectionHasLinkedFiles(fromThumbnails: Bool) -> Bool {
        let objects = NSMutableArray()
        let files = fromThumbnails ? browser.files(forDatabaseMatrixSelection: objects, onlyImages: false)
            : browser.files(forDatabaseOutlineSelection: objects, onlyImages: false)
        files?.removeDuplicatedStrings(inSyncWithThisArray: objects)
        for case let image as NSObject in objects where !boolValue(image.value(forKey: "inDatabaseFolder")) {
            return true
        }
        return false
    }

    // Compared as the former pointers were: two nils are the same.
    func firstResponderIsThumbnails() -> Bool { browser.window?.firstResponder === browser.horos_oMatrix }
    func isListMenuItem() -> Bool { item.menu === browser.horos_databaseOutline?.menu }
    func firstResponderIsList() -> Bool { browser.window?.firstResponder === browser.horos_databaseOutline }
    func firstResponderIsHistory() -> Bool { browser.window?.firstResponder === browser.horos_comparativeTable }
    func selectedThumbnailCount() -> Int { browser.horos_oMatrix?.selectedCells.count ?? 0 }
    func itemTag() -> Int { item.tag }
    func annotationsMode() -> Int { UserDefaults.standard.integer(forKey: "ANNOTATIONS") }
}

extension BrowserController {

    // MARK: - Contextual menus

    /// The list's contextual menu and the albums' (the columns menu has its
    /// own): built again each time it opens, after the selection and the
    /// database.
    @objc(menuWillOpen:)
    public func menuWillOpen(_ menu: NSMenu) {
        if menu === horos_columnsMenu {
            columnsMenuWillOpen()
            return
        }

        menu.removeAllItems()

        let isWritable = !(self.database?.isReadOnly ?? false)

        if let albums = horos_albumTable?.menu, menu === albums {
            if self.database?.isLocal() ?? false {
                let row = horos_albumTable?.clickedRow ?? 0

                func add(_ title: String, _ action: Selector) {
                    let item = NSMenuItem(title: NSLocalizedString(title, comment: ""), action: action, keyEquivalent: "")
                    item.target = self // required because the drawer is the first responder
                    menu.addItem(item)
                }

                if !(horos_databaseIvar?.isReadOnly ?? false) {
                    add("Edit Album", #selector(albumTableDoublePressed(_:)))
                    menu.addItem(.separator())
                    add("Add Album", #selector(addAlbum(_:)))
                    add("Add Smart Album", #selector(addSmartAlbum(_:)))
                    menu.addItem(.separator())

                    if row > 0 { // index 0 is database, cannot be removed. Negative index = click on empty table (not on a particular item)
                        add("Delete Album", NSSelectorFromString("removeAlbum:"))
                        menu.addItem(.separator())
                    }
                }

                add("Save Albums", #selector(saveAlbums(_:)))
                add("Import Albums", #selector(addAlbums(_:)))
                menu.addItem(.separator())
                add("Create Default Albums", #selector(defaultAlbums(_:)))
            }
            return
        }

        // The less frequent commands are grouped in submenus, and what does not
        // apply to the selection is hidden at the end instead of dimmed.
        let groups = NSMutableArray()
        func addGroup(_ title: String) -> NSMenu {
            let group = NSMenu(title: title)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = group
            menu.addItem(item)
            groups.add(group)
            return group
        }
        func add(_ title: String, _ action: String, to target: NSMenu? = nil) {
            (target ?? menu).addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: "")
        }
        func ellipsis(_ title: String) -> String { NSLocalizedString(title, comment: "") + "\u{2026}" }
        var group: NSMenu

        add(NSLocalizedString("Display only this patient", comment: ""), "searchForCurrentPatient:")

        menu.addItem(.separator())
        add(NSLocalizedString("Open Images", comment: ""), "viewerDICOM:")
        add(NSLocalizedString("Open Images in 4D", comment: ""), "MovieViewerDICOM:")
        group = addGroup(NSLocalizedString("Open Special", comment: ""))
        add(NSLocalizedString("Sub-Selection", comment: ""), "viewerSubSeriesDICOM:", to: group)
        add(NSLocalizedString("Reparsed Series", comment: ""), "viewerReparsedSeries:", to: group)
        add(NSLocalizedString("Merged Selection", comment: ""), "viewerDICOMMergeSelection:", to: group)
        group.addItem(.separator())
        add(NSLocalizedString("Key Images", comment: ""), "viewerDICOMKeyImages:", to: group)
        add(NSLocalizedString("ROIs Images", comment: ""), "viewerDICOMROIsImages:", to: group)
        add(NSLocalizedString("ROIs and Key Images", comment: ""), "viewerKeyImagesAndROIsImages:", to: group)
        add(NSLocalizedString("Reveal In Finder", comment: ""), "revealInFinder:")

        menu.addItem(.separator())
        if let workspace = AppController.shared()?.workspaceMenu() {
            group = addGroup(NSLocalizedString("Workspace State", comment: ""))
            let load = NSMenuItem(title: NSLocalizedString("Load DICOM SR", comment: ""), action: nil, keyEquivalent: "")
            load.submenu = workspace.copy() as? NSMenu
            group.addItem(load)
            add(NSLocalizedString("Reset", comment: ""), "resetWindowsState:", to: group)
        }
        group = addGroup(NSLocalizedString("Export", comment: ""))
        add(ellipsis("DICOM Network Node"), "export2PACS:", to: group)
        add(ellipsis("DICOM File(s)"), "exportDICOMFile:", to: group)
        add(ellipsis("Email"), "sendMail:", to: group)
        group.addItem(.separator())
        add(ellipsis("Movie"), "exportQuicktime:", to: group)
        add(ellipsis("JPEG"), "exportJPEG:", to: group)
        add(ellipsis("TIFF"), "exportTIFF:", to: group)
        group.addItem(.separator())
        add(NSLocalizedString("ROI and Key Images as a DICOM Series", comment: ""), "exportROIAndKeyImagesAsDICOMSeries:", to: group)
        if isWritable {
            group.addItem(.separator())
            add(ellipsis("Burn to Disc"), "burnDICOM:", to: group)
        }

        if isWritable {
            group = addGroup(NSLocalizedString("Web Portal Users", comment: ""))
            add(NSLocalizedString("Add selected study(s) to user(s)", comment: ""), "addStudiesToUser:", to: group)
            add(NSLocalizedString("Send an email notification to user(s)", comment: ""), "sendEmailNotification:", to: group)
        }

        if isWritable { // TODO: allow report access, read-only
            add(NSLocalizedString("Create/Open Report", comment: ""), "generateReport:")
            group = addGroup(NSLocalizedString("Convert Report", comment: ""))
            add(ellipsis("Convert to PDF"), "convertReportToPDF:", to: group)
            add(NSLocalizedString("Convert to DICOM PDF", comment: ""), "convertReportToDICOMSR:", to: group)
        }

        if isWritable {
            menu.addItem(.separator())
            add(NSLocalizedString("Lock Studies", comment: ""), "lockStudies:")
            add(NSLocalizedString("Unlock Studies", comment: ""), "unlockStudies:")
            add(NSLocalizedString("Merge Selected Studies", comment: ""), "mergeStudies:")
            add(NSLocalizedString("Unify patient identity", comment: ""), "unifyStudies:")
            add(NSLocalizedString("Anonymize", comment: ""), "anonymizeDICOM:")

            menu.addItem(.separator())
            add(NSLocalizedString("Compress DICOM files", comment: ""), "compressSelectedFiles:")
            add(NSLocalizedString("Decompress DICOM files", comment: ""), "decompressSelectedFiles:")
            group = addGroup(NSLocalizedString("Files & Maintenance", comment: ""))
            add(NSLocalizedString("Rebuild Selected Thumbnails", comment: ""), "rebuildThumbnails:", to: group)
            add(NSLocalizedString("Regenerate Auto-Fill Comment field", comment: ""), "regenerateAutoComments:", to: group)
            add(NSLocalizedString("Copy Linked Files to Database Folder", comment: ""), "copyToDBFolder:", to: group)

            menu.addItem(.separator())
            add(NSLocalizedString("Query Selected Patient from Q&R Window...", comment: ""), "querySelectedStudy:")
        }

        let autoroutingRules = UserDefaults.standard.array(forKey: "AUTOROUTINGDICTIONARY") as NSArray?

        if isWritable && (autoroutingRules?.count ?? 0) != 0, let autoroutingRules {
            menu.addItem(.separator())

            let title = NSLocalizedString("Apply this Routing Rule to Selection", comment: "")
            let submenu = NSMenu(title: title)

            submenu.addItem(NSMenuItem(title: NSLocalizedString("All routing rules", comment: ""), action: NSSelectorFromString("applyRoutingRule:"), keyEquivalent: ""))
            submenu.addItem(.separator())

            for case let routingRule as NSObject in autoroutingRules {
                let name = routingRule.value(forKey: "name")
                let ruleTitle: String
                if let description = routingRule.value(forKey: "description") as? NSString, description.length > 0 {
                    ruleTitle = String(format: "%@ - %@", (name as? NSObject) ?? "(null)" as NSString, description)
                } else {
                    ruleTitle = name as? String ?? ""
                }
                let item = NSMenuItem(title: ruleTitle, action: NSSelectorFromString("applyRoutingRule:"), keyEquivalent: "")
                item.representedObject = routingRule
                // Disabled whether the rule is activated or not.
                item.isEnabled = false
                submenu.addItem(item)
            }

            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }

        if isWritable {
            menu.addItem(.separator())
            add(NSLocalizedString("Delete", comment: ""), "delItem:")
        }

        // Validating here also sets the titles that follow the selection, such
        // as Delete Selected Lines and Merge Selected Series.
        ContextMenuPruning.hideUnavailableItems(in: menu, groups: groups as? [NSMenu] ?? [], defaultTarget: self)
    }

    @objc(addHelpMenu)
    func addHelpMenu() {
        let mainMenu = NSApplication.shared.mainMenu
        let helpItem = mainMenu?.addItem(withTitle: NSLocalizedString("Help", comment: ""), action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: NSLocalizedString("Help", comment: ""))
        helpItem?.submenu = helpMenu

        helpMenu.addItem(withTitle: NSLocalizedString("Professional support", comment: ""), action: NSSelectorFromString("openHorosSupport:"), keyEquivalent: "")
        helpMenu.addItem(withTitle: NSLocalizedString("Community support", comment: ""), action: NSSelectorFromString("openCommunityPage:"), keyEquivalent: "")
        helpMenu.addItem(.separator())
        helpMenu.addItem(withTitle: NSLocalizedString("Report a bug", comment: ""), action: NSSelectorFromString("openBugReportPage:"), keyEquivalent: "")
    }

    // MARK: - Validating the commands

    @objc(validateMenuItem:)
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let outline = horos_databaseOutline
        let selection = outline?.selectedRowIndexes ?? IndexSet()

        if menuItem.action == #selector(attachExistingReport(_:)) || menuItem.action == #selector(insertSelectedImagesIntoReport(_:)) {
            guard let database = self.database, database.isLocal(), !database.isReadOnly, selection.count == 1 else { return false }
            let item = outline?.item(atRow: selection.first ?? -1) as? NSObject
            if isDistantRow(item) { return false }
            let isStudy = (item?.value(forKey: "type") as? NSString)?.isEqual(to: "Study") ?? false
            let study = isStudy ? item : item?.value(forKey: "study") as? NSObject
            guard let study, !boolValue(study.value(forKey: "lockedStudy")) else { return false }
            if menuItem.action == #selector(attachExistingReport(_:)) { return true }

            let report = study.value(forKey: "reportURL") as? String ?? ""
            return !report.isEmpty && FileManager.default.fileExists(atPath: report)
                && ReportImageInsertion.kind(ofReportPath: report) != .unsupported
        }

        var containsDistantStudy = false
        for row in selection where isDistantRow(outline?.item(atRow: row)) {
            containsDistantStudy = true
            break
        }

        let answer = BrowserMenuValidation.validate(action: menuItem.action.map(NSStringFromSelector) ?? "",
                                                    containsDistantStudy: containsDistantStudy,
                                                    facts: BrowserMenuState(browser: self, item: menuItem))
        switch answer.title {
        case .deleteSelectedSeriesThumbnails: menuItem.title = NSLocalizedString("Delete Selected Series Thumbnails", comment: "")
        case .deleteSelectedLines: menuItem.title = NSLocalizedString("Delete Selected Lines", comment: "")
        case .mergeSelectedSeries: menuItem.title = NSLocalizedString("Merge Selected Series", comment: "")
        case .mergeSelectedStudies: menuItem.title = NSLocalizedString("Merge Selected Studies", comment: "")
        case nil: break
        }
        if let checked = answer.checked { menuItem.state = checked ? .on : .off }
        return answer.enabled
    }

    // MARK: - Locking studies

    @objc(unlockStudies:)
    @IBAction func unlockStudies(_ sender: Any!) {
        let outline = horos_databaseOutline
        for row in outline?.selectedRowIndexes ?? IndexSet() {
            let object = outline?.item(atRow: row) as? NSObject
            if StudyLocking.unlocks(type: object?.value(forKey: "type"), locked: { object?.value(forKey: "lockedStudy") }) {
                object?.setValue(NSNumber(value: false), forKey: "lockedStudy")
            }
        }
        refreshDatabase(self)
    }

    @objc(lockStudies:)
    @IBAction func lockStudies(_ sender: Any!) {
        let outline = horos_databaseOutline
        for row in outline?.selectedRowIndexes ?? IndexSet() {
            let object = outline?.item(atRow: row) as? NSObject
            if StudyLocking.locks(type: object?.value(forKey: "type"), locked: { object?.value(forKey: "lockedStudy") }) {
                object?.setValue(NSNumber(value: true), forKey: "lockedStudy")
            }
        }
        refreshDatabase(self)
    }
}
