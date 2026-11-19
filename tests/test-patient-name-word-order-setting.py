#!/usr/bin/env python3
"""Settings › Locations has the check box that finds patient names in any word order.

The preference PatientNameAnyWordOrder (NetworkPreferences of IsiXPreferences,
on by default) lets the Query window and the browser's distant search ask a
node that found nothing again with «^» between the words of the name, in each
order, and the database's search match the words in any order. Its check box is
made in code under the DICOM nodes box of Settings › Locations, as the Q&R
download rows are, so that the localized nibs keep one structure; its title and
help come from the twelve catalogs.

Checked here:
- the pane installs it; PatientNameSearchSettings.swift, compiled with
  IsiXPreferences and a stand-in of the app's PreferencesSource, adds the
  check box under the lowest row of a DICOM nodes box, which grows by its
  height, shows the preference, on by default, and writes it when clicked;
- its title and help are in every catalog, translated;
- its title, measured with the font and size of the box's other check boxes,
  fits the width they have in every variant of the pane's nib, in every
  language (nothing clipped).

    python3 tests/test-patient-name-word-order-setting.py
"""
from pathlib import Path
import json
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import isix_modules  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ('ar', 'de', 'en', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans')
TITLE = 'Find patient names in any word order'
HELP = ('“Jan Kowalski” also finds KOWALSKI^JAN. A remote search that finds nothing asks again with the words of the '
        'name in each order; the database search matches them in any order.')
PANE = ROOT / 'Preference Panes/OSILocationsPreferencePane'
SETTINGS = PANE / 'PatientNameSearchSettings.swift'
failures = []

# --- The wiring ----------------------------------------------------------------
pane = (PANE / 'OSILocationsPreferencePanePref.swift').read_text(encoding='utf-8')
if 'PatientNameSearchSettings.install(below: characterSetPopup, in: mainView)' not in pane:
    failures.append('Settings › Locations does not install the check box')
settings = SETTINGS.read_text(encoding='utf-8') if SETTINGS.exists() else ''
for needed, why in (('NSLocalizedString("%s"' % TITLE, 'the title is not the catalogs\' key'),
                    ('NSLocalizedString("%s"' % HELP, 'the help is not the catalogs\' key'),
                    ('check.toolTip = Self.help', 'the check box has no help'),
                    ('preferences[NetworkPreferences.findsPatientNamesInAnyWordOrder]', 'the check box does not read the preference'),
                    ('preferences.set(check.state == .on, for: NetworkPreferences.findsPatientNamesInAnyWordOrder)',
                     'the check box does not write the preference')):
    if needed not in settings:
        failures.append(why)
project = (ROOT / 'Horos.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
if project.count('PatientNameSearchSettings.swift in Sources') != 2:
    failures.append('PatientNameSearchSettings.swift is not built into the application')
preferences = (ROOT / 'Modules/IsiXPreferences/Sources/NetworkPreferences.swift').read_text(encoding='utf-8')
if 'findsPatientNamesInAnyWordOrder = PreferenceKey<Bool>("PatientNameAnyWordOrder", registered: "1")' not in preferences:
    failures.append('the preference is not on by default')


# --- The check box, run ------------------------------------------------------------
STAND_IN = r'''
import Foundation
import IsiXPreferences
/// The app's source of the preferences, in memory, with the preference
/// registered as the application registers it.
struct PreferencesSource {
    let preferences: MemoryPreferences
    static let process = PreferencesSource(preferences: MemoryPreferences(registered: [
        NetworkPreferences.findsPatientNamesInAnyWordOrder.name: true]))
}
'''
DRIVER = r'''
import AppKit
import IsiXPreferences
let preferences = PreferencesSource.process.preferences
func emit(_ key: String, _ value: Any) { print("\(key)\t\(value)") }
MainActor.assumeIsolated {
    // A pane with the DICOM nodes box: the text encoding popup on its lowest row.
    let pane = NSView(frame: NSRect(x: 0, y: 0, width: 831, height: 400))
    let box = NSBox(frame: NSRect(x: 17, y: 60, width: 797, height: 334))
    pane.addSubview(box)
    let content = box.contentView!
    let popup = NSPopUpButton(frame: NSRect(x: 168, y: 10, width: 205, height: 22), pullsDown: false)
    content.addSubview(popup)
    let below = NSView(frame: NSRect(x: 17, y: 10, width: 100, height: 20))
    pane.addSubview(below)
    let settings = PatientNameSearchSettings.install(below: popup, in: pane)
    emit("installed", settings != nil)
    emit("again", PatientNameSearchSettings.install(below: popup, in: pane) == nil)
    emit("grown", pane.frame.height - 400)
    emit("box", box.frame.height - 334)
    emit("below-kept", below.frame.minY)
    emit("popup-raised", popup.frame.minY - 10)
    guard let check = settings?.check else { return }
    // In the row the popup left, below it.
    emit("check-in-row", check.frame.minY >= 10 && check.frame.maxY <= popup.frame.minY)
    emit("check-inside", check.frame.maxX <= content.frame.width && check.frame.minX >= 0)
    emit("title", check.title)
    emit("help", check.toolTip ?? "")
    emit("on-by-default", check.state == .on)
    check.performClick(nil)
    emit("written-off", preferences.object(forKey: NetworkPreferences.findsPatientNamesInAnyWordOrder.name) as? Bool == false)
    check.performClick(nil)
    emit("written-on", preferences.object(forKey: NetworkPreferences.findsPatientNamesInAnyWordOrder.name) as? Bool == true)
}
'''

run = {}
if settings:
    with tempfile.TemporaryDirectory(prefix='isix-name-order-run-') as folder:
        work = Path(folder)
        (work / 'standin.swift').write_text(STAND_IN)
        (work / 'main.swift').write_text(DRIVER)
        flags = isix_modules.module_flags('IsiXPreferences', work / 'modules', ['-target', 'arm64-apple-macos15.0'])
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos15.0', *flags,
                                str(SETTINGS), str(work / 'standin.swift'), str(work / 'main.swift'), '-o', str(work / 'run')],
                               capture_output=True, text=True)
        if built.returncode:
            failures.append('PatientNameSearchSettings.swift does not compile:\n' + built.stderr[-2500:])
        else:
            ran = subprocess.run([str(work / 'run')], capture_output=True, text=True, timeout=120)
            if ran.returncode:
                failures.append('the check box run failed: ' + ran.stderr[-800:])
            for line in ran.stdout.splitlines():
                key, _, value = line.partition('\t')
                run[key] = value
    wanted = {'installed': 'true', 'again': 'true', 'grown': '24.0', 'box': '24.0', 'below-kept': '10.0',
              'popup-raised': '24.0', 'check-in-row': 'true', 'check-inside': 'true', 'title': TITLE, 'help': HELP,
              'on-by-default': 'true', 'written-off': 'true', 'written-on': 'true'}
    for key, want in wanted.items():
        if not built.returncode and run.get(key) != want:
            failures.append(f'the check box: {key} is {run.get(key)!r}, expected {want!r}')

# --- The catalogs ----------------------------------------------------------------
def catalog(language):
    path = ROOT / 'Horos/Resources' / f'{language}.lproj/Localizable.strings'
    converted = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(path)], capture_output=True)
    if converted.returncode:
        failures.append(f'{language}: the catalog does not parse')
        return {}
    return json.loads(converted.stdout)


titles = {}
for language in LANGUAGES:
    entries = catalog(language)
    for key in (TITLE, HELP):
        value = entries.get(key)
        if not value:
            failures.append(f'{language}: no entry for {key[:40]}…')
        elif language != 'en' and value == key:
            failures.append(f'{language}: {key[:40]}… is not translated')
    if entries.get(TITLE):
        titles[language] = entries[TITLE]

# --- The room the box gives it ----------------------------------------------------
nibs = sorted(ROOT.glob('Horos/Resources/*.lproj/OSILocationsPreferencePanePref.xib')) + \
    sorted(PANE.glob('*.lproj/OSILocationsPreferencePanePref.xib'))
widths = {}
for nib in nibs:
    text = nib.read_text(encoding='utf-8')
    box = re.search(r'<box [^>]*id="112">\s*<rect key="frame"[^>]*/>.*?<view key="contentView"[^>]*>\s*'
                    r'<rect key="frame" x="[^"]*" y="[^"]*" width="([0-9.]+)"', text, re.S)
    if not box:
        failures.append(f'{nib.relative_to(ROOT)}: the DICOM nodes box is not found')
        continue
    widths[str(nib.relative_to(ROOT))] = float(box.group(1))
# The same room as the box's own check boxes: from x = 14 to 4 points before its edge.
room = min(widths.values()) - 14 - 4 if widths else 0

MEASURE = r'''
import AppKit
let titles = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: String]
var widths: [String: Double] = [:]
for (language, title) in titles {
    let check = NSButton(checkboxWithTitle: title, target: nil, action: nil)
    check.controlSize = .small
    check.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    check.sizeToFit()
    widths[language] = Double(check.frame.width)
}
print(String(data: try! JSONSerialization.data(withJSONObject: widths), encoding: .utf8)!)
'''

if titles and room:
    with tempfile.TemporaryDirectory(prefix='isix-name-order-') as folder:
        work = Path(folder)
        (work / 'titles.json').write_text(json.dumps(titles), encoding='utf-8')
        (work / 'main.swift').write_text(MEASURE)
        built = subprocess.run(['xcrun', 'swiftc', '-o', str(work / 'measure'), str(work / 'main.swift')], capture_output=True, text=True)
        if built.returncode:
            failures.append('the measure does not compile:\n' + built.stderr[-1500:])
        else:
            run = subprocess.run([str(work / 'measure'), str(work / 'titles.json')], capture_output=True, text=True, timeout=120)
            if run.returncode:
                failures.append('the measure failed: ' + run.stderr[-800:])
            else:
                measured = json.loads(run.stdout)
                for language in LANGUAGES:
                    width = measured.get(language)
                    if width is None:
                        continue
                    if width > room:
                        failures.append(f'{language}: the title needs {width:.0f} points, the box gives {room:.0f}')
                widest = max(measured, key=measured.get)
                print(f'widest title: {widest}, {measured[widest]:.0f} of {room:.0f} points, in {len(widths)} nibs')

if failures:
    print('FAIL')
    for failure in failures:
        print(' -', failure)
    sys.exit(1)
print('PASS: Settings › Locations finds patient names in any word order, its title fits in every language')
