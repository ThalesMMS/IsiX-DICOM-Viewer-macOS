#!/usr/bin/env python3
"""The UI and portal ask the chosen local databases and keep origin visible.

The browser's search and federated query methods are Swift since #831
(BrowserController+Plugins.swift, declared for the target without Swift in
BrowserController+Plugins.h); the UI search and the study list stay in
BrowserController.m.
"""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sources import source_text

root = Path(__file__).resolve().parents[1]
failures = []

def read(path):
    return (root / path).read_bytes().decode('latin1')

browser = read('Horos/Sources/BrowserController.m')
# BrowserController (Sources) is Swift since #722.
sources = source_text('BrowserController+Sources')
portal = source_text('WebPortalConnection+Data')
response = source_text('WebPortalResponse')
# The Plugins block of BrowserController is Swift since #831.
plugins = source_text('BrowserController+Plugins')
header = read('Horos/Sources/BrowserController+Plugins.h')
main = (root / 'Horos/Resources/WebServicesHTML/English/main.html').read_text()
listing = (root / 'Horos/Resources/WebServicesHTML/English/studyList.html').read_text()
project = (root / 'Horos.xcodeproj/project.pbxproj').read_text()
swift = (root / 'Horos/Sources/FederatedSearch.swift').read_text()

checks = [
    ('class' in swift and 'HorosFederatedSearch' in swift, 'Swift federated search is the new component'),
    ('federatedStudiesMatchingPredicate:' in header
     and '@objc(federatedStudiesMatchingPredicate:excludingDatabasePath:applyingUser:)' in plugins,
     'the browser publishes the aggregate query'),
    ('federatedStudiesMatchingPredicate:self.filterPredicate' in browser, 'a UI search asks the chosen databases'),
    ('displayName:name origin:' in browser, 'the study list shows origin for a foreign hit'),
    (' / Federated: %@' in plugins, 'the status line names the chosen databases'),
    ('toggleFederatedSearch:' in sources, 'each local source can be opted in'),
    ('Include in federated search' in sources, 'the checkbox states the permission'),
    ('isFederatedXID(xid' in portal, 'the portal resolves a study back to its origin'),
    ('federatedStudies(matching: browsePredicate' in portal, 'a portal search aggregates chosen databases'),
    ('forKey: "origin"' in portal, 'JSON keeps the origin'),
    ('federatedOrigin' in response, 'HTML can print the origin'),
    ('federatedPermission' in response, 'HTML can print the permission'),
    ('Info.hasFederatedSources' in main, 'the portal search page lists chosen databases'),
    ('Study.federatedOrigin' in listing, 'the study list shows origin next to a homonym'),
    ('FederatedSearch.swift in Sources' in project, 'the Swift file is compiled into Horos'),
]
for ok, what in checks:
    if not ok:
        failures.append(what)

if failures:
    print('FAIL')
    for item in failures:
        print(' ', item)
    raise SystemExit(1)
print('ok: UI and portal wire optional federated search with visible origin and permissions')
