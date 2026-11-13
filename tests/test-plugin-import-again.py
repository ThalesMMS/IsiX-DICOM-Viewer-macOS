#!/usr/bin/env python3
"""The plugin manager can look again in the plugins folders of Horos and OsiriX, and one name means one plugin by its version.

Installers of plugins made for Horos or OsiriX only know those applications'
folders. IsiX copied what it found there once, at its first launch, and never
looked again: a plugin installed or updated later never arrived. And a plugin
is known by the name of its bundle without the extension, so the old
`Thing.horosplugin` and the newer `Thing.osirixplugin` an installer leaves were
one plugin, of which the first one found stayed: by the alphabet of the
extensions in the copy, by the order of the folder in the loader.

The rules themselves are tested with their modules (`SameNamePluginsTests`,
`LegacyPluginImportTests`), and the loader and the copy with synthetic bundles in
`test-isolated-plugins.py`. Checked here:
- the Swift comparison of versions the choice uses answers what the update
  check's comparison answers, over a table of versions, and compares nothing
  that one calls invalid;
- the loader sets bundles aside by those rules before it loads any;
- the plugin manager has the command, wired to the import, in the build that
  loads plugins only;
- the three buttons of that row fit beside the Uninstall button in every
  language, measured by AppKit;
- the command's texts are translated in the eleven catalogs.
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'tests'))
from isix_modules import module_flags  # noqa: E402
failures = []
LANGUAGES = ('ar', 'de', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans')

manager = (root / 'Horos/Sources/PluginManager.swift').read_text(encoding='utf-8')
controller = (root / 'Horos/Sources/PluginManagerController.swift').read_text(encoding='utf-8')
prompt = (root / 'Horos/Sources/LegacySupportImportPrompt.swift').read_text(encoding='utf-8')

# --- the loader -----------------------------------------------------------------
discovery = manager[manager.index('@objc public class func discoverPlugins()'):]
discovery = discovery[:discovery.index('    /// The action of the "No plugins available for this menu" items')]
chosen = discovery.find('SameNamePlugins.setAside(among:')
loading = discovery.find('PluginManager.loadPlugin(atPath: plugin.path)')
if chosen < 0 or loading < 0 or chosen > loading:
    failures.append('discoverPlugins does not set aside the bundles of one name before it loads any')
if 'PluginBundleVersion.declared(byBundleAt:' not in discovery:
    failures.append('discoverPlugins does not read the versions the choice is made by')
if 'pathsOfPluginsToLoad.remove(duplicate.bundle.path)' not in discovery:
    failures.append('a bundle set aside is still handed to the loader, where the order of the folder decides')

# --- the command ------------------------------------------------------------------
store, direct = controller.split('#else', 1)
if 'importLegacyPlugins' in store or 'LegacySupportImportPrompt' in store:
    failures.append('the App Store build, which loads no plugin, has the import command')
if '#selector(importLegacyPlugins(_:))' not in direct or 'NSLocalizedString("Import Plugins from Horos or OsiriX…"' not in direct:
    failures.append('the plugin manager has no Import Plugins from Horos or OsiriX button')
if 'LegacySupportImportPrompt.importPluginsAgain(attachedTo: window' not in direct \
        or 'PluginManager.replaceInstalledPlugin(at: installed, with: source)' not in direct:
    failures.append('the button does not run the import, or a newer version does not go through the installer')
again = prompt[prompt.index('static var pluginRules'):prompt.index('private static func showPluginImportProblem')]
if not (prompt.rindex('#if !MACAPPSTORE', 0, prompt.index('static var pluginRules')) > prompt.index('offerPluginsIfNeeded')
        and again.rstrip().endswith('#endif')):
    failures.append('the import command is compiled into the App Store build')
for rule in ('PluginAdmission.isPluginBundle', 'PluginBundleVersion.declared(byBundleAt:)', 'PluginBundleVersion.compare',
             'SameNamePlugins.isPreferred('):
    if rule not in again:
        failures.append(f'the copy does not follow the loader\'s rule {rule}')
if 'offerIfNeeded(rules: pluginRules)' not in prompt:
    failures.append('the single offer of the first launch does not follow the same rules')
if 'beginSheetModal(for: window)' not in again or 'runModal()' in again:
    failures.append('the import command does not report in sheets of the plugin manager\'s window')

# --- the catalogs -------------------------------------------------------------------
keys = sorted(set(json.loads('"' + found + '"') for found in re.findall(r'NSLocalizedString\("((?:\\.|[^"\\])*)"', again)))
new = [key for key in keys if key not in ('OK', 'Import', 'Cancel', '%@: %@', 'Some plugins were not copied')]
if len(new) < 10:
    failures.append(f'expected the texts of the import command, found {new}')
catalogs = {}
for language in LANGUAGES + ('en',):
    catalog = root / f'Horos/Resources/{language}.lproj/Localizable.strings'
    catalogs[language] = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(catalog)]))
for language in LANGUAGES:
    for key in new:
        value = catalogs[language].get(key)
        if not value:
            failures.append(f'{language} has no translation of {key!r}')
        elif value == key:
            failures.append(f'{language} shows {key!r} in English')
        elif sorted(re.findall(r'%(?:\d\$)?@', value)) != sorted(re.findall(r'%(?:\d\$)?@', key)):
            failures.append(f'{language}: {key!r} lost or gained an argument: {value!r}')

# --- compiled: the comparison, and the row of buttons ----------------------------------
xib = (root / 'Horos/Resources/en.lproj/PluginManager.xib').read_text(encoding='utf-8')
uninstall = re.search(r'<button [^>]*id="dNG-hG-PSZ">\s*<rect key="frame" x="(\d+)"', xib)
inset = re.search(r'static let protectedModeNoticeInset: CGFloat = (\d+)', controller)
if not uninstall or not inset:
    failures.append('the Uninstall button or the row\'s left inset is not where this test reads them')
    available = 0
else:
    # From the list's left edge to the Uninstall button, less the gap before it.
    available = int(uninstall.group(1)) - 8 - int(inset.group(1))

header = '#import <Foundation/Foundation.h>\n#import "HorosPluginCatalog.h"\n' \
         'static inline NSInteger FormerCompare(id a, id b) { return HorosComparePluginVersions(a, b); }\n' \
         'static inline BOOL FormerValid(id a) { return HorosPluginVersionIsValid(a); }\n'
driver = r'''import AppKit
import IsiXPluginLoading

var failed = 0
let versions: [String?] = [nil, "", "0", "1", "1.0", "1.0.0", "01.2", "1.2", "1.10", "1.9", "2", "2.0", "3.0", "3.3", "10", "1.0rc1", "1.0-rc.1",
                           "1.0-beta", "1.0b2", "1.0b10", "1.0+build7", "2026111201", "three", "1.0 (final)", "v2", "1..2", "1.2."]
for a in versions {
    for b in versions {
        let swift = PluginBundleVersion.compare(a, b)
        let bothValid = FormerValid(a) && FormerValid(b)
        if (swift != nil) != bothValid {
            print("FAIL: \(a ?? "nil") and \(b ?? "nil"): compared \(swift != nil), the update check holds them valid \(bothValid)"); failed += 1
        } else if let swift, swift.rawValue != FormerCompare(a, b) {
            print("FAIL: \(a ?? "nil") against \(b ?? "nil") is \(swift.rawValue), the update check says \(FormerCompare(a, b))"); failed += 1
        }
    }
}

let root = CommandLine.arguments[1], available = CGFloat(Double(CommandLine.arguments[2])!)
let keys = ["Import Plugins from Horos or OsiriX…", "Install Plugin...", "Loading Details..."]
for language in CommandLine.arguments.dropFirst(3) {
    let catalog = NSDictionary(contentsOfFile: "\(root)/Horos/Resources/\(language).lproj/Localizable.strings") as? [String: String] ?? [:]
    // The stack's spacing between the last two, and the gap the first keeps from them.
    let width = keys.map { NSButton(title: catalog[$0] ?? $0, target: nil, action: nil).intrinsicContentSize.width }.reduce(0, +) + 16
    if width > available {
        print("FAIL: \(language): the row's buttons take \(Int(width.rounded(.up))) points of \(Int(available))"); failed += 1
    }
}
if failed > 0 { exit(1) }
print("PASS: versions compare as the update check compares them, and the row of buttons fits in every language")
'''
with tempfile.TemporaryDirectory(prefix='horos-plugin-import-again-') as directory:
    work = Path(directory)
    (work / 'bridge.h').write_text(header)
    (work / 'main.swift').write_text(driver)
    built = subprocess.run(['xcrun', 'swiftc', '-module-name', 'ImportAgain', '-import-objc-header', str(work / 'bridge.h'),
                            '-Xcc', '-I' + str(root / 'Horos/Sources'), str(work / 'main.swift'),
                            *module_flags('IsiXPluginLoading', work / 'modules'), '-o', str(work / 'probe')],
                           capture_output=True, text=True, cwd=directory)
    if built.returncode != 0:
        print(built.stderr[-3000:])
        failures.append('the comparison and layout probe did not compile')
    else:
        ran = subprocess.run([str(work / 'probe'), str(root), str(available), 'en', *LANGUAGES], capture_output=True, text=True, timeout=120)
        sys.stdout.write(ran.stdout)
        sys.stderr.write(ran.stderr)
        if ran.returncode != 0:
            failures.append('the comparison or the layout failed')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('ok: one name is one plugin by its version in the loader and in the copy, and the plugin manager can ask for the copy again')
