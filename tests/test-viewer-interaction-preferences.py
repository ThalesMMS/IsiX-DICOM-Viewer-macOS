#!/usr/bin/env python3
"""The interaction controls of the Viewers pane: their preferences, bindings and texts.

The controls live in the pane's nib, in titled groups, once in each of its ten
copies: the first click on an inactive viewer, the Length by two clicks, the
precise mouse with its
movement pop-up, the MPR plane angles, the exponential slab slider and the
"Previous" mark. Each is bound to its preference, which
is registered with the value the app starts with, and every text is in the
twelve catalogs.

The movement pop-up is bound to a property of the pane, compiled here: its
items are tagged 25, 50 and 75 while the preference keeps the factor.

Italian and Spanish have no copy of the nib: the pane reads the texts of its
window from the catalog when it loads, and they must fit the frames of the
Base nib, which is measured here with those two catalogs applied.
"""
from pathlib import Path
import importlib.util
import plistlib
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import default_preferences  # noqa: E402
import pane_titles  # noqa: E402

PANE = ROOT / 'Preference Panes/OSIViewerPreferencePane/OSIViewerPreferencePanePref.swift'
NAME = 'OSIViewerPreferencePanePref.xib'
source = PANE.read_text()
failures = []

defaults = default_preferences.registered()
for key, value in {'FirstClickOnlyActivatesViewer': True, 'TwoClickLengthMeasurement': True, 'RememberMPRPlaneAngles': False, 'PreciseMouseForMeasuringAndZoom': False,
                   'PreciseMouseFactor': 0.5,
                   'LogarithmicThickSlabSlider': False}.items():
    if type(defaults.get(key)) is not type(value) or defaults[key] != value:
        failures.append(f'{key} is not registered as {value!r}')

GROUPS = ['Mouse and interaction', 'Series and windows', 'Image display', 'MPR and thick slab']
keys = ['First click on an inactive viewer only activates it', 'Measure Length with two clicks', 'Remember MPR plane angles', 'Precise mouse for measuring and zoom', 'Mouse movement:',
        'Exponential thick slab slider', 'Show "Previous" on older studies', 'Series %@', 'Window %ld'] + GROUPS
catalogs = {}
for path in sorted((ROOT / 'Horos/Resources').glob('*.lproj/Localizable.strings')):
    data = plistlib.loads(subprocess.check_output(['plutil', '-convert', 'binary1', '-o', '-', str(path)]))
    for key in keys:
        if not data.get(key):
            failures.append(f'{path.parent.name}: missing {key}')
        elif re.findall(r'%[@a-z]+', data[key]) != re.findall(r'%[@a-z]+', key):
            failures.append(f'{path.parent.name}: the format of {key} changed')
    catalogs[path.parent.stem] = data
if len(catalogs) != 12:
    failures.append(f'{len(catalogs)} catalogs')

# (binding name, destination, key path) -> how many controls of the pane's own window carry it.
BINDINGS = {
    ('value', '308', 'values.FirstClickOnlyActivatesViewer'): 1,
    ('value', '308', 'values.TwoClickLengthMeasurement'): 1,
    ('value', '308', 'values.RememberMPRPlaneAngles'): 1,
    ('value', '308', 'values.PreciseMouseForMeasuringAndZoom'): 1,
    ('enabled', '308', 'values.PreciseMouseForMeasuringAndZoom'): 1,
    ('selectedTag', '-2', 'preciseMouseFactorTag'): 1,
    ('value', '308', 'values.LogarithmicThickSlabSlider'): 1,
    ('value', '308', 'values.ShowPreviousExamLabel'): 1,
}
variants = pane_titles.variants(NAME)
if len(variants) != 10:
    failures.append(f'{len(variants)} copies of the Viewers pane')
main_ids = set()
for language, path in variants.items():
    window = ET.parse(path).getroot().find('.//window[@id="12"]')
    found = {}
    for binding in window.iter('binding'):
        key = (binding.get('name'), binding.get('destination'), binding.get('keyPath'))
        found[key] = found.get(key, 0) + 1
    for key, count in BINDINGS.items():
        if found.get(key, 0) != count:
            failures.append(f'{language}: {found.get(key, 0)} bindings of {key[2]} ({key[0]})')
    boxes = window.findall('./view/subviews/box')
    if [box.get('title') for box in boxes] != [catalogs.get('en' if language == 'Base' else language, {}).get(title, title) for title in GROUPS]:
        failures.append(f'{language}: the groups are {[box.get("title") for box in boxes]}')
    if len(window.findall('./view/subviews/*')) != len(boxes):
        failures.append(f'{language}: a control of the pane is outside the groups')
    factor = next((popup for popup in window.iter('popUpButton')
                   if popup.find('.//binding[@keyPath="preciseMouseFactorTag"]') is not None), None)
    if factor is None or sorted(int(item.get('tag', '0')) for item in factor.iter('menuItem')) != [25, 50, 75]:
        failures.append(f'{language}: the movement pop-up does not offer 25, 50 and 75')
    if window.find('.//binding[@keyPath="values.SeriesListIdentificationMode"]') is not None:
        failures.append(f'{language}: the pane still offers the modes of series identification, which are gone')
    if language == 'Base':
        main_ids = {element.get('id') for element in window.iter() if element.get('id')}

for gone in ['addViewerInteractionControls', 'addPreviousExamCheck', 'ViewerMouseFactorTransformer']:
    if gone in source:
        failures.append(f'the pane still builds controls in code ({gone})')
if 'if type(of: self) == OSIViewerPreferencePanePref.self { translateFromCatalogIfNeeded() }' not in source:
    failures.append('the pane does not read its texts from the catalog where the nib has no copy')

# The property behind the movement pop-up.
start = source.index('    @objc dynamic var preciseMouseFactorTag: Int {')
factor_property = source[start:source.index('\n    }\n', start) + 7]
driver = '''
import Foundation
final class Pane: NSObject {
%s
}
var failures = 0
func check(_ condition: Bool, _ message: String) { if !condition { print("FAIL: " + message); failures += 1 } }
UserDefaults.standard.removeObject(forKey: "PreciseMouseFactor")
let pane = Pane()
check(pane.preciseMouseFactorTag == 50, "nothing stored: 50%%")
for percentage in [25, 50, 75] {
    UserDefaults.standard.set(Double(percentage) / 100, forKey: "PreciseMouseFactor")
    check(pane.preciseMouseFactorTag == percentage, "the factor selects its item")
    pane.preciseMouseFactorTag = percentage
    check(UserDefaults.standard.double(forKey: "PreciseMouseFactor") == Double(percentage) / 100, "an item stores its factor")
}
UserDefaults.standard.set(0.9, forKey: "PreciseMouseFactor")
check(pane.preciseMouseFactorTag == 50, "another factor shows 50%%")
pane.preciseMouseFactorTag = 40
check(UserDefaults.standard.double(forKey: "PreciseMouseFactor") == 0.5, "another tag stores 0.5")
UserDefaults.standard.removeObject(forKey: "PreciseMouseFactor")
exit(failures == 0 ? 0 : 1)
''' % factor_property
with tempfile.TemporaryDirectory(prefix='viewer-interaction-preferences-') as directory:
    folder = Path(directory)
    (folder / 'main.swift').write_text(driver)
    executable = folder / 'precise-mouse-factor-test'
    subprocess.run(['xcrun', 'swiftc', '-suppress-warnings', '-module-cache-path', str(folder / 'modules'),
                    str(folder / 'main.swift'), '-o', str(executable)], check=True)
    ran = subprocess.run([str(executable)], capture_output=True, text=True)
    subprocess.run(['defaults', 'delete', 'precise-mouse-factor-test'], capture_output=True)
    if ran.returncode:
        failures.append('the movement pop-up property: ' + ran.stdout.strip())

    # Italian and Spanish: the Base nib with the catalog's texts must fit.
    spec = importlib.util.spec_from_file_location('localize_pane', ROOT / 'tools/localize-preference-pane.py')
    localize_pane = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(localize_pane)
    base_lines = variants['Base'].read_text(encoding='utf-8').split('\n')
    generated = {}
    for language in ['it-IT', 'es']:
        path = folder / f'{language}.xib'
        path.write_text('\n'.join(localize_pane.localized(base_lines, {}, catalogs[language])), encoding='utf-8')
        generated[language] = path
    if pane_titles.available():
        measured = [item for item in pane_titles.measure(generated)
                    if (set(item['overlap']) <= main_ids if 'overlap' in item else item.get('id', '').split('/')[0] in main_ids)]
        failures += pane_titles.misfits(measured)
        if {item['language'] for item in measured} != set(generated):
            failures.append('Italian and Spanish were not both measured')

if failures:
    for failure in failures:
        print('FAIL: ' + failure)
    sys.exit(1)
print('PASS: ten nib copies, twelve catalogs, bindings, the movement pop-up, and Italian and Spanish texts that fit')
