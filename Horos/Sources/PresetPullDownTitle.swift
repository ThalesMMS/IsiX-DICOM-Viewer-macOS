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

/// The title of a pull-down that shows the name of the preset in use: the
/// window level, the colour table, the opacity table, the filter.
///
/// The button has the width its toolbar item gives it, and a preset has the
/// name its author gave it. A bezelled pull-down cuts a title that does not
/// fit at its end, whatever line break its cell asks for: «Logarithmic
/// Inverse Table» read «Logarithmic In…». The title is cut in the middle
/// instead (MiddleTruncatedTitle), so the end of the name is read too, and
/// the whole name is the button's tool tip.
///
/// The name stays where the windows write it and read it, in the first item
/// of the menu, which a pull-down shows and its open menu hides. While the
/// name fits, the button draws that item, as it always did. While it does
/// not, the cell draws an item of its own that holds the cut title, and the
/// menu is not touched. The title is worked out again when the first item of
/// the menu changes, by any of the ways the windows change it (its title is
/// set, the menu is filled again, the button is given another menu and then a
/// title), and when the button changes width. It is worked out at once and,
/// for the writes that go on after telling of the change, once more at the
/// end of that pass of the run loop.
///
/// A window writes the title in many places and by two means, the first item
/// of the menu and -setTitle: of the button, so the rule is not at those
/// places: it is installed once on the button, where the nib connects it.
@MainActor
final class PresetPullDownTitle: NSObject {
    private weak var popUp: NSPopUpButton?
    /// The item the cell draws while the name is cut; nil while it draws the
    /// first item of the menu.
    private var cutTitle: CutTitleItem?
    private var working = false
    private var again = false

    /// The key the button keeps its rule under: the class itself.
    nonisolated private static var association: UnsafeRawPointer {
        unsafeBitCast(PresetPullDownTitle.self as AnyClass, to: UnsafeRawPointer.self)
    }

    /// `popUp`, a pull-down, shows the name of its first item cut in the
    /// middle when it does not fit, from now on. Once per button.
    static func install(on popUp: NSPopUpButton?) {
        guard let popUp, popUp.pullsDown, titler(of: popUp) == nil else { return }
        let titler = PresetPullDownTitle(popUp)
        objc_setAssociatedObject(popUp, association, titler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        titler.show()
    }

    /// The title of `popUp` worked out again: for the code that makes its
    /// toolbar item, which used to tell the cell to draw the menu's item. A
    /// pull-down this rule is not installed on is told that, as before.
    static func show(on popUp: NSPopUpButton?) {
        guard let popUp else { return }
        if let titler = titler(of: popUp) {
            titler.show()
        } else {
            (popUp.cell as? NSPopUpButtonCell)?.usesItemFromMenu = true
        }
    }

    private static func titler(of popUp: NSPopUpButton) -> PresetPullDownTitle? {
        objc_getAssociatedObject(popUp, association) as? PresetPullDownTitle
    }

    private init(_ popUp: NSPopUpButton) {
        self.popUp = popUp
        super.init()
        let center = NotificationCenter.default
        // Of every menu: the button may be given another menu at any time.
        for name in [NSMenu.didChangeItemNotification, NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification] {
            center.addObserver(self, selector: #selector(menuChanged(_:)), name: name, object: nil)
        }
        popUp.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(frameChanged(_:)), name: NSView.frameDidChangeNotification, object: popUp)
    }

    /// A menu of the application changed. The menus of the windows change on
    /// the main thread; a change from another thread is not followed.
    @objc nonisolated private func menuChanged(_ note: Notification) {
        guard Thread.isMainThread, let changed = (note.object as AnyObject?).map(ObjectIdentifier.init) else { return }
        MainActor.assumeIsolated {
            guard let menu = popUp?.menu, ObjectIdentifier(menu) == changed else { return }
            show()
            showAgainSoon()
        }
    }

    /// -setTitle: of the button tells of the menu's change while it is still
    /// at work, and gives the cell the menu's item again when it ends: the
    /// title is worked out once more when the present pass of the run loop is
    /// over, in whatever mode it runs, once for any number of changes.
    private func showAgainSoon() {
        guard !again else { return }
        again = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.again = false
                self?.show()
            }
        }
    }

    @objc nonisolated private func frameChanged(_ note: Notification) {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { show() }
    }

    /// Whether the cell draws the whole of the title it has now: the rect it
    /// gives the title is as wide as the title while the title is whole, and
    /// as wide as what is left of it once it is cut.
    private static func drawsWhole(_ cell: NSPopUpButtonCell, in popUp: NSPopUpButton) -> Bool {
        cell.titleRect(forBounds: popUp.bounds).width >= cell.attributedTitle.size().width.rounded(.up) - 0.5
    }

    /// The button draws the name of the first item of its menu, whole if it
    /// fits and cut in the middle if not, and has it for its tool tip.
    private func show() {
        guard !working, let popUp, popUp.pullsDown, let cell = popUp.cell as? NSPopUpButtonCell,
              let first = popUp.menu?.item(at: 0) else { return }
        working = true
        defer { working = false }
        let name = first.title
        // The menu's own item first: a name that fits is drawn as it always was.
        cutTitle = nil
        cell.usesItemFromMenu = true
        cell.menuItem = first
        if !Self.drawsWhole(cell, in: popUp) {
            let item = CutTitleItem(title: name, action: nil, keyEquivalent: "")
            cell.usesItemFromMenu = false
            cell.menuItem = item
            item.title = MiddleTruncatedTitle.title(of: name) { candidate in
                item.title = candidate
                return Self.drawsWhole(cell, in: popUp)
            }
            item.written = { [weak self] title in self?.take(title) }
            cutTitle = item
        }
        popUp.toolTip = name.isEmpty ? nil : name
        popUp.needsDisplay = true
    }

    /// A title was written through the button (-setTitle:) while it drew the
    /// cut one: AppKit gave it to the item the cell draws. It is the name of
    /// the preset, and goes where -setTitle: puts it on a pull-down that
    /// draws its menu's item: in the first item of the menu.
    private func take(_ title: String) {
        guard !working, let first = popUp?.menu?.item(at: 0) else { return }
        first.title = title
        show()
        showAgainSoon()
    }
}

/// The item a pull-down's cell draws for a name cut in the middle. It is in
/// no menu, so nothing is told when its title is written: it tells itself.
private final class CutTitleItem: NSMenuItem {
    var written: ((String) -> Void)?

    override var title: String {
        didSet { written?(title) }
    }

    override init(title: String, action: Selector?, keyEquivalent: String) {
        super.init(title: title, action: action, keyEquivalent: keyEquivalent)
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }
}
