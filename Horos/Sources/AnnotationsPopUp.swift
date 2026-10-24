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

/// Choosing an annotation level, from the toolbar popup, the menu bar or the
/// Custom Annotations sheet: what 2D Viewer > Annotations always did.
@MainActor
@objc(HorosAnnotationsMenu)
public final class AnnotationsMenu: NSObject, NSMenuItemValidation {

    private static let shared = AnnotationsMenu()

    /// The levels in the order the popup and the menu bar list them.
    static let levels = [AnnotationLevel.none, AnnotationLevel.graphic, AnnotationLevel.basic,
                         AnnotationLevel.full, AnnotationLevel.pluginOnly, AnnotationLevel.custom]

    static func title(ofLevel level: Int) -> String {
        switch level {
        case AnnotationLevel.none: return NSLocalizedString("None", comment: "Annotation level")
        case AnnotationLevel.graphic: return NSLocalizedString("Graphic", comment: "Annotation level")
        case AnnotationLevel.basic: return NSLocalizedString("Basic", comment: "Annotation level")
        case AnnotationLevel.full: return NSLocalizedString("Full", comment: "Annotation level")
        case AnnotationLevel.pluginOnly: return NSLocalizedString("Plugin Only", comment: "Annotation level")
        default: return NSLocalizedString("Custom", comment: "")
        }
    }

    static var customizeTitle: String { NSLocalizedString("Customize Annotations…", comment: "") }

    /// Makes `level` the level of every image view, and redraws them.
    public static func choose(level: Int) {
        UserDefaults.standard.set(level, forKey: AnnotationLevel.defaultsKey)
        DCMView.setDefaults()
        refreshViewers()
    }

    /// Redraws the image views and the window titles, which carry the
    /// patient's name only at a level that shows it.
    public static func refreshViewers() {
        NotificationCenter.default.post(name: .OsirixUpdateView, object: nil, userInfo: nil)
        if let viewers = ViewerController.getDisplayed2DViewers() {
            for case let viewer as ViewerController in viewers {
                viewer.setWindowTitle(nil)
            }
        }
    }

    /// Adds Custom and Customize Annotations… to 2D Viewer > Annotations,
    /// after Plugin Only, once.
    @objc public static func installInMainMenu() {
        guard let pluginOnly = item(in: NSApp.mainMenu, action: NSSelectorFromString("annotMenu:"), tag: AnnotationLevel.pluginOnly),
              let menu = pluginOnly.menu,
              menu.items.contains(where: { $0.action == NSSelectorFromString("annotMenu:") && $0.tag == AnnotationLevel.custom }) == false
        else { return }
        var index = menu.index(of: pluginOnly) + 1
        let custom = NSMenuItem(title: title(ofLevel: AnnotationLevel.custom), action: NSSelectorFromString("annotMenu:"), keyEquivalent: "")
        custom.tag = AnnotationLevel.custom
        menu.insertItem(custom, at: index)
        index += 1
        let customize = NSMenuItem(title: customizeTitle, action: #selector(customize(_:)), keyEquivalent: "")
        customize.target = shared
        menu.insertItem(customize, at: index)
    }

    private static func item(in menu: NSMenu?, action: Selector, tag: Int) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action == action && item.tag == tag { return item }
            if let found = self.item(in: item.submenu, action: action, tag: tag) { return found }
        }
        return nil
    }

    @objc private func customize(_ sender: Any?) {
        CustomAnnotationsSheet.present(on: NSApp.mainWindow)
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        NSApp.mainWindow?.windowController is ViewerController
    }
}

/// The Annotations item of the 2D viewer's toolbar: a popup of the levels,
/// narrower than the four radios it replaces, with Custom Annotations…
/// at the end. The Tab key, the menu bar and the popup set the same user
/// default, and every popup follows it.
@MainActor
@objc(HorosAnnotationsPopUpButton)
public final class AnnotationsPopUpButton: NSPopUpButton {

    private static let customizeTag = -1

    /// Fills the item's view, once, and gives it the popup's width in the
    /// running language before the toolbar reads its designed size.
    @objc(installInView:)
    public static func install(in view: NSView?) {
        guard let view, !view.subviews.contains(where: { $0 is AnnotationsPopUpButton }) else { return }
        AnnotationsMenu.installInMainMenu()

        let popUp = AnnotationsPopUpButton(frame: .zero, pullsDown: false)
        popUp.controlSize = .small
        popUp.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.toolTip = NSLocalizedString("Annotations", comment: "")
        popUp.target = popUp
        popUp.action = #selector(choose(_:))
        func levelItem(_ level: Int) -> NSMenuItem {
            let item = NSMenuItem(title: AnnotationsMenu.title(ofLevel: level), action: nil, keyEquivalent: "")
            item.tag = level
            return item
        }
        for level in AnnotationsMenu.levels where level != AnnotationLevel.pluginOnly {
            popUp.menu?.addItem(levelItem(level))
        }
        // The control is as wide as the longest of these levels asks for; the
        // menu may be wider for Customize Annotations….
        let width = popUp.intrinsicContentSize.width.rounded(.up)
        // Plugin Only stays in the menu bar; here it shows only while it is the level.
        let pluginOnly = levelItem(AnnotationLevel.pluginOnly)
        pluginOnly.isHidden = true
        popUp.menu?.insertItem(pluginOnly, at: AnnotationsMenu.levels.firstIndex(of: AnnotationLevel.pluginOnly)!)
        popUp.menu?.addItem(.separator())
        let customize = NSMenuItem(title: AnnotationsMenu.customizeTitle, action: nil, keyEquivalent: "")
        customize.tag = customizeTag
        popUp.menu?.addItem(customize)
        popUp.showLevel()
        popUp.startObserving()

        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(popUp)
        for constraint in view.constraints where constraint.firstItem === view && constraint.firstAttribute == .width
            && constraint.secondItem == nil {
            constraint.isActive = false
        }
        NSLayoutConstraint.activate([
            popUp.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            popUp.widthAnchor.constraint(equalToConstant: width),
            popUp.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: width),
        ])
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
    }

    private static let popUps = NSHashTable<AnnotationsPopUpButton>.weakObjects()

    private func startObserving() {
        Self.popUps.add(self)
        LevelObserver.start()
    }

    /// Every popup shows the level, after a change from anywhere.
    fileprivate static func showLevelInAll() {
        for popUp in popUps.allObjects { popUp.showLevel() }
    }

    private func showLevel() {
        let level = UserDefaults.standard.integer(forKey: AnnotationLevel.defaultsKey)
        menu?.item(withTag: AnnotationLevel.pluginOnly)?.isHidden = level != AnnotationLevel.pluginOnly
        selectItem(withTag: level)
    }

    @objc private func choose(_ sender: Any?) {
        guard let item = selectedItem else { return }
        if item.tag == Self.customizeTag {
            showLevel()
            // With the toolbar in a panel of its own, the sheet goes on its viewer.
            let panel = window?.windowController as? ToolbarPanelController
            CustomAnnotationsSheet.present(on: panel?.viewer?.window ?? window)
        } else {
            AnnotationsMenu.choose(level: item.tag)
        }
    }
}

/// The small sheet where the Custom level is set up: a check per element,
/// applied at once to every 2D viewer. Opening it keeps the level; changing a
/// check makes Custom the level, so that the change shows.
@MainActor
@objc(HorosCustomAnnotationsSheet)
public final class CustomAnnotationsSheet: NSObject {

    private static var open: [CustomAnnotationsSheet] = []
    private let panel: NSPanel

    static func title(of element: AnnotationElement) -> String {
        switch element {
        case .rois: return NSLocalizedString("ROIs and measurements", comment: "")
        case .colorBar: return NSLocalizedString("Color bar", comment: "")
        case .scaleRuler: return NSLocalizedString("Scale ruler", comment: "")
        case .referenceLines: return NSLocalizedString("Reference lines", comment: "")
        case .orientation: return NSLocalizedString("Orientation", comment: "")
        case .patientName: return NSLocalizedString("Patient Name", comment: "")
        case .imageInfo: return NSLocalizedString("Image number, position and zoom", comment: "")
        case .windowLevel: return NSLocalizedString("Window Level / Window Width", comment: "")
        case .mousePosition: return NSLocalizedString("Mouse position and pixel value", comment: "")
        case .otherFields: return NSLocalizedString("Other DICOM and database fields", comment: "")
        }
    }

    /// Shows the sheet on `window`, or as a panel of its own without one.
    @objc(presentOnWindow:)
    public static func present(on window: NSWindow?) {
        if let attached = window?.attachedSheet, open.contains(where: { $0.panel === attached }) { return }
        let sheet = CustomAnnotationsSheet()
        open.append(sheet)
        if let window, window.attachedSheet == nil {
            window.beginSheet(sheet.panel)
        } else {
            sheet.panel.center()
            sheet.panel.makeKeyAndOrderFront(nil)
        }
    }

    private override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                        styleMask: [.titled], backing: .buffered, defer: true)
        super.init()
        panel.title = NSLocalizedString("Custom Annotations", comment: "")
        panel.isReleasedWhenClosed = false

        let heading = NSTextField(labelWithString: panel.title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let note = NSTextField(wrappingLabelWithString: NSLocalizedString("Choose what the Custom level shows on the images.", comment: ""))
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 280

        var rows: [NSView] = [heading, note]
        for element in AnnotationElement.allCases {
            if element == .orientation { rows.append(NSBox.separator()) }
            let check = NSButton(checkboxWithTitle: Self.title(of: element), target: self, action: #selector(toggle(_:)))
            check.tag = element.rawValue
            check.state = AnnotationLevel.shows(element, level: AnnotationLevel.custom) ? .on : .off
            rows.append(check)
        }
        let ok = NSButton(title: NSLocalizedString("OK", comment: ""), target: self, action: #selector(close(_:)))
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), ok])
        buttons.distribution = .fill
        rows.append(buttons)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(12, after: note)
        stack.setCustomSpacing(16, after: rows[rows.count - 2])
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows where row is NSBox || row === buttons {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
    }

    @objc private func toggle(_ sender: NSButton) {
        guard let element = AnnotationElement(rawValue: sender.tag) else { return }
        UserDefaults.standard.set(sender.state == .off, forKey: element.hiddenKey)
        if UserDefaults.standard.integer(forKey: AnnotationLevel.defaultsKey) != AnnotationLevel.custom {
            AnnotationsMenu.choose(level: AnnotationLevel.custom)
        } else {
            AnnotationsMenu.refreshViewers()
        }
    }

    @objc private func close(_ sender: Any?) {
        if let parent = panel.sheetParent {
            parent.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
        Self.open.removeAll { $0 === self }
    }
}

/// Watches the level for the popups, for the life of the app.
private final class LevelObserver: NSObject, @unchecked Sendable {
    @MainActor private static var shared: LevelObserver?

    @MainActor static func start() {
        guard shared == nil else { return }
        let observer = LevelObserver()
        UserDefaults.standard.addObserver(observer, forKeyPath: AnnotationLevel.defaultsKey, options: [], context: nil)
        shared = observer
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // UserDefaults reports a default on the thread that wrote it.
        onMainActor { AnnotationsPopUpButton.showLevelInAll() }
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
