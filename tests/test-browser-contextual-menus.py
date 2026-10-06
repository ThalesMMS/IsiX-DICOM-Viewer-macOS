#!/usr/bin/env python3
"""The browser's contextual menus are built once, and the RT one has no «Open Reparsed series».

-initContextualMenus keeps the matrix's contextual menu and its copy for the
RT objects in two statics of the class, and every call added their items once
more: a second call left each item twice in both menus. The RT menu removes
the items that need images, but looked for «Open Reparsed Series» while the
item is titled «Open Reparsed series», so it stayed.

The method runs compiled with xcrun swiftc, taken from
BrowserController+SplitView.swift into an extension of a stand-in class that
has the statics, the outlets and the menu actions it names; it is called three
times, and the menus are read after the first call and after the third.
`<git revision>` as an optional argument reads the source of that revision,
the negative control.
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
revision = sys.argv[1] if len(sys.argv) > 1 else None
PATH = 'Horos/Sources/BrowserController+SplitView.swift'
failures = []


def read(path):
    if revision:
        return subprocess.check_output(['git', '-C', str(root), 'show', f'{revision}:{path}']).decode('utf-8')
    return (root / path).read_text(encoding='utf-8')


source = read(PATH)
start = source.find('    @objc(initContextualMenus)')
end = source.find('    @objc(annotMenu:)', start)
if start < 0 or end < 0:
    print('FAIL: -initContextualMenus is no longer followed by -annotMenu: in %s; this test needs a new look' % PATH)
    sys.exit(1)
methods = source[start:end]

actions = sorted(set(re.findall(r'#selector\(BrowserController\.(\w+)\(_:\)\)', methods)))
STAND_IN = 'import AppKit\n\nfinal class BrowserController: NSObject, NSMenuDelegate {\n' \
    '    @objc static var horos_contextualMenu: NSMenu?\n' \
    '    @objc static var horos_contextualRTMenu: NSMenu?\n' \
    '    var horos_oMatrix: NSMatrix? = NSMatrix(frame: .zero)\n' \
    '    var horos_albumTable: NSTableView? = NSTableView(frame: .zero)\n' + \
    ''.join('    @objc func %s(_ sender: Any!) {}\n' % action for action in actions) + '}\n\n' \
    'extension BrowserController {\n' + methods + '}\n'

DRIVER = r'''
import AppKit

func titles(_ menu: NSMenu?) -> [String] { (menu?.items ?? []).filter { !$0.isSeparatorItem }.map { $0.title } }
func emit(_ key: String, _ value: String) { print("\(key)\t\(value)") }

let browser = BrowserController()
for call in 1...3 {
    browser.initContextualMenus()
    if call == 1 || call == 3 {
        let contextual = titles(BrowserController.horos_contextualMenu)
        let rt = titles(BrowserController.horos_contextualRTMenu)
        emit("\(call).count", "\(contextual.count)")
        emit("\(call).rt.count", "\(rt.count)")
        emit("\(call).duplicates", "\(contextual.count - Set(contextual).count + rt.count - Set(rt).count)")
        emit("\(call).reparsed", "\(contextual.contains("Open Reparsed series"))")
        emit("\(call).rt.reparsed", "\(rt.contains { $0.hasPrefix("Open Reparsed") })")
        emit("\(call).rt.first", rt.first ?? "none")
        emit("\(call).matrix", "\(browser.horos_oMatrix?.menu === BrowserController.horos_contextualMenu)")
        emit("\(call).albums", "\(browser.horos_albumTable?.menu?.delegate === browser)")
    }
}
'''

results = {}
with tempfile.TemporaryDirectory(prefix='horos-contextual-menus-') as folder:
    folder = Path(folder)
    (folder / 'BrowserController.swift').write_text(STAND_IN)
    (folder / 'main.swift').write_text(DRIVER)
    built = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(folder / 'module-cache'),
                            str(folder / 'BrowserController.swift'), str(folder / 'main.swift'),
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

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: the contextual menus are built once, and the RT menu drops «Open Reparsed series»')
