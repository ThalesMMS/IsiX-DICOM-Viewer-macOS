#!/usr/bin/env python3
"""A viewer's series list is never freed by the floating panels that borrow it.

Each screen has a floating panel that borrows the list of its front viewer:
the scroll view leaves the viewer's window for the panel's. The viewer did not
retain its list, and a panel gave it back to "the view it was in when lent".
When the panel of a second screen took a list the first panel still had, that
view was the first panel's content: at the next change of the screens every
panel gave its list back in turn, the list ended in the content of a panel that
was then released, and the viewer read a freed scroll view at its next redraw.

The real methods of ThumbnailsListPanel (-setThumbnailsView:viewer:,
-returnBorrowedList, -prepareForScreenReconfiguration, its deinit and
-thumbnailsListWillClose:) are compiled from the Swift source with peers of the
same shape. The viewer peer keeps its list as the viewer's outlets declare it.
What is checked, with real views and windows:

- a list a second panel takes leaves the first, and after the screens change
  and every panel is released it is alive, in its viewer's dock;
- the same when the first panel went away before the second gave it back;
- a list of a closing viewer goes back to its window and is not left in the panel;
- two viewers sharing a panel get each its own list back;
- a viewer with no dock left keeps its list;
- every loop over the panels covers the spare one, beyond the screens.

`<git revision>` as an optional argument reads the sources from that revision,
the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sources
import harness_defaults  # the harness's preferences stay in its own process
import process_graph_stand_in  # the panel reads the catalog's keys through PreferencesSource

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None


def read(relative):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{relative}']).decode()
    return (root / relative).read_text()


panel = read('Horos/Sources/ThumbnailsListPanel.swift')
outlets = read('Horos/Sources/ViewerController+WindowOutlets.swift')

declaration = re.search(r'^\s*(.*)var previewMatrixScrollView: NSScrollView\?', outlets, re.M)
if declaration:
    retained = declaration.group(1).strip() == ''
else:
    # The outlets are fields of the viewer, which the former plugin SDK
    # declared: this one alone is declared without unowned(unsafe).
    declaration = re.search(r'^\s*(.*)var (?:.*, )?_previewMatrixScrollView: NSScrollView\?', read('Horos/Sources/ViewerController.swift'), re.M)
    assert declaration, 'the outlet of the series list is not where it was'
    retained = 'unowned' not in declaration.group(1) and 'weak' not in declaration.group(1)
if not revision:
    assert retained, 'the viewer does not retain its series list: ' + declaration.group(0).strip()

g = panel.index('@MainActor fileprivate var associatedScreen')
panel_globals = panel[g:panel.index('///', panel.index('fileprivate func pointerKey', g))]
a = panel.index('    @objc public func prepareForScreenReconfiguration()')
giving_back = panel[a:panel.index('    @objc(windowDidResignKey:)', a)]
c = panel.index('    @objc(thumbnailsListWillClose:)')
closing = panel[c:panel.index('    @objc(viewerWillClose:)', c)]
s = panel.index('    @objc(setThumbnailsView:viewer:)')
lending = panel[s:panel.rindex('\n}')]
former_origin = 'private weak var superView: NSView?' if 'weak var superView' in panel else ''

if not revision:
    # A panel is kept for each screen and one more: a loop that stops at the
    # screens leaves the spare panel, or the panel of a screen that went, alone.
    for path in sorted((root / 'Horos/Sources').glob('*.swift')):
        text = path.read_text()
        short = re.search(r'for \w+ in 0\.\.<(?:min\(\w+, )?NSScreen\.screens\.count\)? \{\n[^\n]*\n?[^\n]*AppControllerCAPIThumbnailsListPanel', text)
        assert not short, f'{path.name}: a loop over the series list panels stops at the screens'

driver = r'''
import AppKit
import IsiXPreferences

@MainActor func check(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

let HorosObjCExceptionKey = "HorosObjCException"
enum HorosObjCException {
    static func perform(_ body: () -> Void) throws { body() }
}
func _N2LogExceptionImpl(_ exception: NSException, _ stack: Bool, _ context: String) {}

GLOBALS

enum ViewerWindowArranger { static let maximumScreens = 10 }
@MainActor var panels: [ThumbnailsListPanel?] = []
@MainActor func AppControllerCAPIThumbnailsListPanel(_ index: Int) -> ThumbnailsListPanel? {
    index < panels.count ? panels[index] : nil
}

@MainActor final class SeriesListPresenter {
    weak var listDock: NSView?
}

/// A viewer window: a split view with the dock of the list and the image pane.
@MainActor public final class ViewerController: NSObject {
    let window: NSWindow? = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                                     styleMask: .borderless, backing: .buffered, defer: true)
    let dock = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 600))
    let seriesListPresenter = SeriesListPresenter()
    /// The outlet, kept as the viewer's outlets keep it.
    OUTLET var outlet: NSScrollView?
    /// What the test sees of the list, without keeping it.
    weak var list: NSScrollView?
    override init() {
        super.init()
        window?.isReleasedWhenClosed = false
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        split.addSubview(dock)
        split.addSubview(NSView(frame: NSRect(x: 100, y: 0, width: 700, height: 600)))
        window?.contentView?.addSubview(split)
        autoreleasepool {
            let scrollView = NSScrollView(frame: dock.bounds)
            dock.addSubview(scrollView)
            outlet = scrollView
            list = scrollView
        }
        seriesListPresenter.listDock = dock
    }
    @objc func showCurrentThumbnail(_ sender: Any?) {}
    var inDock: Bool { list != nil && list?.superview === dock }
}

/// The panel's window, as much of it as the panel uses. It goes with its
/// panel, and its content with it: a window of AppKit stays in the
/// application's list for a while after its controller went, which would hide
/// a list left in it.
@MainActor final class ThumbnailsListNSWindow: NSObject {
    let contentView: NSView? = NSView(frame: NSRect(x: 0, y: 0, width: 110, height: 700))
    var isVisible = false
    let screen: NSScreen? = nil
    func order(_ place: NSWindow.OrderingMode, relativeTo other: Int) { isVisible = true }
    func orderBack(_ sender: Any?) { isVisible = true }
    func orderOut(_ sender: Any?) { isVisible = false }
    func hideForReconfiguration() { isVisible = false }
}

@MainActor public final class ThumbnailsListPanel: NSObject {
    public var thumbnailsView: NSView?
    FORMER_ORIGIN
    public var viewer: ViewerController?
    let isWindowLoaded = true
    let window: ThumbnailsListNSWindow? = ThumbnailsListNSWindow()
    func applicationDidChangeScreenParameters(_ note: Notification?) {}
GIVING_BACK
CLOSING
LENDING
}

/// What the application does when the screens change: every panel gives its
/// list back, in the order of the screens, and the panels are replaced.
@MainActor func screensChange() {
    autoreleasepool {
        for i in 0..<panels.count { panels[i]?.prepareForScreenReconfiguration() }
        for i in 0..<panels.count { panels[i] = nil }
    }
    autoreleasepool { panels = [ThumbnailsListPanel(), ThumbnailsListPanel(), ThumbnailsListPanel()] }
}

@main struct Check {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "UseFloatingThumbnailsList")
        defaults.set(true, forKey: "SeriesListVisible")

        // The window moved to the second screen and became key there before
        // the first screen's panel was told: the second panel takes the list.
        autoreleasepool { panels = [ThumbnailsListPanel(), ThumbnailsListPanel(), ThumbnailsListPanel()] }
        let v = ViewerController()
        autoreleasepool {
            panels[0]?.setThumbnailsView(v.list, viewer: v)
            check(v.list?.superview === panels[0]?.window?.contentView, "the first panel borrows the list")
            panels[1]?.setThumbnailsView(v.list, viewer: v)
            check(v.list?.superview === panels[1]?.window?.contentView, "the second panel has the list")
        }
        if RETAINED {
            check(panels[0]?.thumbnailsView == nil && panels[0]?.viewer == nil, "a list is in one panel only")
        }
        screensChange()
        check(v.list != nil, "the list was freed under its viewer when the screens changed")
        check(v.inDock, "after the screens changed the list is not in its viewer's dock")

        // The first panel goes away alone, then the second gives the list back.
        autoreleasepool {
            panels[0]?.setThumbnailsView(v.list, viewer: v)
            panels[1]?.setThumbnailsView(v.list, viewer: v)
            panels[0] = nil
        }
        autoreleasepool { panels[1]?.prepareForScreenReconfiguration() }
        check(v.list != nil, "the list was freed under its viewer when its former panel went")
        check(v.inDock, "the list is not back in its dock after its former panel went")

        // The spare panel, beyond the screens, is asked like the others.
        autoreleasepool {
            panels[2]?.setThumbnailsView(v.list, viewer: v)
            panels[0] = ThumbnailsListPanel()
            panels[0]?.setThumbnailsView(v.list, viewer: v)
        }
        check(panels[2]?.thumbnailsView == nil, "the spare panel still answers for a list another panel has")
        screensChange()
        check(v.inDock, "the list is not back in its dock after the spare panel had it")

        // Two viewers on one screen: each list goes back to its own window.
        let w = ViewerController()
        autoreleasepool {
            panels[0]?.setThumbnailsView(v.list, viewer: v)
            panels[0]?.setThumbnailsView(w.list, viewer: w)
            check(v.inDock && w.list?.superview === panels[0]?.window?.contentView, "the panel shows the second viewer's list, the first is back")
            panels[0]?.setThumbnailsView(nil, viewer: nil)
        }
        check(v.inDock && w.inDock, "each list is back in its own window")

        // A viewer that closes: its list is not left in the panel.
        autoreleasepool {
            panels[0]?.setThumbnailsView(w.list, viewer: w)
            panels[0]?.thumbnailsListWillClose(w.list)
        }
        check(panels[0]?.thumbnailsView == nil && panels[0]?.viewer == nil, "the panel let the closing viewer's list go")
        check(panels[0]?.window?.contentView?.subviews.isEmpty == true, "the list of a closed viewer is left in the panel")
        check(w.inDock, "the list of a closing viewer is not back in its window")

        // A window with no dock left: the viewer still has its list.
        autoreleasepool {
            panels[1]?.setThumbnailsView(v.list, viewer: v)
            v.seriesListPresenter.listDock = nil
            v.dock.removeFromSuperview()
            panels[1]?.returnBorrowedList()
        }
        check(v.list != nil && v.list?.superview == nil, "a list with no dock to go to is kept by its viewer, out of the panel")

        print("PASS: a list lent from panel to panel, through changes of the screens and a closing viewer, is alive and in its viewer's dock")
    }
}
'''.replace('GLOBALS', panel_globals).replace('GIVING_BACK', giving_back).replace('CLOSING', closing) \
   .replace('LENDING', lending).replace('FORMER_ORIGIN', former_origin) \
   .replace('OUTLET', '' if retained else 'weak').replace('RETAINED', 'true' if retained else 'false')

with tempfile.TemporaryDirectory(prefix='horos-thumbnail-outlives-') as folder:
    folder = Path(folder)
    (folder / 'Check.swift').write_text(driver)
    (folder / 'defaults.m').write_text(harness_defaults.OBJC)
    subprocess.run(['xcrun', 'clang', '-c', str(folder / 'defaults.m'), '-o', str(folder / 'defaults.o')], check=True)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library',
                    str(folder / 'Check.swift'), str(folder / 'defaults.o'),
                    *process_graph_stand_in.swift_flags(folder / 'isix'), '-o', str(folder / 'thumbnail-list-outlives-panels')], check=True)
    sys.exit(subprocess.run([str(folder / 'thumbnail-list-outlives-panels')]).returncode)
