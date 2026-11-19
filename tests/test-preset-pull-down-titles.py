#!/usr/bin/env python3
"""A pull-down of presets shows a name that does not fit cut in the middle.

The pull-downs of the window level, the colour table, the opacity table and
the filter show the name of the preset in use, in a button of the width of
its toolbar item: 116 points in most windows. The 3D MPR and the curved MPR
write «Logarithmic Inverse Table» there when the thick slab renders a volume,
and a preset of the user's has any name. A bezelled pull-down cuts its title
at the end, «Logarithmic In…», whatever its cell asks for.

1. PresetPullDownTitle, compiled as it is with MiddleTruncatedTitle
   (IsiXImaging) and a driver in AppKit, on pull-downs made as the nibs make
   them (mini, bezelled, 116 points wide): a name that fits is drawn from the
   menu's first item, as before; a name that does not is drawn cut in the
   middle, whole in what the cell gives its title, with at least six
   characters of each end, and the whole name stays in the first item of the
   menu and is the button's tool tip. The title follows every way a window
   writes it, by the end of the pass of the run loop it is written in: the
   title of the first item, -setTitle: of the button, also with nil, which
   AppKit ignores, and also while the cut title is drawn, the menu filled again, the
   button given another menu, the button made wider or narrower, and the call
   that makes its toolbar item. In a toolbar the cut title is whole too. A
   button that goes takes its rule with it.
2. The nibs: every pull-down of a preset, in every window and every
   language's copy, is a pull-down with a stock cell, which the rule needs.
3. The sources: the rule is installed where the nib connects each of those
   outlets, in the 2D viewer, in the class the 3D windows share and in the
   endoscopy for the two of its 2D views; and no window tells such a cell to
   draw the menu's item behind the rule's back.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402  - the rule of the cut is IsiXImaging's

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Horos/Resources'
RULE = ROOT / 'Horos/Sources/PresetPullDownTitle.swift'
# The outlets of the pull-downs of presets, as the nibs name them.
OUTLETS = ('wlwwPopup', 'clutPopup', 'OpacityPopup', 'convPopup', 'wlww2DPopup', 'clut2DPopup')
# The windows that have them, by nib.
NIBS = ('Viewer', 'OrthogonalMPR', 'MPR', 'CPR', 'VR', 'Endoscopy', 'PETCT')
# Where the nib connects each outlet: the file, and the setters or outlets that install the rule.
INSTALLED = {
    'Horos/Sources/Window3DController.swift': ('@objc(setWlwwPopup:)', '@objc(setClutPopup:)', '@objc(setOpacityPopup:)'),
    'Horos/Sources/ViewerController+WindowOutlets.swift': ('@objc(setWlwwPopup:)', '@objc(setClutPopup:)', '@objc(setOpacityPopup:)',
                                                           '@objc(setConvPopup:)'),
    'Horos/Sources/EndoscopyViewer.swift': ('var wlww2DPopup: NSPopUpButton?', 'var clut2DPopup: NSPopUpButton?'),
}

if not shutil.which('xcrun'):
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(2)

failures = []

found = {}
for nib in NIBS:
    copies = sorted(RESOURCES.glob(f'*.lproj/{nib}.xib'))
    if not copies:
        failures.append(f'no copy of {nib}.xib')
    for xib in copies:
        language = xib.parent.name[:-len('.lproj')]
        document = ET.parse(xib).getroot()
        outlets = {outlet.get('destination'): outlet.get('property') for outlet in document.iter('outlet')
                   if outlet.get('property') in OUTLETS}
        seen = 0
        for pop_up in document.iter('popUpButton'):
            if pop_up.get('id') not in outlets:
                continue
            seen += 1
            cell = pop_up.find('popUpButtonCell')
            where = f'{language} {nib}.xib: {outlets[pop_up.get("id")]}'
            if cell is None or cell.get('pullsDown') != 'YES':
                failures.append(f'{where} is not a pull-down: the rule reads the name from the first item of a pull-down')
            elif cell.get('customClass'):
                failures.append(f'{where} has a cell of class {cell.get("customClass")}; the rule expects the stock cell')
        if seen != len(outlets) or not seen:
            failures.append(f'{language} {nib}.xib: {seen} of its {len(outlets)} pull-downs of presets found')
        found[nib] = seen

for source, places in INSTALLED.items():
    text = (ROOT / source).read_text(encoding='utf-8')
    for place in places:
        line = next((line for line in text.splitlines() if place in line), '')
        if 'PresetPullDownTitle.install(on:' not in line:
            failures.append(f'{source}: {place} does not install the rule of the cut title on the pull-down it connects')
behind = [str(path.relative_to(ROOT)) for path in sorted((ROOT / 'Horos/Sources').glob('*.swift'))
          if path != RULE and re.search(r'[Pp]opup(\(\))?\??\.cell as\? NSPopUpButtonCell\)\?\.usesItemFromMenu\s*=',
                                        path.read_text(encoding='utf-8'))]
if behind:
    failures.append(f'{behind} tell the cell of a pull-down of presets which item to draw; PresetPullDownTitle.show(on:) does it')

driver = r'''
import AppKit
import IsiXImaging

var failures: [String] = []
func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { failures.append(message()) }
}

let long = "Logarithmic Inverse Table"

/// A pull-down as the nibs make those of the presets.
@MainActor func pullDown(width: CGFloat = 116, first: String = "Linear Table") -> NSPopUpButton {
    let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 15), pullsDown: true)
    popUp.controlSize = .mini
    popUp.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .mini))
    popUp.bezelStyle = .rounded
    fill(popUp.menu!, first: first)
    return popUp
}

@MainActor func fill(_ menu: NSMenu, first: String) {
    menu.removeAllItems()
    for title in [first, "Linear Table", "Logarithmic Table", long, "A preset of the user's with a long name of its own"] {
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
    }
}

@MainActor func cell(_ popUp: NSPopUpButton) -> NSPopUpButtonCell { popUp.cell as! NSPopUpButtonCell }
@MainActor func drawn(_ popUp: NSPopUpButton) -> String { cell(popUp).menuItem?.title ?? "<nothing>" }
@MainActor func whole(_ popUp: NSPopUpButton) -> Bool {
    cell(popUp).titleRect(forBounds: popUp.bounds).width >= cell(popUp).attributedTitle.size().width.rounded(.up) - 0.5
}

/// The pass of the run loop a write was made in is over.
@MainActor func settle() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }

/// The button shows `name` whole, from its menu.
@MainActor func expectWhole(_ popUp: NSPopUpButton, _ name: String, _ context: String) {
    settle()
    check(popUp.menu?.item(at: 0)?.title == name, "\(context): the first item is \"\(popUp.menu?.item(at: 0)?.title ?? "nil")\", not \"\(name)\"")
    check(cell(popUp).usesItemFromMenu && cell(popUp).menuItem === popUp.menu?.item(at: 0), "\(context): the cell does not draw the menu's first item")
    check(drawn(popUp) == name && whole(popUp), "\(context): the button draws \"\(drawn(popUp))\" for \"\(name)\"")
    check(popUp.toolTip == (name.isEmpty ? nil : name), "\(context): tool tip \(popUp.toolTip ?? "nil")")
}

/// The button shows `name` cut in the middle, and keeps it whole.
@MainActor func expectCut(_ popUp: NSPopUpButton, _ name: String, _ context: String, ends: Int = 6) {
    settle()
    let title = drawn(popUp)
    check(popUp.menu?.item(at: 0)?.title == name, "\(context): the first item is \"\(popUp.menu?.item(at: 0)?.title ?? "nil")\", not \"\(name)\"")
    check(MiddleTruncatedTitle.isCut(title, of: name), "\(context): the button draws \"\(title)\" for \"\(name)\"")
    check(whole(popUp), "\(context): \"\(title)\" is itself cut by the button")
    if let at = title.range(of: MiddleTruncatedTitle.ellipsis) {
        check(title[..<at.lowerBound].count >= ends && title[at.upperBound...].count >= ends, "\(context): \"\(title)\" keeps too little of the name")
    }
    check(popUp.toolTip == name, "\(context): tool tip \(popUp.toolTip ?? "nil")")
    check(popUp.numberOfItems == 5, "\(context): the menu has \(popUp.numberOfItems) items")
    check(popUp.menu?.items.contains { $0.title.contains(MiddleTruncatedTitle.ellipsis) } == false, "\(context): the cut title is in the menu")
}

final class Host: NSObject, NSToolbarDelegate {
    var view: NSView?
    let id = NSToolbarItem.Identifier("presets")
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [id] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [id] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Presets"
        item.view = view
        return item
    }
}

@main @MainActor struct Test {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // A pull-down no rule is installed on draws its title cut at the end: what the rule is for.
        let stock = pullDown(first: long)
        check(!whole(stock) && drawn(stock) == long, "a stock pull-down of 116 points draws \"\(long)\" whole: nothing to cut")
        PresetPullDownTitle.show(on: stock)
        check(cell(stock).usesItemFromMenu && stock.toolTip == nil, "a pull-down without the rule is changed by the call of the toolbar items")

        let popUp = pullDown()
        PresetPullDownTitle.install(on: popUp)
        PresetPullDownTitle.install(on: popUp)
        expectWhole(popUp, "Linear Table", "installed")

        // The ways a window writes the name.
        popUp.menu?.item(at: 0)?.title = long
        expectCut(popUp, long, "the first item's title")
        check(drawn(popUp).count >= 15, "\"\(drawn(popUp))\" keeps \(drawn(popUp).count) characters of 25 in 116 points")
        popUp.menu?.item(at: 0)?.title = "Default WL & WW"
        expectWhole(popUp, "Default WL & WW", "the first item's title, short again")
        popUp.setTitle(long)
        expectCut(popUp, long, "-setTitle:")
        popUp.setTitle("No CLUT")
        expectWhole(popUp, "No CLUT", "-setTitle: while the cut title is drawn")
        popUp.title = long
        expectCut(popUp, long, "the title property")
        popUp.title = long + " II"
        expectCut(popUp, long + " II", "the title property while the cut title is drawn")
        // As the 2D viewer sends it for a preset with no name: AppKit leaves the title as it is.
        typealias SetTitle = @convention(c) (AnyObject, Selector, NSString?) -> Void
        let selector = #selector(NSPopUpButton.setTitle(_:))
        unsafeBitCast(popUp.method(for: selector), to: SetTitle.self)(popUp, selector, nil)
        expectCut(popUp, long + " II", "-setTitle: with nil while the cut title is drawn")
        popUp.setTitle("Other")
        unsafeBitCast(popUp.method(for: selector), to: SetTitle.self)(popUp, selector, nil)
        expectWhole(popUp, "Other", "-setTitle: with nil")

        fill(popUp.menu!, first: long)
        expectCut(popUp, long, "the menu filled again")
        fill(popUp.menu!, first: "Other")
        expectWhole(popUp, "Other", "the menu filled again, short")
        popUp.menu?.item(at: 0)?.title = long
        let other = NSMenu()
        fill(other, first: "No CLUT")
        popUp.menu = other.copy() as? NSMenu
        popUp.setTitle(long)
        expectCut(popUp, long, "another menu, then -setTitle:")
        let third = NSMenu()
        fill(third, first: "No CLUT")
        popUp.menu = third
        popUp.menu?.item(at: 0)?.title = "VR Muscles-Bones"
        expectWhole(popUp, "VR Muscles-Bones", "another menu, then the first item's title")

        // The user's own name, any length and any script.
        let users = "Coração 👩🏽‍⚕️ e pulmão do paciente — janela larga para contraste tardio"
        popUp.menu?.item(at: 0)?.title = users
        expectCut(popUp, users, "a preset of the user's", ends: 4)

        // The width of the button.
        popUp.menu?.item(at: 0)?.title = long
        expectCut(popUp, long, "116 points")
        let at116 = drawn(popUp)
        popUp.setFrameSize(NSSize(width: 137, height: 15))
        expectWhole(popUp, long, "137 points, the volume rendering's")
        popUp.setFrameSize(NSSize(width: 90, height: 15))
        expectCut(popUp, long, "90 points", ends: 3)
        check(drawn(popUp).count < at116.count, "90 points draw \"\(drawn(popUp))\", 116 drew \"\(at116)\"")
        popUp.setFrameSize(NSSize(width: 116, height: 15))
        check(drawn(popUp) == at116, "back at 116 points the button draws \"\(drawn(popUp))\", not \"\(at116)\"")

        // The call of the code that makes the toolbar item, and a cell told to draw the menu's item behind the rule.
        PresetPullDownTitle.show(on: popUp)
        expectCut(popUp, long, "the toolbar item made")
        cell(popUp).usesItemFromMenu = true
        PresetPullDownTitle.show(on: popUp)
        expectCut(popUp, long, "the toolbar item made after the cell was told to draw its menu")

        // In a toolbar, as the windows hold these buttons.
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 130, height: 40))
        popUp.setFrameOrigin(NSPoint(x: 7, y: 12))
        holder.addSubview(popUp)
        let host = Host()
        host.view = holder
        let window = NSWindow(contentRect: NSRect(x: 60, y: 120, width: 500, height: 200), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .expanded
        let toolbar = NSToolbar(identifier: "IsiXPresetPullDownTest-\(getpid())")
        toolbar.delegate = host
        window.toolbar = toolbar
        window.orderFront(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.6))
        check(popUp.window === window, "the pull-down is not on the toolbar")
        popUp.menu?.item(at: 0)?.title = "Linear Table"
        expectWhole(popUp, "Linear Table", "on the toolbar")
        popUp.menu?.item(at: 0)?.title = long
        expectCut(popUp, long, "on the toolbar", ends: 3)
        print("on the toolbar a 116-point pull-down draws \"\(drawn(popUp))\" for \"\(long)\"")
        window.close()

        // A button that goes takes its rule with it; menus that change later reach nothing.
        weak var gone: NSPopUpButton?
        autoreleasepool {
            let brief = pullDown(first: long)
            PresetPullDownTitle.install(on: brief)
            expectCut(brief, long, "a second button")
            gone = brief
        }
        for _ in 0..<5 where gone != nil { autoreleasepool { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2)) } }
        check(gone == nil, "a pull-down with the rule installed is not released")
        fill(popUp.menu!, first: "Linear Table")
        expectWhole(popUp, "Linear Table", "after another button went")

        if !failures.isEmpty {
            for failure in failures { FileHandle.standardError.write("FAIL: \(failure)\n".data(using: .utf8)!) }
            exit(1)
        }
    }
}
'''

with tempfile.TemporaryDirectory(prefix='isix-preset-pull-down-') as folder:
    work = Path(folder)
    (work / 'Test.swift').write_text(driver)
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', str(RULE), str(work / 'Test.swift'),
                            *isix_modules.module_flags('IsiXImaging', work / 'isix'), '-o', str(work / 'test')],
                           capture_output=True, text=True)
    if built.returncode:
        sys.exit('FAIL: PresetPullDownTitle does not compile with the driver\n' + built.stderr[-4000:])
    ran = subprocess.run([str(work / 'test')], capture_output=True, text=True)
    sys.stdout.write(ran.stdout)
    sys.stderr.write(ran.stderr)
    if ran.returncode:
        failures.append('the pull-down does not show its name as the rule says')

if failures:
    for failure in failures:
        print('FAIL:', failure, file=sys.stderr)
    sys.exit(1)
print(f'PASS: the {sum(found.values())} pull-downs of presets of {len(found)} windows show a long name cut in the middle, '
      'whole in the menu and in the tool tip')
