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

/// Report templates kept in folders inside the templates folder, and the menu
/// that offers them.
///
/// Only the first level of the templates folder was read, so a template put in
/// a subfolder - which is how a radiologist with a template per exam keeps
/// them, `RX/RX TÓRAX.pages` - was simply not offered. A template is now known
/// by its path relative to the templates folder, and a folder is a submenu.
/// A template at the first level keeps its name, which is its path too, so the
/// names a template was chosen by before still find it.
@objc(HorosReportTemplateMenu)
public final class ReportTemplateMenu: NSObject {

    /// How deep folders are followed: a link back to a parent folder must not
    /// make the menu endless.
    static let deepestFolder = 8

    /// The templates under `directory`, as paths relative to it, folder by
    /// folder in the Finder's order. `isTemplate` is given a name and whether
    /// it is a directory: a Pages document saved as a package is a template,
    /// not a folder. What is hidden is left out.
    static func templates(in directory: String, isTemplate: (String, Bool) -> Bool) -> [String] {
        func list(_ relative: String, depth: Int) -> [String] {
            let folder = relative.isEmpty ? directory : (directory as NSString).appendingPathComponent(relative)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
            var found: [String] = []
            for name in names.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) where !name.hasPrefix(".") {
                let path = relative.isEmpty ? name : (relative as NSString).appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(name), isDirectory: &isDirectory) else { continue }
                if isTemplate(name, isDirectory.boolValue) {
                    found.append(path)
                } else if isDirectory.boolValue && depth < deepestFolder {
                    found += list(path, depth: depth + 1)
                }
            }
            return found
        }
        return list("", depth: 0)
    }

    /// Where the template `relative` is under `directory`, or nil when it is not
    /// a template there. A path that is absolute, or that has an empty, `.` or
    /// `..` step, is not one the menu makes, and is refused rather than
    /// followed out of the folder.
    static func path(of relative: String, in directory: String, isTemplate: (String, Bool) -> Bool) -> String? {
        let steps = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !steps.isEmpty, steps.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let path = (directory as NSString).appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isTemplate((relative as NSString).lastPathComponent, isDirectory.boolValue) else { return nil }
        return path
    }

    /// Fills `menu`, after what it already holds, with `templates`: one item a
    /// template, titled with its file name, and a submenu a folder. Every item
    /// holds its template's relative path; the ones inside a submenu send
    /// `action` to `target` themselves, which a pop-up button does not do for
    /// the items of its submenus. After them, an item that shows `folder` in
    /// the Finder.
    @objc(populateMenu:templates:folder:target:action:)
    @MainActor public static func populate(_ menu: NSMenu, templates: [String], folder: String?, target: AnyObject?, action: Selector) {
        var submenus: [String: NSMenu] = [:]
        func container(_ folder: String) -> NSMenu {
            if folder.isEmpty { return menu }
            if let submenu = submenus[folder] { return submenu }
            let parent = container((folder as NSString).deletingLastPathComponent)
            let name = (folder as NSString).lastPathComponent
            let submenu = NSMenu(title: name)
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.submenu = submenu
            parent.addItem(item)
            submenus[folder] = submenu
            return submenu
        }
        for template in templates {
            let folder = (template as NSString).deletingLastPathComponent
            let item = NSMenuItem(title: (template as NSString).lastPathComponent, action: nil, keyEquivalent: "")
            item.representedObject = template
            if !folder.isEmpty {
                item.action = action
                item.target = target
            }
            container(folder).addItem(item)
        }
        guard let folder else { return }
        menu.addItem(.separator())
        let show = NSMenuItem(title: NSLocalizedString("Show the Report Templates Folder in the Finder", comment: "Last item of the report templates menu"),
                              action: #selector(ReportTemplateMenu.showFolder(_:)), keyEquivalent: "")
        show.target = shared
        show.representedObject = folder
        menu.addItem(show)
    }

    // The target of the folder item: it holds nothing, so sharing it is safe.
    nonisolated(unsafe) private static let shared = ReportTemplateMenu()

    @MainActor @objc func showFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? String else { return }
        AppKit.NSWorkspace.shared.open(URL(fileURLWithPath: folder, isDirectory: true))
    }

    /// The template a report is made from when it was chosen in this menu:
    /// the relative path an item holds, or the title of one that holds none.
    @objc(templateNameForSender:)
    @MainActor public static func templateName(for sender: Any?) -> String? {
        let item = (sender as? NSMenuItem) ?? (sender as? NSPopUpButton)?.selectedItem
        return item?.representedObject as? String ?? item?.title
    }
}
