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
import IsiXImaging
import IsiXPreferences

/// The slices of every movie frame, handed to the shares of a convolution:
/// the viewer waits while they run, and each slice is filtered by one share.
private struct ConvolvedSlices: @unchecked Sendable {
    let frames: [[DCMPix]]
}

/// The colour tables, the opacity tables of the thick slab and the
/// convolution filters of a 2D viewer: applying them from their menus, editing
/// them in their sheets, adding and deleting them, and applying a filter to
/// the pixels themselves. The viewer's graph keeps it; the viewer's actions,
/// whose selectors the nibs, the menus and the former plugins use, hand their
/// sender over, and the viewer itself: it keeps no reference to the viewer,
/// whose tear-down (closing a fused viewer applies its colour table again)
/// runs while the viewer is being freed, when no reference to it can be made.
///
/// The stored tables stay in the preferences "CLUT", "OPACITY" and
/// "Convolution", read and written through the typed keys of
/// IsiXPreferences; what an entry gives the viewer is IsiXImaging's
/// ColourTableBook, OpacityTableBook and ConvolutionKernelBook, and the filter
/// applied to a whole series is its SeriesConvolution. The menus are told
/// through the process's PresetMenuCache. The names the viewer shows (the
/// current table, opacity and filter) stay the viewer's, where its bindings
/// and the former plugins read them.
@MainActor final class ViewerColourTables {

    private let preferences: any PreferenceStore
    private let menus: PresetMenuCache
    private let cache: ColourTableCache

    init(preferences: any PreferenceStore, menus: PresetMenuCache, cache: ColourTableCache) {
        self.preferences = preferences
        self.menus = menus
        self.cache = cache
    }

    private var colourTables: PresetTable<ColourTablePreset> {
        PresetTable(ImagePresetPreferences.colourTables, in: preferences)
    }

    private var opacityTables: PresetTable<IsiXPreferences.OpacityTablePreset> {
        PresetTable(ImagePresetPreferences.opacityTables, in: preferences)
    }

    private var convolutionFilters: PresetTable<ConvolutionPreset> {
        PresetTable(ImagePresetPreferences.convolutionPresets, in: preferences)
    }

    /// The stored entry `name` of `table`, as stored; nil when there is none.
    private func stored<Preset: PropertyListRepresentable>(_ table: PresetTable<Preset>, _ name: String?) -> PropertyListValue? {
        guard let name else { return nil }
        return table.entries?[name]
    }

    // MARK: - Colour tables

    /// Applies the colour table `name`: "No CLUT" or a stored table, to the
    /// images, the thick slab and the black index of every slice. A PET fused
    /// in "B/W Inverse" mode takes it as its blending table instead.
    func applyColourTable(_ name: String?, in viewer: ViewerController) {
        if viewer.horos_blending != nil && PETBlendingTable.drawsFusedSeries(inPETCLUTMode: preferences[ViewerPreferences.petCLUTMode]) {
            // The shared PET blending tables are made from this table, without
            // changing the "PET Blending CLUT" preference; without a name, from
            // the one the preference falls back to.
            let blendingName = name ?? (ViewerPreferences.petBlendingCLUT.registration?
                .value(in: PreferenceEnvironment(viewer: true, appStore: false, hostName: nil, graphicsMemory: 0)) as? String)
            let preset = ReconstructionPreferences.preset(blendingName, of: ImagePresetPreferences.colourTables, in: preferences)
            PETBlendingTables.replace(with: PETBlendingTable(preset: preset?.propertyList.object as? [String: Any]))

            viewer.horos_curCLUTMenu = name

            viewer.horos_clutPopup?.menu?.item(at: 0)?.title = name ?? ""
        } else if viewerIsEqualToString(name, NSLocalizedString("No CLUT", comment: "")) {
            for x in 0..<viewer.horos_movieCount {
                for pix in viewer.horos_pixArray(x) { pix.setBlackIndex(0) }
            }

            viewer.horos_imageView?.setCLUT(nil, nil, nil)
            viewer.horos_thickSlab?.setCLUT(nil, nil, nil)

            if let imageView = viewer.horos_imageView { imageView.setIndex(imageView.curImage) }

            viewer.horos_curCLUTMenu = name

            menus.announce(.OsirixUpdateCLUTMenu, current: viewer.horos_curCLUTMenu, presetsChanged: false)

            viewer.horos_clutPopup?.menu?.item(at: 0)?.title = name ?? ""

            viewer.propagateSettings()
        } else if let stored = stored(colourTables, name), let entry = cache.entry(for: stored) {
            var table = entry.table
            viewer.horos_thickSlab?.setCLUT(&table.red, &table.green, &table.blue)

            for x in 0..<viewer.horos_movieCount {
                for pix in viewer.horos_pixArray(x) { pix.setBlackIndex(entry.blackIndex) }
            }

            viewer.horos_imageView?.setCLUT(&table.red, &table.green, &table.blue)

            if let imageView = viewer.horos_imageView { imageView.setIndex(imageView.curImage) }

            viewer.horos_curCLUTMenu = name

            menus.announce(.OsirixUpdateCLUTMenu, current: viewer.horos_curCLUTMenu, presetsChanged: false)

            viewer.propagateSettings()
            viewer.horos_clutPopup?.menu?.item(at: 0)?.title = name ?? ""
        }

        viewer.horos_imageView?.whiteBackground = viewerIsEqualToString(viewer.horos_curCLUTMenu, "B/W Inverse")

        viewer.horos_postCurrentImageUpdate()

        viewer.horos_reapplyWindow()
    }

    /// The CLUT editor changed its table: shown at once.
    func colourTableEdited(_ editor: ColorTransferView?, in viewer: ViewerController) {
        var red = [UInt8](repeating: 0, count: 256), green = red, blue = red

        editor?.convertCLUT(&red, &green, &blue)

        viewer.horos_imageView?.setCLUT(&red, &green, &blue)
        if let imageView = viewer.horos_imageView { imageView.setIndex(imageView.curImage) }
    }

    /// A colour table menu item: applies it; with Shift asks to delete it, with
    /// Option opens it in the CLUT editor.
    func colourTableChosen(_ sender: Any?, in viewer: ViewerController) {
        let title = ViewerSender.string(sender, "title")
        let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []

        if flags.contains(.shift) {
            askToDelete(title: NSLocalizedString("Remove a Color Look Up Table", comment: ""),
                        message: String(format: NSLocalizedString("Are you sure you want to delete this CLUT : '%@'", comment: ""), viewerFormatArgument(title)),
                        name: title, in: viewer) { viewer, name in
                viewer.sessionGraph.colourTables.deleteColourTable(name, in: viewer)
            }

            menus.announce(.OsirixUpdateCLUTMenu, current: viewer.horos_curCLUTMenu, presetsChanged: true)
        } else if flags.contains(.option) {
            viewer.applyCLUTString(title)

            guard let stored = stored(colourTables, viewer.horos_curCLUTMenu)?.object as? [String: Any] else { return }
            if ColourTableBook.opensInEditor(stored) {
                let content = ColourTableBook.editorContent(of: stored)
                viewer.horosLoadViewerPanels()
                viewer.clutAction(viewer)
                viewer.horos_clutName?.stringValue = title ?? ""

                let points = viewer.horos_clutView?.getPoints()
                let colours = viewer.horos_clutView?.getColors()

                points?.removeAllObjects()
                colours?.removeAllObjects()

                points?.addObjects(from: content.points)
                colours?.addObjects(from: content.colours)

                if let sheet = viewer.horos_addCLUTWindow { viewer.window?.beginSheet(sheet, completionHandler: nil) }

                viewer.horos_clutView?.needsDisplay = true
            } else {
                HorosAlertPanel.run(title: NSLocalizedString("Error", comment: ""), message: NSLocalizedString("Only CLUT created in OsiriX 1.3.1 or higher can be edited...", comment: ""),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
            }
        } else {
            viewer.applyCLUTString(title)
        }
    }

    /// Deletes the stored colour table `name` and tells the menus.
    func deleteColourTable(_ name: String, in viewer: ViewerController) {
        var tables = colourTables
        tables.set(nil, named: name)
        tables.write(to: preferences)

        menus.announce(.OsirixUpdateCLUTMenu, current: viewer.horos_curCLUTMenu, presetsChanged: true)
    }

    /// The end of the CLUT editor: OK (a non-zero tag) stores its table under
    /// its name and applies it; Cancel applies the table of before again.
    func endColourTableEditor(_ sender: Any?, in viewer: ViewerController) {
        let tag = ViewerSender.tag(sender)
        viewer.horos_addCLUTWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        if tag != 0 {
            var table = ColorLookupTable(red: [UInt8](repeating: 0, count: 256), green: [UInt8](repeating: 0, count: 256), blue: [UInt8](repeating: 0, count: 256))
            viewer.horos_clutView?.convertCLUT(&table.red, &table.green, &table.blue)

            let points = (viewer.horos_clutView?.getPoints()?.copy() as? [Any]) ?? []
            let colours = (viewer.horos_clutView?.getColors()?.copy() as? [Any]) ?? []
            let name = viewer.horos_clutName?.stringValue ?? ""
            if let stored = PropertyListValue(ColourTableBook.storedForm(of: table, points: points, colours: colours)),
               let preset = ColourTablePreset(propertyList: stored) {
                var tables = colourTables
                tables.set(preset, named: name)
                tables.write(to: preferences)
            }

            // Apply it.
            viewer.horos_curCLUTMenu = name

            menus.announce(.OsirixUpdateCLUTMenu, current: viewer.horos_curCLUTMenu, presetsChanged: true)
        }
        viewer.applyCLUTString(viewer.horos_curCLUTMenu)
    }

    // MARK: - The colour tables' menu

    /// The colour tables' menu, shared by every viewer: built by
    /// updateColourTableMenu, each viewer's popup gets a copy.
    private static var presetsMenu: NSMenu?

    /// Reset CLUT List: after the person agrees, the stored colour tables are
    /// the application's own again, and the menus are built again.
    func resetColourTables(in viewer: ViewerController) {
        guard HorosAlertPanel.runInformational(title: NSLocalizedString("Reset CLUT List", comment: ""), message: NSLocalizedString("Are you sure you want to reset the entire CLUT list to the default list?", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil) == HorosAlertPanel.defaultResponse else { return }

        let key = ImagePresetPreferences.colourTables
        preferences.remove(key)
        preferences.set(DefaultPreferences.applicationDefaults().object(forKey: key.name), forKey: key.name)

        menus.announce(.OsirixUpdateCLUTMenu, current: viewer.horos_curCLUTMenu, presetsChanged: true)
    }

    /// Opens the opacity editor over the current colour table, for a new
    /// table named Unnamed.
    func addOpacityTable(in viewer: ViewerController) {
        if let entry = ColourTableBook.Entry(stored: stored(colourTables, viewer.horos_curCLUTMenu)?.object) {
            var table = entry.table
            viewer.horos_OpacityView?.setCurrentCLUT(&table.red, &table.green, &table.blue)
        }

        viewer.horos_OpacityName?.stringValue = NSLocalizedString("Unnamed", comment: "")

        if let sheet = viewer.horos_addOpacityWindow, let window = viewer.window {
            window.beginSheet(sheet, completionHandler: nil)
        }
    }

    /// Opens the CLUT editor, for a new table named Unnamed.
    func addColourTable(in viewer: ViewerController) {
        viewer.clutAction(viewer)
        viewer.horos_clutName?.stringValue = NSLocalizedString("Unnamed", comment: "")

        if let sheet = viewer.horos_addCLUTWindow, let window = viewer.window {
            window.beginSheet(sheet, completionHandler: nil)
        }
    }

    /// The colour tables changed (a notification with a user info) or the
    /// current one did: the menu is built again from the stored tables when
    /// it must be, the viewer's popup gets its copy, and shows the current table.
    func updateColourTableMenu(_ note: Notification?, in viewer: ViewerController) {
        if Self.presetsMenu == nil || note?.userInfo != nil {
            let menu = NSMenu()
            Self.presetsMenu = menu

            menu.addItem(withTitle: NSLocalizedString("No CLUT", comment: ""), action: nil, keyEquivalent: "")
            menu.addItem(withTitle: NSLocalizedString("No CLUT", comment: ""), action: NSSelectorFromString("ApplyCLUT:"), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            for name in ReconstructionPreferences.menuNames(ImagePresetPreferences.colourTables, in: preferences) {
                menu.addItem(withTitle: name, action: NSSelectorFromString("ApplyCLUT:"), keyEquivalent: "")
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: NSLocalizedString("8-bit CLUT Editor", comment: ""), action: #selector(ViewerController.addCLUT(_:)), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: NSLocalizedString("Reset CLUT List", comment: ""), action: #selector(ViewerController.resetCLUT(_:)), keyEquivalent: "")

            setPopupTitle(viewer.horos_clutPopup, viewer.horos_curCLUTMenu)
            viewer.horos_clutPopup?.menu = menu.copy() as? NSMenu
            viewer.horos_clutPopupSet = true
        } else if viewer.horos_clutPopupSet == false {
            viewer.horos_clutPopup?.menu = Self.presetsMenu?.copy() as? NSMenu
            viewer.horos_clutPopupSet = true
        }

        setPopupTitle(viewer.horos_clutPopup, viewer.horos_curCLUTMenu)
    }

    /// `[popup setTitle: title]`, which the Objective-C also sent with a nil title.
    private func setPopupTitle(_ popup: NSPopUpButton?, _ title: String?) {
        guard let popup else { return }
        if let title {
            popup.setTitle(title)
        } else {
            typealias SetTitleIMP = @convention(c) (AnyObject, Selector, NSString?) -> Void
            let selector = #selector(NSPopUpButton.setTitle(_:))
            unsafeBitCast(popup.method(for: selector), to: SetTitleIMP.self)(popup, selector, nil)
        }
    }

    // MARK: - Opacity tables of the thick slab

    /// The opacity editor changed its table: applied to the thick slab and to
    /// every slice.
    func opacityTableEdited(_ editor: OpacityTransferView?, in viewer: ViewerController) {
        let points = editor?.getPoints()

        viewer.horos_thickSlab?.setOpacity(points)

        setTransferFunction((points?.count ?? 0) == 0 ? nil : OpacityTransferView.tableWith4096Entries(points), in: viewer)

        viewer.updateImage(viewer)
    }

    /// Applies the opacity table `name`: "Linear Table" or a stored table.
    func applyOpacityTable(_ name: String?, in viewer: ViewerController) {
        if viewerIsEqualToString(name, NSLocalizedString("Linear Table", comment: "")) {
            viewer.horos_thickSlab?.setOpacity([])

            viewer.horos_curOpacityMenu = name

            menus.announce(.OsirixUpdateOpacityMenu, current: viewer.horos_curOpacityMenu, presetsChanged: false)

            viewer.horos_OpacityPopup?.menu?.item(at: 0)?.title = name ?? ""

            setTransferFunction(nil, in: viewer)

            viewer.updateImage(viewer)
        } else {
            if let entry = OpacityTableBook.Entry(stored: stored(opacityTables, name)?.object) {
                let points = entry.points.map { $0 as NSArray }
                viewer.horos_thickSlab?.setOpacity(points)
                viewer.horos_curOpacityMenu = name

                menus.announce(.OsirixUpdateOpacityMenu, current: viewer.horos_curOpacityMenu, presetsChanged: false)

                viewer.horos_OpacityPopup?.menu?.item(at: 0)?.title = name ?? ""

                setTransferFunction(entry.givesSlicesATable ? OpacityTransferView.tableWith4096Entries(points) : nil, in: viewer)
            }
            viewer.updateImage(viewer)
        }

        viewer.horos_postCurrentImageUpdate()

        for case let other as ViewerController in ViewerController.getDisplayed2DViewers() ?? [] {
            other.updateImage(viewer)
        }
    }

    /// An opacity menu item: applies it; with Shift asks to delete it, with
    /// Option opens it in the opacity editor, over the current colour table.
    func opacityTableChosen(_ sender: Any?, in viewer: ViewerController) {
        let title = ViewerSender.string(sender, "title")
        let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []

        if flags.contains(.shift) {
            askToDelete(title: NSLocalizedString("Remove a Color Look Up Table", comment: ""),
                        message: String(format: NSLocalizedString("Are you sure you want to delete this Opacity Table : '%@'", comment: ""), viewerFormatArgument(title)),
                        name: title, in: viewer) { viewer, name in
                viewer.sessionGraph.colourTables.deleteOpacityTable(name, in: viewer)
            }

            menus.announce(.OsirixUpdateOpacityMenu, current: viewer.horos_curOpacityMenu, presetsChanged: true)
        } else if flags.contains(.option) {
            viewer.applyOpacityString(title)
            viewer.horosLoadViewerPanels()

            guard let entry = OpacityTableBook.Entry(stored: stored(opacityTables, viewer.horos_curOpacityMenu)?.object) else { return }
            if var table = ColourTableBook.Entry(stored: stored(colourTables, viewer.horos_curCLUTMenu)?.object)?.table {
                viewer.horos_OpacityView?.setCurrentCLUT(&table.red, &table.green, &table.blue)
            }

            if let points = entry.points {
                viewer.horos_OpacityName?.stringValue = viewer.horos_curOpacityMenu ?? ""

                let editorPoints = viewer.horos_OpacityView?.getPoints()
                editorPoints?.removeAllObjects()
                editorPoints?.addObjects(from: points)

                if let sheet = viewer.horos_addOpacityWindow { viewer.window?.beginSheet(sheet, completionHandler: nil) }

                viewer.horos_OpacityView?.needsDisplay = true
            }
        } else {
            viewer.applyOpacityString(title)
        }
    }

    /// Deletes the stored opacity table `name` and tells the menus, with the
    /// colour table's name, as the viewer always did.
    func deleteOpacityTable(_ name: String, in viewer: ViewerController) {
        var tables = opacityTables
        tables.set(nil, named: name)
        tables.write(to: preferences)

        menus.announce(.OsirixUpdateOpacityMenu, current: viewer.horos_curCLUTMenu, presetsChanged: true)
    }

    /// The end of the opacity editor: OK stores its table under its name and
    /// applies it; Cancel applies the table of before again.
    func endOpacityTableEditor(_ sender: Any?, in viewer: ViewerController) {
        let tag = ViewerSender.tag(sender)
        viewer.horos_addOpacityWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        if tag != 0 {
            let points = (viewer.horos_OpacityView?.getPoints()?.copy() as? [Any]) ?? []
            let name = viewer.horos_OpacityName?.stringValue ?? ""
            if let stored = PropertyListValue(OpacityTableBook.storedForm(points: points)),
               let preset = IsiXPreferences.OpacityTablePreset(propertyList: stored) {
                var tables = opacityTables
                tables.set(preset, named: name)
                tables.write(to: preferences)
            }

            // Apply it.
            viewer.horos_curOpacityMenu = name

            menus.announce(.OsirixUpdateOpacityMenu, current: viewer.horos_curOpacityMenu, presetsChanged: true)
        }
        viewer.applyOpacityString(viewer.horos_curOpacityMenu)
    }

    /// The opacity table of every slice of every movie frame: the same table
    /// for all, given as it is rather than copied per slice.
    private func setTransferFunction(_ table: NSData?, in viewer: ViewerController) {
        for x in 0..<viewer.horos_movieCount {
            for pix in viewer.horos_pixArray(x) { pix.transferTable = table }
        }
    }

    // MARK: - Deleting

    /// The sheet that asks before deleting the stored entry `name`; Delete
    /// runs `delete` with the viewer, which the sheet keeps until it ends.
    /// `message` is shown as it is: the callers format it from their literal,
    /// so a "%" in the entry's name is never read as a specifier.
    private func askToDelete(title: String, message: String, name: String?, in viewer: ViewerController,
                             delete: @escaping @Sendable @MainActor (ViewerController, String) -> Void) {
        guard let window = viewer.window else { return }
        HorosAlertPanel.begin(withTitle: title, message: message,
                              defaultButton: NSLocalizedString("Delete", comment: ""), alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil,
                              modalFor: window) { returnCode in
            // The sheet ends on the main thread.
            MainActor.assumeIsolated {
                if returnCode == 1, let name { delete(viewer, name) }
            }
        }
    }

    // MARK: - The convolution filters

    /// Hands the filter `weights` (nil: none) to every slice of every movie frame.
    func setFilter(_ weights: UnsafeMutablePointer<Float>?, size: Int16, normalization: Float, in viewer: ViewerController) {
        for x in 0..<viewer.horos_movieCount {
            for pix in viewer.horos_pixArray(x) { pix.setConvolutionKernel(weights, size, normalization) }
        }
    }

    /// Applies the filter `name`: "No Filter" or a stored filter.
    func applyFilter(_ name: String?, in viewer: ViewerController) {
        if viewerIsEqualToString(name, NSLocalizedString("No Filter", comment: "")) {
            viewer.setConv(nil, 0, 0)
            if let imageView = viewer.horos_imageView { imageView.setIndex(imageView.curImage) }

            viewer.horos_curConvMenu = name
        } else if let kernel = ConvolutionKernelBook.Kernel(stored: stored(convolutionFilters, name)?.object) {
            var weights = kernel.weights
            weights.withUnsafeMutableBufferPointer {
                viewer.setConv($0.baseAddress, Int16(truncatingIfNeeded: kernel.size), kernel.normalization)
            }
            if let imageView = viewer.horos_imageView { imageView.setIndex(imageView.curImage) }
            viewer.horos_curConvMenu = name

            menus.announce(.OsirixUpdateConvolutionMenu, current: viewer.horos_curConvMenu, presetsChanged: false)
        } else {
            HorosAlertPanel.run(title: NSLocalizedString("Error", comment: ""),
                                message: NSLocalizedString("This convolution filter cannot be loaded.", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
        }

        viewer.horos_convPopup?.menu?.item(at: 0)?.title = name ?? ""
    }

    /// A filter menu item: applies it; with Shift asks to delete it, with
    /// Option opens it in the filter editor.
    func filterChosen(_ sender: Any?, in viewer: ViewerController) {
        let title = ViewerSender.string(sender, "title")
        let flags = NSApplication.shared.currentEvent?.modifierFlags ?? []

        if flags.contains(.shift) {
            askToDelete(title: NSLocalizedString("Remove a Convolution Filter", comment: ""),
                        message: String(format: NSLocalizedString("Are you sure you want to delete this convolution filter : '%@'", comment: ""), viewerFormatArgument(title)),
                        name: title, in: viewer) { viewer, name in
                viewer.sessionGraph.colourTables.deleteFilter(name, in: viewer)
            }

            menus.announce(.OsirixUpdateConvolutionMenu, current: viewer.horos_curConvMenu, presetsChanged: true)
        } else if flags.contains(.option) {
            let kernel = ConvolutionKernelBook.Kernel(stored: stored(convolutionFilters, title)?.object)
            let size = kernel?.size ?? 0

            viewer.horos_matrixName?.stringValue = title ?? ""
            viewer.horos_matrixNorm?.floatValue = kernel?.normalization ?? 0

            if size == 3 || size == 5 {
                viewer.horos_sizeMatrix?.selectCell(withTag: size)
                prepareEditorCells(size: size, aligningUnused: size == 5, in: viewer)
                for (index, cell) in ConvolutionKernelBook.writingOrder(size: size).enumerated() {
                    viewer.horos_convMatrix?.cell(atRow: cell.row, column: cell.column)?.floatValue = kernel?.weights[index] ?? 0
                }
            }

            if let sheet = viewer.horos_addConvWindow, let window = viewer.window {
                window.beginSheet(sheet, completionHandler: nil)
            }
        } else {
            viewer.applyConvString(title)
        }
    }

    /// Deletes the stored filter `name` and tells the menus.
    func deleteFilter(_ name: String, in viewer: ViewerController) {
        var filters = convolutionFilters
        filters.set(nil, named: name)
        filters.write(to: preferences)

        menus.announce(.OsirixUpdateConvolutionMenu, current: viewer.horos_curConvMenu, presetsChanged: true)
    }

    /// Readies the editor's cells for a filter of `size`: the cells it uses
    /// are enabled and an empty one reads 0; for a 3 × 3 filter the others are
    /// disabled and emptied. The cells are centred, the unused ones only when
    /// `aligningUnused`.
    private func prepareEditorCells(size: Int, aligningUnused: Bool, in viewer: ViewerController) {
        for column in 0..<ConvolutionKernelBook.gridSide {
            for row in 0..<ConvolutionKernelBook.gridSide {
                guard let used = ConvolutionKernelBook.uses(row: row, column: column, size: size) else { return }
                let cell = viewer.horos_convMatrix?.cell(atRow: row, column: column)
                if used {
                    cell?.isEnabled = true
                    if cell?.stringValue == "" { cell?.stringValue = "0" }
                    cell?.alignment = .center
                } else {
                    cell?.isEnabled = false
                    cell?.stringValue = ""
                    if aligningUnused { cell?.alignment = .center }
                }
            }
        }
    }

    /// The size matrix chose another size: the editor's cells follow and the
    /// filter is shown.
    func editorSizeChanged(_ sender: Any?, in viewer: ViewerController) {
        prepareEditorCells(size: ViewerSender.selectedCellTag(sender), aligningUnused: true, in: viewer)
        viewer.convMatrixAction(viewer)
    }

    /// The weights of the editor for a filter of `size`, in the order of the
    /// stored matrix.
    func editorWeights(size: Int, in viewer: ViewerController) -> [Float] {
        ConvolutionKernelBook.readingOrder(size: size).map {
            viewer.horos_convMatrix?.cell(atRow: $0.row, column: $0.column)?.floatValue ?? 0
        }
    }

    /// The "Sum" button: the normalization becomes the sum of the 25 cells.
    func sumEditorWeights(in viewer: ViewerController) {
        let texts = (0..<25).map { viewer.horos_convMatrix?.cell(withTag: $0)?.stringValue ?? "" }
        viewer.horos_matrixNorm?.floatValue = ConvolutionKernelBook.sum(of: texts)

        viewer.convMatrixAction(viewer)
    }

    /// The editor changed: its filter is shown at once.
    func editorChanged(in viewer: ViewerController) {
        let size = viewer.horos_sizeMatrix?.selectedCell()?.tag ?? 0
        let read = (viewer.getMatrix(Int16(truncatingIfNeeded: size)) as? [NSNumber] ?? []).map(\.floatValue)
        var weights = ConvolutionKernelBook.Kernel(size: size, normalization: 0, weights: Array(read.prefix(max(0, size &* size)))).weights

        weights.withUnsafeMutableBufferPointer {
            viewer.setConv($0.baseAddress, Int16(truncatingIfNeeded: size), viewer.horos_matrixNorm?.floatValue ?? 0)
        }
        if let imageView = viewer.horos_imageView { imageView.setIndex(imageView.curImage) }
    }

    /// Opens the filter editor on a new 5 × 5 filter.
    func addFilter(in viewer: ViewerController) {
        prepareEditorCells(size: 5, aligningUnused: true, in: viewer)

        viewer.convMatrixAction(viewer)
        viewer.horos_matrixName?.stringValue = NSLocalizedString("Unnamed", comment: "")

        if let sheet = viewer.horos_addConvWindow, let window = viewer.window {
            window.beginSheet(sheet, completionHandler: nil)
        }
    }

    /// The end of the filter editor: OK (a non-zero tag) stores its filter
    /// under its name; either way the current filter is applied again.
    func endFilterEditor(_ sender: Any?, in viewer: ViewerController) {
        NSLog("endConv")

        for column in 0..<ConvolutionKernelBook.gridSide {
            for row in 0..<ConvolutionKernelBook.gridSide {
                viewer.horos_convMatrix?.cell(atRow: row, column: column)?.isEnabled = true
            }
        }

        let tag = ViewerSender.tag(sender)
        if tag != 0 {
            let size = viewer.horos_sizeMatrix?.selectedCell()?.tag ?? 0
            let weights = (viewer.getMatrix(Int16(truncatingIfNeeded: size)) as? [NSNumber] ?? []).map(\.floatValue)
            let kernel = ConvolutionKernelBook.Kernel(size: size, normalization: viewer.horos_matrixNorm?.floatValue ?? 0, weights: weights)
            if let name = viewer.horos_matrixName?.stringValue, let stored = PropertyListValue(kernel.storedForm),
               let preset = ConvolutionPreset(propertyList: stored) {
                var filters = convolutionFilters
                filters.set(preset, named: name)
                filters.write(to: preferences)
            }

            // Apply it.
            viewer.horos_curConvMenu = viewer.horos_matrixName?.stringValue

            menus.announce(.OsirixUpdateConvolutionMenu, current: viewer.horos_curConvMenu, presetsChanged: true)
        }

        viewer.horos_addConvWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        viewer.applyConvString(viewer.horos_curConvMenu)
    }

    /// Applies the current filter to the pixels themselves, of every slice of
    /// every movie frame, then across the slices of a volume, and takes the
    /// filter off; without a filter, says so.
    func applyFilterToPixels(in viewer: ViewerController) {
        guard !viewerIsEqualToString(viewer.horos_curConvMenu, NSLocalizedString("No Filter", comment: "")) else {
            HorosAlertPanel.run(title: NSLocalizedString("Convolution", comment: ""),
                                message: NSLocalizedString("First, apply a convolution filter...", comment: ""),
                                defaultButton: nil, alternateButton: nil, otherButton: nil)
            return
        }

        let convolution = SeriesConvolution()
        let slices = ConvolvedSlices(frames: (0..<viewer.horos_movieCount).map { viewer.horos_pixArray($0) })

        // Each slice through its own filter, the slices of every frame shared
        // out by their index in the first frame.
        convolution.perform(over: slices.frames.first?.count ?? 0) { share in
            for frame in slices.frames {
                for index in share where index < frame.count {
                    frame[index].applyConvolutionOnSourceImage()
                }
            }
        }

        if viewer.isDataVolumicIn4D(true) {
            for (x, frame) in slices.frames.enumerated() {
                guard let pix = frame.first else { continue }
                let first = pix.fImage.pointee

                // Across the slices; a colour series has no such pass.
                if !pix.isRGB, let volume = viewer.horos_volumeData(at: x) as? NSData {
                    let weights = SeriesConvolution.kernel(weights: pix.kernel(), normalization: pix.normalization())
                    convolution.filterAcrossSlices(UnsafeMutablePointer(mutating: volume.bytes.assumingMemoryBound(to: Float.self)),
                                                   width: pix.pwidth, height: pix.pheight, depth: frame.count,
                                                   kernel: weights, size: Int(pix.kernelsize()))
                }

                // The first row of every slice takes the first pixel, which
                // keeps the edge free of NaN values.
                for slice in frame where !slice.isRGB {
                    slice.fImage.update(repeating: first, count: max(0, slice.pwidth))
                }
            }
        }

        viewer.applyConvString(NSLocalizedString("No Filter", comment: ""))

        NotificationCenter.default.post(name: .OsirixUpdateVolumeData, object: viewer.horos_pixList(at: Int(viewer.horos_curMovieIndex)), userInfo: nil)
    }
}
