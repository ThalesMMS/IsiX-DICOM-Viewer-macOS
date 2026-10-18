#!/usr/bin/env python3
"""The floating panel shows a newly lent list at its viewer's current series.

Each viewer has its own series list, and the panel of a screen borrows the
front viewer's. A list built while its viewer was in the background kept its
scroll position: the top of the list, or the position -syncThumbnails copied
from another viewer of the study. Scrolling the images of another exam made
its viewer the front one, and the panel then showed that exam's list at the
same series every time instead of the series being scrolled. The real
-setThumbnailsView:viewer: (with the file's associatedScreen dictionary and
its key) is compiled from the Swift source (tests/sources.py) with peers of
the same shape.

`<git revision>` as an optional argument reads ThumbnailsListPanel.swift from
that revision, the negative control.
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
    panel = subprocess.check_output(['git', '-C', str(root), 'show',
                                     sys.argv[1] + ':Horos/Sources/ThumbnailsListPanel.swift']).decode()
else:
    panel = sources.source_text('ThumbnailsListPanel')
g = panel.index('@MainActor fileprivate var associatedScreen')
panel_globals = panel[g:panel.index('///', panel.index('fileprivate func pointerKey', g))]
s = panel.index('    @objc(setThumbnailsView:viewer:)')
method = panel[s:panel.rindex('\n}')]

driver = r'''
import AppKit

@MainActor func check(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let HorosObjCExceptionKey = "HorosObjCException"
enum HorosObjCException {
    static func perform(_ body: () -> Void) throws { body() }
}
func _N2LogExceptionImpl(_ exception: NSException, _ stack: Bool, _ context: String) {}

GLOBALS

@MainActor public final class ViewerController: NSObject {
    let window: NSWindow? = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                     styleMask: .borderless, backing: .buffered, defer: true)
    let home = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 600))
    let list = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 600))
    var shown = 0
    override init() { super.init(); home.addSubview(list) }
    /// ViewerController.m scrolls its list to the series it displays.
    @objc func showCurrentThumbnail(_ sender: Any?) { shown += 1 }
}

@MainActor public final class ThumbnailsListPanel: NSObject {
    public var thumbnailsView: NSView?
    private weak var superView: NSView?
    public var viewer: ViewerController?
    let window: NSWindow? = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 110, height: 700),
                                     styleMask: .borderless, backing: .buffered, defer: true)
    func applicationDidChangeScreenParameters(_ note: Notification?) {}
METHOD
}

@main struct Check {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "UseFloatingThumbnailsList")
        defaults.set(true, forKey: "SeriesListVisible")
        let panel = ThumbnailsListPanel()
        let a = ViewerController(), b = ViewerController()

        panel.setThumbnailsView(a.list, viewer: a)
        check(panel.thumbnailsView === a.list && a.list.superview === panel.window?.contentView, "the panel borrows A's list")
        check(a.shown == 1, "A's list is lent at the series A displays")

        // A redraw or a click in the panel lends the same list again: the list
        // stays where the operator scrolled it.
        panel.setThumbnailsView(a.list, viewer: a)
        check(a.shown == 1, "the list A already lent keeps its scroll position")

        // Scrolling the images of the other exam makes B the front viewer.
        panel.setThumbnailsView(b.list, viewer: b)
        check(panel.viewer === b && a.list.superview === a.home, "A's list is back in A, the panel shows B's")
        check(b.shown == 1 && a.shown == 1, "B's list is lent at the series B displays")

        panel.setThumbnailsView(a.list, viewer: a)
        check(a.shown == 2 && b.shown == 1, "A's list, lent again, shows the series A displays now")

        panel.setThumbnailsView(nil, viewer: nil)
        check(panel.thumbnailsView == nil && a.list.superview === a.home && a.shown == 2, "taking the list back scrolls nothing")

        defaults.set(false, forKey: "SeriesListVisible")
        panel.setThumbnailsView(b.list, viewer: b)
        check(panel.thumbnailsView == nil && b.shown == 1, "a hidden series list is not lent nor scrolled")

        print("PASS: a newly lent list shows its viewer's series; the same list lent again keeps its position")
    }
}
'''.replace('GLOBALS', panel_globals).replace('METHOD', method)

with tempfile.TemporaryDirectory(prefix='horos-thumbnail-lent-scroll-') as folder:
    folder = Path(folder)
    (folder / 'Check.swift').write_text(driver)
    (folder / 'defaults.m').write_text(harness_defaults.OBJC)
    subprocess.run(['xcrun', 'clang', '-c', str(folder / 'defaults.m'), '-o', str(folder / 'defaults.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(folder / 'Check.swift'), str(folder / 'defaults.o'),
                    '-o', str(folder / 'thumbnail-lent-list-scroll')], check=True)
    sys.exit(subprocess.run([str(folder / 'thumbnail-lent-list-scroll')]).returncode)
