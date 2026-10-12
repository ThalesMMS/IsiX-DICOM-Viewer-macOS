#!/usr/bin/env python3
"""Every length measurement is written by one formatter, in the unit and with the
decimal places chosen in the Viewer preferences.

LengthPresentation.swift is compiled as it is and asked:
- the three units: Automatic (µm below 0.01 cm, mm below 1 cm, cm from 1 cm),
  mm and cm, with 0 to 3 decimal places and values outside clamped;
- the limits of 0.01 cm and 1 cm, and rounding that does not move the unit;
- µm keep at most one decimal, and an ASCII-only renderer gets mm instead;
- a length in pixels, on an image without calibration;
- the preferences, read from the argument domain: none set is Automatic with
  three places, today's text.

The wiring is read from the sources: the 2D Length (by drag, in ultrasound
regions, in pixels), polygon and curve lengths, the 3D length of an open
polygon, the Length between images and the Volume Rendering Length all go
through it; the keys are registered; a change redraws the viewers and rewrites
the stored VR lines; the Viewer pane binds both keys once in each of its ten
nibs, inside the ROI labels box and clear of its other controls; the new text
is in the eleven catalogs.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
LANGUAGES = ('ar', 'de', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans')
failures = []


def source(path):
    return (root / path).read_bytes().decode('latin1')


roi = source('Horos/Sources/ROI.m')
for old in ('Length: %0.3f cm', 'Length: %0.3f mm', 'Length: %0.1f %cm', 'Length: %0.3f pix',
            '3D Length: %0.3f', 'Length 3D: %.3f mm', '%0.2f mm', '%0.2f cm'):
    if f'@"{old}"' in roi:
        failures.append(f'ROI.m still writes a length itself: {old}')
for needle, count in (('NSLocalizedString( @"Length: %@", nil), [HorosLengthPresentation stringWithCentimetres:', 5),
                      ('NSLocalizedString( @"Length: %@", nil), [HorosLengthPresentation stringWithPixels:', 2),
                      ('NSLocalizedString( @"3D Length: %@", nil), [HorosLengthPresentation stringWithMillimetres: distance3d]', 1),
                      ('NSLocalizedString(@"Length 3D: %@", nil), [HorosLengthPresentation stringWithMillimetres: self.distanceMM]', 1),
                      ('return [HorosLengthPresentation stringWithCentimetres: lCm];', 1)):
    if roi.count(needle) != count:
        failures.append(f'ROI.m: expected {count} × {needle}, found {roi.count(needle)}')
if '@"Length3DMM":@(self.distanceMM)' not in roi:
    failures.append('the exported Length3DMM must stay in millimetres')

vr = source('Horos/Sources/VRView.mm')
for needle in ('[HorosLengthPresentation asciiStringWithCentimetres: centimetres]',
               'localizedText = HorosVRLengthText( length/(10.*factor));',
               'NSLocalizedString( @"   Measurement: %@ ", nil), [HorosLengthPresentation stringWithCentimetres: measureLength]',
               'name: HorosLengthPresentation.changedNotification',
               'entry->text->SetInput([HorosVRLengthText(centimetres) UTF8String]);'):
    if needle not in vr:
        failures.append(f'VRView.mm lost: {needle}')
if '%2.2f mm' in vr or '%2.2f cm' in vr:
    failures.append('VRView.mm still writes a length itself')

defaults = source('Horos/Sources/DefaultsOsiriX.m')
for needle in ('setObject:@"0" forKey:@"ROILengthUnit"', 'setObject:@"3" forKey:@"ROILengthDecimals"'):
    if needle not in defaults:
        failures.append(f'not registered: {needle}')
app = source('Horos/Sources/AppController.swift')
check = app[app.index('runPreferencesUpdateCheck'):]
if 'LengthPresentation.unitKey' not in check or 'LengthPresentation.decimalsKey' not in check \
        or 'Notification.Name(LengthPresentation.changedNotification)' not in check:
    failures.append('a change of the preferences does not redraw the measurements')
if '"Length: " + LengthPresentation.string(centimetres: centimeters)' not in source('Horos/Sources/AnnotationPresentation.swift'):
    failures.append('AnnotationPresentation writes the length itself')


def catalog(language):
    data = (root / 'Horos/Resources' / f'{language}.lproj/Localizable.strings').read_bytes()
    return data.decode('utf-16') if data[:2] in (b'\xff\xfe', b'\xfe\xff') else data.decode('utf-8')


KEYS = ('Length: %@', '3D Length: %@', 'Length 3D: %@', 'Length: %@ ', '   Measurement: %@ ',
        'Length unit:', 'Automatic', 'Decimal places:', 'mm')
for language in LANGUAGES:
    text = catalog(language)
    for key in KEYS:
        found = re.findall(r'^"' + re.escape(key) + r'" = "(.*)";$', text, re.M)
        if len(found) != 1:
            failures.append(f'{language}: "{key}" is in the catalog {len(found)} times')
        elif '%@' in key and found[0].count('%@') != 1:
            failures.append(f'{language}: "{key}" lost its argument')
    if re.search(r'^"Length: %0\.3f cm" = ', text, re.M):
        failures.append(f'{language}: the catalog keeps the former length texts')

folders = [root / 'Preference Panes/OSIViewerPreferencePane' / f'{language}.lproj' for language in ('Base', 'ja-JP')]
folders += [root / 'Horos/Resources' / f'{language}.lproj' for language in ('ar', 'de', 'fr', 'hi', 'ko', 'pt-BR', 'ru', 'zh-Hans')]


def frame(node):
    r = node.find('rect[@key="frame"]')
    return tuple(float(r.get(k)) for k in ('x', 'y', 'width', 'height'))


MINE = ('roi-length-unit-label', 'roi-length-unit-popup', 'roi-length-decimals-label',
        'roi-length-decimals-field', 'roi-length-decimals-stepper')
for folder in folders:
    tree = ET.parse(folder / 'OSIViewerPreferencePanePref.xib')
    group = tree.find('.//box[@id="roi-labels-box"]')
    for key, count in (('ROILengthUnit', 1), ('ROILengthDecimals', 2)):
        everywhere = tree.findall(f'.//binding[@keyPath="values.{key}"]')
        inside = group.findall(f'.//binding[@keyPath="values.{key}"]')
        if not len(everywhere) == len(inside) == count:
            failures.append(f'{folder.name}: {key} bound {len(everywhere)} times, {len(inside)} in the ROI labels box')
    popup = group.find('.//popUpButton[@id="roi-length-unit-popup"]')
    tags = [int(item.get('tag', '0')) for item in popup.iter('menuItem')] if popup is not None else []
    if tags != [0, 1, 2] or not popup.get('toolTip'):
        failures.append(f'{folder.name}: the unit menu must offer Automatic, mm and cm, with an explanation')
    content = group.find('view')
    width, height = (float(content.find('rect').get(k)) for k in ('width', 'height'))
    subviews = content.find('subviews')
    for name in MINE:
        node = subviews.find(f'*[@id="{name}"]')
        if node is None:
            failures.append(f'{folder.name}: {name} is missing')
            continue
        x, y, w, h = frame(node)
        if x < 0 or y < 0 or x + w > width or y + h > height:
            failures.append(f'{folder.name}: {name} leaves the box')
        for other in subviews:
            if other is node:
                continue
            ox, oy, ow, oh = frame(other)
            if x < ox + ow and ox < x + w and y < oy + oh and oy < y + h:
                failures.append(f'{folder.name}: {name} overlaps {other.get("id")}')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)

if shutil.which('xcrun') is None:
    print('skipped: needs xcrun (swiftc)', file=sys.stderr)
    sys.exit(SKIPPED)

DRIVER = r'''
import Foundation

var failed = false
func check(_ got: String, _ expected: String, _ what: String) {
    if got != expected {
        FileHandle.standardError.write("FAIL: \(what): got «\(got)», expected «\(expected)»\n".data(using: .utf8)!)
        failed = true
    }
}
typealias L = LengthPresentation
func f(_ mm: Double, _ unit: LengthUnit, _ places: Int, micrometres: Bool = true) -> String {
    L.format(millimetres: mm, unit: unit, decimals: places, micrometres: micrometres)
}

// The same 2 cm in each unit, with each number of places.
check(f(20, .automatic, 3), "2.000 cm", "2 cm, Automatic")
check(f(20, .millimetres, 3), "20.000 mm", "2 cm in mm")
check(f(20, .centimetres, 3), "2.000 cm", "2 cm in cm")
check(f(20, .millimetres, 1), "20.0 mm", "mm with one place")
check(f(20, .centimetres, 0), "2 cm", "cm with no place")
check(f(23.456, .automatic, 0), "2 cm", "no place")
check(f(23.456, .automatic, 1), "2.3 cm", "one place")
check(f(23.456, .automatic, 2), "2.35 cm", "two places")
check(f(23.456, .automatic, 3), "2.346 cm", "three places")
check(f(23.456, .automatic, 7), "2.346 cm", "more than three places")
check(f(23.456, .automatic, -2), "2 cm", "fewer than none")

// The limits of Automatic: 0.01 cm and 1 cm.
check(f(10, .automatic, 3), "1.000 cm", "1 cm")
check(f(9.99, .automatic, 3), "9.990 mm", "just below 1 cm")
check(f(0.1, .automatic, 3), "0.100 mm", "0.01 cm")
check(f(0.0999, .automatic, 3), "99.9 \u{00B5}m", "just below 0.01 cm")
check(f(0.05, .automatic, 0), "50 \u{00B5}m", "µm with no place")
check(f(0.05, .automatic, 2), "50.0 \u{00B5}m", "µm keep one place")
check(f(0.05, .automatic, 3, micrometres: false), "0.050 mm", "no µm for an ASCII renderer")
check(f(0.05, .millimetres, 3), "0.050 mm", "below 0.01 cm in mm")
check(f(0.05, .centimetres, 3), "0.005 cm", "below 0.01 cm in cm")

// Rounding: the unit follows the length, not its rounded text.
check(f(9.9996, .automatic, 3), "10.000 mm", "rounding just below 1 cm")
check(f(9.96, .automatic, 1), "10.0 mm", "rounding to one place below 1 cm")
check(f(14.95, .automatic, 0), "1 cm", "rounding with no place")
check(f(15.05, .centimetres, 1), "1.5 cm", "half a step")

// Pixels, on an image without calibration.
check(L.format(pixels: 123.4567, decimals: 3), "123.457 pix", "pixels")
check(L.format(pixels: 123.4567, decimals: 0), "123 pix", "pixels with no place")
check(L.format(pixels: 123.4567, decimals: 9), "123.457 pix", "pixels with too many places")

// The preferences, from the argument domain so nothing is stored.
let defaults = UserDefaults.standard
func preferences(_ values: [String: Any]) {
    defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
}
preferences([:])
check(L.string(centimetres: 2), "2.000 cm", "no preference")
check(L.string(millimetres: 5), "5.000 mm", "no preference below 1 cm")
check(L.string(pixels: 1.5), "1.500 pix", "no preference, pixels")
preferences([L.unitKey: 1, L.decimalsKey: 1])
check(L.string(centimetres: 2), "20.0 mm", "mm with one place")
check(L.string(millimetres: 20), "20.0 mm", "mm with one place, from millimetres")
check(L.asciiString(centimetres: 2), "20.0 mm", "mm with one place, ASCII")
check(L.string(pixels: 1.55), "1.6 pix", "pixels with one place")
preferences([L.unitKey: 2, L.decimalsKey: 0])
check(L.string(millimetres: 4), "0 cm", "cm with no place")
preferences([L.unitKey: 9, L.decimalsKey: 12])
check(L.string(centimetres: 2), "2.000 cm", "values out of range")
preferences([:])

if failed { exit(1) }
print("PASS: three units, 0 to 3 places, the limits of Automatic, rounding, pixels and the preferences")
'''

with tempfile.TemporaryDirectory(prefix='horos-length-presentation-') as folder:
    main = Path(folder) / 'main.swift'
    main.write_text(DRIVER)
    binary = Path(folder) / 'check'
    built = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(Path(folder) / 'modules'),
                            str(root / 'Horos/Sources/LengthPresentation.swift'), str(main), '-o', str(binary)],
                           capture_output=True, text=True)
    if built.returncode:
        print(built.stderr, file=sys.stderr)
        sys.exit(1)
    ran = subprocess.run([str(binary)], capture_output=True, text=True)
    sys.stderr.write(ran.stderr)
    if ran.returncode:
        sys.exit(1)
    print(ran.stdout.strip())
print(f'PASS: every length goes through the formatter, the keys are registered and bound in {len(folders)} nibs')
