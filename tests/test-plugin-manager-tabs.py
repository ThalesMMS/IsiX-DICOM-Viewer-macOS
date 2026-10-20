#!/usr/bin/env python3
"""The Plugins Manager shows the installed plugins and the Horos catalog only.

The OsiriX catalog tab, its outlets and its catalog download are gone from the
ten localized nibs and from the controller, so opening the window asks nothing
of osirixplugins.plist. The updates of installed OsiriX plugins still come from
PluginManager's update check, and download through the controller's
-downloadPluginUpdate:, which takes any plugin package URL.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
failures = []

xibs = sorted(root.glob('Horos/Resources/*.lproj/PluginManager.xib'))
if len(xibs) != 10:
    failures.append(f'expected 10 localized PluginManager.xib, found {len(xibs)}')
for xib in xibs:
    text = xib.read_text(encoding='utf-8')
    items = re.findall(r'<tabViewItem label="[^"]*" identifier="([^"]*)" id="([^"]+)"', text)
    ids = [item_id for _, item_id in items]
    if ids != ['14', 'udo-0p-IM3']:
        failures.append(f'{xib.relative_to(root)}: tabs {ids}, expected the installed plugins (14) and Horos catalog (udo-0p-IM3)')
    for outlet in re.findall(r'<outlet property="([^"]+)"', text):
        if outlet.lower().startswith('osirix') or 'validatedInHorosBox' in outlet:
            failures.append(f'{xib.relative_to(root)}: still connects {outlet}')
    if re.search(r'selector="(?:downloadOsiriXPlugin|changeOsiriXPluginWebView):"', text):
        failures.append(f'{xib.relative_to(root)}: still sends an OsiriX catalog action')

controller = (root / 'Horos/Sources/PluginManagerController.swift').read_text(encoding='utf-8')
for gone in ('OSIRIX_PLUGIN_LIST', 'osirixPlugin', 'availableOsiriXPlugins', 'downloadOsiriXPlugin',
             'setOsiriXPluginDownloadURL', 'validatedInHorosBox'):
    if gone in controller:
        failures.append(f'PluginManagerController.swift still has {gone}')
if '@objc(downloadPluginUpdate:)' not in controller:
    failures.append('PluginManagerController.swift has no -downloadPluginUpdate:')

manager = (root / 'Horos/Sources/PluginManager.swift').read_text(encoding='utf-8')
routes = re.findall(r'if pluginURL\?\.contains\("horosplugin"\) == true \|\| pluginURL\?\.contains\("osirixplugin"\) == true \{\s*'
                    r'_ = pluginManagerController\??\.perform\(NSSelectorFromString\("downloadPluginUpdate:"\), with: pluginURL\)', manager)
if len(routes) != 2:
    failures.append(f'PluginManager.swift routes {len(routes)} of the 2 update downloads through -downloadPluginUpdate:')
for gone in ('downloadOsiriXPlugin:', 'setOsiriXPluginDownloadURL:'):
    if gone in manager:
        failures.append(f'PluginManager.swift still sends {gone}, which the controller no longer answers')
if '@objc(checkForOsiriXPluginsUpdates:)' not in manager:
    failures.append('PluginManager.swift no longer checks installed OsiriX plugins for updates')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print(f'PASS: {len(xibs)} Plugins Manager nibs show two tabs, the controller has no OsiriX catalog, '
      'and installed plugin updates download through -downloadPluginUpdate:')
