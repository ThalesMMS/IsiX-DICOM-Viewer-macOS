#!/usr/bin/env python3
"""Plugin menus, 3D reconstructions and the Hot Keys pane share one catalog."""
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from sources import source_text  # noqa: E402
failures = []


def read(path):
    return (root / path).read_text(errors='replace')


catalog = read('Horos/Sources/MenuShortcutCatalog.swift')
pref = read('Horos/Sources/MenuShortcutPref.swift')
# PluginManager is Swift since #720; setMenus:::: still applies the stored shortcuts.
plugin = source_text('PluginManager')
# PreferencesWindowController is Swift since #711; the pane list is the same.
prefs_window = source_text('PreferencesWindowController')
project = read('Horos.xcodeproj/project.pbxproj')
hotkeys = source_text('OSIHotKeysPref')  # Swift since #711
main_menu = read('Horos/Resources/en.lproj/MainMenu.xib')

checks = [
    ('@objc(HorosMenuShortcutCatalog)' in catalog, 'Swift catalog is the new component'),
    ('HorosMenuShortcuts' in catalog, 'assignments persist in UserDefaults'),
    ('reconstruction.3dMPR' in catalog and 'reconstruction.vr' in catalog,
     'MPR and VR are first-class assignable commands'),
    ('plugin.' in catalog and 'menuTitle' in catalog, 'plugin menu titles are addressable'),
    ('kind' in catalog and 'occupied' in catalog.lower(),
     'a clash with an existing command is detected'),
    ('@objc(HorosMenuShortcutPref)' in pref, 'configuration lives in a Horos preference pane'),
    ('MenuShortcutCatalog' in pref, 'the pane writes through the catalog'),
    ('HorosMenuShortcutPref' in prefs_window, 'the pane is registered next to Hot Keys'),
    ('applyStoredAssignments' in plugin, 'plugin menus receive stored shortcuts after they are built'),
    ('MenuShortcutCatalog.swift in Sources' in project, 'the catalog is compiled into Horos'),
    ('MenuShortcutPref.swift in Sources' in project, 'the preference pane is compiled into Horos'),
    ('setObject(key, forKey: "key" as NSString)' in hotkeys, 'the existing viewer Hot Keys pane is unchanged'),
    ('selector="mprViewer:"' in main_menu and 'selector="VRViewer:"' in main_menu,
     '3D MPR and VR remain the reconstruction menu actions'),
    ('ViewerReferenceLines' not in catalog and 'Viewer.xib' not in catalog,
     'reference-line work is left alone'),
]

for ok, what in checks:
    if not ok:
        failures.append(what)

if failures:
    print('FAIL')
    for item in failures:
        print(' ', item)
    raise SystemExit(1)
print('ok: plugin and reconstruction shortcuts are wired through the catalog and preferences')
