#!/usr/bin/env python3
"""Changing the series list placement keeps the floating panel on the front viewer's list.

With the floating list, the panel borrows the front viewer's scroll view. The
placement menu action makes every viewer re-place its list in its own dock,
and the dock is found from where the list is. A list still in the panel left
the panel showing nothing, and the panel's same-list early return never put it
back; with the dock on the right or at the bottom the image pane was taken for
the dock and hidden. The real menu action, the panel's real return of a
borrowed list and the real SeriesListLayout run on AppKit views; the viewers
re-place their list as ViewerController.m's -updateSeriesListMode does.

`<git revision>` as an optional argument reads SeriesListPlacementMenu.swift
from that revision, the negative control.
"""
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources
import harness_defaults  # the harness's preferences stay in its own process

root = Path(__file__).resolve().parents[1]
if len(sys.argv) > 1:
    menu = subprocess.check_output(['git', '-C', str(root), 'show',
                                    sys.argv[1] + ':Horos/Sources/SeriesListPlacementMenu.swift']).decode()
else:
    menu = (root / 'Horos/Sources/SeriesListPlacementMenu.swift').read_text()
action = menu[menu.index('    @IBAction @objc(setSeriesListPlacement:)'):menu.rindex('\n}')]
panel = sources.source_text('ThumbnailsListPanel')
g = panel.index('fileprivate var associatedScreen')
panel_globals = panel[g:panel.index('///', panel.index('fileprivate func pointerKey', g))]
r = panel.index('    public func returnBorrowedList()')
returning = panel[r:panel.index('    isolated deinit', r)]

driver = r'''
import AppKit

@MainActor func check(_ value: Bool, _ message: String) {
    if !value {
        UserDefaults.standard.removeObject(forKey: SeriesListLayout.placementDefaultsKey)
        fputs("FAIL: \(message)\n", stderr); exit(1)
    }
}

GLOBALS

/// The panel of one screen. The window stays on screen; `content` is its content view.
@MainActor public final class ThumbnailsListPanel: NSObject {
    public var thumbnailsView: NSView?
    weak var superView: NSView?
    public var viewer: ViewerController?
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 110, height: 700))
RETURNING
    /// What the production -setThumbnailsView:viewer: does with a list: the
    /// same list returns early; another one is borrowed once the previous one
    /// is back where it came from.
    public func setThumbnailsView(_ list: NSView?, viewer v: ViewerController?) {
        if list === thumbnailsView { return }
        viewer = v
        if let home = superView, let previous = thumbnailsView { home.addSubview(previous) }
        thumbnailsView = list
        superView = list?.superview
        if let list = list { content.addSubview(list); list.frame = content.bounds }
    }
}

@MainActor public final class AppController: NSObject {
    static var panel: ThumbnailsListPanel!
    public static func thumbnailsListPanel(for screen: NSScreen!) -> ThumbnailsListPanel! { panel }
}

@MainActor public class ViewerController: NSObject {
    static var front: ViewerController?
    public static func frontMostDisplayed2DViewer(for screen: NSScreen!) -> ViewerController? { front }
    let name: String
    let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let dock = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 600))
    let image = NSView(frame: NSRect(x: 109, y: 0, width: 691, height: 600))
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 600))
    init(_ name: String) {
        self.name = name
        super.init()
        split.isVertical = true
        split.addSubview(dock); split.addSubview(image)
        dock.addSubview(scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(updateSeriesListMode),
                                               name: NSNotification.Name(SeriesListLayout.placementDidChangeNotification), object: nil)
    }
    public func previewMatrixScrollView() -> NSScrollView { scroll }
    /// ViewerController.m's -updateSeriesListMode with the floating list shown.
    @objc func updateSeriesListMode() {
        SeriesListLayout.place(scroll, in: split, floating: true, visible: true, thumbnailWidth: 100,
                               placement: SeriesListLayout.storedPlacement(in: UserDefaults.standard))
    }
}

extension ViewerController {
ACTION
}

@main struct Check {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard !NSScreen.screens.isEmpty else { print("SKIP: no screen to give a panel"); exit(2) }
        UserDefaults.standard.removeObject(forKey: SeriesListLayout.placementDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: SeriesListLayout.placementDefaultsKey) }
        let a = ViewerController("A"), b = ViewerController("B")
        let viewers = [a, b]
        for v in viewers { v.updateSeriesListMode() }
        AppController.panel = ThumbnailsListPanel()
        ViewerController.front = a
        AppController.panel.setThumbnailsView(a.scroll, viewer: a)
        let names = ["left", "right", "top", "bottom"]
        // Every edge from every edge, the front viewer changing halfway.
        let steps = [1, 0, 3, 2, 1, 2, 0, 2, 3, 1, 3, 0]
        for (index, tag) in steps.enumerated() {
            if index == steps.count / 2 { ViewerController.front = b }
            let front = ViewerController.front!
            let item = NSMenuItem(title: names[tag], action: nil, keyEquivalent: "")
            item.tag = tag
            front.setSeriesListPlacement(item)
            let step = "step \(index) (\(names[tag]), front \(front.name))"
            check(SeriesListLayout.storedPlacement(in: UserDefaults.standard).name == names[tag], "\(step): the placement is stored")
            let p = AppController.panel!
            check(p.thumbnailsView === front.scroll && front.scroll.superview === p.content && p.viewer === front,
                  "\(step): the panel shows the front viewer's list, and a click loads in that viewer")
            for v in viewers {
                check(v.split.subviews.count == 2 && v.split.subviews.contains(v.image) && !v.image.isHidden,
                      "\(step): viewer \(v.name) keeps its image pane on screen")
                check(!v.scroll.isDescendant(of: v.image), "\(step): viewer \(v.name)'s list is not inside its image pane")
                if v !== front {
                    check(v.scroll.superview === v.dock && v.dock.isHidden, "\(step): viewer \(v.name)'s list is home in its hidden dock")
                }
            }
            let dockIndex = (tag == 0 || tag == 2) ? 0 : 1
            check(front.split.subviews[dockIndex] === front.dock, "\(step): the dock moved to its edge")
        }
        print("PASS: \(steps.count) placement changes keep the floating panel on the front viewer's list and every image pane on screen")
    }
}
'''.replace('GLOBALS', panel_globals).replace('RETURNING', returning).replace('ACTION', action)

with tempfile.TemporaryDirectory(prefix='horos-series-list-placement-panel-') as folder:
    folder = Path(folder)
    (folder / 'Check.swift').write_text(driver)
    (folder / 'defaults.m').write_text(harness_defaults.OBJC)
    subprocess.run(['xcrun', 'clang', '-c', str(folder / 'defaults.m'), '-o', str(folder / 'defaults.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(root / 'Horos/Sources/SeriesListLayout.swift'), str(folder / 'Check.swift'), str(folder / 'defaults.o'),
                    '-o', str(folder / 'series-list-placement-panel')], check=True)
    sys.exit(subprocess.run([str(folder / 'series-list-placement-panel')]).returncode)
