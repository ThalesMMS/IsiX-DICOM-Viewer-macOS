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
import CoreData
import IsiXImaging
import IsiXPreferences

/// The menus of the main menu bar that the application fills in: the menus
/// found by their resource identifier, the presets menus of the Viewer menu
/// (window level and width, colour tables, convolution filters, opacity
/// tables), the workspace states saved as DICOM SR, and Recent Studies.
///
/// MainMenu.xib keeps the application controller as the delegate of the
/// workspace menu and as the owner of the Recent Studies outlet; it hands
/// both over to this object.
@MainActor
final class ApplicationMenus: NSObject, NSMenuItemValidation {

    typealias MenuSource = @MainActor () -> NSMenu?

    private let processGraph: ProcessGraph
    /// The Recent Studies menu of the nib, read when needed: the nib sets the
    /// outlet after this object is made.
    private let recentStudiesMenu: MenuSource

    /// The studies opened last, the latest first, and the album each was
    /// opened from.
    private var recentStudies: [NSManagedObjectID] = []
    private var recentStudiesAlbums: [NSManagedObjectID: String] = [:]

    /// Made by the process graph, the one set of menus of the process.
    init(recentStudiesMenu: @escaping MenuSource, processGraph: ProcessGraph) {
        self.recentStudiesMenu = recentStudiesMenu
        self.processGraph = processGraph
        super.init()
    }

    // MARK: - Lookup

    // Resource identifiers remain stable when menu titles or positions change.
    func viewerMenu() -> NSMenu? { ApplicationMenuLookup.submenu(in: NSApp.mainMenu, identifier: "org.horos.menu.viewer") }
    func fileMenu() -> NSMenu? { ApplicationMenuLookup.submenu(in: NSApp.mainMenu, identifier: "org.horos.menu.file") }
    func exportMenu() -> NSMenu? { ApplicationMenuLookup.submenu(in: fileMenu(), identifier: "org.horos.menu.export") }
    func imageTilingMenu() -> NSMenu? { ApplicationMenuLookup.submenu(in: viewerMenu(), identifier: "org.horos.menu.image-tiling") }
    func orientationMenu() -> NSMenu? { ApplicationMenuLookup.submenu(in: viewerMenu(), identifier: "org.horos.menu.orientation") }
    func opacityMenu() -> NSMenu? { ApplicationMenuLookup.submenu(in: viewerMenu(), identifier: "org.horos.menu.opacity") }
    func wlwwMenu() -> NSMenu? { ApplicationMenuLookup.submenu(in: viewerMenu(), identifier: "org.horos.menu.wlww") }
    func convMenu() -> NSMenu? { ApplicationMenuLookup.submenu(in: viewerMenu(), identifier: "org.horos.menu.convolution") }
    func clutMenu() -> NSMenu? { ApplicationMenuLookup.submenu(in: viewerMenu(), identifier: "org.horos.menu.clut") }
    func workspaceMenu() -> NSMenu? { ApplicationMenuLookup.submenu(in: viewerMenu(), identifier: "org.horos.menu.workspace") }

    /// In debug builds, says in the log which menu a nib change lost.
    func testMenus() {
        #if DEBUG
        NSLog("Testing localization for menus")
        let menus: [(String, NSMenu?)] = [
            ("viewerMenu", viewerMenu()), ("fileMenu", fileMenu()), ("wlwwMenu", wlwwMenu()),
            ("imageTilingMenu", imageTilingMenu()), ("orientationMenu", orientationMenu()),
            ("opacityMenu", opacityMenu()), ("convMenu", convMenu()), ("clutMenu", clutMenu()),
            ("workspaceMenu", workspaceMenu()), ("exportMenu", exportMenu()),
        ]
        // The lookup no longer depends on the language: the localized pass
        // finds what the first one found.
        for suffix in ["", " Localized"] {
            for (name, menu) in menus where menu == nil {
                NSLog("******* WARNING MENU MOVED / RENAMED ! %@%@", name as NSString, suffix as NSString)
            }
        }
        #endif
    }

    // MARK: - Presets menus

    /// A presets menu of the Viewer menu, rebuilt when its presets change.
    private enum PresetMenu: CaseIterable {
        case opacity, windowLevel, convolution, colourTable

        /// The preference that holds the presets.
        var preferenceName: String {
            switch self {
            case .opacity: return ImagePresetPreferences.opacityTables.name
            case .windowLevel: return ImagePresetPreferences.windowLevelPresets.name
            case .convolution: return ImagePresetPreferences.convolutionPresets.name
            case .colourTable: return ImagePresetPreferences.colourTables.name
            }
        }

        /// The notification a change of the presets, or of the current one, posts.
        var notification: Notification.Name {
            switch self {
            case .opacity: return .OsirixUpdateOpacityMenu
            case .windowLevel: return .OsirixUpdateWLWWMenu
            case .convolution: return .OsirixUpdateConvolutionMenu
            case .colourTable: return .OsirixUpdateCLUTMenu
            }
        }
    }

    /// Each presets menu once found, and the presets it was last built from.
    private var presetMenus: [PresetMenu: NSMenu] = [:]
    private var builtPresets: [PresetMenu: AnyObject] = [:]

    /// Rebuilds the presets menus whenever a viewer, a 3D window or the
    /// preferences tell that their presets may have changed.
    func observePresetChanges() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(opacityPresetsDidChange(_:)), name: PresetMenu.opacity.notification, object: nil)
        center.addObserver(self, selector: #selector(windowLevelPresetsDidChange(_:)), name: PresetMenu.windowLevel.notification, object: nil)
        center.addObserver(self, selector: #selector(convolutionPresetsDidChange(_:)), name: PresetMenu.convolution.notification, object: nil)
        center.addObserver(self, selector: #selector(colourTablePresetsDidChange(_:)), name: PresetMenu.colourTable.notification, object: nil)
    }

    /// Builds the four presets menus from the preferences, as the launch does.
    func updatePresetMenus() {
        for presets in PresetMenu.allCases { updatePresetMenu(presets) }
    }

    @objc private func opacityPresetsDidChange(_ note: Notification) { updatePresetMenu(.opacity) }
    @objc private func windowLevelPresetsDidChange(_ note: Notification) { updatePresetMenu(.windowLevel) }
    @objc private func convolutionPresetsDidChange(_ note: Notification) { updatePresetMenu(.convolution) }
    @objc private func colourTablePresetsDidChange(_ note: Notification) { updatePresetMenu(.colourTable) }

    private func menu(for presets: PresetMenu) -> NSMenu? {
        switch presets {
        case .opacity: return opacityMenu()
        case .windowLevel: return wlwwMenu()
        case .convolution: return convMenu()
        case .colourTable: return clutMenu()
        }
    }

    /// Rebuilds the menu of `presets` when the preference holds another
    /// dictionary than the one it was built from. The preferences hand out
    /// the same object until the value changes, so this compares objects,
    /// not contents; a value that is not a dictionary counts as none.
    private func updatePresetMenu(_ presets: PresetMenu) {
        if presetMenus[presets] == nil {
            presetMenus[presets] = menu(for: presets)
        }
        let stored = processGraph.preferences.object(forKey: presets.preferenceName)
        let dictionary = stored as? [String: Any]
        let current: AnyObject? = dictionary == nil ? nil : stored.map { $0 as AnyObject }
        guard current !== builtPresets[presets] else { return }
        builtPresets[presets] = current
        let names = ViewerPresetMenus.sortedNames(dictionary.map { Array($0.keys) } ?? [])
        guard let menu = presetMenus[presets] else { return }
        menu.removeAllItems()
        switch presets {
        case .opacity:
            menu.addItem(withTitle: NSLocalizedString("Linear Table", comment: ""), action: NSSelectorFromString("ApplyOpacity:"), keyEquivalent: "")
            for name in names {
                menu.addItem(withTitle: name, action: NSSelectorFromString("ApplyOpacity:"), keyEquivalent: "")
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: NSLocalizedString("Add an Opacity Table", comment: ""), action: NSSelectorFromString("AddOpacity:"), keyEquivalent: "")
        case .windowLevel:
            menu.addItem(withTitle: NSLocalizedString("Default WL & WW", comment: ""), action: NSSelectorFromString("ApplyWLWW:"), keyEquivalent: "l")
            menu.addItem(withTitle: NSLocalizedString("Other", comment: ""), action: NSSelectorFromString("ApplyWLWW:"), keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("Full dynamic", comment: ""), action: NSSelectorFromString("ApplyWLWW:"), keyEquivalent: "y")
            menu.addItem(NSMenuItem.separator())
            for (index, name) in names.enumerated() {
                menu.addItem(withTitle: ViewerPresetMenus.wlwwPresetTitle(index: index, name: name), action: NSSelectorFromString("ApplyWLWW:"), keyEquivalent: "")
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: NSLocalizedString("Add Current WL/WW", comment: ""), action: NSSelectorFromString("AddCurrentWLWW:"), keyEquivalent: "")
            // This opened the preset-naming sheet, the same one as the item above it,
            // so setting a window without saving it as a preset was reachable only
            // from the viewer's own pop-up menu, which wires it correctly.
            menu.addItem(withTitle: NSLocalizedString("Set WL/WW manually", comment: ""), action: NSSelectorFromString("SetWLWW:"), keyEquivalent: "")
        case .convolution:
            menu.addItem(withTitle: NSLocalizedString("No Filter", comment: ""), action: NSSelectorFromString("ApplyConv:"), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            for name in names {
                menu.addItem(withTitle: name, action: NSSelectorFromString("ApplyConv:"), keyEquivalent: "")
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: NSLocalizedString("Add a Filter", comment: ""), action: NSSelectorFromString("AddConv:"), keyEquivalent: "")
        case .colourTable:
            menu.addItem(withTitle: NSLocalizedString("No CLUT", comment: ""), action: NSSelectorFromString("ApplyCLUT:"), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            for name in names {
                menu.addItem(withTitle: name, action: NSSelectorFromString("ApplyCLUT:"), keyEquivalent: "")
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: NSLocalizedString("Add a CLUT", comment: ""), action: NSSelectorFromString("AddCLUT:"), keyEquivalent: "")
        }
    }

    // MARK: - Workspace states saved as DICOM SR

    /// What an item of the Load Workspace State DICOM SR menu loads.
    private final class SavedWorkspaceState {
        let study: DicomStudy
        let windowsState: [Any]
        init(study: DicomStudy, windowsState: [Any]) {
            self.study = study
            self.windowsState = windowsState
        }
    }

    /// The 2D viewers on screen.
    private func displayedViewers() -> [ViewerController] {
        ViewerController.getDisplayed2DViewers()?.compactMap { $0 as? ViewerController } ?? []
    }

    /// Fills the Load Workspace State DICOM SR menu with the states saved for
    /// the study selected in the database window, when it is the key window,
    /// or else for the study of the first 2D viewer.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        var study: DicomStudy? = nil
        if let browser = processGraph.currentBrowser, browser.window?.isKeyWindow == true {
            study = browser.selectedStudy()
        }
        if study == nil {
            // A viewer without a study is passed over.
            study = displayedViewers().lazy.compactMap { $0.currentStudy() }.first
        }

        if let study {
            var index: Int32 = 1
            for case let image as DicomImage in (study.allWindowsStateSRSeries() ?? []) {
                // The DICOM SR of a state is read by DCMTK through Objective-C,
                // which raises on a file it cannot read: that file is left out.
                let failure = HorosObjCException.caught {
                    let r: SRAnnotation? = SRAnnotation(contentsOfFile: image.completePathResolved())
                    let dataEncapsulated: Data? = r?.dataEncapsulated()
                    let viewers = dataEncapsulated.flatMap { try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) } as? [Any]
                    guard let viewers, !viewers.isEmpty else { return }
                    let last = viewers.last as? [String: Any]

                    var name = last?["name"] as? String
                    if (name ?? "").isEmpty {
                        if last?["date"] != nil {
                            name = UserDefaults.formatDateTime(last?["date"] as? Date)
                        } else {
                            name = NSLocalizedString("State", comment: "").appendingFormat(" %d", index)
                            index += 1
                        }
                    }

                    let mi = NSMenuItem(title: name ?? "", action: #selector(ApplicationMenus.loadWindowsStateDICOMSR(_:)), keyEquivalent: "")
                    mi.representedObject = SavedWorkspaceState(study: study, windowsState: viewers)
                    mi.target = self
                    menu.addItem(mi)
                }
                if let failure { _N2LogExceptionImpl(failure, false, "-[AppController menuNeedsUpdate:]") }
            }
        }

        if menu.numberOfItems == 0 {
            menu.addItem(withTitle: NSLocalizedString("No saved state", comment: ""), action: nil, keyEquivalent: "")
        }
    }

    @objc private func loadWindowsStateDICOMSR(_ menuItem: NSMenuItem) {
        guard let saved = menuItem.representedObject as? SavedWorkspaceState else { return }
        let state: [Any]? = saved.windowsState
        let windowsState: Data? = state.flatMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0) }
        guard let windowsState else { return }

        // Replace the current windows state of the study, with the content of the DICOM SR
        saved.study.windowsState = windowsState

        // The browser opens the study with its state only while the automatic
        // workspace load is on: on for this opening, then back as it was.
        let preferences = processGraph.preferences
        let automatic = preferences[ViewerPreferences.automaticWorkspaceLoad]
        if !automatic { preferences.set(true, for: ViewerPreferences.automaticWorkspaceLoad) }
        processGraph.currentBrowser?.databaseOpenStudy(saved.study)
        if !automatic { preferences.set(false, for: ViewerPreferences.automaticWorkspaceLoad) }
    }

    // MARK: - Recent Studies

    /// Puts the study first in Recent Studies, with the album the database
    /// window shows, and keeps the number of studies the preferences allow.
    func addRecentStudy(_ studyID: NSManagedObjectID) {
        recentStudies.removeAll { $0 == studyID }
        recentStudies.insert(studyID, at: 0)

        if let selectedAlbumName = processGraph.currentBrowser?.selectedAlbumName {
            recentStudiesAlbums[studyID] = selectedAlbumName
        }

        // The preference is compared as an unsigned count, as the former code did.
        if UInt(recentStudies.count) > UInt(bitPattern: processGraph.preferences[DatabasePreferences.maxNumberOfRecentStudies]) {
            recentStudies.removeLast()
        }

        buildRecentStudiesMenu()
    }

    /// Opens the study of a Recent Studies item, in its album, alone.
    @objc func loadRecentStudy(_ sender: Any?) {
        let item = sender as? NSMenuItem

        ViewerController.closeAllWindows()

        let study = processGraph.browserDatabase?.object(withID: item?.representedObject) as? DicomStudy
        if let study, study.isDeleted == false {
            let browser = processGraph.currentBrowser
            if let studyID = item?.representedObject as? NSManagedObjectID, let albumName = recentStudiesAlbums[studyID] {
                browser?.selectAlbum(withName: albumName)
            }
            _ = browser?.selectThisStudy(study)
            browser?.databaseOpenStudy(study)
        }
    }

    /// The Recent Studies menu, from the studies the database still has; the
    /// others leave the list.
    func buildRecentStudiesMenu() {
        let menu = recentStudiesMenu()
        menu?.removeAllItems()

        var gone: Set<NSManagedObjectID> = []
        let database = processGraph.browserDatabase
        for studyID in recentStudies {
            guard let study = database?.object(withID: studyID) as? DicomStudy else {
                gone.insert(studyID)
                continue
            }
            var components: [String] = []
            if let name = study.name, !name.isEmpty { components.append(name) }
            if let date = study.date { components.append(UserDefaults.dateTimeFormatter().string(from: date)) }
            if let studyName = study.studyName, !studyName.isEmpty { components.append(studyName) }
            if let modality = study.modality, !modality.isEmpty { components.append(modality) }

            let title = NSAttributedString(string: components.joined(separator: " / "), attributes: [NSAttributedString.Key.font: NSFont.boldSystemFont(ofSize: 14)])

            let menuItem = NSMenuItem(title: title.string, action: #selector(ApplicationMenus.loadRecentStudy(_:)), keyEquivalent: "")
            menuItem.attributedTitle = title
            menuItem.target = self
            menuItem.representedObject = studyID
            menu?.addItem(menuItem)
        }

        recentStudies.removeAll { gone.contains($0) }
    }

    /// Recent Studies: an item whose study is gone is off and disabled, one
    /// whose study a 2D viewer shows is checked. The workspace states are
    /// always enabled.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(ApplicationMenus.loadRecentStudy(_:)) {
            let database = processGraph.browserDatabase
            let shown = Set(displayedViewers().compactMap { $0.currentStudy()?.objectID })
            for item in recentStudiesMenu()?.items ?? [] {
                let study = database?.object(withID: item.representedObject) as? DicomStudy
                if study == nil || (study?.isDeleted ?? false) {
                    item.isEnabled = false
                    item.state = .off
                } else {
                    item.isEnabled = true
                    let studyID = item.representedObject as? NSManagedObjectID
                    item.state = studyID.map { shown.contains($0) } == true ? .on : .off
                }
            }
        }
        return true
    }
}
