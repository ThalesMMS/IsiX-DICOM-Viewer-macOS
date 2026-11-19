#!/usr/bin/env python3
"""Version 1 plugins have a Report menu, found beside the Database one.

+[PluginManager setMenus::::] takes the four menus the plugins made for Horos
and OsiriX know, and its signature is theirs to call. The fifth menu, Report,
which only version 1 commands with the report placement fill, is found from
the fourth: the item of the Plugins menu that carries an identifier.

Checked here:

* in the main menu of each of the 12 languages, the Plugins menu holds the
  four former menus and, after Database, an item with that identifier and a
  submenu of its own, before the separator and the Plugins Manager;
* the lookup, compiled as PluginManager+IsiXPlugins.swift has it: the Report
  menu beside the Database menu of such a menu, none for a menu that stands
  alone or whose parent has no such item (the menus of a caller that is not
  the application);
* the host names every placement the kit declares, each with its menu, and
  keeps `@unknown default` for a placement of a later kit: none falls to
  Others unnoticed.

    python3 tests/test-plugins-report-menu.py
"""
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import private_tmpdir  # noqa: F401,E402  - its own TMPDIR for the compiler

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ('en', 'de', 'es', 'fr', 'it-IT', 'ja-JP', 'ar', 'zh-Hans', 'hi', 'ru', 'ko', 'pt-BR')
failures = []

lookup = (ROOT / 'Horos/Sources/PluginManager+IsiXPlugins.swift').read_text(encoding='utf-8')
identifier = re.search(r'static let reportMenuItemIdentifier = "([^"]+)"', lookup)
function = re.search(r'\n    (class func reportMenu\(beside dbMenu: NSMenu\?\) -> NSMenu\? \{\n.*?\n    \})\n', lookup, re.S)
if not identifier or not function:
    print('FAIL: the Report menu lookup is not in PluginManager+IsiXPlugins.swift as the test reads it')
    sys.exit(1)

# The nibs.
for language in LANGUAGES:
    tree = ET.parse(ROOT / f'Horos/Resources/{language}.lproj/MainMenu.xib')
    outlets = {o.get('property'): o.get('destination') for o in tree.iter('outlet')
               if o.get('property') in ('filtersMenu', 'roisMenu', 'othersMenu', 'dbMenu')}
    plugins = next((menu for menu in tree.iter('menu')
                    if any(item.find('menu') is not None and item.find('menu').get('id') == outlets.get('dbMenu')
                           for item in menu.findall('items/menuItem'))), None)
    if plugins is None:
        failures.append(f'{language}: no menu holds the Database plugins menu')
        continue
    items = plugins.findall('items/menuItem')
    submenus = [item.find('menu').get('id') if item.find('menu') is not None else None for item in items]
    former = [outlets.get(name) for name in ('filtersMenu', 'roisMenu', 'othersMenu', 'dbMenu')]
    if submenus[:4] != former:
        failures.append(f'{language}: the Plugins menu does not begin with the four former menus')
    report = items[4] if len(items) > 4 else None
    if report is None or report.get('identifier') != identifier.group(1) or report.find('menu') is None:
        failures.append(f'{language}: the item after Database is not the Report menu ({identifier.group(1)})')
    elif report.find('menu').get('id') in former or report.find('menu').findall('items/menuItem'):
        failures.append(f'{language}: the Report menu is not an empty menu of its own')
    if len(items) < 7 or items[5].get('isSeparatorItem') != 'YES':
        failures.append(f'{language}: the separator and the Plugins Manager do not follow the Report menu')
    if sum(1 for item in tree.iter('menuItem') if item.get('identifier') == identifier.group(1)) != 1:
        failures.append(f'{language}: the identifier of the Report menu is not on one item alone')

# The host's switch.
kit = (ROOT / 'IsiXPluginKit/Sources/IsiXCommands.swift').read_text(encoding='utf-8')
placement = re.search(r'public enum Placement: Hashable, Sendable \{(.*?)\n    \}', kit, re.S)
cases = re.findall(r'^\s*case (\w+)$', placement.group(1), re.M) if placement else []
host = (ROOT / 'Horos/Sources/IsiXPluginHost.swift').read_text(encoding='utf-8')
switch = re.search(r'switch command\.placement \{(.*?)\n                \}', host, re.S)
if not cases or not switch:
    failures.append('the placements of the kit or the switch of the host are not where the test reads them')
else:
    named = dict(re.findall(r'case \.(\w+): menu = (.+)', switch.group(1)))
    if sorted(named) != sorted(cases):
        failures.append(f'the host names {sorted(named)}, the kit declares {sorted(cases)}')
    if named.get('report') != 'report ?? others':
        failures.append('a report command does not go to the Report menu, or to Others where there is none')
    if '@unknown default:' not in switch.group(1) or re.search(r'^\s*default:', switch.group(1), re.M):
        failures.append('the switch has a plain default, which hides a placement it does not name')

HARNESS = r'''
import AppKit

enum PluginManager {
    static let reportMenuItemIdentifier = "%(identifier)s"
    %(function)s
}

func submenu(_ title: String, in parent: NSMenu, identifier: String? = nil) -> NSMenu {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    if let identifier { item.identifier = NSUserInterfaceItemIdentifier(identifier) }
    let menu = NSMenu(title: title)
    item.submenu = menu
    parent.addItem(item)
    return menu
}

var failures: [String] = []
let plugins = NSMenu(title: "Plugins")
_ = submenu("Image Filters", in: plugins)
let database = submenu("Datenbank", in: plugins)
let report = submenu("Befund", in: plugins, identifier: PluginManager.reportMenuItemIdentifier)
plugins.addItem(.separator())
if PluginManager.reportMenu(beside: database) !== report { failures.append("the Report menu beside the Database menu was not found") }
if PluginManager.reportMenu(beside: report) !== report { failures.append("the lookup goes by the parent menu, whichever of its menus it is given") }

// The menus of a caller that is not the application.
let alone = NSMenu(title: "Database")
if PluginManager.reportMenu(beside: alone) != nil { failures.append("a menu that stands alone has a Report menu") }
let other = NSMenu(title: "Mine")
let mine = submenu("Database", in: other)
_ = submenu("Report", in: other)
if PluginManager.reportMenu(beside: mine) != nil { failures.append("an item with the title alone was taken for the Report menu") }
if PluginManager.reportMenu(beside: nil) != nil { failures.append("no menu has a Report menu") }
for failure in failures { print("FAIL: " + failure) }
exit(failures.isEmpty ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix='horos-report-menu-') as directory:
    p = Path(directory)
    (p / 'main.swift').write_text(HARNESS % {'identifier': identifier.group(1), 'function': function.group(1).replace('class func', 'static func')})
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-suppress-warnings', str(p / 'main.swift'), '-o', str(p / 'test')],
                           capture_output=True, text=True)
    if build.returncode != 0:
        print(build.stderr[-3000:])
        failures.append('the lookup does not compile with the stand-ins')
    else:
        ran = subprocess.run([str(p / 'test')], capture_output=True, text=True)
        sys.stdout.write(ran.stdout)
        if ran.returncode != 0:
            failures.append('the lookup of the Report menu' if 'FAIL' in ran.stdout else f'the harness ended with {ran.returncode} {ran.stderr.strip()[-300:]}')

for failure in failures:
    print('FAIL: ' + failure)
if failures:
    sys.exit(1)
print('PASS: the Plugins menu of the 12 languages has a Report menu after Database, found from it by its identifier and by nothing else; '
      'the host names every placement of the kit and keeps @unknown default')
