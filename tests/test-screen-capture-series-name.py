#!/usr/bin/env python3
"""The series of "Save as DICOM SC and mark as Key Image" has a name that can be set.

ScreenCaptureSeriesName.swift is compiled as it is and asked what the
application asks it:
- a name is written in ASCII: accents are removed ("Reconstruções" gives
  "Reconstrucoes"), another script, a backslash and control characters are
  dropped, the ends are trimmed and the name is cut at the 64 characters of a
  DICOM Long String;
- the preference names the series, and one that is not set, or that leaves
  nothing to write, gives the default name;
- the default name is the catalog's, in ASCII too: each of the eleven catalogs
  is read here, and a translation in another script gives the English name.

The wiring is read from the sources: the capture names its series and looks for
the series of an earlier capture with the same name, read once; a DICOMExport
nobody named writes "IsiX SC"; the names the database reads back to recognise
its own series are not renamed; and the Viewer pane binds the preference once
in each of its ten nibs, inside its box and clear of the other controls, and
stores what was typed as it will be written.
"""
import private_tmpdir  # noqa: F401  - its own TMPDIR for the tools it runs
from pathlib import Path
import json
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

SKIPPED = 2
root = Path(__file__).resolve().parents[1]
KEY = 'screenCaptureKeyImageSeriesName'
ENGLISH = 'IsiX Screen Captures'
LANGUAGES = ('ar', 'de', 'es', 'fr', 'hi', 'it-IT', 'ja-JP', 'ko', 'pt-BR', 'ru', 'zh-Hans')
# What each language's default name becomes; the others give the English one.
LATIN = {'fr': "Captures d'ecran IsiX", 'pt-BR': 'Capturas de tela do IsiX'}

failures = []


def source(path):
    return (root / path).read_bytes().decode('latin1')


def catalog(language):
    data = (root / 'Horos/Resources' / f'{language}.lproj/Localizable.strings').read_bytes()
    return data.decode('utf-16') if data[:2] in (b'\xff\xfe', b'\xfe\xff') else data.decode('utf-8')


defaults = {}
for language in LANGUAGES:
    text = catalog(language)
    found = re.findall(r'^"' + re.escape(ENGLISH) + r'" = "(.*)";$', text, re.M)
    if len(found) != 1:
        failures.append(f'{language}: the catalog names the default series {len(found)} times')
        continue
    defaults[language] = found[0]
    if re.search(r'^"OsiriX Screen Captures" = ', text, re.M):
        failures.append(f'{language}: the catalog still has the former default name')

# The capture is Swift (ViewerController+KeyImageCapture.swift).
capture = source('Horos/Sources/ViewerController+KeyImageCapture.swift')
capture = capture[capture.index('func captureAndSetKeyImage('):]
if capture.count('ScreenCaptureSeriesName.current()') != 1:
    failures.append('the capture must read the name of its series once')
if 'exportDICOMFileInt(1, withName: seriesName, allViewers: false)' not in capture:
    failures.append('the capture is not exported under the name in use')
if '(iseries.name as NSString?)?.isEqual(to: seriesName)' not in capture:
    failures.append('the series of an earlier capture is not looked for by the name in use')
if 'O2ScreenCapturesSeriesName' in capture:
    failures.append('the capture still uses the fixed name')

# DICOMExport is Swift.
export = source('Horos/Sources/DICOMExport.swift')
if 'horos_seriesDescription = "IsiX SC"' not in export or 'OsiriX SC' in export:
    failures.append('a DICOMExport nobody named must write "IsiX SC"')
# DicomDatabase is Swift: the import reads the names back in
# DicomDatabase+Import.swift, and the exported constant is set at load in
# DicomDatabase+CAPI.m.
database = source('Horos/Sources/DicomDatabase+Import.swift')
capi = source('Horos/Sources/DicomDatabase+CAPI.m')
for name in ('OsiriX Annotations SR', 'OsiriX ROI SR', 'OsiriX Report SR', 'OsiriX WindowsState SR'):
    if f'isEqualString(curDict?.value(forKey: "seriesDescription"), "{name}")' not in database:
        failures.append(f'{name} is a name the database reads back: it must stay')
if 'O2ScreenCapturesSeriesName = [[HorosScreenCaptureSeriesName defaultName] copy];' not in capi:
    failures.append('the exported constant must be the default name')

pane = source('Preference Panes/OSIViewerPreferencePane/OSIViewerPreferencePanePref.swift')
for needle in ('captureSeriesNameField?.placeholderString = ScreenCaptureSeriesName.defaultName()',
               '@IBAction func captureSeriesNameChanged(_ sender: Any?)',
               'ScreenCaptureSeriesName.normalizePreference()'):
    if needle not in pane:
        failures.append(f'the Viewer pane lost: {needle}')

folders = [root / 'Preference Panes/OSIViewerPreferencePane' / f'{language}.lproj' for language in ('Base', 'ja-JP')]
folders += [root / 'Horos/Resources' / f'{language}.lproj' for language in ('ar', 'de', 'fr', 'hi', 'ko', 'pt-BR', 'ru', 'zh-Hans')]


def frame(node):
    r = node.find('rect[@key="frame"]')
    return tuple(float(r.get(k)) for k in ('x', 'y', 'width', 'height'))


for folder in folders:
    tree = ET.parse(folder / 'OSIViewerPreferencePanePref.xib')
    bindings = tree.findall(f'.//binding[@keyPath="values.{KEY}"]')
    field = tree.find('.//textField[@id="capture-series-field"]')
    label = tree.find('.//textField[@id="capture-series-label"]')
    if len(bindings) != 1 or field is None or label is None or field.find('.//binding') is not bindings[0]:
        failures.append(f'{folder.name}: the field of the series name is not bound once')
        continue
    if tree.find('.//outlet[@property="captureSeriesNameField"][@destination="capture-series-field"]') is None:
        failures.append(f'{folder.name}: the pane cannot reach the field')
    if field.find('connections/action[@selector="captureSeriesNameChanged:"][@target="-2"]') is None:
        failures.append(f'{folder.name}: the field does not tell the pane that its name changed')
    if not field.get('toolTip') or not label.find('textFieldCell').get('title'):
        failures.append(f'{folder.name}: the field has no label or no explanation')
    box = next(view for view in tree.iter('view') if field in view.findall('subviews/textField'))
    width, height = (float(box.find('rect').get(k)) for k in ('width', 'height'))
    mine = {'capture-series-field': frame(field), 'capture-series-label': frame(label)}
    for name, (x, y, w, h) in mine.items():
        if x < 0 or y < 0 or x + w > width or y + h > height:
            failures.append(f'{folder.name}: {name} leaves its box')
        for other in box.find('subviews'):
            if other.get('id') in mine:
                continue
            ox, oy, ow, oh = frame(other)
            if x < ox + ow and ox < x + w and y < oy + oh and oy < y + h:
                failures.append(f'{folder.name}: {name} overlaps {other.get("id")}')
    lx, ly, lw, lh = mine['capture-series-label']
    if lx + lw > mine['capture-series-field'][0]:
        failures.append(f'{folder.name}: the label runs under the field')

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
typealias Name = ScreenCaptureSeriesName

// Names as they are written.
check(Name.sanitized("Imagens-chave"), "Imagens-chave", "a plain name")
check(Name.sanitized("Reconstruções"), "Reconstrucoes", "accents")
check(Name.sanitized("  Imagens  chave \n"), "Imagens  chave", "spaces at the ends")
check(Name.sanitized("Clés\tde\nl’étude"), "Cles de l'etude", "tab, line break and a typographic apostrophe")
check(Name.sanitized("Straße – Ærø"), "Strasse - AEro", "ligatures and a dash")
check(Name.sanitized("A\\B"), "AB", "the separator of DICOM values")
check(Name.sanitized("Key\u{0007}\u{007F} Images"), "Key Images", "control characters")
check(Name.sanitized("キー画像 Key 画像"), "Key", "another script around a Latin word")
check(Name.sanitized("キー画像"), "", "another script alone")
check(Name.sanitized("   "), "", "spaces alone")
check(Name.sanitized(""), "", "nothing")
check(Name.sanitized(nil), "", "no value")
check(Name.sanitized(String(repeating: "a", count: 80)), String(repeating: "a", count: 64), "more than a Long String holds")
check(Name.sanitized(String(repeating: "a", count: 63) + " bcd"), String(repeating: "a", count: 63), "a cut that ends on a space")
check(Name.sanitized(String(repeating: "é", count: 70)), String(repeating: "e", count: 64), "accents and the limit")
for text in ["Reconstruções", "Straße – Ærø", "A\\B", "  x  ", String(repeating: "ç", count: 99)] {
    let once = Name.sanitized(text)
    check(Name.sanitized(once), once, "a written name read again")
    if once.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value > 0x7E || $0 == "\\" }) || once.count > 64 {
        check("not a Long String in ASCII", once, "what «\(text)» gives")
    }
}

// The default name of every catalog.
check(Name.englishName, "IsiX Screen Captures", "the English name")
check(Name.defaultName(), "IsiX Screen Captures", "the default name without a catalog")
let catalogs = try! JSONSerialization.jsonObject(with: Data(CommandLine.arguments[1].utf8)) as! [String: [String]]
for (language, pair) in catalogs.sorted(by: { $0.key < $1.key }) {
    check(Name.defaultName(localized: pair[0]), pair[1], "the default name in \(language)")
}
check(Name.defaultName(localized: ""), "IsiX Screen Captures", "an empty translation")
check(Name.defaultName(localized: "IsiX 화면 캡처"), "IsiX Screen Captures", "a translation that would leave one word")

// The preference, read from the argument domain so nothing is stored.
let defaults = UserDefaults.standard
func preference(_ value: String?) {
    defaults.setVolatileDomain(value.map { [Name.defaultsKey: $0] } ?? [:], forName: UserDefaults.argumentDomain)
}
preference(nil)
check(Name.current(), "IsiX Screen Captures", "no preference")
preference("")
check(Name.current(), "IsiX Screen Captures", "an empty preference")
preference("   ")
check(Name.current(), "IsiX Screen Captures", "a preference of spaces")
preference("画像")
check(Name.current(), "IsiX Screen Captures", "a preference with nothing to write")
preference("Imagens-chave")
check(Name.current(), "Imagens-chave", "the preference")
preference(" Reconstruções ")
check(Name.current(), "Reconstrucoes", "a preference stored with accents")
preference(nil)

if failed { exit(1) }
print("PASS: names in ASCII within a Long String, the default name of \(catalogs.count) catalogs, and the preference")
'''

expected = {language: [value, LATIN.get(language, ENGLISH)] for language, value in defaults.items()}
for language, (value, name) in expected.items():
    if value.isascii() and name != value:
        failures.append(f'{language}: an ASCII default name must be kept as it is ({value})')
if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)

with tempfile.TemporaryDirectory(prefix='horos-capture-series-') as folder:
    main = Path(folder) / 'main.swift'
    main.write_text(DRIVER)
    binary = Path(folder) / 'check'
    built = subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(Path(folder) / 'modules'),
                            str(root / 'Horos/Sources/ScreenCaptureSeriesName.swift'), str(main), '-o', str(binary)],
                           capture_output=True, text=True)
    if built.returncode:
        print(built.stderr, file=sys.stderr)
        sys.exit(1)
    ran = subprocess.run([str(binary), json.dumps(expected)], capture_output=True, text=True)
    sys.stderr.write(ran.stderr)
    if ran.returncode:
        sys.exit(1)
    print(ran.stdout.strip())
print(f'PASS: the capture names and finds its series by the name in use, "IsiX SC" by default, and the field is bound in {len(folders)} nibs')
