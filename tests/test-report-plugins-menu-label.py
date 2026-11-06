#!/usr/bin/env python3
"""The Database pane's reports menu keeps its "Plugins" label out of the choices.

Every localized OSIDatabasePreferencePanePref nib ends the reports menu with a
separator and a label over the report plugins, the label tagged -1 and its title
translated. `-buildPluginsMenu` once took the item at index 4 for the label; the
nib had gained an editor since, so with one report plugin the separator was
renamed "Plugin" and disabled while the real label stayed enabled, and choosing
it saved REPORTSMODE=3 with REPORTSPLUGIN="Plugins". `-setReportMode:` found the
label by its English title, which most translations do not have, so in those
languages a choice among two or more plugins was saved as Microsoft Word.

Measured in the development app with a stand-in report plugin added to
PluginManager's report plugins before the pane loads:

    0 plugins   ... "Microsoft Word (.doc)"                (no separator, no label)
    1 plugin    ... "Microsoft Word (.doc)", ---, "Plugin" (disabled), the plugin
    2 plugins   ... "Microsoft Word (.doc)", ---, "Plugins" (disabled), both plugins

and the chosen plugin read back from REPORTSPLUGIN after the pane was loaded again
in a new process.

This test keeps the two sides of that contract: the nibs keep the label where the
pane looks for it, and the pane finds it by its tag, marks plugin items by their
represented object, and never saves the label.
"""
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
pane = root / 'Preference Panes/OSIDatabasePreferencePane/OSIDatabasePreferencePanePref.swift'
nibs = sorted(list(root.glob('Preference Panes/OSIDatabasePreferencePane/*.lproj/OSIDatabasePreferencePanePref.xib')) +
              list(root.glob('Horos/Resources/*.lproj/OSIDatabasePreferencePanePref.xib')))

failures = []


def body(source, signature):
    at = source.find(signature)
    if at < 0:
        return ''
    opening = source.index('{', at)
    depth, index = 0, opening
    while index < len(source):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return re.sub(r'//[^\n]*', '', source[opening:index + 1])
        index += 1
    return ''


if len(nibs) < 10:
    failures.append('expected the ten localized Database pane nibs, found %d' % len(nibs))

for nib in nibs:
    where = '%s/%s' % (nib.parent.parent.name, nib.parent.name)
    document = ET.parse(nib).getroot()
    outlet = next((o.get('destination') for o in document.iter('outlet') if o.get('property') == 'reportsMode'), None)
    popup = next((p for p in document.iter('popUpButton') if p.get('id') == outlet), None)
    if popup is None:
        failures.append('%s: no reportsMode pop-up' % where)
        continue
    items = list(popup.iter('menuItem'))
    labels = [i for i, item in enumerate(items) if item.get('tag') == '-1' and item.get('isSeparatorItem') != 'YES']
    if len(labels) != 1:
        failures.append('%s: %d items tagged -1 in the reports menu, expected the one label' % (where, len(labels)))
        continue
    label = labels[0]
    if label != len(items) - 1:
        failures.append('%s: the plugins label is not the last item, so plugins would not follow it' % where)
    if label == 0 or items[label - 1].get('isSeparatorItem') != 'YES':
        failures.append('%s: no separator right before the plugins label' % where)
    if not (items[label].get('title') or '').strip():
        failures.append('%s: the plugins label has no title' % where)

source = pane.read_text(encoding='utf-8')
build = body(source, 'func buildPluginsMenu()')
choose = body(source, 'func setReportMode(')
if not build or not choose:
    failures.append('-buildPluginsMenu or -setReportMode: is gone from the pane')
else:
    if 'reportPluginsLabelTag = -1' not in source or 'Self.reportPluginsLabelTag' not in build:
        failures.append('the pane no longer finds the plugins label by its tag')
    if re.search(r'item\(at:\s*\d', build):
        failures.append('the pane takes a menu item at a fixed index again')
    if 'isSeparatorItem' not in build:
        failures.append('removing the label no longer checks the item before it is the separator')
    if 'isEnabled = false' not in build or 'autoenablesItems = false' not in build:
        failures.append('the plugins label is no longer disabled')
    if 'NSLocalizedString("Plugin"' not in build:
        failures.append('one plugin no longer gets the singular label')
    if 'representedObject = name' not in build:
        failures.append('plugin items no longer carry their plugin name')
    if 'addItem(withTitle:' in build:
        failures.append('plugin items are added by title, which removes an item of the same title')
    if '"Plugins"' in choose or '"Plugin"' in choose:
        failures.append('-setReportMode: looks the label up by its English title again')
    if 'representedObject as? String' not in choose:
        failures.append('-setReportMode: no longer saves the plugin from its item')
    label_branch = choose[choose.find('Self.reportPluginsLabelTag'):]
    label_branch = label_branch[:label_branch.find('} else')]
    if not label_branch or 'return' not in label_branch or '.set(' in label_branch:
        failures.append('choosing the plugins label can still save it')

for failure in failures:
    print('FAIL: %s' % failure)
if failures:
    sys.exit(1)
print('ok: %d nibs keep the plugins label after its separator, tagged -1, and the pane finds it by '
      'that tag, disables it and never saves it as a plugin' % len(nibs))
