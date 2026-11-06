#!/usr/bin/env python3
"""The Plugins Manager shows the installed plugins only.

The OsiriX and Horos catalog tabs, their outlets, web views and catalog
downloads are gone from the ten localized nibs and from the controller: both
catalogs only listed plugins of the former API, which the app refuses after the
download. Opening the window loads nothing from the network.

Updates come from PluginManager's update check and download through the
controller's -downloadPluginUpdate:, only for a version 1 package
(.isixplugin): a former plugin package is never downloaded as an update. The
download reports in a status line (a spinner and a text field) below the plugin
list of the Installed Plugins tab, which the controller's statusControls hands
to the download and the installation.

The ten nibs keep one structure: with their localized texts set aside, they are
the same.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
failures = []


def element(text, tag, ident):
    """The <tag ... id="ident"> element, to its closing tag, or ''."""
    start = re.search(r'\n([ ]*)<%s\b[^>]*\bid="%s"' % (tag, re.escape(ident)), text)
    if not start:
        return ''
    close = '\n%s</%s>' % (start.group(1), tag)
    end = text.find(close, start.end())
    return text[start.start():end + len(close)] if end >= 0 else ''


def structure(text):
    """The nib with its localized texts blanked."""
    return re.sub(r'\b(title|label|placeholderString|toolTip)="[^"]*"', r'\1=""', text)


xibs = sorted(root.glob('Horos/Resources/*.lproj/PluginManager.xib'))
if len(xibs) != 10:
    failures.append(f'expected 10 localized PluginManager.xib, found {len(xibs)}')
shapes = {}
for xib in xibs:
    name = xib.relative_to(root)
    text = xib.read_text(encoding='utf-8')
    shapes[name] = structure(text)
    ids = [item_id for _, item_id in re.findall(r'<tabViewItem label="[^"]*" identifier="([^"]*)" id="([^"]+)"', text)]
    if ids != ['14']:
        failures.append(f'{name}: tabs {ids}, expected only the installed plugins (14)')
    outlets = dict(re.findall(r'<outlet property="([^"]+)" destination="([^"]+)"', text))
    for outlet in outlets:
        if outlet.lower().startswith(('osirix', 'horosplugin')) or 'validatedInHorosBox' in outlet:
            failures.append(f'{name}: still connects {outlet}')
    if re.search(r'selector="(?:downloadOsiriXPlugin|changeOsiriXPluginWebView|downloadHorosPlugin|changeHorosPluginWebView):"', text):
        failures.append(f'{name}: still sends a catalog action')
    if '<wkWebView' in text or 'WebKit2IBPlugin' in text:
        failures.append(f'{name}: still has a catalog web view')
    installed = element(text, 'view', '15')
    for outlet, tag in (('downloadStatusTextField', 'textField'), ('downloadStatusProgressIndicator', 'progressIndicator')):
        destination = outlets.get(outlet)
        if not destination:
            failures.append(f'{name}: does not connect {outlet}')
        elif not re.search(r'<%s\b[^>]*\bid="%s"' % (tag, re.escape(destination)), installed):
            failures.append(f'{name}: {outlet} is not a {tag} of the Installed Plugins tab')
english = next((shape for name, shape in shapes.items() if name.parent.name == 'en.lproj'), None)
if english is None:
    failures.append('no English PluginManager.xib')
else:
    for name, shape in shapes.items():
        if shape != english:
            failures.append(f'{name}: its structure differs from the English nib')

controller = (root / 'Horos/Sources/PluginManagerController.swift').read_text(encoding='utf-8')
for gone in ('OSIRIX_PLUGIN_LIST', 'osirixPlugin', 'availableOsiriXPlugins', 'downloadOsiriXPlugin',
             'setOsiriXPluginDownloadURL', 'validatedInHorosBox',
             'HOROS_PLUGIN_LIST', 'HorosLoadPluginCatalog', 'horosPlugin', 'availableHorosPlugins', 'downloadHorosPlugin',
             'setHorosPluginDownloadURL', 'loadSubmitPluginPage', 'sendPluginSubmission', 'WKWebView', 'import WebKit',
             'CatalogNavigation', 'DispatchQueue.global'):
    if gone in controller:
        failures.append(f'PluginManagerController.swift still has {gone}')
if '@objc(downloadPluginUpdate:)' not in controller:
    failures.append('PluginManagerController.swift has no -downloadPluginUpdate:')
if not re.search(r'func statusControls\(forPath path: String\)[^{]*\{\s*return \(downloadStatusTextField, downloadStatusProgressIndicator\)', controller):
    failures.append('PluginManagerController.swift does not report downloads in the Installed Plugins status line')

manager = (root / 'Horos/Sources/PluginManager.swift').read_text(encoding='utf-8')
routes = re.findall(r'if PluginManager\.isVersion1Download\(pluginURL\) \{\s*'
                    r'_ = pluginManagerController\??\.perform\(NSSelectorFromString\("downloadPluginUpdate:"\), with: pluginURL\)', manager)
if len(routes) != 2:
    failures.append(f'PluginManager.swift routes {len(routes)} of the 2 update downloads through -downloadPluginUpdate:')
for gone in ('downloadOsiriXPlugin:', 'setOsiriXPluginDownloadURL:', 'downloadHorosPlugin:', 'setHorosPluginDownloadURL:'):
    if gone in manager:
        failures.append(f'PluginManager.swift still sends {gone}, which the controller no longer answers')
if '@objc(checkForOsiriXPluginsUpdates:)' not in manager:
    failures.append('PluginManager.swift no longer keeps -checkForOsiriXPluginsUpdates:')
if re.search(r'contains\("(horosplugin|osirixplugin)"\)', manager):
    failures.append('PluginManager.swift still downloads a former plugin package as an update')

for failure in failures:
    print('FAIL:', failure)
if failures:
    sys.exit(1)
print(f'PASS: {len(xibs)} Plugins Manager nibs of one structure show the installed plugins only, with the download status '
      'line in that tab; the controller has no catalog, and version 1 plugin updates download through -downloadPluginUpdate:')
