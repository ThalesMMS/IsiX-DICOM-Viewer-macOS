#!/usr/bin/env python3
"""The browser's contextual menus are built once, grouped, and hide what does not apply.

-initContextualMenus keeps the matrix's contextual menu and its variant for
the RT objects in two statics of the class, and every call added their items
once more: a second call left each item twice in both menus. The RT menu
removes the items that need images, «Reparsed Series» among them.

The less frequent commands sit in the submenus of the database list's menu
(Open Special, Export with Burn to Disc, Files & Maintenance). The menus are
built once and reused, so a delegate hides the commands that do not apply each
time one opens, with the submenus and separators they leave empty. A command
in a submenu still counts as one of the thumbnails' menu, which tells the
actions to work on the selected thumbnails.

The methods run compiled with xcrun swiftc, taken from
BrowserController+SplitView.swift into an extension of a stand-in class that
has the statics, the outlets and the menu actions it names, with
ContextMenuPruning.swift; the stand-in refuses a few commands. The method is
called three times, and the menus are read after the first call and after the
third. `<git revision>` as an optional argument reads the source of that
revision, the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
PATH = 'Horos/Sources/BrowserController+SplitView.swift'
PRUNING = 'Horos/Sources/ContextMenuPruning.swift'
failures = []


def read(path):
    if revision:
        shown = subprocess.run(['git', '-C', str(root), 'show', f'{revision}:{path}'], capture_output=True)
        return shown.stdout.decode('utf-8') if shown.returncode == 0 else ''
    return (root / path).read_text(encoding='utf-8')


source = read(PATH)
start = source.find('    @objc(initContextualMenus)')
end = source.find('    @objc(annotMenu:)', start)
if start < 0 or end < 0:
    print('FAIL: -initContextualMenus is no longer followed by -annotMenu: in %s; this test needs a new look' % PATH)
    sys.exit(1)
methods = source[start:end]

actions = sorted(set(re.findall(r'#selector\(BrowserController\.(\w+)\(_:\)\)', methods)))
REFUSED = ['burnDICOM', 'exportROIAndKeyImagesAsDICOMSeries', 'rebuildThumbnails', 'copyToDBFolder']
STAND_IN = 'import AppKit\n\n@MainActor final class BrowserController: NSObject, NSMenuDelegate, NSMenuItemValidation {\n' \
    '    func validateMenuItem(_ item: NSMenuItem) -> Bool {\n' \
    '        ![%s].contains(item.action.map(NSStringFromSelector) ?? "")\n    }\n' % ', '.join('"%s:"' % a for a in REFUSED) + \
    '    @objc static var horos_contextualMenu: NSMenu?\n' \
    '    @objc static var horos_contextualRTMenu: NSMenu?\n' \
    '    var horos_oMatrix: NSMatrix? = NSMatrix(frame: .zero)\n' \
    '    var horos_albumTable: NSTableView? = NSTableView(frame: .zero)\n' + \
    ''.join('    @objc func %s(_ sender: Any!) {}\n' % action for action in actions) + '}\n\n' \
    'extension BrowserController {\n' + methods + '}\n'

DRIVER = r'''
import AppKit

// The commands, those of the submenus included, as "Submenu/Title".
func titles(_ menu: NSMenu?, _ prefix: String = "") -> [String] {
    (menu?.items ?? []).filter { !$0.isSeparatorItem }.flatMap { item in
        item.submenu.map { titles($0, prefix + item.title + "/") } ?? [prefix + item.title]
    }
}
// What shows once the delegate has pruned the menu, separators as "-".
func shown(_ menu: NSMenu) -> String {
    menu.items.filter { !$0.isHidden }.map { item in
        item.isSeparatorItem ? "-" : item.submenu.map { item.title + "(" + shown($0) + ")" } ?? item.title
    }.joined(separator: ",")
}
func emit(_ key: String, _ value: String) { print("\(key)\t\(value)") }

// The browser and its menus belong to the main actor, as in the app.
MainActor.assumeIsolated {
    let browser = BrowserController()
    for call in 1...3 {
        browser.initContextualMenus()
        if call == 1 || call == 3 {
            let contextual = titles(BrowserController.horos_contextualMenu)
            let rt = titles(BrowserController.horos_contextualRTMenu)
            emit("\(call).count", "\(contextual.count)")
            emit("\(call).rt.count", "\(rt.count)")
            emit("\(call).duplicates", "\(contextual.count - Set(contextual).count + rt.count - Set(rt).count)")
            emit("\(call).reparsed", "\(contextual.contains("Open Special/Reparsed Series"))")
            emit("\(call).burn", "\(contextual.contains("Export/Burn to Disc\u{2026}"))")
            emit("\(call).rt.reparsed", "\(rt.contains { $0.contains("Reparsed") })")
            emit("\(call).rt.first", rt.first ?? "none")
            emit("\(call).matrix", "\(browser.horos_oMatrix?.menu === BrowserController.horos_contextualMenu)")
            emit("\(call).albums", "\(browser.horos_albumTable?.menu?.delegate === browser)")
        }
    }

    for (name, menu) in [("menu", BrowserController.horos_contextualMenu!), ("rt", BrowserController.horos_contextualRTMenu!)] {
        menu.delegate?.menuNeedsUpdate?(menu)
        emit("\(name).shown", shown(menu))
    }
    let submenuItem = BrowserController.horos_contextualRTMenu!.items.compactMap(\.submenu).first!.items.first!
    emit("thumbnail.submenu", "\(browser.isThumbnailMenuItem(submenuItem))")
    let otherMenu = NSMenu(title: "")
    emit("thumbnail.other", "\(browser.isThumbnailMenuItem(otherMenu.addItem(withTitle: "Open Images", action: nil, keyEquivalent: "")))")
}
'''

results = {}
with tempfile.TemporaryDirectory(prefix='horos-contextual-menus-') as folder:
    folder = Path(folder)
    (folder / 'BrowserController.swift').write_text(STAND_IN)
    (folder / 'main.swift').write_text(DRIVER)
    (folder / 'ContextMenuPruning.swift').write_text(read(PRUNING))
    built = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'module-cache'),
                            str(folder / 'BrowserController.swift'), str(folder / 'ContextMenuPruning.swift'),
                            str(folder / 'main.swift'),
                            '-o', str(folder / 'menus')], capture_output=True, text=True)
    if built.returncode != 0:
        failures.append('the contextual menus do not compile:\n%s' % built.stderr[-3000:])
    else:
        run = subprocess.run([str(folder / 'menus')], capture_output=True, text=True, timeout=120)
        if run.returncode != 0:
            failures.append('the driver failed: %s' % run.stderr[-800:])
        for line in run.stdout.splitlines():
            key, _, value = line.partition('\t')
            results[key] = value

if results:
    for call in ('1', '3'):
        expected = {
            'duplicates': '0',
            'reparsed': 'true',
            'burn': 'true',
            'rt.reparsed': 'false',
            'rt.first': 'Create ROIs from RTSTRUCT',
            'matrix': 'true',
            'albums': 'true',
        }
        for key, want in expected.items():
            got = results.get('%s.%s' % (call, key))
            if got != want:
                failures.append('after call %s, %s: %r, expected %r' % (call, key, got, want))
    for key in ('count', 'rt.count'):
        if results.get('1.' + key) != results.get('3.' + key):
            failures.append('%s grows from %s items after the first call to %s after the third'
                            % (key, results.get('1.' + key), results.get('3.' + key)))
    if results.get('1.count') and results.get('1.rt.count'):
        if int(results['1.count']) - int(results['1.rt.count']) != 9 - 1:
            failures.append('the RT menu has %s items for the %s of the matrix; it should drop the 9 that need '
                            'images and add one' % (results['1.rt.count'], results['1.count']))
    # The refused commands go, with the Files & Maintenance submenu they empty
    # and the separators of Export they leave with nothing to separate.
    expected_shown = {
        'menu.shown': 'Open Images,Open Images in 4D,Open Special(Sub-Selection,Reparsed Series,Merged Selection,-,'
                      'Key Images,ROIs Images,ROIs and Key Images),Reveal In Finder,-,'
                      'Export(DICOM Network Node\u2026,DICOM File(s)\u2026,-,Movie\u2026,JPEG\u2026,TIFF\u2026),-,'
                      'Toggle Images/Series Displaying,Merge Selected Series,Anonymize,-,'
                      'Compress DICOM files,Decompress DICOM files,-,'
                      'Query Selected Patient from Q&R Window...,-,Delete',
        'rt.shown': 'Create ROIs from RTSTRUCT,-,Open Images,Open Special(Merged Selection),Reveal In Finder,-,'
                    'Export(DICOM Network Node\u2026,DICOM File(s)\u2026),-,'
                    'Toggle Images/Series Displaying,Merge Selected Series,Anonymize,-,'
                    'Compress DICOM files,Decompress DICOM files,-,'
                    'Query Selected Patient from Q&R Window...,-,Delete',
        'thumbnail.submenu': 'true',
        'thumbnail.other': 'false',
    }
    for key, want in expected_shown.items():
        if results.get(key) != want:
            failures.append('%s: %r, expected %r' % (key, results.get(key), want))

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the contextual menus are built once, grouped in submenus, and hide what does not apply')
